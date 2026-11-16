// Periodic refresh: no queries while the app is in the background (screen off, another app open);
// if the interval elapsed meanwhile, it refreshes once on return to the foreground. Saves battery and mobile data.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app is visible (resumed/inactive). Starts listening to the lifecycle on first access.
final ValueNotifier<bool> appVisible = () {
  final v = ValueNotifier<bool>(true);
  AppLifecycleListener(
    onStateChange: (s) => v.value = s == AppLifecycleState.resumed || s == AppLifecycleState.inactive,
  );
  return v;
}();

/// Calls [onDue] after [every]; if the app is in the background at that moment, waits until it comes to the foreground.
/// The returned function cancels the timer.
VoidCallback whenVisibleAfter(Duration every, VoidCallback onDue) {
  void Function()? waiting;
  final t = Timer(every, () {
    if (appVisible.value) return onDue();
    waiting = () {
      if (!appVisible.value) return;
      appVisible.removeListener(waiting!);
      waiting = null;
      onDue();
    };
    appVisible.addListener(waiting!);
  });
  return () {
    t.cancel();
    if (waiting != null) appVisible.removeListener(waiting!);
  };
}

/// Refreshes the provider every [every] (only while the app is visible).
void autoRefresh(Ref ref, Duration every) => ref.onDispose(whenVisibleAfter(every, ref.invalidateSelf));
