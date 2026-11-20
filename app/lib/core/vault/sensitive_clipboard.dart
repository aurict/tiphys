// Copying passwords from the vault: written to Android with the "sensitive" flag (ClipDescription EXTRA_IS_SENSITIVE;
// hidden in keyboard suggestions and the clipboard preview), and cleared after [clearAfter] if the clipboard still
// holds this copy.
// Since the clipboard can't be read in the background, ownership is checked locally via a random clip label per copy.
// When the vault locks, a pending copy is cleared immediately. The value lives only in memory (never on disk).
import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:tiphys_native/tiphys_native.dart';

import '../platform.dart';

/// Local clipboard operations (tests supply a fake).
abstract interface class SensitiveClipboardNative {
  Future<void> setSensitive(String text, String label);

  /// Clears the clipboard if it holds the copy labeled [label] (or its content can't be read); true if cleared.
  Future<bool> clearIfLabel(String label);
}

/// Android: the native plugin (sensitive flag, clip label). Elsewhere (iOS, desktops; no tiphys_native there) a
/// plain copy, cleared later only if the clipboard still holds exactly that text.
class TiphysSensitiveClipboard implements SensitiveClipboardNative {
  TiphysSensitiveClipboard();
  final _plain = <String, String>{};

  @override
  Future<void> setSensitive(String text, String label) async {
    if (hasTiphysNative) return TiphysNative.setSensitiveClipboard(text, label);
    _plain
      ..clear()
      ..[label] = text;
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<bool> clearIfLabel(String label) async {
    if (hasTiphysNative) return TiphysNative.clearClipboardIfLabel(label);
    final text = _plain.remove(label);
    if (text == null || (await Clipboard.getData(Clipboard.kTextPlain))?.text != text) return false;
    await Clipboard.setData(const ClipboardData(text: ''));
    return true;
  }
}

typedef TimerFactory = Timer Function(Duration, void Function());

class SensitiveClipboard {
  SensitiveClipboard(this.native, {TimerFactory? timer, Random? random, this.clearAfter = const Duration(seconds: 30)})
      : _timer = timer ?? Timer.new,
        _random = random ?? Random.secure();
  final SensitiveClipboardNative native;
  final TimerFactory _timer;
  final Random _random;
  final Duration clearAfter;

  Timer? _pending;
  String? _label;
  String? _value;

  /// Is there a copy currently waiting to be cleared?
  bool get pending => _pending != null;

  /// Is this text the value copied from the vault and not yet cleared? (Clipboard sync doesn't send it to the PC.)
  bool isGuarded(String text) => _value != null && _value == text;

  Future<void> copy(String text) async {
    _pending?.cancel();
    final label = 'Tiphys-${List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _label = label;
    _value = text;
    await native.setSensitive(text, label);
    _pending = _timer(clearAfter, () => unawaited(_clear(label)));
  }

  /// Clears the pending copy immediately (when the vault locks).
  Future<void> clearNow() async {
    final label = _label;
    if (label != null) await _clear(label);
  }

  Future<void> _clear(String label) async {
    if (_label != label) return; // there's a newer copy; its timer clears it
    _pending?.cancel();
    _pending = null;
    _label = null;
    _value = null;
    try {
      await native.clearIfLabel(label);
    } catch (_) {
      // No plugin (desktop test) or clipboard inaccessible: nothing else to do.
    }
  }
}
