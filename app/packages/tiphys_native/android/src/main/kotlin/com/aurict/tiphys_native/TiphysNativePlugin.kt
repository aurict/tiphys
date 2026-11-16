package com.aurict.tiphys_native

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/** Tiphys's native methods: attached to every Flutter engine (including the notification buttons' background engine). */
class TiphysNativePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: Activity? = null

    /** The live screen's H.264 decoders (by texture id). */
    private val decoders = HashMap<Long, H264Decoder>()

    /** If the activity is recreated (rotation etc.) the secure window flag is reapplied. */
    private var secure = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "tiphys/native")
        channel.setMethodCallHandler(this)
    }

    private fun clipboard() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun applySecure() {
        val a = activity ?: return
        a.runOnUiThread {
            if (secure) {
                a.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "setClipboard" -> {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("args", "text gerekli", null)
                    return
                }
                // Writing to the clipboard is allowed in the background too (Android 10+ restricts only reading to the foreground).
                clipboard().setPrimaryClip(ClipData.newPlainText("Tiphys", text))
                result.success(null)
            }
            "setSensitiveClipboard" -> {
                val text = call.argument<String>("text")
                val label = call.argument<String>("label")
                if (text == null || label == null) {
                    result.error("args", "text ve label gerekli", null)
                    return
                }
                val clip = ClipData.newPlainText(label, text)
                // API 33+ constant ClipDescription.EXTRA_IS_SENSITIVE; the same string is recommended for older versions.
                val key = if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE"
                clip.description.extras = PersistableBundle().apply { putBoolean(key, true) }
                clipboard().setPrimaryClip(clip)
                result.success(null)
            }
            "clearClipboardIfLabel" -> {
                val label = call.argument<String>("label")
                if (label == null) {
                    result.error("args", "label gerekli", null)
                    return
                }
                val cm = clipboard()
                // Android 10+ withholds the description in the background (null): clear in that case too (so no password stays on the clipboard).
                val current = cm.primaryClipDescription?.label?.toString()
                if (current == null || current == label) {
                    if (Build.VERSION.SDK_INT >= 28) {
                        cm.clearPrimaryClip()
                    } else {
                        cm.setPrimaryClip(ClipData.newPlainText("", ""))
                    }
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            "isClipboardSensitive" -> {
                // Password managers (Bitwarden, KeePassDX…) flag the passwords they copy with EXTRA_IS_SENSITIVE.
                // If the description can't be read (background, restriction) err on the safe side: treat as sensitive, don't send to the PC.
                val d = clipboard().primaryClipDescription
                if (d == null) {
                    result.success(true)
                    return
                }
                val extras = d.extras
                val key = if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE"
                result.success(extras?.getBoolean(key, false) == true || extras?.getBoolean("android.content.extra.IS_SENSITIVE", false) == true)
            }
            "setSecureWindow" -> {
                secure = call.argument<Boolean>("secure") ?: false
                applySecure()
                result.success(null)
            }
            "isPackageInstalled" -> {
                // Android 11+ only sees packages named in the app's AndroidManifest <queries> section.
                val pkg = call.argument<String>("package")
                if (pkg == null) {
                    result.error("args", "package gerekli", null)
                    return
                }
                val installed =
                    try {
                        if (Build.VERSION.SDK_INT >= 33) {
                            context.packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            context.packageManager.getPackageInfo(pkg, 0)
                        }
                        true
                    } catch (e: PackageManager.NameNotFoundException) {
                        false
                    }
                result.success(installed)
            }
            "startActivity" -> {
                // Another app's activity: if [component] is given, that class (must be exported), otherwise the package's
                // launcher. Extras are String/Boolean only. False if there is no activity.
                val pkg = call.argument<String>("package")
                if (pkg == null) {
                    result.error("args", "package gerekli", null)
                    return
                }
                val component = call.argument<String>("component")
                val extras = call.argument<Map<String, Any>>("extras") ?: emptyMap()
                val intent =
                    if (component != null) {
                        Intent().setClassName(pkg, component)
                    } else {
                        context.packageManager.getLaunchIntentForPackage(pkg)
                    }
                if (intent == null) {
                    result.success(false)
                    return
                }
                for ((k, v) in extras) {
                    when (v) {
                        is String -> intent.putExtra(k, v)
                        is Boolean -> intent.putExtra(k, v)
                    }
                }
                val a = activity
                if (a == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    (a ?: context).startActivity(intent)
                    result.success(true)
                } catch (e: android.content.ActivityNotFoundException) {
                    result.success(false)
                } catch (e: SecurityException) {
                    result.success(false)
                }
            }
            "h264Support" -> result.success(H264Decoder.support())
            "h264Create" -> {
                // Hardware decoder (software if none) + the texture's surface; the size is updated on the first config.
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                val info = try {
                    H264Decoder.pick()
                } catch (e: RuntimeException) {
                    null
                }
                if (info == null || w <= 0 || h <= 0) {
                    result.error("h264", "çözücü yok", null)
                    return
                }
                val producer = textures.createSurfaceProducer()
                producer.setSize(w, h)
                val d = H264Decoder(producer, info.name)
                decoders[producer.id()] = d
                result.success(producer.id())
            }
            "h264Queue" -> {
                val d = decoders[call.argument<Number>("id")?.toLong() ?: -1L]
                val data = call.argument<ByteArray>("data")
                if (d == null || data == null) {
                    result.success(H264Decoder.FAILED)
                    return
                }
                result.success(
                    d.queue(
                        data,
                        call.argument<Number>("pts")?.toLong() ?: 0L,
                        call.argument<Boolean>("key") ?: false,
                        call.argument<Boolean>("config") ?: false,
                        call.argument<Int>("width") ?: 0,
                        call.argument<Int>("height") ?: 0,
                    ),
                )
            }
            "h264Stats" -> result.success(decoders[call.argument<Number>("id")?.toLong() ?: -1L]?.stats())
            "h264Dispose" -> {
                decoders.remove(call.argument<Number>("id")?.toLong() ?: -1L)?.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (secure) applySecure()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        for (d in decoders.values) d.release()
        decoders.clear()
    }
}
