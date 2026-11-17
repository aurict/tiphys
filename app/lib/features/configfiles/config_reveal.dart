// Revealed secret values (PLAN.md §13.3): they live in memory only, for [revealLifetime] after each reveal, and are
// dropped when the screen is left or the app goes to the background. Nothing here is written anywhere or logged.
import 'dart:async';

/// A revealed value is masked again after this long.
const revealLifetime = Duration(seconds: 30);

typedef RevealTimerFactory = Timer Function(Duration, void Function());

class RevealStore {
  RevealStore({required this.onChanged, RevealTimerFactory? timer, this.lifetime = revealLifetime}) : _timer = timer ?? Timer.new;

  /// Called after the set of revealed keys changed (the screen rebuilds and updates FLAG_SECURE).
  final void Function() onChanged;
  final RevealTimerFactory _timer;
  final Duration lifetime;

  final _values = <String, String>{};

  /// Key → the reveal it belongs to, so an older timer doesn't mask a value that was revealed again later.
  final _generation = <String, int>{};
  final _timers = <Timer>[];
  int _next = 0;

  bool get isEmpty => _values.isEmpty;
  Iterable<String> get keys => _values.keys;
  bool isRevealed(String key) => _values.containsKey(key);
  String? valueOf(String key) => _values[key];

  /// Shows [values] and masks them again after [lifetime].
  void reveal(Map<String, String> values) {
    if (values.isEmpty) return;
    final gen = ++_next;
    for (final MapEntry(:key, :value) in values.entries) {
      _values[key] = value;
      _generation[key] = gen;
    }
    _timers.add(_timer(lifetime, () {
      var changed = false;
      for (final k in values.keys) {
        if (_generation[k] == gen) {
          _values.remove(k);
          _generation.remove(k);
          changed = true;
        }
      }
      if (changed) onChanged();
    }));
    onChanged();
  }

  void hide(String key) {
    if (_values.remove(key) != null) {
      _generation.remove(key);
      onChanged();
    }
  }

  /// Drops every value (screen left, app in the background, locked).
  void clear({bool notify = true}) {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    final had = _values.isNotEmpty;
    _values.clear();
    _generation.clear();
    if (had && notify) onChanged();
  }
}
