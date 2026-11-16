// 10.1 Desktop panel: models, screen (light/dark 390, narrow 320, control strip), control session (lock, token,
// closing on exit/in background), window actions, app launcher, states. Data is synthetic.
// To update: flutter test test/goldens/desktop_test.dart --update-goldens
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/desktop_screen.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/harness.dart';
import '../helpers/png.dart';

const _route = '/system/desktop?host=argo';

Future<void> _wait(WidgetTester tester) async {
  // Images are decoded in real time.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

/// Lock prompt (fake): how many times it was asked and its answer.
class _Auth {
  _Auth([this.ok = true]);
  final bool ok;
  int asked = 0;
  Harness harness({List<String> features = Harness.defaultAgentFeatures}) => Harness(
        agentFeatures: features,
        extra: [
          controlAuthProvider.overrideWithValue((_) async {
            asked++;
            return ok;
          }),
        ],
      );
}

List<String> _posts() => [for (final c in FakeAgent.calls.where((c) => c.$1 != 'GET')) '${c.$1} ${c.$2}${c.$3 is Map && (c.$3 as Map).isNotEmpty ? ' ${c.$3}' : ''}'];

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.headersByPath.clear();
    FakeAgent.desktop = sampleDesktop();
  });

  group('modeller', () {
    test('durum, taşıma hedefleri, uygulama grubu ve arama', () {
      final s = DesktopState(sampleDesktop());
      expect(s.activeWorkspace, 1);
      expect(s.windows.map((w) => (w.address, w.focused, w.visible, w.appId)).first, ('0x55d1a0', true, true, 'firefox'));
      expect(s.moveTargets, [1, 2, 3, 4]);
      expect(s.screenOn, isTrue);
      expect(DesktopState({'workspaces': [], 'windows': [], 'monitors': [{'dpms': false}]}).moveTargets, [1]);
      expect(DesktopState({'monitors': [{'dpms': false}]}).screenOn, isFalse);
      final apps = [for (final a in sampleApps) DesktopApp(a)];
      expect({for (final a in apps) a.id: a.group}, containsPair('org.gnome.Nautilus', 'utility'));
      expect(apps.firstWhere((a) => a.id == 'pavucontrol').group, 'media');
      expect(apps.firstWhere((a) => a.id == 'steam').group, 'game');
      expect(DesktopApp({'id': 'x', 'name': 'X', 'categories': ['Science']}).group, 'other');
      // Turkish upper/lower case: "İ" / "ı" / "I" match in search.
      final w = DesktopApp({'id': 'x', 'name': 'İNCE Işık', 'keywords': ['kelime']});
      expect([w.matches('ince'), w.matches('ışık'), w.matches('işik'), w.matches('KELİME'), w.matches('yok'), w.matches('  ')], [true, true, true, true, false, true]);
      expect(isRasterImage(iconPng(0xFF000000)), isTrue);
      expect(isRasterImage(windowPng(0xFF000000)), isTrue);
      expect(isRasterImage(Uint8List.fromList('<svg xmlns="x"/>'.codeUnits)), isFalse);
    });

    test('olay metni: kontrol oturumu açıldı / kapandı', () {
      final l = AppLocalizationsTr();
      expect(noticeText(l, 'control.started', {'device': 'Redmi', 'minutes': 15}), ('Uzaktan kontrol açıldı', 'Redmi · 15 dk'));
      expect(noticeText(l, 'control.ended', {'device': 'Redmi', 'seconds': 930, 'reason': 'expired'}), ('Uzaktan kontrol kapandı', 'Redmi · 16 dk · süre doldu'));
      expect(noticeText(l, 'control.ended', {'device': 'Redmi', 'seconds': 40, 'reason': 'stopped'})!.$2, 'Redmi · 40 sn');
    });
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('masaüstü paneli $v', (tester) async {
      await _Auth().harness().pump(tester, route: _route, dark: dark);
      await _wait(tester);
      expect(find.text('Masaüstü · argo (PC)'), findsOneWidget);
      expect(find.text('Tiphys — Mozilla Firefox'), findsOneWidget);
      expect(find.text('Gelen kutusu - Notlar - Obsidian'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await golden('png/desktop_${v}_tr.png');
      // Apps are further down.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
      await _wait(tester);
      expect(find.text('Visual Studio Code'), findsOneWidget);
      await golden('png/desktop_apps_${v}_tr.png');
      // Browsing does not open a session; no mutating request goes to the agent.
      expect(_posts(), isEmpty);
      await _finish(tester);
    });
  }

  testWidgets('dar ekran (320)', (tester) async {
    await _Auth().harness().pump(tester, route: _route);
    tester.view.physicalSize = const Size(320 * 2, 844 * 2);
    await _wait(tester);
    expect(tester.takeException(), isNull);
    await golden('png/desktop_narrow_light_tr.png');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await _wait(tester);
    expect(tester.takeException(), isNull);
    await golden('png/desktop_apps_narrow_light_tr.png');
    await _finish(tester);
  });

  testWidgets('dokun = öne getir: önce kilit, sonra belirteçle; şerit, uzat, durdur', (tester) async {
    final auth = _Auth();
    final c = await auth.harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('~/Desktop/tiphys — npm run build'));
    await _wait(tester);
    expect(auth.asked, 1);
    expect(_posts(), ['POST /v1/desktop/control/session {minutes: 15}', 'POST /v1/desktop/windows/0x55d1b0/focus']);
    expect(FakeAgent.headersByPath['/v1/desktop/windows/0x55d1b0/focus'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(find.text('Kontrol açık · 15:00'), findsOneWidget);
    await golden('png/desktop_control_light_tr.png');
    // With a session open, a second action does not ask for the lock again.
    await tester.tap(find.text('Tiphys — Mozilla Firefox'));
    await _wait(tester);
    expect(auth.asked, 1);
    await tester.tap(find.byTooltip('15 dk uzat'));
    await _wait(tester);
    expect(find.text('Kontrol açık · 30:00'), findsOneWidget);
    expect(FakeAgent.headersByPath['/v1/desktop/control/session/extend'], {'X-Tiphys-Control': 'tpc_fake'});
    await tester.tap(find.text('Durdur'));
    await _wait(tester);
    expect(find.textContaining('Kontrol açık'), findsNothing);
    expect(c.read(controlProvider), isNull);
    expect(_posts().last, 'DELETE /v1/desktop/control/session');
    await _finish(tester);
  });

  testWidgets('kilit iptal: istek gitmez', (tester) async {
    final auth = _Auth(false);
    await auth.harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Tiphys — Mozilla Firefox'));
    await _wait(tester);
    expect(auth.asked, 1);
    expect(_posts(), isEmpty);
    expect(find.textContaining('Kontrol açık'), findsNothing);
    await _finish(tester);
  });

  testWidgets('kaydır = kapat (onaylı), basılı tut = menü (taşı, tam ekran)', (tester) async {
    await _Auth().harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.drag(find.text('~/Desktop/tiphys — npm run build'), const Offset(-300, 0));
    await _wait(tester);
    expect(find.textContaining('kaydedilmemiş işler kaybolabilir'), findsOneWidget);
    await tester.tap(find.text('Pencereyi kapat'));
    await _wait(tester);
    expect(_posts(), ['POST /v1/desktop/control/session {minutes: 15}', 'POST /v1/desktop/windows/0x55d1b0/close']);
    // A cancelled swipe sends nothing.
    await tester.drag(find.text('Tiphys — Mozilla Firefox'), const Offset(300, 0));
    await _wait(tester);
    await tester.tap(find.text('Vazgeç'));
    await _wait(tester);
    expect(_posts(), hasLength(2));
    // Menu: move to workspace 4 (new).
    await tester.longPress(find.text('Ev'));
    await _wait(tester);
    expect(find.text('Çalışma alanına taşı'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, '4'));
    await _wait(tester);
    expect(_posts().last, 'POST /v1/desktop/windows/0x55d1c0/move-to-workspace {workspace: 4}');
    await tester.longPress(find.text('Ev'));
    await _wait(tester);
    await tester.tap(find.text('Tam ekran'));
    await _wait(tester);
    expect(_posts().last, 'POST /v1/desktop/windows/0x55d1c0/fullscreen');
    // Workspace strip.
    await tester.tap(find.bySemanticsLabel(RegExp('^Çalışma alanı 2,')));
    await _wait(tester);
    expect(_posts().last, 'POST /v1/desktop/workspace/2');
    await _finish(tester);
  });

  testWidgets('uygulama başlat: son kullanılanlara eklenir; arama ve kategori süzer', (tester) async {
    await _Auth().harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await _wait(tester);
    await tester.tap(find.text('GIMP'));
    await _wait(tester);
    expect(_posts().last, 'POST /v1/desktop/apps/gimp/launch');
    expect(find.text('GIMP açılıyor'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 250));
    await _wait(tester);
    expect(find.text('SON KULLANILANLAR'), findsOneWidget);
    expect(find.text('GIMP'), findsWidgets);
    await tester.tap(find.text('Ofis'));
    await _wait(tester);
    expect(find.text('Obsidian'), findsOneWidget);
    expect(find.text('Firefox'), findsNothing);
    expect(find.text('SON KULLANILANLAR'), findsNothing);
    await tester.tap(find.text('Tümü'));
    await tester.enterText(find.byType(TextField), 'kod');
    await _wait(tester);
    expect(find.text('Visual Studio Code'), findsOneWidget);
    expect(find.text('Blender'), findsNothing);
    await tester.enterText(find.byType(TextField), 'zzz');
    await _wait(tester);
    expect(find.text('Uygulama bulunamadı'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ekrandan çıkınca oturum kapanır; arka planda 60 sn sonra da', (tester) async {
    final c = await _Auth().harness().pump(tester, route: _route);
    await _wait(tester);
    await tester.tap(find.text('Tiphys — Mozilla Firefox'));
    await _wait(tester);
    expect(c.read(controlProvider)?.token, 'tpc_fake');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(c.read(controlProvider), isNotNull); // 60 s not yet elapsed
    await tester.pump(const Duration(seconds: 31));
    await _wait(tester);
    expect(c.read(controlProvider), isNull);
    expect(_posts().last, 'DELETE /v1/desktop/control/session');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _wait(tester);
    // Reopen, then leave the screen.
    await tester.tap(find.text('Tiphys — Mozilla Firefox'));
    await _wait(tester);
    expect(c.read(controlProvider), isNotNull);
    FakeAgent.calls.clear();
    c.router.go('/system');
    await _wait(tester);
    expect(c.read(controlProvider), isNull);
    expect(_posts(), ['DELETE /v1/desktop/control/session']);
    await _finish(tester);
  });

  testWidgets('durumlar: özellik kapalı, control kapalı, Hyprland yok, pencere yok, oturum bitti', (tester) async {
    final off = await _Auth().harness(features: ['system', 'power']).pump(tester, route: _route);
    await _wait(tester);
    expect(find.text('Bu ajanda masaüstü özelliği kapalı'), findsOneWidget);
    expect(find.textContaining('Ajan ayarları'), findsWidgets);
    off.dispose();
    await _finish(tester);

    final auth = _Auth();
    await auth.harness(features: ['system', 'desktop']).pump(tester, route: _route);
    await _wait(tester);
    expect(find.textContaining('Salt okunur'), findsOneWidget);
    await tester.tap(find.text('Tiphys — Mozilla Firefox'));
    await _wait(tester);
    expect(auth.asked, 0);
    expect(_posts(), isEmpty);
    expect(find.textContaining('Salt okunur'), findsNWidgets(2)); // note + warning
    await _finish(tester);

    FakeAgent.desktop = const AgentError('agent.desktop.noHyprland', {}, 503);
    await _Auth().harness().pump(tester, route: _route);
    await _wait(tester);
    expect(find.text('Hyprland çalışmıyor'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await _wait(tester);
    expect(find.text('Firefox'), findsOneWidget); // apps are still listed
    await _finish(tester);

    FakeAgent.desktop = {...sampleDesktop(), 'windows': <Map>[]};
    await _Auth().harness().pump(tester, route: _route);
    await _wait(tester);
    expect(find.text('Açık pencere yok'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ana ekran kısayolu: masaüstü özelliği varsa görünür ve paneli açar', (tester) async {
    final p = exampleProfile();
    final profile = p.copyWith(app: p.app.copyWith(layout: HomeLayout.grid, shortcuts: ['desktop', 'media']));
    await Harness(profile: profile).pump(tester);
    await _wait(tester);
    expect(find.text('Masaüstü'), findsOneWidget);
    await tester.tap(find.text('Masaüstü'));
    await _wait(tester);
    expect(find.byType(DesktopScreen), findsOneWidget);
    await _finish(tester);
    await Harness(profile: profile, agentFeatures: const ['system']).pump(tester);
    await _wait(tester);
    expect(find.text('Masaüstü'), findsNothing);
    await _finish(tester);
  });
}
