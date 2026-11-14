import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/system/wake.dart';

void main() {
  test('sihirli paket: 6×FF + 16×MAC', () {
    final p = magicPacket('02:00:00:00:00:01');
    expect(p.length, 102);
    expect(p.sublist(0, 6), List.filled(6, 0xFF));
    expect(p.sublist(96), [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]);
    expect(() => magicPacket('xx'), throwsArgumentError);
  });

  test('UDP ile gerçekten gönderilir (yerel dinleyici yakalar)', () async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
      final rx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final got = <List<int>>[];
      rx.listen((e) {
        final d = rx.receive();
        if (d != null) got.add(d.data);
      });
      await sendLocalMagicPacket('02-00-00-00-00-01', broadcast: '127.0.0.1', port: rx.port);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      rx.close();
      expect(got, isNotEmpty);
      expect(got.first.length, 102);
    });
  });
}
