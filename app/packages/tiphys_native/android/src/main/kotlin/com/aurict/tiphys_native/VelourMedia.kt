package com.aurict.tiphys_native

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

/**
 * Velour (the PC's music player) on the phone: a MediaSession with a MediaStyle notification, so the lock screen,
 * the notification shade and Bluetooth buttons control it, and the volume buttons while the remote screen is open.
 * Nothing plays on the phone; every button goes to Dart ("velourMedia" / "volumeKey" on the main engine's channel),
 * which sends the command to the PC. Lives as long as the app process.
 */
object VelourMedia {
    private const val CHANNEL_ID = "velour_media"
    private const val NOTIFICATION_ID = 7301
    const val ACTION = "com.aurict.tiphys_native.VELOUR_MEDIA"
    private const val ART_MAX_BYTES = 3 * 1024 * 1024

    /** The main engine's channel (set by the plugin instance that received the call). */
    @Volatile var channel: MethodChannel? = null

    /** Volume buttons go to Dart while the Velour remote screen is open. */
    @Volatile var captureVolumeKeys = false

    private val main = Handler(Looper.getMainLooper())
    private var session: MediaSession? = null
    private var last: Map<String, Any?> = emptyMap()
    private var artUrl: String? = null
    private var art: Bitmap? = null

    fun send(
        method: String,
        args: Map<String, Any?>
    ) {
        main.post { channel?.invokeMethod(method, args) }
    }

    /** From MainActivity.dispatchKeyEvent: true if the key was taken. */
    @JvmStatic
    fun onKey(event: KeyEvent): Boolean {
        if (!captureVolumeKeys || channel == null) return false
        val up = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP
        if (!up && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        if (event.action == KeyEvent.ACTION_DOWN) send("volumeKey", mapOf("up" to up))
        return true
    }

    fun update(
        context: Context,
        args: Map<String, Any?>
    ) {
        val ctx = context.applicationContext
        last = args
        val s =
            session ?: MediaSession(ctx, "Velour").also {
                it.setCallback(
                    object : MediaSession.Callback() {
                        override fun onPlay() = send("velourMedia", mapOf("action" to "play"))

                        override fun onPause() = send("velourMedia", mapOf("action" to "pause"))

                        override fun onSkipToNext() = send("velourMedia", mapOf("action" to "next"))

                        override fun onSkipToPrevious() = send("velourMedia", mapOf("action" to "prev"))

                        override fun onStop() = send("velourMedia", mapOf("action" to "stop"))

                        override fun onSeekTo(pos: Long) = send("velourMedia", mapOf("action" to "seek", "ms" to pos))
                    }
                )
                it.isActive = true
                session = it
            }
        val playing = args["playing"] == true
        val url = args["art"] as? String
        if (url != artUrl) {
            artUrl = url
            art = null
            if (url != null && url.startsWith("https://")) loadArt(ctx, url)
        }
        s.setMetadata(
            MediaMetadata
                .Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, args["title"] as? String ?: "")
                .putString(MediaMetadata.METADATA_KEY_ARTIST, args["artist"] as? String ?: "")
                .putString(MediaMetadata.METADATA_KEY_ALBUM, args["album"] as? String ?: "")
                .putLong(MediaMetadata.METADATA_KEY_DURATION, (args["durationMs"] as? Number)?.toLong() ?: 0L)
                .apply { art?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
                .build()
        )
        s.setPlaybackState(
            PlaybackState
                .Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_STOP
                ).setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    (args["positionMs"] as? Number)?.toLong() ?: 0L,
                    if (playing) 1f else 0f,
                    SystemClock.elapsedRealtime()
                ).build()
        )
        notify(ctx, s, args, playing)
    }

    fun stop(context: Context) {
        session?.release()
        session = null
        art = null
        artUrl = null
        (context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
    }

    private fun notify(
        ctx: Context,
        s: MediaSession,
        args: Map<String, Any?>,
        playing: Boolean
    ) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL_ID, args["channelName"] as? String ?: "Velour", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val labels = (args["labels"] as? Map<*, *>) ?: emptyMap<String, String>()

        fun pending(
            action: String,
            code: Int
        ) = PendingIntent.getBroadcast(
            ctx,
            code,
            Intent(ctx, VelourMediaReceiver::class.java).setAction(ACTION).putExtra("action", action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        fun action(
            icon: Int,
            key: String,
            code: Int
        ) = Notification.Action.Builder(Icon.createWithResource(ctx, icon), labels[key] as? String ?: key, pending(key, code)).build()
        val small = ctx.resources.getIdentifier("ic_notification", "drawable", ctx.packageName).takeIf { it != 0 } ?: android.R.drawable.ic_media_play
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val b =
            if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(ctx, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(ctx)
            }
        b
            .setSmallIcon(small)
            .setContentTitle(args["title"] as? String ?: "")
            .setContentText(args["artist"] as? String ?: "")
            .setSubText(args["host"] as? String)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(playing)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setDeleteIntent(pending("stop", 4))
            .addAction(action(android.R.drawable.ic_media_previous, "prev", 1))
            .addAction(
                if (playing) action(android.R.drawable.ic_media_pause, "pause", 2) else action(android.R.drawable.ic_media_play, "play", 2)
            ).addAction(action(android.R.drawable.ic_media_next, "next", 3))
            .setStyle(Notification.MediaStyle().setMediaSession(s.sessionToken).setShowActionsInCompactView(0, 1, 2))
        art?.let { b.setLargeIcon(it) }
        if (launch != null) {
            b.setContentIntent(PendingIntent.getActivity(ctx, 5, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        try {
            nm.notify(NOTIFICATION_ID, b.build())
        } catch (_: SecurityException) {
            // No notification permission: the session still serves Bluetooth buttons.
        }
    }

    /** Cover in the background (https only, ≤ 3 MB, scaled to ≤ 512 px), then the notification again. */
    private fun loadArt(
        ctx: Context,
        url: String
    ) {
        Thread {
            val bmp =
                try {
                    val c = URL(url).openConnection() as HttpURLConnection
                    c.connectTimeout = 8000
                    c.readTimeout = 8000
                    c.instanceFollowRedirects = true
                    val bytes = c.inputStream.use { it.readNBytesCompat(ART_MAX_BYTES) }
                    c.disconnect()
                    bytes?.let { decode(it) }
                } catch (_: Exception) {
                    null
                }
            main.post {
                if (bmp != null && artUrl == url && session != null) {
                    art = bmp
                    update(ctx, last)
                }
            }
        }.start()
    }

    private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        while (true) {
            val n = read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            if (out.size() > max) return null
        }
        return out.toByteArray()
    }

    private fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 512 && bounds.outHeight / (sample * 2) >= 512) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}

/** Notification buttons (and swiping it away) → Dart. */
class VelourMediaReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent
    ) {
        if (intent.action != VelourMedia.ACTION) return
        val action = intent.getStringExtra("action") ?: return
        if (action in setOf("play", "pause", "next", "prev", "stop")) VelourMedia.send("velourMedia", mapOf("action" to action))
    }
}
