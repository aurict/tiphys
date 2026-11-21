// Screen modes data layer (PLAN.md §20 U): status parsing (and the §19 fallback), optimistic settings, start / hot switch
// / stop, Focus timer actions, connecting a source (service token), code sharing on the source, the home card target,
// the gameMode → screenMode card migration, the quiet-notification filter and the Focus side effects, and the texts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/focus_notices.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/core/security/app_lock.dart';
import 'package:tiphys/features/screen/screen_data.dart';
import 'package:tiphys/features/screen/screen_texts.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/features/system/events.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';
import '../helpers/screen_fixtures.dart';

late Harness _h;

ProviderContainer _container() {
  _h = Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'screen', 'gamemode']);
  final c = ProviderContainer(overrides: _h.overrides);
  addTearDown(c.dispose);
  return c;
}

/// Keeps the autoDispose provider alive and waits for its first value.
Future<ScreenStatus> _status(ProviderContainer c, [String host = screenDisplayHost]) async {
  c.listen(screenProvider(host), (_, _) {});
  return c.read(screenProvider(host).future);
}

List<(String, String, Object?)> _calls(String path) => [
  for (final c in FakeAgent.calls)
    if (c.$2 == path) c,
];

void main() {
  setUp(() {
    FakeAgent.resetScreen();
    FakeAgent.calls.clear();
  });

  group('model', () {
    test('durum ayrıştırılır; odak kalan süresi saat kaymasını düzeltir', () {
      final received = DateTime.fromMillisecondsSinceEpoch(1_000_000);
      final s = ScreenStatus.fromJson({
        'running': true,
        'mode': 'focus',
        'startedAt': '2026-11-21T09:00:00Z',
        'settings': {
          'lastMode': 'focus',
          'share': {'code': true},
          'modes': {
            'focus': {'focusMin': 30, 'quietPhone': false},
          },
        },
        'sources': [
          {'name': 'self', 'url': null, 'state': 'ok', 'topics': []},
          {'name': 'atlas', 'url': 'https://atlas.example.ts.net:7443', 'state': 'down', 'topics': ['git']},
        ],
        'veil': true,
        // The agent's clock is 60 s ahead of the phone's.
        'focus': {'phase': 'focus', 'endsAt': 1_000_000 + 60_000 + 300_000, 'pausedLeft': null, 'total': 1_500_000, 'round': 2, 'longEvery': 4, 'task': 'x', 'now': 1_060_000},
        'live': {
          'claude': {'sessions': 2, 'waiting': 1},
          'jobs': 3,
        },
      }, receivedAt: received);
      expect(s.mode, 'focus');
      expect(s.settings.shareCode, isTrue);
      expect(s.settings.mode('focus').focusMin, 30);
      expect(s.settings.mode('focus').quietPhone, isFalse);
      expect(s.settings.mode('focus').shortMin, 5, reason: 'varsayılan');
      expect(s.remoteSources.single.state, 'down');
      expect(s.veil, isTrue);
      expect((s.claudeSessions, s.claudeWaiting, s.jobs), (2, 1, 3));
      // 300 s left on the agent's clock, whatever the phone's clock says.
      expect(s.focus.remaining(received), const Duration(seconds: 300));
      expect(s.focus.remaining(received.add(const Duration(seconds: 100))), const Duration(seconds: 200));
      expect(s.focus.progress(received), 0.8);
      expect(clockText(const Duration(milliseconds: 871_400)), '14:32');
      expect(clockText(const Duration(hours: 1, seconds: 5)), '1:00:05');
    });

    test('eski ajan (§19) durumu: yalnız Oyun, kaynak main', () {
      final s = ScreenStatus.fromLegacy({
        'running': true,
        'settings': {'scene': 'drive', 'brightness': 40},
        'source': {'configured': true, 'url': 'https://atlas.example.ts.net:7443', 'state': 'ok'},
        'live': {
          'truck': {'state': 'driving', 'from': 'Bursa', 'to': 'Münih', 'speedKmh': 84},
        },
      });
      expect(s.legacy, isTrue);
      expect(s.mode, 'game');
      expect(s.settings.mode('game').brightness, 40);
      expect(s.settings.mode('game').layout.commonSource, 'main');
      expect(s.remoteSources.single.name, 'main');
      expect(s.activeScene, 'drive');
    });

    test('düzen: şablonda olup düzende olmayan kartlar kapalı eklenir; ortak kaynak; ayar birleştirme', () {
      final l = ScreenLayout.fromJson('focus', {
        'template': 'focus',
        'cards': [
          {'kind': 'task', 'source': 'atlas', 'enabled': true},
          {'kind': 'focus', 'source': 'atlas', 'enabled': true},
        ],
      });
      expect(l.commonSource, 'atlas');
      expect([for (final c in l.complete('focus')) '${c.kind}:${c.enabled}'], ['task:true', 'focus:true', 'day:false', 'music:false', 'servers:false']);
      expect(l.withSource('self').commonSource, 'self');
      expect(ScreenLayout(l.template, [l.cards.first, l.cards.last.copyWith(source: 'self')]).commonSource, isNull);
      final merged = mergeSettings(
        {
          'modes': {
            'work': {
              'city': '3d',
              'project': {'path': '/a'},
              'layout': {'template': 'work', 'cards': []},
            },
          },
        },
        {
          'modes': {
            'work': {'project': 'auto', 'brightness': null},
          },
        },
      );
      expect(merged['modes']['work'], {'city': '3d', 'project': 'auto', 'layout': {'template': 'work', 'cards': []}, 'brightness': null});
    });
  });

  group('işlemler', () {
    test('ayar hemen görünür ve iç içe PUT edilir; hata gerçek durumu geri okur', () async {
      final c = _container();
      await _status(c);
      final n = c.read(screenProvider(screenDisplayHost).notifier);
      final f = n.saveSettings({
        'modes': {
          'work': {'city': '2d'},
        },
      });
      expect(c.read(screenProvider(screenDisplayHost)).value!.settings.mode('work').city, '2d');
      await f;
      expect(_calls('/v1/screen').where((x) => x.$1 == 'PUT').single.$3, {
        'settings': {
          'modes': {
            'work': {'city': '2d'},
          },
        },
      });
      expect(FakeAgent.screen.settings['modes']['work']['city'], '2d');
      FakeAgent.screen.putError = const AgentError('net.unreachable');
      await expectLater(
        n.saveSettings({
          'modes': {
            'work': {'city': '3d'},
          },
        }),
        throwsA(isA<AgentError>()),
      );
      FakeAgent.screen.putError = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await c.read(screenProvider(screenDisplayHost).future)).settings.mode('work').city, '2d');
    });

    test('başlat, sıcak geçiş (mode), durdur', () async {
      final c = _container();
      await _status(c);
      final n = c.read(screenProvider(screenDisplayHost).notifier);
      await n.start('work');
      expect(_calls('/v1/screen/start').single.$3, {'mode': 'work'});
      await n.start('focus');
      expect(_calls('/v1/screen/mode').single.$3, {'mode': 'focus'}, reason: 'çalışırken başka mod sıcak geçiştir');
      expect(c.read(screenProvider(screenDisplayHost)).value!.mode, 'focus');
      await n.stop();
      expect(_calls('/v1/screen/stop'), hasLength(1));
      expect(c.read(screenProvider(screenDisplayHost)).value!.running, isFalse);
      FakeAgent.screen.startError = const AgentError('agent.screen.bindTaken', {'bind': 'SUPER,grave'}, 409);
      await expectLater(n.start('work'), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.screen.bindTaken')));
    });

    test('odak sayacı ve görev; perde', () async {
      final c = _container();
      FakeAgent.screen.focus(phase: 'idle', task: null);
      await _status(c);
      final n = c.read(screenProvider(screenDisplayHost).notifier);
      await n.focus(action: 'start', task: 'Kısa görev');
      expect(_calls('/v1/screen/focus').single.$3, {'action': 'start', 'task': 'Kısa görev'});
      final f = c.read(screenProvider(screenDisplayHost)).value!.focus;
      expect((f.phase, f.round, f.task, f.ticking), ('focus', 1, 'Kısa görev', true));
      await n.focus(task: '');
      expect(_calls('/v1/screen/focus').last.$3, {'task': ''});
      expect(c.read(screenProvider(screenDisplayHost)).value!.focus.task, isNull);
      await n.veil(true);
      expect(_calls('/v1/screen/veil').single.$3, {'on': true});
      expect(c.read(screenProvider(screenDisplayHost)).value!.veil, isTrue);
    });

    test('eski ajan: /v1/gamemode\'a düşülür, Çalışma/Odak güncelleme ister', () async {
      FakeAgent.screen.legacy = true;
      final c = _container();
      final s = await _status(c);
      expect(s.legacy, isTrue);
      final n = c.read(screenProvider(screenDisplayHost).notifier);
      await expectLater(n.start('work'), throwsA(isA<AgentError>().having((e) => e.code, 'code', needsUpdateCode)));
      await n.start('game');
      expect(_calls('/v1/gamemode/start'), hasLength(1));
      await n.saveSettings({
        'modes': {
          'game': {'lyrics': false},
        },
      });
      expect(_calls('/v1/gamemode').where((x) => x.$1 == 'PUT').single.$3, {
        'settings': {'lyrics': false},
      });
      await n.stop();
      expect(_calls('/v1/gamemode/stop'), hasLength(1));
      expect(_calls('/v1/screen/start'), isEmpty);
    });

    test('kaynak bağlama: kaynakta screen kapsamlı jeton, ekran ajanına sources altında; hata olursa iptal', () async {
      final c = _container();
      final p = c.read(profileProvider);
      final st = FakeAgent.screen..sources.clear();
      final name = await connectScreenSource(display: p.host('argo')!, source: p.host('atlas')!, displayClient: FakeAgent('argo'), sourceClient: FakeAgent('atlas'), legacy: false);
      expect(name, 'atlas');
      expect(st.tokensCreated.single['scopes'], ['screen']);
      expect(st.tokensCreated.single['name'], 'Screen mode: argo (PC)');
      expect(st.sources, {'atlas': 'https://atlas.example.ts.net:7443'});
      expect(st.storedTokens['atlas'], 'tps_secret_1');
      // Removing it revokes the token the wizard made.
      await revokeScreenTokens(display: p.host('argo')!, sourceClient: FakeAgent('atlas'));
      expect(st.tokensRevoked, ['screen-1']);

      st.putError = const AgentError('agent.request.invalid', {}, 400);
      await expectLater(
        connectScreenSource(display: p.host('argo')!, source: p.host('atlas')!, displayClient: FakeAgent('argo'), sourceClient: FakeAgent('atlas'), legacy: false),
        throwsA(isA<AgentError>()),
      );
      expect(st.tokensRevoked, ['screen-1', 'screen-2']);
    });

    test('eski ekran ajanına bağlama: gamemode kapsamı, PUT /v1/gamemode {source}', () async {
      final c = _container();
      final p = c.read(profileProvider);
      FakeAgent.screen.legacySource = null;
      final name = await connectScreenSource(display: p.host('argo')!, source: p.host('atlas')!, displayClient: FakeAgent('argo'), sourceClient: FakeAgent('atlas'), legacy: true);
      expect(name, 'main');
      expect(FakeAgent.screen.tokensCreated.single['scopes'], ['gamemode']);
      expect(FakeAgent.screen.legacySource, {'url': 'https://atlas.example.ts.net:7443', 'token': 'tps_secret_1'});
    });

    test('kod paylaşımı kaynağın kendi API\'sine yazılır', () async {
      await setShareCode(FakeAgent('atlas'), true);
      expect((FakeAgent.calls.single.$1, FakeAgent.calls.single.$2), ('PUT', '/v1/screen'));
      expect(FakeAgent.calls.single.$3, {
        'settings': {
          'share': {'code': true},
        },
      });
      expect(FakeAgent.screen.shareCode, {'argo': false, 'atlas': true});
    });

    test('ana sayfa hedefi: çalışan ekran hostu; eski ajanda kaynak yoksa kurulum', () async {
      final c = _container();
      c.listen(screenTargetProvider, (_, _) {});
      expect((await c.read(screenTargetProvider.future))!.host.id, screenDisplayHost);
      FakeAgent.screen
        ..legacy = true
        ..legacySource = null;
      final c2 = _container();
      c2.listen(screenTargetProvider, (_, _) {});
      final t = await c2.read(screenTargetProvider.future);
      expect(t!.ready, isFalse);
    });

    test('kaynak adı ve okunur etiket', () {
      final c = _container();
      final p = c.read(profileProvider);
      expect(sourceNameFor(p.host('atlas')!), 'atlas');
      expect(hostForAgentUrl(p, 'https://ATLAS.example.ts.net:7443/')?.id, 'atlas');
      expect(hostForAgentUrl(p, 'https://unknown.example.ts.net:7443'), isNull);
    });
  });

  group('ana sayfa kartı göçü', () {
    test('gameMode → screenMode aynı yerde; tekrar yok', () {
      expect(migrateHomeCards(['infra', 'gameMode', 'claude']), ['infra', 'screenMode', 'claude']);
      expect(migrateHomeCards(['gameMode', 'screenMode', 'system']), ['screenMode', 'system']);
      expect(allHomeCards, contains('screenMode'));
      expect(allHomeCards, isNot(contains('gameMode')));
      expect(defaultHomeCards, isNot(contains('screenMode')));
    });

    test('eski profil dosyası şemadan geçer ve screenMode olarak okunur; kaydedilince screenMode yazılır', () {
      final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
      (j['app']['home'] as Map<String, dynamic>)['cards'] = ['infra', 'gameMode', 'claude', 'system'];
      final p = codec.decode(jsonEncode(j)).toProfile();
      expect(p.app.cards, ['infra', 'screenMode', 'claude', 'system']);
      expect(p.app.toJson()['home']['cards'], ['infra', 'screenMode', 'claude', 'system']);
      // The new id is valid in the schema too.
      (j['app']['home'] as Map<String, dynamic>)['cards'] = ['screenMode'];
      expect(codec.decode(jsonEncode(j)).toProfile().app.cards, ['screenMode']);
    });
  });

  group('bildirim susturma (Odak)', () {
    final now = DateTime(2026, 11, 21, 10);

    test('kritik olanlar her zaman geçer, diğerleri bekletilir', () {
      final r = QuietRecord(host: 'argo', until: now.add(const Duration(minutes: 20)), at: now);
      for (final k in ['host.offline', 'uptime.down', 'service.failed', 'claude.waiting', 'agy.waiting', 'command.failed', 'claude.error', 'backup.failed', 'security.trap']) {
        expect(quietHolds(r, k, const {}, now), isFalse, reason: k);
      }
      expect(quietHolds(r, 'security.change', const {'severity': 'critical'}, now), isFalse);
      for (final k in ['claude.done', 'git.committed', 'host.online', 'uptime.up', 'backup.ok', 'command.done', 'security.change', 'clipboard.pc']) {
        expect(quietHolds(r, k, const {}, now), isTrue, reason: k);
      }
      // Between rounds, after the round's end, or without a record: everything shows.
      expect(quietHolds(QuietRecord(host: 'argo', at: now), 'claude.done', const {}, now), isFalse);
      expect(quietHolds(r, 'claude.done', const {}, now.add(const Duration(minutes: 21))), isFalse);
      expect(quietHolds(null, 'claude.done', const {}, now), isFalse);
    });

    test('kayıt: tur, sayım, mola, bitiş; unutulan kayıt 6 saat sonra biter; içerik saklanmaz', () async {
      final vault = MemoryVault();
      final q = FocusQuiet(vault);
      await q.enter('argo', now.add(const Duration(minutes: 25)), now);
      expect(await q.hold('claude.done', {'title': 'Gizli başlık'}, now), isTrue);
      expect(await q.hold('git.committed', const {}, now), isTrue);
      expect(await q.hold('host.offline', const {}, now), isFalse);
      await q.rest('argo', now.add(const Duration(minutes: 26)));
      expect(await q.hold('claude.done', const {}, now.add(const Duration(minutes: 27))), isFalse);
      await q.enter('argo', now.add(const Duration(minutes: 55)), now.add(const Duration(minutes: 30)));
      expect(await q.hold('claude.done', const {}, now.add(const Duration(minutes: 31))), isTrue);
      expect(vault.m.values.single, isNot(contains('Gizli')));
      expect(jsonDecode(vault.m.values.single), {'host': 'argo', 'until': now.add(const Duration(minutes: 55)).millisecondsSinceEpoch, 'held': 3, 'at': now.add(const Duration(minutes: 30)).millisecondsSinceEpoch});
      expect(await q.endIfStale(now.add(const Duration(hours: 2))), 0);
      expect(await q.end(), 3);
      expect(vault.m, isEmpty);
      await q.enter('argo', now, now);
      expect(await q.endIfStale(now.add(const Duration(hours: 7))), 0, reason: 'bekletilen yok, özet yok');
      expect(vault.m, isEmpty);
    });

    test('uygulama durumu: Odak turu → kalıcı bildirim + susturma; mod kapanınca özet', () async {
      final c = _container();
      FakeAgent.screen.focus();
      await _status(c);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final shown = _h.focusNotifications.shown;
      expect(shown.last, isNotNull);
      expect((shown.last!.phase, shown.last!.round, shown.last!.paused), ('focus', 2, false));
      final q = FocusQuiet(_h.quietVault);
      expect(await q.hold('claude.done', const {}, DateTime.now()), isTrue);
      await c.read(screenProvider(screenDisplayHost).notifier).stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shown.last, isNull);
      expect(_h.focusNotifications.summaries, [1]);
      expect(await q.read(), isNull);
    });

    test('quietPhone kapalıyken susturma yok; mola arası', () async {
      final c = _container();
      FakeAgent.screen.focus(phase: 'short');
      await _status(c);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await FocusQuiet(_h.quietVault).read(), isNull, reason: 'molada tur yok');
      expect(_h.focusNotifications.shown.last!.phase, 'short');
      FakeAgent.screen.settings['modes']['focus']['quietPhone'] = false;
      FakeAgent.screen.focus();
      final c2 = _container();
      await _status(c2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await FocusQuiet(_h.quietVault).read(), isNull);
    });
  });

  test('metinler: hata kodları, olaylar ve odak bildirimi iki dilde (görev yok)', () {
    final tr = AppLocalizationsTr(), en = AppLocalizationsEn();
    for (final code in ['noSource', 'noDisplay', 'startFailed', 'bindTaken', 'badLayout', 'notFocus', 'notRunning', 'noArt']) {
      for (final l in [tr, en]) {
        expect(agentErrorText(l, AgentError('agent.screen.$code', const {'bind': 'SUPER,grave'})), isNot(contains('agent.screen')), reason: code);
      }
    }
    for (final code in ['noSource', 'noDisplay', 'startFailed', 'noGame', 'noArt', 'pluginDownloadFailed', 'pluginHashMismatch', 'pluginBadArchive']) {
      expect(agentErrorText(tr, AgentError('agent.gamemode.$code')), isNot(contains('agent.gamemode')), reason: code);
    }
    expect(agentErrorText(tr, const AgentError('agent.screen.bindTaken', {'bind': 'SUPER,grave'})), contains('Super + `'));
    expect(agentErrorText(en, const AgentError(needsUpdateCode)), en.smNeedsUpdate);
    expect(noticeText(tr, 'screen.started', {'mode': 'focus', 'device': 'Redmi'}), ('Ekran modu açıldı: Odak', 'Redmi'));
    expect(noticeText(en, 'screen.stopped', {}), ('Screen mode stopped', ''));
    expect(noticeText(tr, 'screen.focus.phase', {'phase': 'short', 'from': 'focus', 'round': 2, 'cause': 'timer'}), ('Odak: kısa mola', '2. tur bitti'));
    expect(noticeText(en, 'screen.focus.phase', {'phase': 'focus', 'from': 'short', 'round': 3, 'cause': 'timer'}), ('Focus: round 3', 'The break is over'));
    expect(noticeText(tr, 'screen.focus.phase', {'phase': 'idle', 'from': 'focus', 'round': 3, 'cause': 'stop'})!.$2, 'Mod kapandı');
    expect(noticeId('screen.focus.phase', {'phase': 'focus'}), noticeId('screen.focus.phase', {'phase': 'short'}));
    expect(eventType('screen.started'), 'system');
    expect(eventType('screen.focus.phase'), 'system');
    expect(routeForPayload('{"link":"tiphys://screen","host":"argo"}'), '/screen?host=argo');
    expect(bindText('SUPER_SHIFT,F'), 'Super + Shift + F');
    expect(focusCritical('docker.died', const {}), isTrue);
  });
}
