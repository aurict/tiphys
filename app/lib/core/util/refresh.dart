// Periyodik yenileme: uygulama arka plandayken (ekran kapalı, başka uygulama açık) sorgu atılmaz;
// süre o arada dolduysa uygulama öne gelince bir kez yenilenir. Pil ve mobil veri tasarrufu.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Uygulama görünür mü (resumed/inactive). İlk erişimde yaşam döngüsünü dinlemeye başlar.
final ValueNotifier<bool> appVisible = () {
  final v = ValueNotifier<bool>(true);
  AppLifecycleListener(
    onStateChange: (s) => v.value = s == AppLifecycleState.resumed || s == AppLifecycleState.inactive,
  );
  return v;
}();

/// [every] sonra [onDue]'yu çağırır; uygulama o an arka plandaysa öne gelene kadar bekletir.
/// Dönen fonksiyon zamanlayıcıyı iptal eder.
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

/// Sağlayıcıyı [every] aralıkla yeniler (yalnızca uygulama görünürken).
void autoRefresh(Ref ref, Duration every) => ref.onDispose(whenVisibleAfter(every, ref.invalidateSelf));
