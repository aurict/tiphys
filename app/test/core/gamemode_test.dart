// Game mode data layer (PLAN.md §19): status parsing, optimistic settings, start/stop, connect (service token) and the
// source-host lookup, against the fake agent (no network).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/gamemode/gamemode_data.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/gamemode_fixtures.dart';
import '../helpers/harness.dart';

ProviderContainer _container() {
  final c = ProviderContainer(overrides: Harness(agentFeatures: [...Harness.defaultAgentFeatures, 'gamemode']).overrides);
  addTearDown(c.dispose);
  return c;
}

/// Keeps the autoDispose provider alive and waits for its first value.
Future<GameStatus> _status(ProviderContainer c, [String host = gameDisplayHost]) async {
  c.listen(gameModeProvider(host), (_, _) {});
  return c.read(gameModeProvider(host).future);
}

void main() {
  setUp(() {
    FakeAgent.resetGame();
    FakeAgent.calls.clear();
  });

  test('durum ayrıştırılır; otomatik sahne sürüşe geçer', () {
    final s = GameStatus.fromJson({
      'running': true,
      'startedAt': '2026-11-14T13:00:00Z',
      'settings': {'scene': 'auto', 'brightness': 40, 'dimIdleMinutes': 0},
      'source': {'configured': true, 'url': 'https://atlas.example.ts.net:7443', 'state': 'ok'},
      'live': {
        'music': {'title': 'A', 'artist': 'B', 'playing': true},
        'truck': {'state': 'driving', 'from': 'Bursa', 'to': 'Münih', 'speedKmh': 84},
      },
    });
    expect(s.running, isTrue);
    expect(s.settings.brightness, 40);
    expect(s.settings.dimIdleMinutes, 0);
    expect(s.truck!.driving, isTrue);
    expect(s.activeScene, 'drive');
    expect(s.copyWith(settings: s.settings.apply({'scene': 'music'})).activeScene, 'music');
    // Nothing playing and no game: standby; brightness "don't touch" survives apply.
    final idle = GameStatus.fromJson({
      'running': true,
      'live': {'music': null, 'truck': null},
    });
    expect(idle.activeScene, 'idle');
    expect(const GameSettings(brightness: 50).apply({'brightness': null}).brightness, isNull);
  });

  test('ayar değişikliği hemen görünür ve ajana PUT edilir', () async {
    final c = _container();
    await _status(c);
    final f = c.read(gameModeProvider(gameDisplayHost).notifier).saveSettings({'lyrics': false});
    // Optimistic: before the answer.
    expect(c.read(gameModeProvider(gameDisplayHost)).value!.settings.lyrics, isFalse);
    await f;
    expect(FakeAgent.calls.where((x) => x.$1 == 'PUT' && x.$2 == '/v1/gamemode').single.$3, {
      'settings': {'lyrics': false},
    });
    expect(FakeAgent.game.settings['lyrics'], isFalse);
    expect(c.read(gameModeProvider(gameDisplayHost)).value!.settings.lyrics, isFalse);
  });

  test('parlaklık "dokunma" null olarak gider', () async {
    final c = _container();
    FakeAgent.game.settings['brightness'] = 70;
    await _status(c);
    await c.read(gameModeProvider(gameDisplayHost).notifier).saveSettings({'brightness': null});
    expect(FakeAgent.calls.last.$3, {
      'settings': {'brightness': null},
    });
    expect(c.read(gameModeProvider(gameDisplayHost)).value!.settings.brightness, isNull);
  });

  test('ayar hatası: hata fırlatılır, gerçek durum yeniden okunur', () async {
    final c = _container();
    await _status(c);
    FakeAgent.game.putError = const AgentError('net.unreachable');
    await expectLater(c.read(gameModeProvider(gameDisplayHost).notifier).saveSettings({'scene': 'drive'}), throwsA(isA<AgentError>()));
    FakeAgent.game.putError = null;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await c.read(gameModeProvider(gameDisplayHost).future)).settings.scene, 'auto');
  });

  test('başlat ve durdur; kaynak yoksa agent.gamemode.noSource', () async {
    final c = _container();
    await _status(c);
    final n = c.read(gameModeProvider(gameDisplayHost).notifier);
    await n.setRunning(true);
    expect(c.read(gameModeProvider(gameDisplayHost)).value!.running, isTrue);
    expect(FakeAgent.calls.any((x) => x.$1 == 'POST' && x.$2 == '/v1/gamemode/start'), isTrue);
    await n.setRunning(false);
    expect(c.read(gameModeProvider(gameDisplayHost)).value!.running, isFalse);
    expect(FakeAgent.calls.last.$2, '/v1/gamemode/stop');

    FakeAgent.game.configured = false;
    await expectLater(n.setRunning(true), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.gamemode.noSource')));
  });

  test('kaynak sunucusunu adresten bulur', () {
    final c = _container();
    final p = c.read(profileProvider);
    expect(hostForAgentUrl(p, 'https://atlas.example.ts.net:7443/')?.id, 'atlas');
    expect(hostForAgentUrl(p, 'https://ATLAS.example.ts.net:7443')?.id, 'atlas');
    expect(hostForAgentUrl(p, 'https://unknown.ts.net:7443'), isNull);
    expect(hostForAgentUrl(p, null), isNull);
  });

  test('bağlan: kaynakta gamemode kapsamlı jeton, ekran ajanına yazılır, jeton geri dönmez', () async {
    final c = _container();
    final p = c.read(profileProvider);
    FakeAgent.game.configured = false;
    final st = await connectGameMode(display: p.host('argo')!, source: p.host('atlas')!, displayClient: FakeAgent('argo'), sourceClient: FakeAgent('atlas'));
    expect(FakeAgent.game.tokensCreated.single['scopes'], ['gamemode']);
    expect(FakeAgent.game.storedSource, {'url': 'https://atlas.example.ts.net:7443', 'token': 'tps_secret_1'});
    expect(st.sourceConfigured, isTrue);
    expect(st.toString(), isNot(contains('tps_')));
    expect(FakeAgent.game.tokensRevoked, isEmpty);
  });

  test('bağlan: ekran ajanı reddederse jeton iptal edilir', () async {
    final c = _container();
    final p = c.read(profileProvider);
    FakeAgent.game.putError = const AgentError('agent.request.invalid', {}, 400);
    await expectLater(
      connectGameMode(display: p.host('argo')!, source: p.host('atlas')!, displayClient: FakeAgent('argo'), sourceClient: FakeAgent('atlas')),
      throwsA(isA<AgentError>()),
    );
    expect(FakeAgent.game.tokensRevoked, ['game-mode-1']);
  });

  test('ana sayfa hedefi: kaynağı kurulu olan ekran hostu', () async {
    final c = _container();
    c.listen(gameModeTargetProvider, (_, _) {});
    final t = await c.read(gameModeTargetProvider.future);
    expect(t!.host.id, gameDisplayHost);
    expect(t.configured, isTrue);
  });

  test('ana sayfa hedefi: hiçbiri kurulu değilse ilk özellikli host, kurulum gerekli', () async {
    FakeAgent.game.configured = false;
    final c = _container();
    c.listen(gameModeTargetProvider, (_, _) {});
    final t = await c.read(gameModeTargetProvider.future);
    expect(t!.configured, isFalse);
  });
}
