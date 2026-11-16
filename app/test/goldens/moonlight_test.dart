// 10.2 Phase B: high quality (Sunshine + Moonlight) page — Sunshine not installed (commands, copy), stopped
// (start: lock + session token), Moonlight not on the phone (store), ready (open Moonlight: shortcut to the paired
// PC), no-web-login warning, PIN page (validation, wrong PIN, pairing), "control" disabled, Sunshine entry in agent
// settings. Screenshots in light theme. To update: flutter test test/goldens/moonlight_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/moonlight.dart';

import '../helpers/harness.dart';

const _route = '/system/desktop?host=argo';
const _entry = 'Yüksek kalite (Moonlight)';

class _FakeMoonlight implements MoonlightApp {
  _FakeMoonlight(this.present);
  bool present;
  final opened = <(String?, String?)>[];
  @override
  Future<bool> installed() async => present;
  @override
  Future<bool> open({String? uuid, String? name}) async {
    opened.add((uuid, name));
    return true;
  }
}

class _Setup {
  _Setup({bool moonlight = true}) : app = _FakeMoonlight(moonlight);
  final _FakeMoonlight app;
  int asked = 0;
  Harness harness({List<String> features = Harness.defaultAgentFeatures}) => Harness(
        agentFeatures: features,
        extra: [
          controlAuthProvider.overrideWithValue((_) async {
            asked++;
            return true;
          }),
          moonlightProvider.overrideWithValue(app),
        ],
      );
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

/// Desktop › Tools › "Yüksek kalite (Moonlight)".
Future<void> _openSheet(WidgetTester tester, Harness h) async {
  await h.pump(tester, route: _route);
  await _wait(tester);
  await tester.scrollUntilVisible(find.text(_entry), 300, scrollable: find.byType(Scrollable).first);
  await _wait(tester);
  await tester.tap(find.text(_entry));
  await _wait(tester);
  expect(find.byType(MoonlightSheet), findsOneWidget);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

List<String> _posts() => [
      for (final c in FakeAgent.calls.where((c) => c.$1 != 'GET' && c.$2.startsWith('/v1/desktop/')))
        '${c.$1} ${c.$2}${c.$3 is Map && (c.$3 as Map).isNotEmpty ? ' ${c.$3}' : ''}',
    ];

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.headersByPath.clear();
    FakeAgent.desktop = sampleDesktop();
    FakeAgent.sunshine = sampleSunshine();
  });

  test('aşama: kurulu değil → durmuş → Moonlight yok → hazır', () {
    SunshineStatus s(Map<String, dynamic> j) => SunshineStatus(j);
    expect(moonlightStage(s(sampleSunshine(installed: false, running: false)), true), MoonlightStage.notInstalled);
    expect(moonlightStage(s(sampleSunshine(running: false)), true), MoonlightStage.stopped);
    expect(moonlightStage(s(sampleSunshine()), false), MoonlightStage.noMoonlight);
    expect(moonlightStage(s(sampleSunshine()), true), MoonlightStage.ready);
    // Setup commands: trixie package, wlr capture, NVENC, user unit.
    expect(sunshineInstallCommands, contains('debiantrixie_amd64.deb'));
    expect(sunshineInstallCommands, contains('sudo apt install ./sunshine.deb'));
    expect(sunshineInstallCommands, contains(r"capture = wlr\nencoder = nvenc"));
    expect(sunshineInstallCommands, contains('systemctl --user start app-dev.lizardbyte.app.Sunshine'));
  });

  testWidgets('Sunshine kurulu değil: komutlar ve kopyala', (tester) async {
    FakeAgent.sunshine = sampleSunshine(installed: false, running: false);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _openSheet(tester, _Setup().harness());
    expect(find.text('Sunshine kurulu değil'), findsOneWidget);
    expect(find.textContaining('sudo apt install ./sunshine.deb'), findsOneWidget);
    expect(find.text("Moonlight'ı aç"), findsNothing);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_not_installed_light_tr.png');
    await tester.ensureVisible(find.text('Komutları kopyala'));
    await tester.tap(find.text('Komutları kopyala'));
    await _wait(tester);
    expect(copied, sunshineInstallCommands);
    expect(_posts(), isEmpty);
    await _finish(tester);
  });

  testWidgets('Sunshine durmuş: başlat (kilit + belirteç) → hazır', (tester) async {
    FakeAgent.sunshine = sampleSunshine(running: false);
    final setup = _Setup();
    await _openSheet(tester, setup.harness());
    expect(find.text('Sunshine durmuş'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_stopped_light_tr.png');
    await tester.tap(find.text("Sunshine'ı başlat"));
    await _wait(tester);
    expect(setup.asked, 1);
    expect(_posts(), ['POST /v1/desktop/control/session {minutes: 15}', 'POST /v1/desktop/sunshine/start']);
    expect(FakeAgent.headersByPath['/v1/desktop/sunshine/start'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(find.text("Moonlight'ı aç"), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('"control" kapalı: başlat yalnız açıklama gösterir', (tester) async {
    FakeAgent.sunshine = sampleSunshine(running: false);
    final setup = _Setup();
    await _openSheet(tester, setup.harness(features: [...Harness.defaultAgentFeatures]..remove('control')));
    await tester.tap(find.text("Sunshine'ı başlat"));
    await _wait(tester);
    expect(setup.asked, 0);
    expect(_posts(), isEmpty);
    expect(find.textContaining('"Uzaktan kontrol"ü aç'), findsWidgets);
    await _finish(tester);
  });

  testWidgets('Moonlight telefonda yok: Google Play / F-Droid', (tester) async {
    await _openSheet(tester, _Setup(moonlight: false).harness());
    expect(find.text('Moonlight bu telefonda yok'), findsOneWidget);
    expect(find.text('Google Play'), findsOneWidget);
    expect(find.text('F-Droid'), findsOneWidget);
    expect(find.textContaining('Yakalama wlr · kodlayıcı nvenc · eşleşmiş cihaz 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_missing_light_tr.png');
    await _finish(tester);
  });

  testWidgets('hazır: Moonlight eşleşmiş PC kısayoluyla açılır; durdur', (tester) async {
    final setup = _Setup();
    await _openSheet(tester, setup.harness());
    expect(find.text('Sunshine çalışıyor'), findsOneWidget);
    expect(find.text('2026.914.233613-1+debiantrixie · Yakalama wlr · kodlayıcı nvenc · eşleşmiş cihaz 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_ready_light_tr.png');
    await tester.tap(find.text("Moonlight'ı aç"));
    await _wait(tester);
    expect(setup.app.opened, [('7A3D5D8C-1F2B-4C3D-9E8F-0123456789AB', 'argo')]);
    await tester.ensureVisible(find.text("Sunshine'ı durdur"));
    await tester.tap(find.text("Sunshine'ı durdur"));
    await _wait(tester);
    expect(_posts().last, 'POST /v1/desktop/sunshine/stop');
    expect(find.text('Sunshine durmuş'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('hazır ama web girişi yok: uyarı, PIN düğmesi kapalı; eşleşmiş PC yoksa Moonlight ana ekranı', (tester) async {
    FakeAgent.sunshine = sampleSunshine(api: 'noCredentials');
    final setup = _Setup();
    await _openSheet(tester, setup.harness());
    expect(find.textContaining('Ajan ayarlarına gir'), findsOneWidget);
    expect(find.text('Ajan ayarları'), findsOneWidget);
    final pin = tester.widget<OutlinedButton>(find.ancestor(of: find.text("Moonlight PIN'ini gir"), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(pin.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_no_credentials_light_tr.png');
    await tester.tap(find.text("Moonlight'ı aç"));
    await _wait(tester);
    expect(setup.app.opened, [(null, null)]);
    await _finish(tester);
  });

  testWidgets('PIN sayfası: 4 hane, yanlış PIN hatası, doğru PIN eşleşir (belirteçle)', (tester) async {
    final setup = _Setup();
    await _openSheet(tester, setup.harness());
    await tester.tap(find.text("Moonlight PIN'ini gir"));
    await _wait(tester);
    expect(find.byType(MoonlightPinSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_pin_light_tr.png');

    final field = find.descendant(of: find.byType(MoonlightPinSheet), matching: find.byType(TextField));
    await tester.enterText(field, '12');
    await tester.tap(find.text('Eşleştir'));
    await _wait(tester);
    expect(find.text('PIN 4 haneli olmalı.'), findsOneWidget);
    expect(setup.asked, 0);
    // Non-digits and extra digits cannot be entered.
    await tester.enterText(field, '12ab567');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '1256');

    await tester.enterText(field, '1234');
    await tester.tap(find.text('Eşleştir'));
    await _wait(tester);
    expect(find.textContaining('PIN yanlış'), findsOneWidget);
    expect(setup.asked, 1);
    expect(tester.takeException(), isNull);
    await golden('png/moonlight_pin_error_light_tr.png');

    await tester.enterText(field, '4821');
    await tester.tap(find.text('Eşleştir'));
    await _wait(tester);
    expect(find.byType(MoonlightPinSheet), findsNothing);
    expect(find.text('Eşleşti. Moonlight artık bağlanabilir.'), findsOneWidget);
    expect(_posts(), [
      'POST /v1/desktop/control/session {minutes: 15}',
      'POST /v1/desktop/sunshine/pair {pin: 1234}',
      'POST /v1/desktop/sunshine/pair {pin: 4821}',
    ]);
    expect(FakeAgent.headersByPath['/v1/desktop/sunshine/pair'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(setup.asked, 1); // the lock is not asked again while the session is open
    await _finish(tester);
  });

  testWidgets('ajan ayarları: Sunshine girişi (desktop açıkken) PATCH ile gider', (tester) async {
    await Harness().pump(tester, route: '/settings/hosts/agent?id=atlas');
    await _wait(tester);
    const label = 'SUNSHİNE (MOONLİGHT)'; // section header in Turkish uppercase
    expect(find.text(label), findsNothing); // hidden while "desktop" is disabled
    await tester.tap(find.text('Masaüstü (pano, ekran görüntüsü)'));
    await _wait(tester);
    await tester.ensureVisible(find.text(label));
    await _wait(tester);
    final card = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == 'FieldCard'));
    await tester.enterText(find.descendant(of: card, matching: find.widgetWithText(TextFormField, 'Kullanıcı')), 'sunny');
    await tester.enterText(find.descendant(of: card, matching: find.widgetWithText(TextFormField, 'Şifre')), 'gizli');
    await tester.tap(find.text('Kaydet'));
    await _wait(tester);
    final patch = FakeAgent.calls.lastWhere((x) => x.$1 == 'PATCH');
    expect((patch.$3 as Map)['sunshine'], {'username': 'sunny', 'password': 'gizli'});
    await _finish(tester);
  });
}
