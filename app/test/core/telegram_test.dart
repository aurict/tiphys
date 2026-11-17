// Telegram newsletters: HTML subset parser (incl. hostile input), schedule/feed summaries, helpers, the research
// connect flow with fake agents, notification texts/actions and error texts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/features/telegram/research_screen.dart';
import 'package:tiphys/features/telegram/telegram_data.dart';
import 'package:tiphys/features/telegram/telegram_html.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/state/providers.dart';

final _codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
Profile _example() => _codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();

/// Records requests; [answers] maps "METHOD path" to a response or an AgentError to throw.
class _Fake extends AgentClient {
  _Fake(this.name, this.log, [this.answers = const {}]) : super(baseUrl: 'http://$name', token: 't');
  final String name;
  final List<String> log;
  final Map<String, Object> answers;
  final bodies = <String, Object?>{};
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    final key = '$method $path';
    log.add('$name $key');
    bodies[key] = body;
    final a = answers[key];
    if (a is AgentError) throw a;
    return a ?? {'ok': true};
  }
}

/// Answers successive `GET /v1/telegram/issues/<id>` calls from [answers] (the last one repeats).
class _IssueSeq extends AgentClient {
  _IssueSeq(this.answers) : super(baseUrl: 'http://tg', token: 't');
  final List<Object> answers;
  var calls = 0;
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    final a = answers[calls < answers.length ? calls : answers.length - 1];
    calls++;
    if (a is AgentError) throw a;
    return {'issue': {'id': 'i1', 'status': a}};
  }
}

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));

  group('Telegram HTML alt kümesi', () {
    test('b / i / a ve varlıklar', () {
      expect(parseTelegramHtml('1. <b>Başlık</b>\nÖzet &amp; &lt;x&gt; &quot;q&quot;\nKaynak: <a href="https://a.example/x?y=1&amp;z=2">a.example</a> · <i>son</i>'), const [
        TgSpan('1. '),
        TgSpan('Başlık', bold: true),
        TgSpan('\nÖzet & <x> "q"\nKaynak: '),
        TgSpan('a.example', href: 'https://a.example/x?y=1&z=2'),
        TgSpan(' · '),
        TgSpan('son', italic: true),
      ]);
      expect(parseTelegramHtml('<b><i>iç</i></b>'), const [TgSpan('iç', bold: true, italic: true)]);
      expect(parseTelegramHtml('&#65;&#x42;'), const [TgSpan('AB')]);
    });

    test('düşmanca girdi düz metin kalır', () {
      String text(String s) => parseTelegramHtml(s).map((x) => x.text).join();
      expect(parseTelegramHtml('<script>alert(1)</script>'), const [TgSpan('<script>alert(1)</script>')]);
      expect(text('<img src=x onerror=alert(1)>'), '<img src=x onerror=alert(1)>');
      // Unsafe schemes: text shown, but not a link.
      for (final h in ['javascript:alert(1)', 'data:text/html,x', 'file:///etc/passwd', 'intent://x', 'tiphys://system', '//evil.example', '']) {
        expect(parseTelegramHtml('<a href="$h">x</a>'), const [TgSpan('x')], reason: h);
      }
      expect(parseTelegramHtml('<a href="jav&#x61;script:alert(1)">x</a>'), const [TgSpan('x')]);
      // Extra attributes: the tag is not recognised.
      expect(text('<a href="https://a.example" onclick="x()">y</a>'), '<a href="https://a.example" onclick="x()">y</a>');
      expect(parseTelegramHtml('<a href="https://a.example" onclick="x()">y</a>').every((s) => s.href == null), isTrue);
      // Escaped markup stays text, never becomes a tag.
      expect(parseTelegramHtml('&lt;b&gt;x&lt;/b&gt;'), const [TgSpan('<b>x</b>')]);
      // Unmatched / unclosed tags.
      expect(parseTelegramHtml('a</b>c'), const [TgSpan('a</b>c')]);
      expect(parseTelegramHtml('<b>açık kaldı'), const [TgSpan('açık kaldı', bold: true)]);
      expect(text('</a><a>'), '</a><a>');
      // A link inside a link: the inner tag is text, the outer href kept.
      expect(parseTelegramHtml('<a href="https://a.example"><a href="https://b.example">x</a></a>').first.href, 'https://a.example');
      // Invalid entities stay as written.
      expect(text('&#0; &#xD800; &#99999999; &bogus;'), '&#0; &#xD800; &#99999999; &bogus;');
      expect(text('<<b>>'), '<>');
      // Large input stays linear and complete.
      final big = List.filled(5000, '<b>x</b>&amp;<').join();
      expect(text(big).length, 15000);
    });

    test('safeHttpUrl', () {
      expect(safeHttpUrl('https://a.example/x'), 'https://a.example/x');
      expect(safeHttpUrl('HTTP://A.example'), isNotNull);
      expect(safeHttpUrl('mailto:a@b.c'), isNull);
      expect(safeHttpUrl('https://'), isNull);
    });
  });

  group('özetler ve yardımcılar', () {
    final now = DateTime(2026, 11, 14, 14, 5);
    Map<String, dynamic> feed(Map when, {bool enabled = true, String? next}) => {'when': when, 'enabled': enabled, 'nextRun': next};

    test('zamanlama özeti', () {
      expect(feedScheduleSummary(tr, 'tr', feed({'kind': 'daily', 'time': '08:00'}, next: DateTime(2026, 11, 15, 8).toUtc().toIso8601String()), now), 'Her gün 08:00 · sonraki: yarın 08:00');
      expect(feedScheduleSummary(en, 'en', feed({'kind': 'daily', 'time': '08:00'}, next: DateTime(2026, 11, 15, 8).toUtc().toIso8601String()), now), 'Daily at 08:00 · next: tomorrow 08:00');
      expect(feedScheduleSummary(tr, 'tr', feed({'kind': 'weekly', 'time': '09:00', 'days': [1]}, enabled: false), now), 'Pzt · 09:00 · kapalı');
      expect(feedScheduleSummary(en, 'en', feed({'kind': 'interval', 'everyMinutes': 120}), now), 'Every 2 h');
      expect(windowText(tr, 24), 'son 24 saat');
      expect(windowText(en, 168), 'last 7 days');
      expect(windowText(en, 48), 'last 48 h');
      expect(approvalText(tr, {'mode': 'firstN', 'n': 3}), 'İlk 3 sayıda bana sor, sonra otomatik');
    });

    test('alan adları, abonelik farkları, feed girdisi', () {
      expect(parseDomains('https://www.Reuters.com/world, apnews.com\nbbc.co.uk;  '), ['reuters.com', 'apnews.com', 'bbc.co.uk']);
      final rs = [
        {'id': 'a', 'subscriptions': ['f1']},
        {'id': 'b', 'subscriptions': <String>[]},
        {'id': 'c', 'subscriptions': ['f2']},
      ];
      expect([for (final (id, subs) in subscriptionChanges(rs, 'f1', {'b', 'c'})) '$id:${subs.join(',')}'], ['a:', 'b:f1', 'c:f2,f1']);
      expect(subscriptionChanges(rs, 'f1', {'a'}), isEmpty);
      final input = feedInput({'id': 'x', 'name': 'n', 'when': {'kind': 'daily', 'time': '08:00'}, 'topic': 't', 'instructions': '', 'running': true, 'recipientIds': []});
      expect(input.keys, isNot(contains('id')));
      expect(input.keys, isNot(contains('instructions')));
      expect(input['approval'], {'mode': 'firstN', 'n': 3});
      expect(recipientName({'id': 'r', 'firstName': 'Ayşe', 'lastName': 'Yılmaz'}), 'Ayşe Yılmaz');
      expect(recipientName({'id': 'r', 'firstName': '', 'username': 'u'}), '@u');
    });
  });

  group('atlas bağlama akışı', () {
    final p = _example();
    final pc = p.host('argo')!, tg = p.host('atlas')!;
    final created = {'token': 'tps_secret', 'serviceToken': {'id': 'st_1', 'name': 'atlas', 'scopes': ['research'], 'createdAt': 'x'}};

    test('sıra: config → belirteç → PATCH → durum; uyandırma hedefi atlas ayarından', () async {
      final log = <String>[];
      final pcC = _Fake('pc', log, {'POST /v1/service-tokens': created});
      final tgC = _Fake('tg', log, {
        'GET /v1/config': {'wake': {'targets': [{'hostId': 'argo'}]}},
        'GET /v1/telegram/status': {'research': {'reachable': true}},
      });
      final r = await connectResearch(pc: pc, tg: tg, pcClient: pcC, tgClient: tgC);
      expect(log, ['tg GET /v1/config', 'pc POST /v1/service-tokens', 'tg PATCH /v1/config', 'tg GET /v1/telegram/status']);
      expect(pcC.bodies['POST /v1/service-tokens'], {'name': 'atlas', 'scopes': ['research']});
      expect(tgC.bodies['PATCH /v1/config'], {'research': {'url': 'https://argo.example.ts.net:7443', 'token': 'tps_secret', 'wakeHostId': 'argo'}});
      expect((r.tokenId, r.wakeHostId, r.reachable), ('st_1', 'argo', true));
    });

    test('uyandırma hedefi yoksa null; durum okunamazsa reachable null', () async {
      final log = <String>[];
      final tgC = _Fake('tg', log, {'GET /v1/config': {'wake': {'targets': []}}, 'GET /v1/telegram/status': const AgentError('agent.route.notFound')});
      final r = await connectResearch(pc: pc, tg: tg, pcClient: _Fake('pc', log, {'POST /v1/service-tokens': created}), tgClient: tgC);
      expect((tgC.bodies['PATCH /v1/config'] as Map)['research']['wakeHostId'], isNull);
      expect(r.reachable, isNull);
    });

    test('PATCH başarısızsa yeni belirteç iptal edilir ve hata yükselir', () async {
      final log = <String>[];
      final tgC = _Fake('tg', log, {'GET /v1/config': {}, 'PATCH /v1/config': const AgentError('agent.request.invalid')});
      await expectLater(connectResearch(pc: pc, tg: tg, pcClient: _Fake('pc', log, {'POST /v1/service-tokens': created}), tgClient: tgC), throwsA(isA<AgentError>()));
      expect(log, ['tg GET /v1/config', 'pc POST /v1/service-tokens', 'tg PATCH /v1/config', 'pc DELETE /v1/service-tokens/st_1']);
    });

    test('profilde PC atlas üzerinden uyandırılıyorsa hedef sayılır', () {
      const viaTg = Host(id: 'argo', name: 'argo', color: '#000000', address: 'a', wake: WakeConfig(mac: '02:00:00:00:00:01', viaHostId: 'atlas'));
      expect(researchWakeTarget({}, viaTg, tg), 'argo');
      expect(researchWakeTarget({}, pc, tg), isNull);
    });
  });

  group('bildirimler', () {
    test('metinler TR/EN', () {
      const ap = {'feed': 'Günlük', 'feedId': 'f', 'issueId': 'i', 'items': 6, 'recipients': 2};
      expect(noticeText(tr, 'telegram.approval', ap), ('Bülten onay bekliyor: Günlük', '6 madde · 2 kişi'));
      expect(noticeText(en, 'telegram.approval', ap), ('Newsletter waiting for approval: Günlük', '6 items · 2 people'));
      expect(noticeText(en, 'telegram.sent', {...ap, 'recipients': 1, 'failed': 1}), ('Newsletter sent: Günlük', '6 items · 1 person · 1 failed'));
      expect(noticeText(tr, 'telegram.sent', {...ap, 'failed': 0})!.$2, '6 madde · 2 kişi');
      expect(noticeText(tr, 'telegram.failed', {'feed': 'G', 'reason': 'agent.telegram.noItems'}), ('Bülten gönderilmedi: G', 'Doğrulamadan geçen haber yok.'));
      expect(noticeText(en, 'telegram.failed', {'feed': 'G', 'reason': 'agent.telegram.approvalExpired'}), ('Approval expired: G', 'The approval time ran out; nothing was sent.'));
      expect(noticeText(tr, 'telegram.pcUnreachable', {'feed': 'G'}), ("Araştırma PC'sine ulaşılamadı", 'G bu sefer gönderilmedi.'));
      expect(noticeText(tr, 'telegram.stateCorrupt', {}), ('Telegram durumu sıfırlandı', 'Bozuk durum dosyası kenara alındı; kişiler ve bültenler yeniden eklenmeli.'));
      expect(telegramReasonText(tr, 'agent.telegram.shutdown'), telegramReasonText(tr, 'agent.research.interrupted'));
      expect(noticeText(en, 'telegram.failed', {'feed': 'G', 'reason': 'agent.telegram.whatever'})!.$2, '${en.commonError} (agent.telegram.whatever)');
    });

    test('tercihler, kilit ekranı, kimlik, bağlantı', () {
      const off = Profile(notifications: NotificationSettings(telegramSent: false, telegramAlerts: false));
      for (final k in ['telegram.sent', 'telegram.approval', 'telegram.failed', 'telegram.pcUnreachable']) {
        expect(noticeAllowed(const Profile(), k), isTrue);
        expect(noticeAllowed(off, k), isFalse);
      }
      expect(noticeAllowed(const Profile(notifications: NotificationSettings(telegramSent: false)), 'telegram.approval'), isTrue);
      expect(lockScreenVisibility('telegram.approval', const {}, null, null), NotificationVisibility.secret);
      expect(lockScreenVisibility('telegram.sent', const {}, null, null), isNull);
      // The approval request is replaced by the outcome of the same issue.
      expect(noticeId('telegram.approval', {'issueId': 'i_1'}), noticeId('telegram.sent', {'issueId': 'i_1'}));
      expect(noticeId('telegram.approval', {'issueId': 'i_1'}), isNot(noticeId('telegram.approval', {'issueId': 'i_2'})));
      expect(routeForLink('tiphys://telegram/issues/i_abc123'), '/telegram/issues/i_abc123');
      expect(routeForLink('tiphys://telegram'), '/system/telegram');
      expect(routeForLink('tiphys://telegram/issues/../../settings'), isNull);
      expect(routeForPayload(jsonEncode({'link': 'tiphys://telegram/issues/i_1', 'issueId': 'i_1'})), '/telegram/issues/i_1');
    });

    test('profil: telegram tercihleri şemadan geçer ve korunur', () {
      final raw = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
      raw['notifications'] = {'telegramSent': false, 'telegramAlerts': true};
      final p = _codec.decode(jsonEncode(raw)).toProfile();
      expect((p.notifications.telegramSent, p.notifications.telegramAlerts), (false, true));
      expect(NotificationSettings.fromJson(p.notifications.toJson()).telegramSent, isFalse);
    });

    group('Gönder / Vazgeç düğmeleri', () {
      final profile = _example().copyWith(agentConfigs: {
        'atlas': {'features': {'telegram': true}},
      });
      final secrets = MemorySecretStore({'agent-argo': 'a', 'agent-atlas': 'b'});
      final payload = jsonEncode({'link': 'tiphys://telegram/issues/i_1', 'issueId': 'i_1', 'feedId': 'f'});

      test('telegram ajanı önce denenir; onaylar', () async {
        final log = <String>[];
        final ok = await telegramDecideFromNotification(payload, true, profile: profile, secrets: secrets, clientFor: (u, t) => _Fake(Uri.parse(u).host.split('.').first, log));
        expect(ok, isTrue);
        expect(log, ['atlas POST /v1/telegram/issues/i_1/approve']);
      });

      test('bilmeyen ajan atlanır, sonraki reddeder', () async {
        final log = <String>[];
        final p = _example(); // no saved configs: profile order (argo, atlas)
        final ok = await telegramDecideFromNotification(payload, false, profile: p, secrets: secrets, clientFor: (u, t) {
          final h = Uri.parse(u).host.split('.').first;
          return _Fake(h, log, h == 'argo' ? {'POST /v1/telegram/issues/i_1/reject': const AgentError('agent.route.notFound')} : {});
        });
        expect(ok, isTrue);
        expect(log, ['argo POST /v1/telegram/issues/i_1/reject', 'atlas POST /v1/telegram/issues/i_1/reject']);
      });

      test('kesin hata (artık beklemiyor) → false, başka ajana gidilmez; bozuk yük → false', () async {
        final log = <String>[];
        final ok = await telegramDecideFromNotification(payload, true, profile: profile, secrets: secrets,
            clientFor: (u, t) => _Fake(Uri.parse(u).host.split('.').first, log, {'POST /v1/telegram/issues/i_1/approve': const AgentError('agent.telegram.issueNotAwaiting')}));
        expect(ok, isFalse);
        expect(log, hasLength(1));
        expect(await telegramDecideFromNotification('bozuk', true, profile: profile, secrets: secrets), isFalse);
        expect(await telegramDecideFromNotification(jsonEncode({'issueId': '../x'}), true, profile: profile, secrets: secrets), isFalse);
      });
    });
  });

  test('agentErrorText: telegram, araştırma, kapsam', () {
    expect(agentErrorText(tr, const AgentError('agent.auth.scopeDenied')), 'Bu belirteç bu işlem için yetkili değil (kapsam).');
    expect(agentErrorText(en, const AgentError('agent.research.toolMissing', {'tool': 'agy'})), 'agy is not installed on the PC.');
    expect(agentErrorText(en, const AgentError('agent.telegram.badRequest', {'description': 'chat not found'})), 'Telegram rejected the request: chat not found');
    expect(agentErrorText(tr, const AgentError('agent.telegram.research.unreachable')), "Araştırma PC'sine ulaşılamadı.");
    expect(agentErrorText(tr, const AgentError('agent.telegram.issue.notFound')), 'Bulunamadı (silinmiş olabilir).');
  });

  group('sayı yoklaması', () {
    Future<(ProviderContainer, _IssueSeq)> start(WidgetTester tester, List<Object> answers) async {
      final client = _IssueSeq(answers);
      final c = ProviderContainer(overrides: [
        initialProfileProvider.overrideWithValue(_example()),
        agentClientFactoryProvider.overrideWithValue((h) async => client),
      ]);
      addTearDown(c.dispose);
      c.listen(telegramIssueProvider(('atlas', 'i1')), (_, _) {});
      await tester.pump();
      return (c, client);
    }

    testWidgets('geçici hata yoklamayı durdurmaz; bitince durur', (tester) async {
      final (c, client) = await start(tester, [const AgentError('net.unreachable'), 'researching', 'sent']);
      expect(client.calls, 1);
      expect(c.read(telegramIssueProvider(('atlas', 'i1'))).hasError, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(client.calls, 2);
      expect(c.read(telegramIssueProvider(('atlas', 'i1'))).value?.$2['status'], 'researching');
      await tester.pump(const Duration(seconds: 5));
      expect(client.calls, 3);
      expect(c.read(telegramIssueProvider(('atlas', 'i1'))).value?.$2['status'], 'sent');
      await tester.pump(const Duration(minutes: 2));
      expect(client.calls, 3);
    });

    testWidgets('art arda hatalarda 3 s → 10 s → 30 s; 404 olunca durur', (tester) async {
      final (_, client) = await start(tester, [
        const AgentError('net.timeout'),
        const AgentError('agent.internal', {}, 503),
        const AgentError('net.unreachable'),
        const AgentError('agent.telegram.issue.notFound', {}, 404),
      ]);
      expect(client.calls, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(client.calls, 2);
      await tester.pump(const Duration(seconds: 9));
      expect(client.calls, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(client.calls, 3);
      await tester.pump(const Duration(seconds: 29));
      expect(client.calls, 3);
      await tester.pump(const Duration(seconds: 1));
      expect(client.calls, 4);
      await tester.pump(const Duration(minutes: 5));
      expect(client.calls, 4);
    });

    test('geçici hata sınıflandırması', () {
      expect(isTransientAgentError(const AgentError('net.timeout')), isTrue);
      expect(isTransientAgentError(const AgentError('agent.x', {}, 502)), isTrue);
      expect(isTransientAgentError(const AgentError('agent.auth.invalidToken', {}, 401)), isFalse);
      expect(isTransientAgentError(const AgentError('agent.telegram.issue.notFound', {}, 404)), isFalse);
      expect(isTransientAgentError(StateError('x')), isFalse);
    });
  });
}
