// Tiphys's Android native methods. Being registered as a plugin, they also exist in the background engine where
// notification buttons run (Flutter's own Clipboard channel only answers while the activity is open).
import 'package:flutter/services.dart';

class TiphysNative {
  static const _channel = MethodChannel('tiphys/native');

  /// Writes text to the phone clipboard (also while the app is in the background; Android only restricts reading).
  static Future<void> setClipboard(String text) => _channel.invokeMethod<void>('setClipboard', {'text': text});

  /// Writes text with the "sensitive" flag (ClipDescription EXTRA_IS_SENSITIVE) and the given clip label:
  /// Android 13+ hides the content in the clipboard preview and keyboard suggestions.
  static Future<void> setSensitiveClipboard(String text, String label) =>
      _channel.invokeMethod<void>('setSensitiveClipboard', {'text': text, 'label': label});

  /// Clears the clipboard if its clip has label [label] or the clipboard can't be read (background); true if cleared.
  static Future<bool> clearClipboardIfLabel(String label) async =>
      await _channel.invokeMethod<bool>('clearClipboardIfLabel', {'label': label}) ?? false;

  /// Is the clipboard clip flagged "sensitive" (e.g. a password from a password manager)? True if the description
  /// can't be read.
  static Future<bool> isClipboardSensitive() async => await _channel.invokeMethod<bool>('isClipboardSensitive') ?? true;

  /// Adds/removes FLAG_SECURE on the window: blocks screenshots, screen recording and the recent-apps preview.
  static Future<void> setSecureWindow(bool secure) => _channel.invokeMethod<void>('setSecureWindow', {'secure': secure});

  /// Is the package installed on the phone? Android 11+ only sees packages named in AndroidManifest `<queries>`.
  static Future<bool> isPackageInstalled(String package) async =>
      await _channel.invokeMethod<bool>('isPackageInstalled', {'package': package}) ?? false;

  /// Opens another app's activity: [component] (full class name, must be exported) or the package's
  /// launcher; [extras] String/bool only. False if the activity isn't found.
  static Future<bool> startActivity(String package, {String? component, Map<String, Object> extras = const {}}) async =>
      await _channel.invokeMethod<bool>('startActivity', {'package': package, 'component': component, 'extras': extras}) ?? false;

  // ---- live screen H.264 decoder (MediaCodec → Flutter texture) ----

  /// The phone's video/avc decoder: {available, hardware, name, lowLatency}.
  static Future<Map<String, Object?>> h264Support() async =>
      Map<String, Object?>.from(await _channel.invokeMethod<Map>('h264Support') ?? const {});

  /// Creates the decoder + texture; returns the texture id ([Texture.textureId]).
  static Future<int> h264Create(int width, int height) async =>
      (await _channel.invokeMethod<int>('h264Create', {'width': width, 'height': height}))!;

  /// Feeds a frame (Annex-B) to the decoder; returned status: 0 ok, 1 key frame needed, 2 unrecoverable error.
  static Future<int> h264Queue(int id, Uint8List data, {required int ptsUs, required bool key, required bool config, required int width, required int height}) async =>
      await _channel.invokeMethod<int>('h264Queue', {'id': id, 'data': data, 'pts': ptsUs, 'key': key, 'config': config, 'width': width, 'height': height}) ?? 2;

  /// Since the last call: {fps, latencyMs, dropped, needKey, failed}.
  static Future<Map<String, Object?>> h264Stats(int id) async =>
      Map<String, Object?>.from(await _channel.invokeMethod<Map>('h264Stats', {'id': id}) ?? const {});

  static Future<void> h264Dispose(int id) => _channel.invokeMethod<void>('h264Dispose', {'id': id});
}
