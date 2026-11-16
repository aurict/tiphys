// 10.3 Claude uses the PC: "use the PC" on the new-session page (only with desktop + control enabled; the lock is
// asked again and it starts with a control token), live screen strip above the chat (fake frames, low quality), Stop
// (interrupts Claude + closes control), reopen after control ends (new link), approval card, screenshot thumbnail
// (tap = enlarge) and screenshots (light/dark, 390x844).
// To update: flutter test test/goldens/pc_chat_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/features/claude/pc_ongoing.dart';
import 'package:tiphys/features/desktop/desktop_data.dart';
import 'package:tiphys/features/desktop/live_stream.dart';

import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';
import 'live_screen_test.dart' show FakeLive, desktopPng, frameBytes;

/// Open control session (until 14:20; test clock 14:05 → "15:00").
class _OpenControl extends ControlController {
  @override
  ControlSession? build() => ControlSession(hostId: 'argo', token: 'tpc_fake', expiresAt: DateTime(2026, 11, 14, 14, 20));
}

/// Session that looks expired locally (14:04; test clock 14:05).
class _StaleControl extends ControlController {
  @override
  ControlSession? build() => ControlSession(hostId: 'argo', token: 'tpc_fake', expiresAt: DateTime(2026, 11, 14, 14, 4));
}

class _Pc {
  _Pc({this.open = true, this.features = Harness.defaultAgentFeatures});
  final bool open;
  final List<String> features;
  final conns = <FakeLive>[];
  int asked = 0;
  late final Harness h = harness();
  Harness harness() => Harness(agentFeatures: features, extra: [
        if (open) controlProvider.overrideWith(_OpenControl.new),
        controlAuthProvider.overrideWithValue((_) async {
          asked++;
          return true;
        }),
        liveConnectorProvider.overrideWithValue((host, token, query) async {
          final c = FakeLive(query);
          conns.add(c);
          return c;
        }),
      ]);
}

/// A frame arrives on the strip (with the real decoder).
Future<void> _frames(WidgetTester tester, FakeLive c) async {
  c.hello();
  c.ctrl.add(frameBytes(1, desktopPng(), 480, 270));
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  debugDisableShadows = true;
}

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.headersByPath.clear();
    FakeAgent.pcControl = true;
  });

  for (final dark in [false, true]) {
    testWidgets('PC sohbeti ${dark ? 'koyu' : 'açık'}: canlı şerit, süre/Durdur, ekran görüntüsü, onay kartı', (tester) async {
      final pc = _Pc();
      await pc.harness().pump(tester, route: '/claude/session/pc1', dark: dark);
      expect(pc.conns, hasLength(1));
      // The strip runs at low quality (4 fps, ×0.35), with the control token.
      expect(pc.conns.single.query, {'fps': '4', 'scale': '0.35', 'q': '45'});
      await _frames(tester, pc.conns.single);
      // Let the thumbnail load.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      expect(find.text('Kontrol açık · 15:00'), findsOneWidget);
      expect(find.text('Claude onay istiyor'), findsOneWidget);
      expect(find.text('Sitenin konum iznini kabul edeyim mi?'), findsWidgets); // tool card + approval card
      expect(find.bySemanticsLabel('Ekran görüntüsü'), findsWidgets);
      expect(find.byTooltip('Slash komutları'), findsNothing); // no slash commands in a PC session
      await golden('png/claude_pc_chat_${dark ? 'dark' : 'light'}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('Durdur: Claude kesilir ve kontrol kapanır; kontrol bitince yeniden aç → yeni bağ', (tester) async {
    final pc = _Pc();
    final c = await pc.harness().pump(tester, route: '/claude/session/pc1');
    await _frames(tester, pc.conns.single);
    await tester.tap(find.text('Durdur'));
    await settle(tester);
    expect(FakeAgent.calls.any((x) => x.$1 == 'POST' && x.$2 == '/v1/claude/sessions/pc1/interrupt'), isTrue);
    expect(FakeAgent.calls.any((x) => x.$1 == 'DELETE' && x.$2 == '/v1/desktop/control/session'), isTrue);
    expect(c.read(controlProvider), isNull);
    expect(pc.conns.single.closed, isTrue); // strip stream closed
    expect(find.text('Kontrol kapandı · Claude PC\'yi kullanamaz'), findsOneWidget);

    // Reopen: the lock is asked again, a new session opens, the chat connects with this token.
    await tester.tap(find.text('Kontrolü yeniden aç'));
    await settle(tester);
    expect(pc.asked, 1);
    expect(FakeAgent.calls.where((x) => x.$1 == 'POST' && x.$2 == '/v1/desktop/control/session'), hasLength(1));
    expect(FakeAgent.headersByPath['/v1/claude/sessions/pc1/control'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(find.text('Kontrolü yeniden aç'), findsNothing);
    expect(pc.conns, hasLength(2)); // strip reconnected
    await _finish(tester);
  });

  testWidgets('ajan kontrolü kapalı bildiriyorsa (süre doldu): durum kartı, şerit yok', (tester) async {
    FakeAgent.pcControl = false;
    final pc = _Pc();
    await pc.harness().pump(tester, route: '/claude/session/pc1');
    expect(pc.conns, isEmpty);
    expect(find.text('Kontrol süresi doldu · Claude durduruldu'), findsWidgets); // card + divider in the chat
    expect(find.text('Kontrolü yeniden aç'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('11.5 araç kartları: kısa insan metni + hedef (sekme, sayfa, bileşen), sekme kapatma onayı gerekçeyle', (tester) async {
    final pc = _Pc();
    await pc.harness().pump(tester, route: '/claude/session/pc2');
    await _frames(tester, pc.conns.single);
    await settle(tester);
    expect(find.text('Sekme açtı'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('Sayfayı okudu'), findsOneWidget);
    expect(find.text('Yarın yağmur bekleniyor'), findsOneWidget);
    expect(find.text('Bileşenleri okudu'), findsOneWidget);
    expect(find.text('Untitled 1 - Mousepad'), findsOneWidget);
    expect(find.text('Alana yazdı'), findsOneWidget);
    expect(find.text('Düğmeye bastı'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Sekme kapattı'), findsOneWidget);
    expect(find.text('#41, #42'), findsOneWidget);
    expect(find.text('Firefox sekmeleri kapatılacak (2): "Yarın yağmur bekleniyor", "Gelen kutusu"'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await golden('png/claude_pc_tools_light_tr.png');
    await _finish(tester);
  });

  testWidgets('onay kartı İzin ver → karar ajana; ekran görüntüsü dokununca büyür', (tester) async {
    final pc = _Pc();
    await pc.harness().pump(tester, route: '/claude/session/pc1');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    expect(FakeAgent.calls.any((x) => x.$2 == '/v1/claude/shots/0123456789abcdef'), isTrue);
    await tester.tap(find.text('İzin ver'));
    await settle(tester);
    final post = FakeAgent.calls.lastWhere((x) => x.$1 == 'POST' && x.$2 == '/v1/claude/sessions/pc1/permissions/p1');
    expect(post.$3, {'allow': true});
    await tester.tap(find.bySemanticsLabel('Ekran görüntüsü').first);
    await settle(tester);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Kapat'));
    await settle(tester);
    expect(find.byType(InteractiveViewer), findsNothing);
    await _finish(tester);
  });

  testWidgets('yeni oturum: PC\'yi kullan kilidi yeniden sorar, belirteçle başlatır', (tester) async {
    final pc = _Pc(open: false);
    final c = await pc.harness().pump(tester, route: '/claude');
    await tester.tap(find.byTooltip('Yeni Claude oturumu'));
    await settle(tester);
    await tester.tap(find.text('PC\'yi kullan'));
    await settle(tester);
    expect(find.text('Kilidi aç ve başlat'), findsOneWidget);
    expect(find.text('İzin modu'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Hava durumuna bak');
    await tester.tap(find.text('Kilidi aç ve başlat'));
    await settle(tester);
    expect(pc.asked, 1);
    final post = FakeAgent.calls.lastWhere((x) => x.$1 == 'POST' && x.$2 == '/v1/claude/sessions');
    expect(post.$3, containsPair('kind', 'pc'));
    expect((post.$3 as Map)['prompt'], 'Hava durumuna bak');
    expect((post.$3 as Map).containsKey('permissionMode'), isFalse);
    expect(FakeAgent.headersByPath['/v1/claude/sessions'], {'X-Tiphys-Control': 'tpc_fake'});
    expect(c.router.routerDelegate.currentConfiguration.last.matchedLocation, '/claude/session/pc1');
    await _finish(tester);
  });

  testWidgets('kontrol kapalı hostta PC\'yi kullan görünmez', (tester) async {
    final pc = _Pc(open: false, features: [...Harness.defaultAgentFeatures]..remove('control'));
    await pc.harness().pump(tester, route: '/claude');
    await tester.tap(find.byTooltip('Yeni Claude oturumu'));
    await settle(tester);
    expect(find.text('PC\'yi kullan'), findsNothing);
    expect(find.text('İzin modu'), findsOneWidget);
    await _finish(tester);
  });

  group('kalıcı bildirim ve gevşetilmiş kural (PC oturumu)', () {
    testWidgets('sohbet açılınca bildirim + saklı belirteç; arka plan ve sohbetten çıkmak kontrolü kapatmaz; Durdur düğmesi', (tester) async {
      final pc = _Pc();
      final c = await pc.h.pump(tester, route: '/claude/session/pc1');
      await settle(tester);
      final n = pc.h.pcNotifications;
      expect(n.shown?.sessionId, 'pc1');
      expect(n.body, "Firefox'ta yarının hava durumu · kontrol bitişi 14:20");
      final saved = PcHold.fromJson(await pc.h.secrets.read(pcControlSecretId))!;
      expect([saved.token, saved.sessionId, saved.hostId], ['tpc_fake', 'pc1', 'argo']);

      // 61 s in background: control stays open (only the strip stream stops).
      for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await tester.pump(const Duration(seconds: 61));
      for (final st in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await settle(tester);
      // Leaving the chat: control is not closed, the notification stays.
      c.router.go('/claude');
      await settle(tester);
      expect(FakeAgent.calls.any((x) => x.$1 == 'DELETE' && x.$2 == '/v1/desktop/control/session'), isFalse);
      expect(c.read(controlProvider), isNotNull);
      expect(n.shown, isNotNull);
      // The panel/live screen strict rule (release) does not close control while a PC session holds it.
      await c.read(controlProvider.notifier).release();
      expect(c.read(controlProvider), isNotNull);

      // Stop in the notification (UI path while the app is open): Claude is interrupted, control closes, notification +
      // token are removed.
      expect(await c.read(pcOngoingProvider.notifier).action(actionPcStop), isTrue);
      await settle(tester);
      expect(FakeAgent.calls.any((x) => x.$1 == 'POST' && x.$2 == '/v1/claude/sessions/pc1/interrupt'), isTrue);
      expect(FakeAgent.calls.any((x) => x.$1 == 'DELETE' && x.$2 == '/v1/desktop/control/session'), isTrue);
      expect(c.read(controlProvider), isNull);
      expect(n.shown, isNull);
      expect(n.log.last, 'cancel');
      expect(await pc.h.secrets.read(pcControlSecretId), isNull);
      await _finish(tester);
    });

    testWidgets('Uzat: bildirim ve saklı bitiş güncellenir; ajan "kontrol bitti" deyince bildirim kalkar', (tester) async {
      final pc = _Pc();
      final c = await pc.h.pump(tester, route: '/claude/session/pc1');
      await settle(tester);
      expect(await c.read(pcOngoingProvider.notifier).action(actionPcExtend), isTrue);
      await settle(tester);
      expect(FakeAgent.headersByPath['/v1/desktop/control/session/extend'], {'X-Tiphys-Control': 'tpc_fake'});
      expect(pc.h.pcNotifications.body, endsWith('14:35'));
      expect(PcHold.fromJson(await pc.h.secrets.read(pcControlSecretId))!.expiresAt, DateTime(2026, 11, 14, 14, 35));
      c.read(pcOngoingProvider.notifier).ended('baska');
      expect(pc.h.pcNotifications.shown, isNotNull); // another session: left untouched
      c.read(pcOngoingProvider.notifier).ended('pc1');
      await settle(tester);
      expect(pc.h.pcNotifications.shown, isNull);
      expect(c.read(controlProvider), isNull);
      expect(await pc.h.secrets.read(pcControlSecretId), isNull);
      await _finish(tester);
    });

    testWidgets('bildirimden arka planda uzatıldı: öne gelince saklı bitiş okunur, kontrol kapatılmaz', (tester) async {
      final pc = _Pc();
      final c = await pc.h.pump(tester, route: '/claude/session/pc1');
      await settle(tester);
      expect(find.text('Kontrol açık · 15:00'), findsOneWidget);
      // The background isolate (handlePcAction) only updates the stored record; the UI state stays stale.
      final saved = PcHold.fromJson(await pc.h.secrets.read(pcControlSecretId))!;
      await pc.h.secrets.write(pcControlSecretId, jsonEncode(saved.copyWith(expiresAt: DateTime(2026, 11, 14, 14, 35)).toJson()));
      for (final st in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await settle(tester);
      expect(c.read(controlProvider)!.expiresAt, DateTime(2026, 11, 14, 14, 35));
      expect(find.text('Kontrol açık · 30:00'), findsOneWidget);
      expect(pc.h.pcNotifications.body, endsWith('14:35'));
      expect(FakeAgent.calls.any((x) => x.$1 == 'DELETE'), isFalse);
      await _finish(tester);
    });

    test('yerel süre doldu: önce saklı kayda bakılır (uzatıldıysa sürer), gerçekten dolduysa unutulur', () async {
      final hold = PcHold(hostId: 'argo', sessionId: 'pc1', title: 'Hava', token: 'tpc_fake', expiresAt: DateTime(2026, 11, 14, 14, 35));
      final secrets = MemorySecretStore({pcControlSecretId: jsonEncode(hold.toJson())});
      final c = ProviderContainer(overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        clockProvider.overrideWithValue(() => DateTime(2026, 11, 14, 14, 5)),
        controlProvider.overrideWith(_StaleControl.new),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(controlProvider.notifier)..pcHold = 'pc1';
      await ctrl.expireIfDue();
      expect(c.read(controlProvider)!.expiresAt, DateTime(2026, 11, 14, 14, 35));
      // A record for another token doesn't count; with no record / a stale one, the expired session is forgotten.
      c.invalidate(controlProvider);
      await secrets.write(pcControlSecretId, jsonEncode(hold.copyWith(token: 'tpc_eski').toJson()));
      await (c.read(controlProvider.notifier)..pcHold = 'pc1').expireIfDue();
      expect(c.read(controlProvider), isNull);
    });

    testWidgets('PC oturumu tutmazken panelin sıkı kuralı aynen: release kontrolü kapatır', (tester) async {
      final pc = _Pc();
      final c = await pc.h.pump(tester, route: '/claude');
      expect(c.read(pcOngoingProvider), isNull);
      await c.read(controlProvider.notifier).release();
      expect(c.read(controlProvider), isNull);
      expect(FakeAgent.calls.any((x) => x.$1 == 'DELETE' && x.$2 == '/v1/desktop/control/session'), isTrue);
      expect(pc.h.pcNotifications.log, isEmpty);
      await _finish(tester);
    });
  });
}
