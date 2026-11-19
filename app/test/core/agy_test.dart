// agy sessions: event model (upsert by eid/seq, toolUpdate merge), option choice, notifications (text, filtering, ids,
// links, Allow/Deny actions), texts in both languages for every code and key, shell quoting, the controller's polling.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/features/agy/agy_data.dart';
import 'package:tiphys/features/agy/agy_texts.dart';
import 'package:tiphys/features/claude/continue_on_pc.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/features/system/agent_providers.dart';

import '../helpers/agy_fixtures.dart';

final _tr = lookupAppLocalizations(const Locale('tr'));
final _en = lookupAppLocalizations(const Locale('en'));

Map<String, dynamic> _ev(int eid, int seq, String kind, [Map<String, dynamic> more = const {}]) => {
  'eid': eid,
  'seq': seq,
  'at': 'x',
  'kind': kind,
  ...more,
};

/// Agent client that answers from [FakeAgyState] and records the calls.
class _Fake extends AgentClient {
  _Fake(this.state, this.calls, {this.fail = false, String base = 'https://argo.example.ts.net:7443', this.urls})
    : super(baseUrl: base, token: 'tph_x');
  final FakeAgyState state;
  final List<(String, String, Object?)> calls;
  final bool fail;

  /// Base URL of every request, when asked for (which agent was reached).
  final List<String>? urls;
  @override
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration? timeout,
    Map<String, String>? headers,
  }) async {
    if (fail) throw const AgentError('net.unreachable');
    calls.add((method, path, method == 'GET' ? query : body));
    urls?.add(baseUrl);
    return state.route(method, path, body, query);
  }
}

void main() {
  group('olaylar', () {
    test('eid ile güncellenir (çoğalmaz), yeni seq alınır; sıra eid sırasıdır; dönen değer en yüksek seq', () {
      final events = <AgyEvent>[];
      var after = upsertAgyEvents(events, [
        _ev(1, 1, 'user', {'text': 'Selam'}),
        _ev(2, 2, 'agent', {'text': 'Mer'}),
      ]);
      expect(after, 2);
      // The streamed message grows: same eid, new seq; a tool arrives meanwhile.
      after = upsertAgyEvents(events, [
        _ev(3, 3, 'tool', {'toolCallId': 't'}),
        _ev(2, 4, 'agent', {'text': 'Merhaba'}),
      ], after: after);
      expect(after, 4);
      expect(events.map((e) => e.eid), [1, 2, 3]);
      expect(events[1].text, 'Merhaba');
      expect(events[1].seq, 4);
      // An older version arriving late doesn't lower the cursor.
      expect(
        upsertAgyEvents(events, [
          _ev(1, 1, 'user', {'text': 'Selam'}),
        ], after: 4),
        4,
      );
      expect(events, hasLength(3));
      // Out-of-order eids are put in order.
      upsertAgyEvents(events, [_ev(5, 6, 'agent'), _ev(4, 5, 'agent')], after: 4);
      expect(events.map((e) => e.eid), [1, 2, 3, 4, 5]);
    });

    test('toolUpdate aynı toolCallId’li aracı günceller; başlık yalnız doluysa değişir; eşleşmeyen güncelleme düşmez', () {
      final events = [
        AgyEvent(_ev(1, 1, 'tool', {'toolCallId': 't1', 'title': 'npm test', 'status': 'pending', 'command': 'npm test', 'toolKind': 'execute'})),
        AgyEvent(_ev(2, 2, 'tool', {'toolCallId': 't2', 'title': 'ls', 'status': 'pending'})),
        AgyEvent(_ev(3, 3, 'toolUpdate', {'toolCallId': 't1', 'status': 'in_progress'})),
        AgyEvent(_ev(4, 4, 'toolUpdate', {'toolCallId': 't1', 'status': 'completed', 'title': 'npm test (18 geçti)'})),
        AgyEvent(_ev(5, 5, 'toolUpdate', {'toolCallId': 't2', 'status': 'failed', 'title': ''})),
        AgyEvent(_ev(6, 6, 'toolUpdate', {'toolCallId': 'yok', 'status': 'completed'})),
      ];
      final s = agyToolStates(events);
      expect(s['t1'], containsPair('status', 'completed'));
      expect(s['t1'], containsPair('title', 'npm test (18 geçti)'));
      expect(s['t1'], containsPair('command', 'npm test'));
      expect(s['t2'], containsPair('title', 'ls'));
      expect(s['t2'], containsPair('status', 'failed'));
      expect(s['yok'], containsPair('status', 'completed'));
    });

    test('yanıtlanan izinler: requestId → optionId (iptal = cancelled)', () {
      final events = [
        AgyEvent(_ev(1, 1, 'permissionResolved', {'requestId': 'a', 'optionId': 'allow'})),
        AgyEvent(_ev(2, 2, 'permissionResolved', {'requestId': 'b', 'optionId': 'cancelled'})),
        AgyEvent(_ev(3, 3, 'agent')),
      ];
      expect(agyResolvedPermissions(events), {'a': 'allow', 'b': 'cancelled'});
    });

    test('Allow/Deny seçeneği: türüne göre (once önce), yoksa agy’nin allow/deny kimlikleri', () {
      final opts = [
        {'optionId': 'always', 'name': 'Always', 'kind': 'allow_always'},
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
      ];
      expect(agyOptionFor(opts, true), 'allow');
      expect(agyOptionFor(opts, false), 'deny');
      expect(agyOptionFor([opts[0]], true), 'always', reason: 'yalnız “her zaman” varsa o');
      expect(agyOptionFor([opts[0]], false), isNull);
      expect(
        agyOptionFor([
          {'optionId': 'deny', 'name': 'x', 'kind': 'other'},
        ], false),
        'deny',
      );
      expect(agyOptionFor(const [], true), isNull);
    });
  });

  group('denetleyici', () {
    test('ilk yükleme + after = en yüksek seq; akış güncellemesi aynı olayı değiştirir; 409 busy fırlatılır', () async {
      final st = FakeAgyState();
      final msg = st.emit({'kind': 'agent', 'text': 'Mer'});
      final calls = <(String, String, Object?)>[];
      final c = AgyController(client: _Fake(st, calls), sessionId: agySessionId, poll: false);
      await c.start();
      expect(c.events.single.text, 'Mer');
      expect(c.after, 1);
      expect(c.status, 'idle');
      expect(c.resumeCommand, agyResume(agyCwd, agyConversationId));
      st.appendText(msg['eid'] as int, 'haba');
      expect(await c.pollOnce(wait: 0), isTrue);
      expect(c.events.single.text, 'Merhaba');
      expect(c.after, 2);
      expect((calls.last.$3 as Map)['after'], '1');
      st.setStatus('waiting');
      await c.pollOnce(wait: 0);
      expect(c.active, isTrue);
      await expectLater(c.send('x'), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.agy.busy')));
      c.dispose();
    });

    test('oturum yok → gone/ended; ağ hatası hata olarak tutulur', () async {
      final st = FakeAgyState();
      final c = AgyController(client: _Fake(st, []), sessionId: 'agy-cccccccccccc', poll: false);
      await c.start();
      expect(c.gone, isTrue);
      expect(c.ended, isTrue);
      final d = AgyController(client: _Fake(st, [], fail: true), sessionId: agySessionId, poll: false);
      await d.start();
      expect(d.gone, isFalse);
      expect((d.error as AgentError).code, 'net.unreachable');
      c.dispose();
      d.dispose();
    });
  });

  group('bildirimler', () {
    test('metinler iki dilde: agy.waiting / agy.done / agy.error', () {
      expect(noticeText(_tr, 'agy.waiting', {'title': 'Testler', 'tool': 'npm test'}), (
        'agy iznini bekliyor',
        'Testler · npm test çalıştırmak istiyor',
      ));
      expect(noticeText(_en, 'agy.waiting', {'title': 'Tests', 'tool': 'npm test'}), ('agy needs your permission', 'Tests · wants to run npm test'));
      expect(noticeText(_tr, 'agy.done', {'title': 'Testler'}), ('agy bitirdi: Testler', ''));
      expect(noticeText(_en, 'agy.done', {'title': 'Tests'})!.$1, 'agy finished: Tests');
      expect(noticeText(_tr, 'agy.error', {'title': 'Testler'}), ('agy hatayla durdu', 'Testler'));
      expect(noticeText(_en, 'agy.error', {'title': 'Tests'})!.$1, 'agy stopped with an error');
    });

    test('tercihler Claude’unkilerle aynı anahtarlardan; bildirim kimlikleri oturum başına, izin isteği başına', () {
      const off = Profile(claude: ClaudeSettings(notifyDone: false, notifyWaiting: false, notifyError: false));
      expect(noticeAllowed(off, 'agy.done'), isFalse);
      expect(noticeAllowed(off, 'agy.waiting'), isFalse);
      expect(noticeAllowed(off, 'agy.error'), isFalse);
      expect(noticeAllowed(const Profile(), 'agy.waiting'), isTrue);
      const link = 'tiphys://agy/agy-aaaaaaaaaaaa';
      expect(
        noticeId('agy.done', const {}, link: link),
        noticeId('agy.error', const {}, link: link),
        reason: 'son durum öncekini değiştirir',
      );
      expect(noticeId('agy.waiting', const {}, link: link, requestId: 'r1'), isNot(noticeId('agy.waiting', const {}, link: link, requestId: 'r2')));
      expect(noticeId('agy.waiting', const {}, link: link, requestId: 'r1'), noticeId('agy.waiting', const {}, link: link, requestId: 'r1'));
    });

    test('bağlantılar: tiphys://agy ve tiphys://agy/<kimlik>; düğmeli yük ve ajan adı ipucu', () {
      expect(routeForLink('tiphys://agy'), '/agy');
      expect(routeForLink('tiphys://agy/agy-aaaaaaaaaaaa'), '/agy/agy-aaaaaaaaaaaa');
      expect(routeForLink('tiphys://agy/../x'), isNull);
      expect(routeForLink('tiphys://agy/evil'), isNull);
      final payload = jsonEncode({'link': 'tiphys://agy/agy-aaaaaaaaaaaa', 'sessionId': 'agy-aaaaaaaaaaaa', 'requestId': 'a1b2c3d4e5f6'});
      expect(routeForPayload(payload), '/agy/agy-aaaaaaaaaaaa');
      expect(routeForPayload(jsonEncode({'link': 'tiphys://agy/agy-aaaaaaaaaaaa', 'host': 'argo'})), '/agy/agy-aaaaaaaaaaaa?host=argo');
      expect(routeForPayload('tiphys://agy/agy-aaaaaaaaaaaa'), '/agy/agy-aaaaaaaaaaaa');
    });

    test('agent adı: ipucu olarak dokunma yolunda (done/error düz yük, waiting düğmeli yük) ve yoksa eski davranış', () {
      expect(agyAgentHint('agy.waiting', {'agent': 'atlas'}), 'atlas');
      expect(agyAgentHint('agy.done', {'agent': ''}), isNull);
      expect(agyAgentHint('agy.done', const {}), isNull);
      expect(agyAgentHint('claude.done', {'agent': 'atlas'}), isNull);
      const link = 'tiphys://agy/agy-aaaaaaaaaaaa';
      expect(agyPayload('agy.done', link, {'agent': 'atlas'}), jsonEncode({'link': link, 'host': 'atlas'}));
      expect(agyPayload('agy.error', link, const {}), isNull);
      expect(routeForPayload(agyPayload('agy.done', link, {'agent': 'atlas'})), '/agy/agy-aaaaaaaaaaaa?host=atlas');
      expect(routeForPayload(agyPayload('agy.error', link, const {})), isNull);
      expect(routeForPayload(link), '/agy/agy-aaaaaaaaaaaa');
    });

    group('düğmeler', () {
      final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
      final profile = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();
      final payload = jsonEncode({'link': 'tiphys://agy/$agySessionId', 'sessionId': agySessionId, 'requestId': 'a1b2c3d4e5f6'});

      FakeAgyState waiting() => FakeAgyState()..waitingScenario();

      // This agent offers other ids: the kind decides, not the id.
      FakeAgyState otherIds() => waiting()
        ..session = {
          ...(waiting().session),
          'pendingPermissions': [
            {
              'requestId': 'a1b2c3d4e5f6',
              'options': [
                {'optionId': 'yes-once', 'name': 'Yes', 'kind': 'allow_once'},
                {'optionId': 'no-once', 'name': 'No', 'kind': 'reject_once'},
              ],
            },
          ],
        };

      test('İzin ver: oturumun sunduğu allow_once seçeneği gönderilir (Reddet: reject_once)', () async {
        final st = otherIds();
        final calls = <(String, String, Object?)>[];
        final ok = await decideFromNotification(
          payload,
          true,
          profile: profile,
          secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
          clientFor: (u, t) => _Fake(st, calls),
        );
        expect(ok, isTrue);
        expect(calls.map((c) => '${c.$1} ${c.$2}'), [
          'GET /v1/agy/sessions/$agySessionId',
          'POST /v1/agy/sessions/$agySessionId/permissions/a1b2c3d4e5f6',
        ]);
        expect(calls.last.$3, {'optionId': 'yes-once'});
        final calls2 = <(String, String, Object?)>[];
        await decideFromNotification(
          payload,
          false,
          profile: profile,
          secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
          clientFor: (u, t) => _Fake(otherIds(), calls2),
        );
        expect(calls2.last.$3, {'optionId': 'no-once'});
      });

      test('agent ipucu bir ajanı gösteriyorsa yalnız o ajana gidilir; eşleşmezse ya da yoksa Claude ajanı önce', () async {
        final named = jsonEncode({'link': 'tiphys://agy/$agySessionId', 'sessionId': agySessionId, 'requestId': 'a1b2c3d4e5f6', 'host': 'atlas'});
        final secrets = MemorySecretStore({'agent-argo': 'tph_a', 'agent-atlas': 'tph_b'});
        final calls = <(String, String, Object?)>[];
        final urls = <String>[];
        _Fake mk(String u, String t) => _Fake(waiting(), calls, base: u, urls: urls);
        expect(await decideFromNotification(named, true, profile: profile, secrets: secrets, clientFor: mk), isTrue);
        expect(urls.toSet(), {'https://atlas.example.ts.net:7443'}, reason: 'argo hiç sorulmadı');
        urls.clear();
        // A hint that matches no host: the old order (Claude host first).
        urls.clear();
        final unknown = jsonEncode({'link': 'tiphys://agy/$agySessionId', 'sessionId': agySessionId, 'requestId': 'a1b2c3d4e5f6', 'host': 'nowhere'});
        expect(await decideFromNotification(unknown, true, profile: profile, secrets: secrets, clientFor: mk), isTrue);
        expect(urls.first, 'https://argo.example.ts.net:7443');
        urls.clear();
        expect(await decideFromNotification(payload, true, profile: profile, secrets: secrets, clientFor: mk), isTrue);
        expect(urls.first, 'https://argo.example.ts.net:7443');
        // The named agent doesn't know the session: no guessing on other hosts.
        urls.clear();
        final stale = jsonEncode({
          'link': 'tiphys://agy/agy-cccccccccccc',
          'sessionId': 'agy-cccccccccccc',
          'requestId': 'a1b2c3d4e5f6',
          'host': 'atlas',
        });
        expect(await decideFromNotification(stale, true, profile: profile, secrets: secrets, clientFor: mk), isFalse);
        expect(urls.toSet(), {'https://atlas.example.ts.net:7443'});
      });

      test('agy’nin kendi kimlikleri (agent testindeki sahte): allow / deny; karar oturumda çözülür', () async {
        final st = waiting();
        final calls = <(String, String, Object?)>[];
        final ok = await decideFromNotification(
          payload,
          true,
          profile: profile,
          secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
          clientFor: (u, t) => _Fake(st, calls),
        );
        expect(ok, isTrue);
        expect(calls.last.$3, {'optionId': 'allow'});
        expect(st.log, ['POST permissions/a1b2c3d4e5f6 allow']);
        expect(agyResolvedPermissions(st.events.map(AgyEvent.new)), {'a1b2c3d4e5f6': 'allow'});
      });

      test('Reddet; istek artık yoksa (404) ya da oturum bilinmiyorsa false; belirteç yoksa false; Claude yükü Claude yoluna gider', () async {
        final st = waiting();
        final calls = <(String, String, Object?)>[];
        expect(
          await decideFromNotification(
            payload,
            false,
            profile: profile,
            secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
            clientFor: (u, t) => _Fake(st, calls),
          ),
          isTrue,
        );
        expect(calls.last.$3, {'optionId': 'deny'});
        // Already answered: the POST fails with permissionNotFound → false (the user is told).
        expect(
          await decideFromNotification(
            payload,
            false,
            profile: profile,
            secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
            clientFor: (u, t) => _Fake(st, []),
          ),
          isFalse,
        );
        final unknown = jsonEncode({'link': 'tiphys://agy/agy-cccccccccccc', 'sessionId': 'agy-cccccccccccc', 'requestId': 'a1b2c3d4e5f6'});
        expect(
          await decideFromNotification(
            unknown,
            true,
            profile: profile,
            secrets: MemorySecretStore({'agent-argo': 'tph_x'}),
            clientFor: (u, t) => _Fake(st, []),
          ),
          isFalse,
        );
        expect(await decideFromNotification(payload, true, profile: profile, secrets: MemorySecretStore()), isFalse);
        expect(
          await decideFromNotification(
            payload,
            true,
            profile: profile,
            secrets: MemorySecretStore({'agent-argo': 't'}),
            clientFor: (u, t) => _Fake(st, [], fail: true),
          ),
          isFalse,
        );
      });
    });
  });

  group('metinler', () {
    test('agent.agy.* kodlarının hepsi iki dilde metne çevrilir (yedek metin kalmaz) ve agentErrorText’ten geçer', () {
      expect(agyErrorCodes, hasLength(15));
      for (final l in [_tr, _en]) {
        final seen = <String>{};
        for (final code in agyErrorCodes) {
          final t = agyErrorText(l, code);
          expect(t, isNot(contains(code)), reason: '$code ${l.localeName}');
          expect(t.trim(), isNotEmpty);
          expect(seen.add(t), isTrue, reason: 'her kodun kendi metni var: $code');
          expect(agentErrorText(l, AgentError(code, const {}, 409)), t);
        }
        expect(agyErrorText(l, 'agent.agy.yeni'), contains('agent.agy.yeni'), reason: 'bilinmeyen kod: kod görünür');
      }
      expect(agyErrorText(_tr, 'agent.agy.busy'), 'agy şu an çalışıyor ya da izin bekliyor; bitince tekrar dene.');
      expect(agyErrorText(_en, 'agent.agy.busy'), startsWith('agy is working'));
    });

    test('kip etiketleri ve açıklamaları iki dilde; bilinmeyen kip agy’nin adını gösterir', () {
      for (final l in [_tr, _en]) {
        for (final m in agyKnownModes) {
          expect(agyModeLabel(l, m), isNotEmpty);
          expect(agyModeHint(l, m), isNotEmpty);
        }
      }
      expect(agyModeLabel(_tr, 'accept-edits'), 'Düzenlemeleri kabul et');
      expect(agyModeLabel(_en, 'auto'), 'Auto');
      expect(agyModeLabel(_tr, 'yeni', 'Yeni kip'), 'Yeni kip');
      expect(agyModeLabel(_tr, 'yeni'), 'yeni');
      expect(agyModeHint(_tr, 'yeni'), isNull);
      expect(agyEventErrorText(_tr, 'agent.agy.timeout'), agyErrorText(_tr, 'agent.agy.timeout'));
      expect(agyEventErrorText(_tr, 'agy exited'), 'agy exited');
    });

    test('yeni anahtarların hepsi TR ve EN arb dosyalarında (aynı yer tutucularla) var', () {
      Map<String, dynamic> arb(String n) => jsonDecode(File('lib/l10n/app_$n.arb').readAsStringSync()) as Map<String, dynamic>;
      final tr = arb('tr'), en = arb('en');
      bool mine(String k) => !k.startsWith('@') && (k.startsWith('agy') || k.startsWith('continuePc') || k.startsWith('notifAgy'));
      final keys = tr.keys.where(mine).toList();
      expect(keys.length, greaterThan(60));
      for (final k in keys) {
        expect(en[k], isA<String>(), reason: 'EN: $k');
        expect((en[k] as String).trim(), isNotEmpty);
        expect(
          RegExp(r'\{(\w+)\}').allMatches(en[k] as String).map((m) => m.group(1)).toSet(),
          RegExp(r'\{(\w+)\}').allMatches(tr[k] as String).map((m) => m.group(1)).toSet(),
          reason: 'yer tutucular: $k',
        );
      }
      expect(en.keys.where(mine).toSet(), keys.toSet());
    });
  });

  group('PC’de devam et komutu', () {
    test('kabuk tırnağı ajanla aynı: tek tırnak içinde, içindeki tek tırnak \'\\\'\' olur', () {
      expect(shellQuote('/home/user/proj'), "'/home/user/proj'");
      expect(shellQuote("/home/user/it's here"), "'/home/user/it'\\''s here'");
      expect(shellQuote(r'/a b/$HOME/`x`;rm'), r"'/a b/$HOME/`x`;rm'");
    });

    test('Claude ve agy komutları ajanın resumeCommand’ıyla aynı biçimde', () {
      expect(
        claudeResumeCommand('/home/user/Desktop/website', '7e08e218-0000-4000-8000-000000000001'),
        "cd '/home/user/Desktop/website' && claude --resume 7e08e218-0000-4000-8000-000000000001",
      );
      expect(agyResumeCommand('/home/user/Desktop/tiphys', 's-new-0001'), agyResume('/home/user/Desktop/tiphys', 's-new-0001'));
      expect(agyResumeCommand("/home/u/it's", 'abc12345'), "cd '/home/u/it'\\''s' && agy --conversation abc12345");
    });
  });
}
