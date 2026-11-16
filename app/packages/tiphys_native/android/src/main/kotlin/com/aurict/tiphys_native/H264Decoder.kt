package com.aurict.tiphys_native

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The live screen's H.264 decoder (10.2 Stage C): hardware MediaCodec, output straight into a Flutter texture
 * (TextureRegistry.SurfaceProducer; the recommended API since Flutter 3.27, onSurfaceAvailable/onSurfaceCleanup).
 *
 * Flow: Dart passes every WS frame via [queue]. The config (SPS+PPS, Annex-B) precedes every key frame;
 * if it changed (resolution etc.) the decoder is rebuilt. All decoder work runs on a single HandlerThread, in
 * MediaCodec's asynchronous (callback) mode; the platform thread only enqueues work and returns the last status:
 * [OK], [NEED_KEY] (waiting for a key frame: Dart requests one from the agent), [FAILED] (unrecoverable: Dart
 * falls back to MJPEG).
 *
 * Low latency: KEY_LOW_LATENCY (API 30+, if supported), KEY_PRIORITY=0 (real-time), high
 * KEY_OPERATING_RATE, Qualcomm's low-latency/output-order keys (unknown keys are ignored). If this
 * "tuned" format is rejected in configure, it is retried with a plain format. The encoder has no B-frames, so no
 * reordering. If the decoder falls behind (pending > [MAX_PENDING]) the queue and decoder are flushed and a key
 * frame is awaited; frames coming out later than 300 ms are not drawn. When the surface goes away (background)
 * the decoder is released synchronously; when the surface returns it is rebuilt and a key frame is awaited.
 */
internal class H264Decoder(
    private val producer: TextureRegistry.SurfaceProducer,
    private val codecName: String?,
) {
    companion object {
        private const val TAG = "TiphysH264"
        const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        const val OK = 0
        const val NEED_KEY = 1
        const val FAILED = 2
        private const val MAX_PENDING = 8
        private const val STALE_NS = 300_000_000L

        /** The phone's video/avc decoder: a hardware one is preferred if available. */
        fun pick(): MediaCodecInfo? {
            var best: MediaCodecInfo? = null
            for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (info.isEncoder || info.supportedTypes.none { it.equals(MIME, ignoreCase = true) }) continue
                if (best == null || (isHardware(info) && !isHardware(best))) best = info
            }
            return best
        }

        fun isHardware(info: MediaCodecInfo): Boolean {
            if (Build.VERSION.SDK_INT >= 29) return info.isHardwareAccelerated && !info.isSoftwareOnly
            val n = info.name.lowercase()
            return !(n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.contains(".sw."))
        }

        fun lowLatency(info: MediaCodecInfo): Boolean =
            Build.VERSION.SDK_INT >= 30 &&
                try {
                    info.getCapabilitiesForType(MIME).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                } catch (e: IllegalArgumentException) {
                    false
                }

        fun support(): Map<String, Any?> {
            val info = try {
                pick()
            } catch (e: RuntimeException) {
                null
            }
            return mapOf(
                "available" to (info != null),
                "hardware" to (info?.let { isHardware(it) } ?: false),
                "name" to info?.name,
                "lowLatency" to (info?.let { lowLatency(it) } ?: false),
            )
        }

        /** SPS (7) and PPS (8) from the Annex-B config, including the start code (csd-0 / csd-1). */
        fun splitConfig(data: ByteArray): Pair<ByteArray, ByteArray>? {
            val starts = ArrayList<Int>()
            var i = 0
            while (i + 2 < data.size) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                    starts.add(if (i > 0 && data[i - 1].toInt() == 0) i - 1 else i)
                    i += 3
                } else {
                    i++
                }
            }
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            for ((k, s) in starts.withIndex()) {
                val end = if (k + 1 < starts.size) starts[k + 1] else data.size
                var h = s
                while (h < end && data[h].toInt() == 0) h++
                h++ // 01
                if (h >= end) continue
                when (data[h].toInt() and 0x1f) {
                    7 -> sps = data.copyOfRange(s, end)
                    8 -> pps = data.copyOfRange(s, end)
                }
            }
            return if (sps != null && pps != null) Pair(sps, pps) else null
        }
    }

    private class Frame(val data: ByteArray, val ptsUs: Long, val key: Boolean, val at: Long)

    private val thread = HandlerThread("tiphys-h264").also { it.start() }
    private val handler = Handler(thread.looper)
    private val lowLatencySupported = try {
        pick()?.let { lowLatency(it) } ?: false
    } catch (e: RuntimeException) {
        false
    }

    // Only on the decoder thread:
    private var codec: MediaCodec? = null
    private var config: ByteArray? = null
    private var width = 0
    private var height = 0
    private var surfaceReady = true
    private val pending = ArrayDeque<Frame>()
    private val inputs = ArrayDeque<Int>()
    private val queuedAt = HashMap<Long, Long>()

    // Read from any thread:
    @Volatile private var needKey = true
    @Volatile private var failed: String? = null
    @Volatile private var released = false

    private val statsLock = Any()
    private var decoded = 0
    private var dropped = 0
    private var latencyNs = 0L
    private var statsSince = System.nanoTime()

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
            if (c !== codec) return
            inputs.add(index)
            try {
                feed()
            } catch (e: RuntimeException) {
                recover(e)
            }
        }

        override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (c !== codec) return
            val at = queuedAt.remove(info.presentationTimeUs)
            val now = System.nanoTime()
            val late = at != null && now - at > STALE_NS
            try {
                c.releaseOutputBuffer(index, !late && surfaceReady)
            } catch (e: IllegalStateException) {
                return
            }
            synchronized(statsLock) {
                if (late) {
                    dropped++
                } else {
                    decoded++
                    if (at != null) latencyNs += now - at
                }
            }
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "çıktı biçimi: $format")
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            if (c !== codec) return
            Log.w(TAG, "çözücü hatası (geçici=${e.isTransient}, kurtarılabilir=${e.isRecoverable})", e)
            if (e.isTransient) return
            releaseCodec()
            needKey = true
            // Without a surface (background) the rebuild is left to onSurfaceAvailable.
            if (!e.isRecoverable) failed = e.diagnosticInfo ?: "codec" else if (surfaceReady) startCodec()
        }
    }

    init {
        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    handler.post {
                        if (released) return@post
                        surfaceReady = true
                        val c = codec
                        if (c != null) {
                            try {
                                c.setOutputSurface(producer.surface)
                            } catch (e: RuntimeException) {
                                releaseCodec()
                                startCodec()
                            }
                        } else if (config != null) {
                            startCodec()
                        }
                        needKey = true
                    }
                }

                override fun onSurfaceCleanup() {
                    // The surface is destroyed after this call: the decoder must stop writing to it (synchronously).
                    onCodecThread {
                        surfaceReady = false
                        releaseCodec()
                        needKey = true
                    }
                }
            },
        )
    }

    /** From the platform thread: enqueues the frame to the decoder, returns the last known status. */
    fun queue(data: ByteArray, ptsUs: Long, key: Boolean, isConfig: Boolean, w: Int, h: Int): Int {
        if (released || failed != null) return FAILED
        val f = Frame(data, ptsUs, key, System.nanoTime())
        handler.post {
            try {
                if (isConfig) onConfig(data, w, h) else onFrame(f)
            } catch (e: RuntimeException) {
                recover(e)
            }
        }
        return if (failed != null) FAILED else if (needKey && !key && !isConfig) NEED_KEY else OK
    }

    fun stats(): Map<String, Any?> {
        synchronized(statsLock) {
            val now = System.nanoTime()
            val secs = (now - statsSince) / 1e9
            val m = mapOf(
                "fps" to if (secs > 0) decoded / secs else 0.0,
                "latencyMs" to if (decoded > 0) latencyNs / decoded / 1e6 else null,
                "dropped" to dropped,
                "needKey" to needKey,
                "failed" to failed,
            )
            decoded = 0
            dropped = 0
            latencyNs = 0
            statsSince = now
            return m
        }
    }

    /** Releases the decoder and the texture (waits at most 500 ms). */
    fun release() {
        if (released) return
        released = true
        producer.setCallback(null)
        onCodecThread {
            releaseCodec()
            pending.clear()
        }
        thread.quitSafely()
        producer.release()
    }

    // ---- decoder thread ----

    private fun onCodecThread(block: () -> Unit) {
        val done = CountDownLatch(1)
        handler.post {
            try {
                block()
            } finally {
                done.countDown()
            }
        }
        done.await(500, TimeUnit.MILLISECONDS)
    }

    /** MediaCodec state error (CodecException / IllegalStateException): the decoder is rebuilt, a key frame is awaited. */
    private fun recover(e: RuntimeException) {
        Log.w(TAG, "kare işlenemedi", e)
        releaseCodec()
        needKey = true
        if (config != null && surfaceReady) startCodec()
    }

    private fun onConfig(data: ByteArray, w: Int, h: Int) {
        if (codec != null && data.contentEquals(config) && w == width && h == height) return
        config = data
        width = w
        height = h
        releaseCodec()
        producer.setSize(w, h)
        needKey = true
        if (surfaceReady) startCodec()
    }

    private fun onFrame(f: Frame) {
        if (codec == null || (needKey && !f.key)) {
            synchronized(statsLock) { dropped++ }
            if (codec == null) needKey = true
            return
        }
        if (f.key) {
            needKey = false
            // Once a key frame arrives, older pending ones are useless.
            if (pending.isNotEmpty()) {
                synchronized(statsLock) { dropped += pending.size }
                pending.clear()
            }
        } else if (pending.size >= MAX_PENDING) {
            // The decoder can't keep up: drop everything and resume from the next key frame.
            synchronized(statsLock) { dropped += pending.size + 1 }
            pending.clear()
            flushCodec()
            needKey = true
            return
        }
        pending.add(f)
        feed()
    }

    private fun feed() {
        val c = codec ?: return
        while (pending.isNotEmpty() && inputs.isNotEmpty()) {
            val f = pending.poll() ?: break
            val index = inputs.poll() ?: break
            val buf = c.getInputBuffer(index)
            if (buf == null || f.data.size > buf.capacity()) {
                c.queueInputBuffer(index, 0, 0, f.ptsUs, 0)
                synchronized(statsLock) { dropped++ }
                needKey = true
                continue
            }
            buf.clear()
            buf.put(f.data)
            queuedAt[f.ptsUs] = f.at
            c.queueInputBuffer(index, 0, f.data.size, f.ptsUs, 0)
        }
    }

    private fun format(tuned: Boolean, sps: ByteArray, pps: ByteArray): MediaFormat {
        val f = MediaFormat.createVideoFormat(MIME, width, height)
        f.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        f.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height * 3 / 2, 512 * 1024))
        if (tuned) {
            if (Build.VERSION.SDK_INT >= 30 && lowLatencySupported) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            f.setInteger(MediaFormat.KEY_PRIORITY, 0)
            f.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            f.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
        }
        return f
    }

    private fun startCodec() {
        val cfg = config ?: return
        val (sps, pps) = splitConfig(cfg) ?: run {
            failed = "config"
            return
        }
        val c = try {
            if (codecName != null) MediaCodec.createByCodecName(codecName) else MediaCodec.createDecoderByType(MIME)
        } catch (e: Exception) {
            Log.w(TAG, "çözücü oluşturulamadı", e)
            failed = "create"
            return
        }
        for (tuned in listOf(true, false)) {
            try {
                c.setCallback(callback, handler)
                c.configure(format(tuned, sps, pps), producer.surface, null, 0)
                c.start()
                codec = c
                inputs.clear()
                queuedAt.clear()
                pending.clear()
                needKey = true
                return
            } catch (e: Exception) {
                Log.w(TAG, "configure başarısız (ayarlı=$tuned)", e)
                try {
                    c.reset()
                } catch (e2: Exception) {
                    break
                }
            }
        }
        try {
            c.release()
        } catch (e: Exception) {
        }
        failed = "configure"
    }

    private fun flushCodec() {
        val c = codec ?: return
        try {
            c.flush()
            inputs.clear()
            queuedAt.clear()
            c.start() // required after flush in asynchronous mode
        } catch (e: RuntimeException) {
            releaseCodec()
            startCodec()
        }
    }

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        try {
            c.stop()
        } catch (e: RuntimeException) {
        }
        try {
            c.release()
        } catch (e: RuntimeException) {
        }
        inputs.clear()
        queuedAt.clear()
        pending.clear()
    }
}
