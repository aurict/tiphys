// System › Compose stacks (fake SSH shell) and Claude › Scheduled tasks (fake agent).
// To update: flutter test test/goldens/compose_schedules_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/claude/schedules.dart';
import 'package:tiphys/features/system/compose.dart';

import '../helpers/fake_shell.dart';
import '../helpers/harness.dart';

Future<void> _load(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
}

/// Fake agent that also records which host's agent a request went to.
class _HostAgent extends FakeAgent {
  _HostAgent(super.hostId);
  static final calls = <(String, String, String, Object?)>[];
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) {
    calls.add((hostId, method, path, body));
    return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
  }
}

Harness _compose(FakeComposeHost h, {Map<String, FakeComposeHost>? perHost}) => Harness(
      agent: (host) async => _HostAgent(host.id),
      extra: [composeShellOpenerProvider.overrideWithValue((host) async => (perHost?[host.id] ?? h).shell)],
    );

void main() {
  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('compose yığınları $v', (tester) async {
      await _compose(FakeComposeHost()).pump(tester, route: '/system/compose', dark: dark);
      await _load(tester);
      expect(find.text('web'), findsOneWidget);
      expect(find.text('2/3 çalışıyor · sağlıksız · ~/stack/monitoring'), findsOneWidget);
      expect(find.text('Okunamadı · ~/stack/aurict'), findsOneWidget);
      await golden('png/compose_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('compose yığını ayrıntısı: container durumları ve işlemler', (tester) async {
    await _compose(FakeComposeHost()).pump(tester, route: '/system/compose');
    await _load(tester);
    await tester.tap(find.text('monitoring'));
    await _load(tester);
    expect(find.text('prometheus'), findsOneWidget);
    expect(find.text('Başlat'), findsOneWidget); // one container is down
    expect(find.text('Durdur'), findsOneWidget);
    await golden('png/compose_stack_light_tr.png');
    await _finish(tester);
  });

  testWidgets('compose: ajansız hostta güncelle → canlı çıktı, özet, olay ilk ajanlı hosta', (tester) async {
    _HostAgent.calls.clear();
    final orion = FakeComposeHost()..afterPull['nginx:1.27-alpine'] = 'sha256:new';
    await _compose(FakeComposeHost(), perHost: {'orion': orion}).pump(tester, route: '/system/compose');
    await _load(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'orion'));
    await _load(tester);
    await tester.tap(find.text('web'));
    await _load(tester);
    await tester.tap(find.text('Güncelle'));
    await settle(tester);
    expect(find.text('web güncellensin mi? İmajlar çekilir; yeni imajı olan servisler yeniden oluşturulur.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Güncelle'));
    await _load(tester);
    expect(find.text('1 servis güncellendi: nginx'), findsOneWidget);
    expect(find.textContaining('nginx Pulled'), findsOneWidget);
    expect(orion.shell.commands.last, endsWith("up -d 'nginx'"));
    final ev = _HostAgent.calls.singleWhere((c) => c.$2 == 'POST' && c.$3 == '/v1/events');
    expect(ev.$1, 'argo'); // orion has no agent → first host with an agent in the profile
    expect(ev.$4, {
      'key': 'compose.updated',
      'params': {'host': 'orion', 'stack': 'web', 'services': 'nginx', 'count': 1},
      'link': 'tiphys://system/compose',
    });
    await golden('png/compose_update_light_tr.png');
    await tester.tap(find.text('Kapat'));
    await settle(tester);
    expect(find.byType(ComposeRunSheet), findsNothing);
    await _finish(tester);
  });

  testWidgets('compose: güncel yığında up çalışmaz, olay yazılmaz; başarısız pull olay olarak kaydedilir', (tester) async {
    _HostAgent.calls.clear();
    final h = FakeComposeHost();
    await _compose(h).pump(tester, route: '/system/compose');
    await _load(tester);
    await tester.tap(find.text('web'));
    await _load(tester);
    await tester.tap(find.text('Güncelle'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Güncelle'));
    await _load(tester);
    expect(find.text('Zaten güncel; hiçbir şey yeniden başlatılmadı.'), findsOneWidget);
    expect(h.shell.commands.where((c) => c.contains(' up ')), isEmpty);
    expect(_HostAgent.calls.where((c) => c.$3 == '/v1/events'), isEmpty);
    await tester.tap(find.text('Kapat'));
    await settle(tester);

    h.pullCode = 18;
    await tester.tap(find.text('Güncelle'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Güncelle'));
    await _load(tester);
    expect(find.text('Başarısız: pull (çıkış 18)'), findsOneWidget);
    final ev = _HostAgent.calls.singleWhere((c) => c.$3 == '/v1/events');
    expect(ev.$1, 'argo');
    expect((ev.$4 as Map)['key'], 'compose.failed');
    expect((ev.$4 as Map)['params'], {'host': 'argo (PC)', 'stack': 'web', 'step': 'pull', 'code': 18});
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('compose: durdurma onay ister; vazgeçince komut çalışmaz; loglar', (tester) async {
    final h = FakeComposeHost();
    await _compose(h).pump(tester, route: '/system/compose');
    await _load(tester);
    await tester.tap(find.text('web'));
    await _load(tester);
    await tester.tap(find.text('Durdur'));
    await settle(tester);
    expect(find.text("web durdurulsun mu? Container'lar yeniden başlatılana dek kapalı kalır."), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await settle(tester);
    expect(h.shell.commands.where((c) => c.endsWith(' stop')), isEmpty);
    await tester.tap(find.text('Loglar (son 200 satır)'));
    await _load(tester);
    expect(find.textContaining('Ready to accept connections'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('compose: SSH hatası tekrar dene ile gösterilir', (tester) async {
    await Harness().pump(tester, route: '/system/compose'); // default opener: unreachable
    await _load(tester);
    expect(find.text('Tekrar dene'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('zamanlanmış görevler $v', (tester) async {
      await Harness().pump(tester, route: '/claude/schedules', dark: dark);
      await _load(tester);
      expect(find.text('Sabah raporu'), findsOneWidget);
      expect(find.text('Pzt, Sal, Çar, Per, Cum · 08:30'), findsOneWidget);
      expect(find.text('tiphys · sonraki: 16 Kas Pzt 08:30'), findsOneWidget);
      expect(find.text('6 saatte bir'), findsOneWidget);
      expect(find.text('Son çalışma dün 03:00 · başarısız'), findsOneWidget);
      await golden('png/claude_schedules_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('zamanlanmış görev: düzenle sayfası, kaydet PUT gönderir', (tester) async {
    FakeAgent.calls.clear();
    await Harness().pump(tester, route: '/claude/schedules');
    await _load(tester);
    await tester.tap(find.text('Düzenle').first);
    await settle(tester);
    expect(find.text('Görevi düzenle'), findsOneWidget);
    expect(find.byType(ScheduleEditSheet), findsOneWidget);
    await golden('png/claude_schedule_edit_light_tr.png');
    await tester.tap(find.text('Cum'));
    await tester.ensureVisible(find.text('Kaydet'));
    await settle(tester);
    await tester.tap(find.text('Kaydet'));
    await _load(tester);
    final put = FakeAgent.calls.lastWhere((c) => c.$1 == 'PUT');
    expect(put.$2, '/v1/claude/schedules/s1');
    expect(put.$3, containsPair('when', {'kind': 'weekly', 'time': '08:30', 'days': [1, 2, 3, 4]}));
    expect(put.$3, containsPair('permissionMode', 'plan'));
    expect(find.byType(ScheduleEditSheet), findsNothing);
    await _finish(tester);
  });

  testWidgets('zamanlanmış görev: aç/kapat, şimdi çalıştır oturumu açar, yeni görev doğrulanır', (tester) async {
    FakeAgent.calls.clear();
    await Harness().pump(tester, route: '/claude');
    await _load(tester);
    await tester.tap(find.byTooltip('Zamanlanmış görevler'));
    await _load(tester);
    expect(find.byType(ClaudeSchedulesScreen), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await _load(tester);
    final put = FakeAgent.calls.lastWhere((c) => c.$1 == 'PUT');
    expect(put.$3, containsPair('enabled', false));
    expect(put.$3, isNot(contains('lastRun')));

    await tester.tap(find.byTooltip('Görev ekle'));
    await settle(tester);
    await tester.ensureVisible(find.text('Kaydet'));
    await settle(tester);
    await tester.tap(find.text('Kaydet'));
    await settle(tester);
    expect(find.text('Ad ve görev gerekli'), findsOneWidget);
    expect(FakeAgent.calls.where((c) => c.$1 == 'POST' && c.$2 == '/v1/claude/schedules'), isEmpty);
    Navigator.of(tester.element(find.byType(ScheduleEditSheet))).pop();
    await settle(tester);

    await tester.tap(find.text('Şimdi çalıştır').first);
    await _load(tester);
    expect(FakeAgent.calls.any((c) => c.$1 == 'POST' && c.$2 == '/v1/claude/schedules/s1/run'), isTrue);
    expect(find.text('Durum raporu'), findsWidgets); // md1 session opened
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('zamanlanmış görevler: ajan eskiyse özellik kapalı uyarısı', (tester) async {
    await Harness(agent: (h) async => _NoSchedules(h.id)).pump(tester, route: '/claude/schedules');
    await _load(tester);
    expect(find.byType(ClaudeSchedulesScreen), findsOneWidget);
    expect(find.textContaining('kapalı'), findsWidgets);
    await _finish(tester);
    debugDisableShadows = true;
  });
}

class _NoSchedules extends FakeAgent {
  _NoSchedules(super.hostId);
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (path.startsWith('/v1/claude/schedules')) throw const AgentError('agent.route.notFound');
    return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
  }
}
