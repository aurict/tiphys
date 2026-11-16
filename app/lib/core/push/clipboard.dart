// Notification side of clipboard sync (PC → phone) and the "last seen clipboard" record.
// Text copied on the PC arrives from the agent as a "clipboard.pc" notification; the "Copy" button writes it to the
// phone's clipboard without opening the app (in the background engine, via the native plugin).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:tiphys_native/tiphys_native.dart';

/// Id of the notification's "Copy" button.
const actionCopyClipboard = 'clipboard-copy';

/// Short preview shown in the notification: single line, at most [max] characters.
String clipboardPreview(String text, {int max = 80}) {
  final s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

/// Notification payload (JSON {clipboard: text}) → text.
String? clipboardPayloadText(String? payload) {
  if (payload == null || !payload.startsWith('{')) return null;
  try {
    final t = (jsonDecode(payload) as Map)['clipboard'];
    return t is String ? t : null;
  } catch (_) {
    return null;
  }
}

/// Salted SHA-256 hash of the text last seen on the phone clipboard (or copied from the PC). The text itself is
/// never written to disk. The file is re-read on every read: the background "Copy" button updates it too.
class ClipboardSeen {
  ClipboardSeen(this.dir);

  /// App documents folder; if null, in memory only (tests).
  final Future<String?> Function() dir;
  String? _salt;
  String? _hash;

  Future<File?> _file() async {
    final d = await dir();
    return d == null ? null : File('$d/clipboard-seen.json');
  }

  Future<void> _load() async {
    final f = await _file();
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map;
      _salt = j['salt'] as String?;
      _hash = j['hash'] as String?;
    } catch (_) {
      // Corrupt file: start over with a new salt.
    }
  }

  Future<String> _digest(String text) async {
    _salt ??= base64Encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
    final h = await Sha256().hash(utf8.encode('$_salt\u0000$text'));
    return base64Encode(h.bytes);
  }

  /// Is the text different from the last seen one?
  Future<bool> isNew(String text) async {
    await _load();
    return await _digest(text) != _hash;
  }

  Future<void> mark(String text) async {
    await _load();
    _hash = await _digest(text);
    final f = await _file();
    await f?.writeAsString(jsonEncode({'salt': _salt, 'hash': _hash}));
  }
}

/// "Copy" button: writes the payload text to the clipboard and marks it as seen (so it isn't sent back to the PC
/// on returning to the foreground). True on success.
Future<bool> copyFromNotification(String? payload, {Future<void> Function(String text)? setClipboard, ClipboardSeen? seen}) async {
  final text = clipboardPayloadText(payload);
  if (text == null) return false;
  try {
    await (setClipboard ?? TiphysNative.setClipboard)(text);
  } catch (_) {
    return false;
  }
  try {
    await seen?.mark(text);
  } catch (_) {
    // Record couldn't be written: worst case the text is sent back to the PC once (the agent doesn't rewrite the same
    // text).
  }
  return true;
}
