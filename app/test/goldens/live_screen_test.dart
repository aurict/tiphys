// 10.2 Live screen: frame parsing, image ↔ screen transform (letterboxing, zoom), double-tap fit,
// two-finger scroll, auto quality, shortcut keys; viewer with a fake frame source (tap → event,
// keyboard bar, quality, on session end, stop) and screenshots (portrait, landscape, keyboard bar).
// 10.2 Phase C: header flags, codec selection/fallback, H.264 viewer with a fake native decoder (mimicking the
// tiphys/native method channel): texture in the same rect, tap mapping same as JPEG; screenshot (H.264).
// To update: flutter test test/goldens/live_screen_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/live_screen.dart';
import 'package:tiphys/features/desktop/live_stream.dart';
import 'package:tiphys/features/desktop/moonlight.dart';

import '../helpers/harness.dart';
import '../helpers/png.dart';

const _route = '/system/desktop/live?host=argo';

/// Synthetic desktop (480x270): top bar, two windows; marker dots in the corners.
Uint8List desktopPng({int w = 480, int h = 270}) => testPng(w, h, (x, y) {
      if (y < 12) return 0xFF1E1E2E; // top bar
      if (x >= 24 && x < 250 && y >= 30 && y < 240) return y < 44 ? 0xFF3B3F51 : 0xFF282A36; // terminal
      if (x >= 266 && x < 456 && y >= 30 && y < 200) return y < 44 ? 0xFFE0E0E6 : 0xFFF5F5F7; // browser
      if (x >= 278 && x < 380 && y >= 60 && y < 70) return 0xFFFF7139;
      if (x >= 40 && x < 160 && (y - 56) % 14 < 4 && y > 50 && y < 180) return 0xFF50FA7B; // text lines
      return 0xFF5B6EE1 + ((x + y) ~/ 60 % 2) * 0x00080808; // wallpaper
    });

Uint8List frameBytes(int seq, Uint8List img, int w, int h, {int flags = 0, double? ts}) {
  final head = ByteData(16)
    ..setUint32(0, seq)
    ..setUint8(0, flags)
    ..setFloat64(4, ts ?? 1000.0 * seq)
    ..setUint16(12, w)
    ..setUint16(14, h);
  return Uint8List.fromList([...head.buffer.asUint8List(), ...img]);
}

class FakeLive implements LiveConnection {
  FakeLive(this.query);
  final Map<String, String> query;
  final ctrl = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  int? code;
  bool closed = false;
  @override
  Stream<dynamic> get messages => ctrl.stream;
  @override
  void send(String text) => sent.add(Map<String, dynamic>.from(jsonDecode(text) as Map));
  @override
  Future<void> close([int? c]) async {
    closed = true;
    if (!ctrl.isClosed) await ctrl.close();
  }

  @override
  int? get closeCode => code;

  void hello({int w = 480, int h = 270, String source = 'wf-recorder', String? codec}) => ctrl.add(jsonEncode({
        'type': 'hello',
        'width': w,
        'height': h,
        'region': {'x': 0, 'y': 0, 'w': 1920, 'h': 1080},
        'fps': 12,
        'source': source,
        'codec': ?codec,
        'cursor': {'x': 240, 'y': 135},
      }));

  /// Agent closed it (e.g. 4401 session ended).
  Future<void> drop(int c) async {
    code = c;
    await ctrl.close();
  }

  List<Map<String, dynamic>> get input => [for (final m in sent) if (m['type'] != 'ping') m];
}

class _Live {
  final conns = <FakeLive>[];
  final tokens = <String>[];
  int asked = 0;
  Harness harness({bool video = false}) => Harness(extra: [
        if (video) liveVideoProvider.overrideWithValue(const NativeVideoBackend()),
        controlAuthProvider.overrideWithValue((_) async {
          asked++;
          return true;
        }),
        liveConnectorProvider.overrideWithValue((host, token, query) async {
          tokens.add(token);
          final c = FakeLive(query);
          conns.add(c);
          return c;
        }),
      ]);
}

/// A frame arrives and is decoded with the real decoder.
Future<void> _frames(WidgetTester tester, FakeLive c, {Uint8List? img}) async {
  c.hello();
  c.ctrl.add(frameBytes(1, img ?? desktopPng(), 480, 270));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Fake native H.264 decoder: mimics the tiphys/native method channel.
class _FakeDecoder {
  _FakeDecoder() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _handle);
  }
  static const _channel = MethodChannel('tiphys/native');
  final calls = <MethodCall>[];
  Map<String, Object?> support = {'available': true, 'hardware': true, 'name': 'c2.fake.avc.decoder', 'lowLatency': true};
  int status = 0;
  int nextId = 42;

  List<Map> get queued => [for (final c in calls) if (c.method == 'h264Queue') c.arguments as Map];
  Iterable<String> get methods => calls.map((c) => c.method);

  Future<Object?> _handle(MethodCall c) async {
    calls.add(c);
    return switch (c.method) {
      'h264Support' => support,
      'h264Create' => nextId++,
      'h264Queue' => status,
      'h264Stats' => {'fps': 29.7, 'latencyMs': 6.5, 'dropped': 0, 'needKey': false, 'failed': null},
      _ => null,
    };
  }

  void detach() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
}

/// First three messages of an H.264 stream: config (SPS+PPS), IDR, P-frame (ts ms).
void _h264(FakeLive c, {int w = 480, int h = 270}) {
  c.ctrl.add(frameBytes(1, Uint8List.fromList([0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2]), w, h, flags: 0x12, ts: 5000));
  c.ctrl.add(frameBytes(2, Uint8List.fromList([0, 0, 0, 1, 0x65, 0x88]), w, h, flags: 0x11, ts: 5000));
  c.ctrl.add(frameBytes(3, Uint8List.fromList([0, 0, 0, 1, 0x41, 0x9a]), w, h, flags: 0x10, ts: 5033.5));
}

Future<void> _pumpVideo(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

void main() {
  setUp(FakeAgent.calls.clear);

  group('mantık', () {
    test('kare başlığı', () {
      final f = LiveFrame.parse(frameBytes(7, Uint8List.fromList([0xff, 0xd8, 1]), 1152, 648))!;
      expect([f.seq, f.ts, f.width, f.height, f.image.length], [7, 7000.0, 1152, 648, 3]);
      expect(LiveFrame.parse(Uint8List(16)), isNull);
      expect(LiveFrame.parse(frameBytes(1, Uint8List(2), 0, 10)), isNull);
    });

    test('kare başlığı: H.264 bayrakları, 24 bit sıra; JPEG eski düzenle aynı', () {
      final cfg = LiveFrame.parse(frameBytes(0x123456, Uint8List.fromList([0, 0, 0, 1, 0x67]), 1280, 720, flags: 0x12))!;
      expect([cfg.seq, cfg.width, cfg.height, cfg.isH264, cfg.isConfig, cfg.isKey], [0x123456, 1280, 720, true, true, false]);
      final key = LiveFrame.parse(frameBytes(9, Uint8List.fromList([0, 0, 0, 1, 0x65]), 1280, 720, flags: 0x11))!;
      expect([key.isH264, key.isKey, key.isConfig, key.image.length], [true, true, false, 5]);
      final p = LiveFrame.parse(frameBytes(10, Uint8List(3), 2, 2, flags: 0x10))!;
      expect([p.isH264, p.isKey, p.isConfig], [true, false, false]);
      // An old agent's u32 sequence (top byte 0) is read as JPEG.
      final j = LiveFrame.parse(frameBytes(7, Uint8List.fromList([0xff, 0xd8, 1]), 1152, 648))!;
      expect([j.flags, j.seq, j.isH264], [0, 7, false]);
    });

    test('kodek seçimi ve geri düşme durumu', () {
      final c = CodecChooser();
      expect(c.useH264, isFalse); // no decoder
      c.support = const H264Support(available: true, hardware: false);
      expect(c.useH264, isFalse); // Auto requires hardware
      c.setPref(LiveCodec.h264);
      expect(c.useH264, isTrue); // software is fine when chosen manually
      c.support = const H264Support(available: true, hardware: true);
      c.setPref(LiveCodec.auto);
      expect(c.useH264, isTrue);
      c.awaitKey();
      expect(c.waitingKey, isTrue);
      c.gotKey();
      expect(c.waitingKey, isFalse);
      c.awaitKey();
      c.fail('noKey');
      expect([c.useH264, c.failure, c.waitingKey], [false, 'noKey', false]);
      c.fail('decoder');
      expect(c.failure, 'noKey'); // the first reason is kept
      c.setPref(LiveCodec.jpeg);
      expect([c.useH264, c.failure], [false, null]);
      c.setPref(LiveCodec.auto);
      expect(c.useH264, isTrue); // retried when the preference changes
      // H.264 tiers: bitrate in the query and in the quality message.
      expect(paramsFor(LiveQuality.medium, 0, h264: true).toJson(), {'fps': 24, 'scale': 0.6, 'q': 70, 'kbps': 2000});
      expect(paramsFor(LiveQuality.medium, 0).toJson(), {'fps': 12, 'scale': 0.6, 'q': 70});
      expect(liveLevelsH264.length, liveLevels.length); // auto mode has the same number of tiers
    });

    test('dikey ekranda kenar boşluklu sığdırma, ters dönüşüm, boşluğa dokunuş', () {
      // 16:9 image in a 390x700 area: fits the width, margins above/below.
      final v = LiveView(viewport: const Size(390, 700), image: const Size(1152, 648));
      expect(v.rect.left, 0);
      expect(v.rect.width, closeTo(390, 1e-9));
      expect(v.rect.height, closeTo(219.375, 1e-9));
      expect(v.rect.top, closeTo((700 - 219.375) / 2, 1e-9));
      expect(v.toImage(v.rect.center), const Offset(576, 324));
      expect(v.toImage(const Offset(10, 5)), isNull); // top margin
      expect(v.toImage(const Offset(10, 5), clamp: true)!.dy, 0);
      final p = v.toImage(Offset(97.5, v.rect.top + 54.84375))!;
      expect(p.dx, closeTo(288, 1e-6));
      expect(p.dy, closeTo(162, 1e-6));
      expect(v.toScreen(p).dx, closeTo(97.5, 1e-6));
      // Landscape: fits the height, margins on the sides.
      final h = LiveView(viewport: const Size(844, 340), image: const Size(1152, 648));
      expect(h.rect.height, closeTo(340, 1e-9));
      expect(h.rect.left, closeTo((844 - 340 * 1152 / 648) / 2, 1e-9));
      expect(h.toImage(const Offset(5, 100)), isNull);
      // Relative motion: 39 px on screen = 39 / (390/1152) px in the image.
      expect(v.deltaToImage(const Offset(39, 0)).dx, closeTo(115.2, 1e-9));
    });

    test('yakınlaştırma: odak noktası yerinde kalır, kaydırma sınırlı, dönüşüm tutarlı', () {
      final v = LiveView(viewport: const Size(400, 300), image: const Size(800, 600));
      final focal = const Offset(100, 75);
      final before = v.toImage(focal)!;
      final z = v.zoomed(2, focal);
      expect(z.zoom, 2);
      expect(z.toImage(focal)!.dx, closeTo(before.dx, 1e-9));
      expect(z.toImage(focal)!.dy, closeTo(before.dy, 1e-9));
      expect(z.toImage(const Offset(0, 0)), const Offset(100, 75)); // focus (200,150) stays put, top-left halfway
      // Panning off-screen: the image edge does not move inside the screen.
      final far = z.zoomed(2, focal, panBy: const Offset(500, 500));
      expect(far.rect.left, 0);
      expect(far.rect.top, 0);
      final far2 = z.zoomed(2, focal, panBy: const Offset(-2000, -2000));
      expect(far2.rect.right, closeTo(400, 1e-9));
      expect(far2.rect.bottom, closeTo(300, 1e-9));
      // Limits and zooming out.
      expect(v.zoomed(9, focal).zoom, 5);
      expect(z.zoomed(0.5, focal).pan, Offset.zero);
      // When a letterboxed image is zoomed, the margin stays centered on that axis (while the image is smaller than the
      // screen).
      final lb = LiveView(viewport: const Size(390, 700), image: const Size(1152, 648)).zoomed(1.5, const Offset(195, 350));
      expect(lb.rect.center.dy, closeTo(350, 1e-6));
    });

    test('çift tık oturtma ve iki parmak kaydırma', () {
      final s = TapSnapper();
      final t0 = DateTime(2026);
      expect(s.snap(const Offset(100, 100), const Offset(50, 50), t0), const Offset(50, 50));
      expect(s.snap(const Offset(110, 104), const Offset(55, 52), t0.add(const Duration(milliseconds: 200))), const Offset(50, 50));
      // A third tap starts a new series; a far or late tap does not fit.
      expect(s.snap(const Offset(110, 104), const Offset(55, 52), t0.add(const Duration(milliseconds: 300))), const Offset(55, 52));
      expect(s.snap(const Offset(200, 104), const Offset(99, 52), t0.add(const Duration(milliseconds: 350))), const Offset(99, 52));
      expect(s.snap(const Offset(200, 104), const Offset(98, 52), t0.add(const Duration(milliseconds: 900))), const Offset(98, 52));

      final a = ScrollAccumulator(step: 36);
      expect(a.add(const Offset(0, -20)), (0, 0));
      expect(a.add(const Offset(0, -20)), (0, 1)); // finger up → scroll down
      expect(a.add(const Offset(0, 80)), (0, -2));
      expect(a.add(const Offset(-40, 0)), (1, 0));
    });

    test('otomatik kalite: kötüleşince iner, uzun süre iyi giderse çıkar', () {
      final q = AutoQuality();
      expect(q.sample(dropped: 0, fps: 12, targetFps: 12, rttMs: 80), isNull);
      expect(q.sample(dropped: 4, fps: 6, targetFps: 12, rttMs: 80), 1);
      // waiting: no decision with 2 samples
      expect(q.sample(dropped: 4, fps: 6, targetFps: 12, rttMs: 80), isNull);
      expect(q.sample(dropped: 4, fps: 6, targetFps: 12, rttMs: 80), isNull);
      expect(q.sample(dropped: 0, fps: 8, targetFps: 8, rttMs: 600), 0); // slow network
      expect(q.sample(dropped: 9, fps: 2, targetFps: 5, rttMs: 900), isNull);
      expect(q.sample(dropped: 9, fps: 2, targetFps: 5, rttMs: 900), isNull);
      expect(q.sample(dropped: 9, fps: 2, targetFps: 5, rttMs: 900), isNull); // en altta
      int? up;
      for (var i = 0; i < 8; i++) {
        up = q.sample(dropped: 0, fps: 5, targetFps: 5, rttMs: 60);
      }
      expect(up, 1);
      // A static screen (fps 0) alone is not a degradation.
      expect(AutoQuality().sample(dropped: 0, fps: 0, targetFps: 12, rttMs: 50), isNull);
      expect(paramsFor(LiveQuality.high, 0), liveLevels[3]);
      expect(paramsFor(LiveQuality.auto, 1), liveLevels[1]);
    });

    test('kısayol harfi ve metin doğrulama', () {
      expect(chordKey('c', {'ctrl'}), 'C');
      expect(chordKey('7', {'alt'}), '7');
      expect(chordKey('c', {'shift'}), isNull);
      expect(chordKey('c', {}), isNull);
      expect(chordKey('ğ', {'ctrl'}), isNull);
      expect(liveTextOk('Çalış ğüş\n\t'), isTrue);
      expect(liveTextOk('a\u001bb'), isFalse);
      expect(liveTextOk(''), isFalse);
    });
  });

  group('görüntüleyici', () {
    testWidgets('oturum açılır, kare çizilir, dokunuşlar ve klavye olaya dönüşür, durdur', (tester) async {
      final live = _Live();
      final c = await live.harness().pump(tester, route: _route);
      expect(live.asked, 1);
      expect(live.tokens, ['tpc_fake']);
      expect(FakeAgent.calls.where((x) => x.$1 == 'POST').map((x) => x.$2), contains('/v1/desktop/control/session'));
      final conn = live.conns.single;
      expect(conn.query, {'fps': '12', 'scale': '0.6', 'q': '70'});
      await _frames(tester, conn);
      expect(tester.takeException(), isNull);
      expect(find.text('15:00'), findsOneWidget);

      // The image fits 390 width; a tap in the middle = the middle of the image (480x270 → 240,135).
      final canvas = tester.getRect(find.byType(LiveCanvas));
      await tester.tapAt(canvas.center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.last, {'type': 'click', 'button': 'left', 'x': 240.0, 'y': 135.0, 'w': 480, 'h': 270});
      // Taps on the margin are not sent.
      final n = conn.input.length;
      await tester.tapAt(canvas.bottomCenter - const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.length, n);
      // Long press = right click.
      await tester.longPressAt(canvas.center + const Offset(39, 0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.last, {'type': 'click', 'button': 'right', 'x': 288.0, 'y': 135.0, 'w': 480, 'h': 270});

      // One-finger drag = mouse drag (press, move, release).
      conn.sent.clear();
      final g = await tester.startGesture(canvas.center);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 4; i++) {
        await g.moveBy(const Offset(13, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      final types = [for (final m in conn.input) m['type']];
      expect(types.first, 'move');
      expect(types[1], 'down');
      expect(types.last, 'up');
      expect(conn.input.first, {'type': 'move', 'x': 240.0, 'y': 135.0, 'w': 480, 'h': 270});
      final lastMove = conn.input.lastWhere((m) => m['type'] == 'move');
      expect(lastMove['x'], closeTo(240 + 52 * 480 / 390, 0.2));

      // Two-finger vertical drag = wheel.
      conn.sent.clear();
      final a = await tester.startGesture(canvas.center - const Offset(30, 0), pointer: 7);
      final b = await tester.startGesture(canvas.center + const Offset(30, 0), pointer: 8);
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(0, -20));
        await b.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(conn.input.where((m) => m['type'] == 'scroll'), isNotEmpty);
      expect(conn.input.where((m) => m['type'] == 'scroll').every((m) => m['dy'] == 1 && m['dx'] == 0), isTrue);
      expect(conn.input.where((m) => m['type'] == 'click' || m['type'] == 'down'), isEmpty);

      // Pinch = zoom the image (no event to the PC); afterwards a tap in the middle is still the same content point.
      conn.sent.clear();
      final p1 = await tester.startGesture(canvas.center - const Offset(20, 0), pointer: 9);
      final p2 = await tester.startGesture(canvas.center + const Offset(20, 0), pointer: 10);
      for (var i = 0; i < 6; i++) {
        await p1.moveBy(const Offset(-10, 0));
        await p2.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await p1.up();
      await p2.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(conn.input, isEmpty);
      expect(find.byTooltip('Yakınlaştırmayı sıfırla'), findsOneWidget);
      await tester.tapAt(canvas.center + const Offset(39, 0));
      await tester.pump(const Duration(milliseconds: 500));
      // When zoomed in, 39 px on screen maps to fewer content pixels (zoom between 1–5).
      expect(conn.input.last['x'] as double, inExclusiveRange(240 + 48 / 5, 240 + 48 / 1.5));
      await tester.tap(find.byTooltip('Yakınlaştırmayı sıfırla'));
      await tester.pump();

      // Keyboard bar: key, one-shot modifier, preset shortcut, on-screen keyboard text and backspace.
      conn.sent.clear();
      await tester.tap(find.byTooltip('Esc'));
      await tester.tap(find.byTooltip('Ctrl'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tab'));
      await tester.ensureVisible(find.byTooltip('Sol ok')); // the key row is scrolled
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Sol ok'));
      await tester.tap(find.text('Kopyala'));
      await tester.tap(find.text('Pencere değiştir'));
      await tester.pump();
      final field = find.byType(TextField);
      await tester.enterText(field, '  Çağ');
      await tester.enterText(field, ' ');
      await tester.ensureVisible(find.byTooltip('Alt'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Alt'));
      await tester.pump();
      await tester.enterText(field, '  f');
      await tester.pump();
      expect(conn.input, [
        {'type': 'key', 'key': 'Esc', 'mods': []},
        {'type': 'key', 'key': 'Tab', 'mods': ['ctrl']},
        {'type': 'key', 'key': 'Left', 'mods': []},
        {'type': 'key', 'key': 'C', 'mods': ['ctrl']},
        {'type': 'key', 'key': 'Tab', 'mods': ['alt']},
        {'type': 'text', 'text': 'Çağ'},
        {'type': 'key', 'key': 'Backspace', 'mods': []},
        {'type': 'key', 'key': 'F', 'mods': ['alt']},
      ]);

      // Touchpad mode: one finger is relative, tap = click at the cursor position.
      conn.sent.clear();
      await tester.tap(find.byTooltip('Doğrudan dokunma (dokunmatik fareye geçmek için dokun)'));
      await tester.pump();
      final pad = await tester.startGesture(canvas.center + const Offset(0, 80));
      for (var i = 0; i < 3; i++) {
        await pad.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await pad.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(conn.input.every((m) => m['type'] == 'move'), isTrue);
      expect(conn.input.last['y'], 135.0); // no vertical movement, cursor stays put
      expect(conn.input.last['x'] as double, greaterThan(240));
      await tester.tapAt(canvas.center + const Offset(100, 60));
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.last, {'type': 'click', 'button': 'left'});

      // The quality choice goes to the agent.
      await tester.tap(find.text('Otomatik'));
      await settle(tester);
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, 'Düşük'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(conn.input.last, {'type': 'quality', 'fps': 8, 'scale': 0.45, 'q': 55});

      // End of the quality menu: high quality (Sunshine + Moonlight) sheet; the stream keeps running.
      await settle(tester);
      await tester.tap(find.byTooltip('Kalite: Düşük'));
      await settle(tester);
      await tester.tap(find.text('Yüksek kalite (Moonlight)'));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await settle(tester);
      }
      expect(find.byType(MoonlightSheet), findsOneWidget);
      expect(find.text('Sunshine çalışıyor'), findsOneWidget);
      await tester.tapAt(const Offset(20, 40)); // close the sheet
      await settle(tester);
      expect(find.byType(MoonlightSheet), findsNothing);

      // Stop: the session closes (the PC indicator goes away), the screen closes.
      await tester.tap(find.text('Durdur'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(FakeAgent.calls.where((x) => x.$1 == 'DELETE').map((x) => x.$2), ['/v1/desktop/control/session']);
      expect(c.read(controlProvider), isNull);
      expect(find.byType(LiveCanvas), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(conn.closed, isTrue);
      await _finish(tester);
    });

    testWidgets('oturum biterse uyarı; kopunca yeniden bağlanır; yedek kip uyarısı; arka planda akış durur', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final first = live.conns.single;
      await _frames(tester, first);
      // Network dropped (no close code): reconnects.
      await first.drop(1006);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bağlantı koptu, yeniden bağlanıyor…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(live.conns, hasLength(2));
      final second = live.conns[1];
      second.hello(source: 'grim');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('wf-recorder kurulu değil'), findsOneWidget);

      // Background: the stream closes; reconnects on return.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));
      expect(second.closed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      expect(live.conns, hasLength(3));

      // The agent closed the session (4401): warning + restart.
      final third = live.conns[2];
      third.hello();
      await tester.pump();
      await third.drop(4401);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Canlı ekran durdu'), findsOneWidget);
      expect(find.text('Kontrol oturumu bitti; yeniden dene.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(live.conns, hasLength(3)); // does not reconnect on its own
      await tester.tap(find.text('Yeniden başlat'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(live.asked, 2); // the lock was asked again
      expect(live.conns, hasLength(4));
      await _finish(tester);
    });

    testWidgets('Masaüstü ekranından: "Canlı ekran" düğmesi ve pencere menüsünde "Bu pencereyi göster"', (tester) async {
      FakeAgent.desktop = sampleDesktop();
      final live = _Live();
      final c = await live.harness().pump(tester, route: '/system/desktop?host=argo');
      await tester.tap(find.byTooltip('Canlı ekran'));
      await settle(tester);
      expect(live.conns.single.query.containsKey('window'), isFalse);
      expect(find.byType(LiveCanvas), findsOneWidget);
      await tester.tap(find.byTooltip('Geri'));
      await settle(tester);
      // When opened from the Desktop screen, the session does not close on exit (it lives with the Desktop screen).
      expect(c.read(controlProvider), isNotNull);
      expect(live.conns.single.closed, isTrue);
      await tester.longPress(find.text('Tiphys — Mozilla Firefox'));
      await settle(tester);
      await tester.tap(find.text('Bu pencereyi göster'));
      await settle(tester);
      expect(live.conns, hasLength(2));
      expect(live.conns[1].query['window'], '0x55d1a0');
      expect(live.asked, 1); // session already open: the lock is not asked again
      await _finish(tester);
    });

    testWidgets('oturum başka yerden bitince (akış duraklatılır) "Yeniden başlat" akışı yeniden açar', (tester) async {
      final live = _Live();
      final c = await live.harness().pump(tester, route: _route);
      await _frames(tester, live.conns.single);
      await c.read(controlProvider.notifier).stop(); // strip / timer / notification
      await tester.pump(const Duration(milliseconds: 100));
      expect(live.conns.single.closed, isTrue);
      await tester.tap(find.text('Yeniden başlat'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(live.asked, 2);
      expect(live.conns, hasLength(2)); // the paused stream starts with a new session
      expect(live.tokens.last, 'tpc_fake');
      live.conns[1].hello();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Yeniden başlat'), findsNothing);
      await _finish(tester);
    });

    testWidgets('sürükleme başlangıcı kareler gelip tuval yeniden kurulsa da parmağın ilk değdiği yer', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route);
      final conn = live.conns.single;
      await _frames(tester, conn);
      final canvas = tester.getRect(find.byType(LiveCanvas));
      conn.sent.clear();
      final g = await tester.startGesture(canvas.center);
      for (var i = 1; i <= 4; i++) {
        // An update from the stream (frame/stats) on every step: the canvas is rebuilt.
        conn.ctrl.add(jsonEncode({'type': 'stats', 'bytes': 1000}));
        await tester.pump(const Duration(milliseconds: 20));
        await g.moveBy(const Offset(13, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      final moves = conn.input.where((m) => m['type'] == 'move' || m['type'] == 'down').toList();
      expect(moves.first, {'type': 'move', 'x': 240.0, 'y': 135.0, 'w': 480, 'h': 270});
      expect(moves[1]['type'], 'down');
      await _finish(tester);
    });

    testWidgets('kabul edip hemen kapatan ajan: yeniden deneme beklemesi büyür, sağlam bağlantıdan sonra sıfırlanır', (tester) async {
      var now = DateTime(2026, 11, 14, 14, 5);
      final conns = <FakeLive>[];
      final c = LiveController(
        host: exampleProfile().host('argo')!,
        connector: (host, token, query) async {
          conns.add(FakeLive(query));
          return conns.last;
        },
        decoder: (b) async => throw UnsupportedError('kare yok'),
        token: 'tpc_x',
        clock: () => now,
      );
      Future<void> dropAfterHello() async {
        conns.last.hello();
        await tester.pump();
        await conns.last.drop(1011);
        await tester.pump();
      }

      await c.start();
      await dropAfterHello();
      await tester.pump(const Duration(seconds: 1));
      expect(conns, hasLength(2));
      await dropAfterHello();
      await tester.pump(const Duration(seconds: 1));
      expect(conns, hasLength(2)); // second attempt after 2 s
      await tester.pump(const Duration(seconds: 1));
      expect(conns, hasLength(3));
      // Stayed healthy for longer than 5 s: the delay is back to 1 s.
      conns.last.hello();
      await tester.pump();
      now = now.add(const Duration(seconds: 6));
      await conns.last.drop(1011);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(conns, hasLength(4));
      c.dispose();
    });
  });

  group('H.264', () {
    testWidgets('anlaşma, doku, anahtar kare, istatistik; dokunma eşlemesi JPEG ile aynı; çıkınca çözücü bırakılır', (tester) async {
      final dec = _FakeDecoder();
      addTearDown(dec.detach);
      final live = _Live();
      await live.harness(video: true).pump(tester, route: _route);
      final conn = live.conns.single;
      expect(conn.query, {'fps': '24', 'scale': '0.6', 'q': '70', 'kbps': '2000', 'codec': 'h264'});
      conn.hello(codec: 'h264');
      await tester.pump();
      expect(conn.sent.where((m) => m['type'] == 'keyframe'), hasLength(1)); // on (re)connect
      _h264(conn);
      await _pumpVideo(tester);
      expect(tester.takeException(), isNull);
      expect(dec.methods.where((m) => m == 'h264Create'), hasLength(1));
      expect((dec.calls.firstWhere((c) => c.method == 'h264Create').arguments as Map), {'width': 480, 'height': 270});
      expect([for (final q in dec.queued) (q['config'], q['key'], q['pts'], q['id'])], [(true, false, 0, 42), (false, true, 0, 42), (false, false, 33500, 42)]);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // The texture is in the same fitted rect where the JPEG is drawn: tap mapping is unchanged.
      final canvas = tester.getRect(find.byType(LiveCanvas));
      final view = LiveView(viewport: canvas.size, image: const Size(480, 270));
      expect(tester.getRect(find.byType(LiveVideoView)), view.rect.shift(canvas.topLeft));
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
      await tester.tapAt(canvas.center);
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.last, {'type': 'click', 'button': 'left', 'x': 240.0, 'y': 135.0, 'w': 480, 'h': 270});
      await tester.tapAt(canvas.bottomCenter - const Offset(0, 40)); // margin
      await tester.pump(const Duration(milliseconds: 500));
      expect(conn.input.last['x'], 240.0);

      // Stats: the native decoder's fps + the agent's bandwidth; no fallback after 3 s.
      conn.ctrl.add(jsonEncode({'type': 'stats', 'codec': 'h264', 'sent': 30, 'skipped': 0, 'dropped': 0, 'waited': 0, 'bytes': 125000}));
      await _pumpVideo(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('H.264 · 30 fps · 1.0 Mbit/sn'), findsOneWidget);
      expect(conn.sent.where((m) => m['codec'] == 'mjpeg'), isEmpty);

      // Quality menu: codec options; Low → H.264 tier (with bitrate).
      await tester.tap(find.text('Otomatik'));
      await settle(tester);
      expect(find.text('Kodek: Otomatik'), findsOneWidget);
      expect(find.text('Kodek: H.264'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, 'Düşük'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(conn.input.last, {'type': 'quality', 'fps': 15, 'scale': 0.6, 'q': 70, 'kbps': 1000});

      // If the decoder says "keyframe required", one is requested from the agent.
      dec.status = 1;
      conn.ctrl.add(frameBytes(4, Uint8List.fromList([0, 0, 0, 1, 0x41, 1]), 480, 270, flags: 0x10, ts: 5066));
      await _pumpVideo(tester);
      expect(conn.sent.where((m) => m['type'] == 'keyframe'), hasLength(2));
      dec.status = 0;

      // Codec: choosing JPEG requests MJPEG on the same connection, the decoder is released.
      await settle(tester);
      await tester.tap(find.byTooltip('Kalite: Düşük'));
      await settle(tester);
      await tester.tap(find.text('Kodek: JPEG'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(conn.input.last, {'type': 'quality', 'codec': 'mjpeg', 'fps': 8, 'scale': 0.45, 'q': 55});
      conn.hello(codec: 'mjpeg');
      await tester.pump();
      expect(dec.methods.where((m) => m == 'h264Dispose'), hasLength(1));
      expect(find.byType(Texture), findsNothing);
      await _frames(tester, conn);
      expect(find.textContaining('JPEG · '), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('geri düşme: 3 sn anahtar kare yok, çözücü hatası, ajan bildirimi, eski ajan', (tester) async {
      final dec = _FakeDecoder();
      addTearDown(dec.detach);
      final live = _Live();
      await live.harness(video: true).pump(tester, route: _route);
      final conn = live.conns.single;
      // 1) No keyframe arrives: JPEG is requested after 3 s, a warning is shown.
      conn.hello(codec: 'h264');
      await tester.pump(const Duration(seconds: 2));
      expect(conn.sent.where((m) => m['codec'] == 'mjpeg'), isEmpty);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(conn.input.last, {'type': 'quality', 'codec': 'mjpeg', 'fps': 12, 'scale': 0.6, 'q': 70});
      await tester.pump();
      expect(find.text("H.264 kullanılamadı, JPEG'e geçildi."), findsOneWidget);
      conn.hello(codec: 'mjpeg');
      await _frames(tester, conn);
      expect(tester.takeException(), isNull);
      expect(find.byType(Texture), findsNothing);
      await tester.pump(const Duration(seconds: 4)); // the warning disappears

      // 2) Retried when the preference goes back to H.264; if the decoder reports an unrecoverable error, JPEG.
      await tester.tap(find.text('Otomatik'));
      await settle(tester);
      await tester.tap(find.text('Kodek: H.264'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(conn.input.last, {'type': 'quality', 'codec': 'h264', 'fps': 24, 'scale': 0.6, 'q': 70, 'kbps': 2000});
      conn.hello(codec: 'h264');
      await tester.pump();
      // The old JPEG frame goes away: loading indicator until the first H.264 frame.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      dec.status = 2;
      _h264(conn);
      await _pumpVideo(tester);
      expect(conn.input.last, {'type': 'quality', 'codec': 'mjpeg', 'fps': 12, 'scale': 0.6, 'q': 70});
      expect(dec.methods.where((m) => m == 'h264Dispose'), hasLength(1));
      expect(find.byType(Texture), findsNothing);
      await tester.pump(const Duration(seconds: 4));

      // 3) The agent could not start H.264 (notice): the client sends no extra request, JPEG via the agent's hello.
      dec.status = 0;
      await settle(tester);
      await tester.tap(find.byTooltip('Kalite: Otomatik'));
      await settle(tester);
      await tester.tap(find.text('Kodek: Otomatik'));
      await tester.pump(const Duration(milliseconds: 400));
      conn.hello(codec: 'h264');
      _h264(conn);
      await _pumpVideo(tester);
      expect(find.byType(Texture), findsOneWidget);
      final sentBefore = conn.sent.length;
      conn.ctrl.add(jsonEncode({'type': 'notice', 'code': 'agent.desktop.codecFallback', 'codec': 'mjpeg'}));
      await _pumpVideo(tester);
      expect(find.byType(Texture), findsNothing);
      expect(conn.sent.skip(sentBefore).where((m) => m['type'] == 'quality'), isEmpty);
      await tester.pump(const Duration(seconds: 4));

      // 4) Old agent (doesn't know codecs): no codec in hello → JPEG, warning.
      await tester.tap(find.byTooltip('Kalite: Otomatik'));
      await settle(tester);
      await tester.tap(find.text('Kodek: H.264'));
      await tester.pump(const Duration(milliseconds: 400));
      conn.hello();
      await tester.pump();
      expect(find.text("H.264 kullanılamadı, JPEG'e geçildi."), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('ekran görüntüsü: H.264 akışı (doku testte boş çizilir), üstte kodek · fps · bit hızı', (tester) async {
      final dec = _FakeDecoder();
      addTearDown(dec.detach);
      final live = _Live();
      await live.harness(video: true).pump(tester, route: _route, dark: true);
      tester.view.physicalSize = const Size(844 * 2, 390 * 2);
      final conn = live.conns.single;
      conn.hello(codec: 'h264');
      _h264(conn);
      await _pumpVideo(tester);
      conn.ctrl.add(jsonEncode({'type': 'stats', 'codec': 'h264', 'sent': 30, 'bytes': 262144}));
      await _pumpVideo(tester);
      expect(tester.takeException(), isNull);
      await golden('png/live_h264_landscape_tr.png');
      await _finish(tester);
    });
  });

  group('ekran görüntüleri', () {
    testWidgets('dikey', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      await _frames(tester, live.conns.single);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await golden('png/live_portrait_tr.png');
      await _finish(tester);
    });

    testWidgets('yatay', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      tester.view.physicalSize = const Size(844 * 2, 390 * 2);
      await _frames(tester, live.conns.single);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await golden('png/live_landscape_tr.png');
      await _finish(tester);
    });

    testWidgets('klavye çubuğu: Ctrl basılı, dokunmatik fare kipi, yatay kaydırılmış tuşlar', (tester) async {
      final live = _Live();
      await live.harness().pump(tester, route: _route, dark: true);
      await _frames(tester, live.conns.single);
      await tester.tap(find.byTooltip('Ctrl'));
      await tester.tap(find.byTooltip('Doğrudan dokunma (dokunmatik fareye geçmek için dokun)'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(find.byTooltip('Esc'), const Offset(-200, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await golden('png/live_keys_tr.png');
      await _finish(tester);
    });
  });
}
