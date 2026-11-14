import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/util/refresh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uygulama görünürken süre dolunca yeniler', () {
    fakeAsync((f) {
      appVisible.value = true;
      var n = 0;
      whenVisibleAfter(const Duration(seconds: 5), () => n++);
      f.elapse(const Duration(seconds: 4));
      expect(n, 0);
      f.elapse(const Duration(seconds: 1));
      expect(n, 1);
    });
  });

  test('arka plandayken bekler, öne gelince bir kez yeniler', () {
    fakeAsync((f) {
      appVisible.value = false;
      var n = 0;
      whenVisibleAfter(const Duration(seconds: 5), () => n++);
      f.elapse(const Duration(minutes: 10));
      expect(n, 0);
      appVisible.value = true;
      expect(n, 1);
      appVisible.value = false;
      appVisible.value = true;
      expect(n, 1);
    });
  });

  test('iptal edilince hiç çağırmaz', () {
    fakeAsync((f) {
      appVisible.value = false;
      var n = 0;
      final cancel = whenVisibleAfter(const Duration(seconds: 5), () => n++);
      f.elapse(const Duration(seconds: 6));
      cancel();
      appVisible.value = true;
      expect(n, 0);
    });
  });
}
