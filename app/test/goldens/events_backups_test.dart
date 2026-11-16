// System › Events, System › Backups, the "Son olaylar" card on the home screen and backup checks in agent settings.
// To update: flutter test test/goldens/events_backups_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/system/backups.dart';
import 'package:tiphys/features/system/events.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
}

/// argo's events endpoint does not respond; atlas is normal.
class _BrokenEvents extends FakeAgent {
  _BrokenEvents(super.hostId);
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (hostId == 'argo' && (path == '/v1/events' || path == '/v1/backups')) throw const AgentError('net.unreachable');
    return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
  }
}

void main() {
  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('olaylar $v', (tester) async {
      await Harness().pump(tester, route: '/system/events', dark: dark);
      await _load(tester);
      expect(find.text('Container çöktü · atlas'), findsOneWidget);
      expect(find.text('BUGÜN'), findsOneWidget);
      await golden('png/events_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('olaylar: tür süzgeci ve dokununca bildirimdeki ekran', (tester) async {
    await Harness().pump(tester, route: '/system/events');
    await _load(tester);
    await tester.tap(find.text('Yedek'));
    await settle(tester);
    expect(find.text('Container çöktü · atlas'), findsNothing);
    expect(find.text('Yedek eskidi: Veritabanı'), findsOneWidget);
    await tester.tap(find.text('Tüm türler'));
    await tester.tap(find.text('argo (PC)'));
    await settle(tester);
    expect(find.text('Yedek eskidi: Veritabanı'), findsNothing);
    expect(find.text('Claude bitirdi: Testleri düzelt ve raporla'), findsOneWidget);
    await tester.tap(find.text('Tüm hostlar'));
    await settle(tester);
    await tester.tap(find.text('Yedek eskidi: Veritabanı'));
    await _load(tester);
    expect(find.byType(BackupsScreen), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('olaylar: bir hostun hatası diğerlerini engellemez', (tester) async {
    await Harness(agent: (h) async => _BrokenEvents(h.id)).pump(tester, route: '/system/events');
    await _load(tester);
    expect(find.textContaining('argo (PC): olaylar alınamadı'), findsOneWidget);
    expect(find.text('Container çöktü · atlas'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('yedekler $v', (tester) async {
      await Harness().pump(tester, route: '/system/backups', dark: dark);
      await _load(tester);
      expect(find.text('Obsidian kasası'), findsOneWidget);
      await golden('png/backups_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('yedekler: şimdi kontrol et; hatalı host ayrı gösterilir', (tester) async {
    FakeAgent.calls.clear();
    await Harness(agent: (h) async => _BrokenEvents(h.id)).pump(tester, route: '/system/backups');
    await _load(tester);
    expect(find.textContaining('argo (PC): '), findsOneWidget);
    await tester.tap(find.byTooltip('Şimdi kontrol et').first);
    await _load(tester);
    expect(FakeAgent.calls.any((x) => x.$1 == 'POST' && x.$2 == '/v1/backups/db/check'), isTrue);
    expect(find.text('Kontrol edildi: Güncel'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('ana ekran: Son olaylar kartı', (tester) async {
    final h = Harness();
    final c = await h.pump(tester);
    await tester.runAsync(() => c.read(profileProvider.notifier).update((p) => p.copyWith(app: p.app.copyWith(cards: ['events', 'infra']))));
    await _load(tester);
    expect(find.text('SON OLAYLAR'), findsOneWidget);
    expect(find.text('Claude bitirdi: Testleri düzelt ve raporla'), findsOneWidget);
    expect(find.text('Container çöktü · atlas'), findsOneWidget);
    expect(find.text('Claude onayını bekliyor'), findsOneWidget);
    expect(find.text('Yedek eskidi: Veritabanı'), findsNothing); // only the last 3
    await golden('png/home_events_light_tr.png');
    await tester.tap(find.text('Tümü'));
    await _load(tester);
    expect(find.byType(EventsScreen), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ajan ayarları: yedek denetimi ekle/sil, Kaydet ile gönderilir', (tester) async {
    FakeAgent.calls.clear();
    await Harness().pump(tester, route: '/settings/hosts/agent?id=atlas');
    await _load(tester);
    expect(find.text('Yedek durumu'), findsOneWidget); // feature key
    await tester.ensureVisible(find.text('Denetim ekle'));
    await settle(tester);
    expect(find.text('Obsidian kasası'), findsOneWidget);
    await tester.tap(find.text('Denetim ekle'));
    await settle(tester);
    expect(find.text('En yeni dosya'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ad'), 'Veritabanı');
    await tester.tap(find.text('systemd birimi'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Birim'), 'db-backup.service');
    await tester.tap(find.text('Kaydet'));
    await settle(tester);
    expect(find.text('Veritabanı'), findsOneWidget);
    await tester.tap(find.byTooltip('Denetimi sil').first);
    await settle(tester);
    await tester.tap(find.text('Sil'));
    await settle(tester);
    expect(find.text('Obsidian kasası'), findsNothing);
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final patch = FakeAgent.calls.lastWhere((x) => x.$1 == 'PATCH');
    expect((patch.$3 as Map)['backups'], {
      'checks': [
        {'id': 'veritabani', 'name': 'Veritabanı', 'kind': 'unit', 'unit': 'db-backup.service', 'maxAgeHours': 26, 'minBytes': 0},
      ],
    });
    expect(((patch.$3 as Map)['features'] as Map)['backups'], isTrue);
    await _finish(tester);
    debugDisableShadows = true;
  });
}
