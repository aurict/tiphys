// Game mode (PLAN.md §19): the data side. The display PC's agent (laptop) holds the mode: GET/PUT /v1/gamemode,
// POST /v1/gamemode/{start,stop}. The source PC (theloth) answers GET /v1/gamemode/source and POST /v1/gamemode/plugin.
// The status is polled every 2 s while a screen or card watches it (and the app is in front); settings changes show at
// once (optimistic) and are sent in order. The source token is only ever in the request that stores it on the agent.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../state/providers.dart';
import '../system/agent_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// The kiosk's settings (`config.gamemode.display` on the agent).
@immutable
class GameSettings {
  const GameSettings({
    this.scene = 'auto',
    this.lyrics = true,
    this.spectrum = true,
    this.motion = 'normal',
    this.brightness,
    this.clock24 = true,
    this.dimIdleMinutes = 10,
  });

  factory GameSettings.fromJson(Map j) => GameSettings(
    scene: '${j['scene'] ?? 'auto'}',
    lyrics: j['lyrics'] != false,
    spectrum: j['spectrum'] != false,
    motion: '${j['motion'] ?? 'normal'}',
    brightness: (j['brightness'] as num?)?.round(),
    clock24: j['clock24'] != false,
    dimIdleMinutes: (j['dimIdleMinutes'] as num?)?.round() ?? 10,
  );

  /// auto | drive | music
  final String scene;
  final bool lyrics;
  final bool spectrum;

  /// low | normal | high
  final String motion;

  /// 5..100; null: the backlight is not touched.
  final int? brightness;
  final bool clock24;

  /// 0: never.
  final int dimIdleMinutes;

  Map<String, Object?> toJson() => {
    'scene': scene,
    'lyrics': lyrics,
    'spectrum': spectrum,
    'motion': motion,
    'brightness': brightness,
    'clock24': clock24,
    'dimIdleMinutes': dimIdleMinutes,
  };

  /// A copy with the given keys replaced (a key mapped to null is kept as null: brightness "don't touch").
  GameSettings apply(Map<String, Object?> patch) => GameSettings.fromJson({...toJson(), ...patch});

  @override
  bool operator ==(Object other) => other is GameSettings && mapEquals(other.toJson(), toJson());
  @override
  int get hashCode => Object.hashAll(toJson().values);
}

class GameMusic {
  GameMusic(Map j) : title = '${j['title'] ?? ''}', artist = '${j['artist'] ?? ''}', playing = j['playing'] == true;
  final String title;
  final String artist;
  final bool playing;
}

class GameTruck {
  GameTruck(Map j) : state = '${j['state'] ?? 'none'}', from = j['from'] as String?, to = j['to'] as String?, speedKmh = (j['speedKmh'] as num?)?.round();

  /// none | menu | paused | driving
  final String state;
  final String? from;
  final String? to;
  final int? speedKmh;
  bool get driving => state == 'driving';
}

@immutable
class GameStatus {
  const GameStatus({
    required this.running,
    this.startedAt,
    this.settings = const GameSettings(),
    this.sourceConfigured = false,
    this.sourceUrl,
    this.sourceState = 'off',
    this.music,
    this.truck,
  });

  factory GameStatus.fromJson(Map j) {
    final src = (j['source'] as Map?) ?? const {};
    final live = (j['live'] as Map?) ?? const {};
    final music = live['music'];
    final truck = live['truck'];
    return GameStatus(
      running: j['running'] == true,
      startedAt: j['startedAt'] is String ? DateTime.tryParse(j['startedAt'] as String) : null,
      settings: GameSettings.fromJson((j['settings'] as Map?) ?? const {}),
      sourceConfigured: src['configured'] == true,
      sourceUrl: src['url'] as String?,
      sourceState: '${src['state'] ?? 'off'}',
      music: music is Map ? GameMusic(music) : null,
      truck: truck is Map ? GameTruck(truck) : null,
    );
  }

  final bool running;
  final DateTime? startedAt;
  final GameSettings settings;
  final bool sourceConfigured;
  final String? sourceUrl;

  /// off | connecting | ok | down
  final String sourceState;
  final GameMusic? music;
  final GameTruck? truck;

  GameStatus copyWith({bool? running, GameSettings? settings}) => GameStatus(
    running: running ?? this.running,
    startedAt: startedAt,
    settings: settings ?? this.settings,
    sourceConfigured: sourceConfigured,
    sourceUrl: sourceUrl,
    sourceState: sourceState,
    music: music,
    truck: truck,
  );

  /// What the kiosk shows right now (scene "auto": driving when the truck is driving, otherwise music or standby).
  String get activeScene => switch (settings.scene) {
    'drive' => 'drive',
    'music' => 'music',
    _ => truck?.driving == true ? 'drive' : (music != null ? 'music' : 'idle'),
  };
}

/// Polls GET /v1/gamemode; actions update the state from the agent's answer (same shape as the GET).
class GameModeNotifier extends AsyncNotifier<GameStatus> {
  GameModeNotifier(this.hostId);
  final String hostId;
  VoidCallback? _cancelTimer;
  bool _closed = false;
  bool _paused = false;

  /// Settings sent but not confirmed yet: laid over every status that arrives meanwhile (so a poll doesn't undo a drag).
  Map<String, Object?> _pending = {};
  int _inflight = 0;
  Future<void> _chain = Future.value();

  @override
  Future<GameStatus> build() async {
    _closed = false;
    _paused = false;
    // Nobody watching (a screen left, the card scrolled away): stop polling at once; it picks up again with a fresh read.
    ref.onCancel(() {
      _paused = true;
      _cancelTimer?.call();
      _cancelTimer = null;
    });
    ref.onResume(() {
      _paused = false;
      unawaited(_poll());
    });
    ref.onDispose(() {
      _closed = true;
      _cancelTimer?.call();
    });
    try {
      return _merge(await _fetch());
    } finally {
      _schedule();
    }
  }

  Future<GameStatus> _fetch() async => GameStatus.fromJson(await withAgent(ref, hostId, (c) => c.get('/v1/gamemode')));

  GameStatus _merge(GameStatus s) => _pending.isEmpty ? s : s.copyWith(settings: s.settings.apply(_pending));

  void _schedule() {
    _cancelTimer?.call();
    if (_closed || _paused) return;
    _cancelTimer = whenVisibleAfter(const Duration(seconds: 2), _poll);
  }

  Future<void> _poll() async {
    if (_closed) return;
    // A request in flight answers with the newest state itself.
    if (_inflight == 0) {
      try {
        final s = _merge(await _fetch());
        if (!_closed && _inflight == 0) state = AsyncData(s);
      } catch (e, st) {
        if (!_closed) state = AsyncError(e, st);
      }
    }
    _schedule();
  }

  /// Another read right away (after a failed action, or the retry button).
  void retry() => ref.invalidateSelf();

  /// Sends changed display settings. The new values show at once; on failure the real state is read again and the
  /// error is thrown to the caller (for a toast).
  Future<void> saveSettings(Map<String, Object?> patch) {
    final cur = state.value;
    if (cur == null || _closed) return Future.value();
    _pending = {..._pending, ...patch};
    state = AsyncData(cur.copyWith(settings: cur.settings.apply(patch)));
    _inflight++;
    final done = _chain.then((_) async {
      try {
        final s = GameStatus.fromJson(await withAgent(ref, hostId, (c) async => (await c.put('/v1/gamemode', {'settings': patch})) as Map));
        if (--_inflight == 0) _pending = {};
        if (!_closed && _inflight == 0) state = AsyncData(s);
      } catch (_) {
        if (--_inflight == 0) _pending = {};
        if (!_closed) retry();
        rethrow;
      }
    });
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Start / stop the mode. Idempotent on the agent.
  Future<void> setRunning(bool on) async {
    final cur = state.value;
    if (_closed) return;
    if (cur != null) state = AsyncData(cur.copyWith(running: on));
    try {
      final j = await withAgent(
        ref,
        hostId,
        (c) async => (await c.request('POST', '/v1/gamemode/${on ? 'start' : 'stop'}', body: const {}, timeout: const Duration(seconds: 25))) as Map,
      );
      if (!_closed) state = AsyncData(_merge(GameStatus.fromJson(j)));
    } catch (_) {
      if (!_closed) retry();
      rethrow;
    }
  }
}

final gameModeProvider = AsyncNotifierProvider.autoDispose.family<GameModeNotifier, GameStatus, String>(GameModeNotifier.new, retry: _noRetry);

/// Hosts whose agent reports the `gamemode` feature as on.
final gameModeHostsProvider = FutureProvider.autoDispose<List<Host>>((ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final found = await Future.wait([
    for (final h in hosts)
      ref.watch(healthProvider(h.id).future).then<Host?>((j) => (j['features'] as Map?)?['gamemode'] == true ? h : null, onError: (_) => null),
  ]);
  return [for (final h in found) ?h];
});

/// The display host for the home card: the first game-mode host whose status says a source is set up. If none is set up
/// yet but a host has the feature, that host with `configured == false` (the card leads to the setup).
class GameTarget {
  const GameTarget(this.host, this.configured);
  final Host host;
  final bool configured;
}

final gameModeTargetProvider = FutureProvider.autoDispose<GameTarget?>(retry: _noRetry, (ref) async {
  autoRefresh(ref, const Duration(seconds: 60));
  final hosts = await ref.watch(gameModeHostsProvider.future);
  var anyFailed = false;
  for (final h in hosts) {
    try {
      final s = GameStatus.fromJson(await withAgent(ref, h.id, (c) => c.get('/v1/gamemode')));
      if (s.sourceConfigured) return GameTarget(h, true);
    } catch (_) {
      anyFailed = true;
    }
  }
  return hosts.isEmpty || anyFailed ? null : GameTarget(hosts.first, false);
});

/// `GET /v1/gamemode/source` on the source PC.
class GameSourceInfo {
  GameSourceInfo(Map j)
    : velour = j['velour'] == true,
      audio = j['audio'] == true,
      gameDir = (j['ets2'] as Map?)?['gameDir'] as String?,
      plugin = '${(j['ets2'] as Map?)?['plugin'] ?? 'missing'}',
      pluginVersion = (j['ets2'] as Map?)?['version'] as String?,
      ets2Running = (j['ets2'] as Map?)?['running'] == true,
      telemetry = '${(j['ets2'] as Map?)?['telemetry'] ?? 'none'}',
      mapPresent = (j['map'] as Map?)?['present'] == true;
  final bool velour;
  final bool audio;
  final String? gameDir;

  /// installed | missing | outdated
  final String plugin;
  final String? pluginVersion;
  final bool ets2Running;

  /// ok | unsupported | none
  final String telemetry;
  final bool mapPresent;
}

final gameSourceProvider = FutureProvider.autoDispose.family<GameSourceInfo, String>(retry: _noRetry, (ref, hostId) async {
  return GameSourceInfo(await withAgent(ref, hostId, (c) => c.get('/v1/gamemode/source')));
});

/// The profile host whose agent URL is [url] (the display agent only reports the URL of its source).
Host? hostForAgentUrl(Profile p, String? url) {
  final u = _origin(url);
  if (u == null) return null;
  return p.hosts.where((h) => _origin(h.agent?.url) == u).firstOrNull;
}

String? _origin(String? url) {
  final u = url == null ? null : Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) return null;
  return '${u.host.toLowerCase()}:${u.hasPort ? u.port : (u.scheme == 'http' ? 80 : 443)}';
}

/// Connects [display] to [source]: a service token with scope `gamemode` is created on the source host, handed to the
/// display agent and nothing else keeps it. If storing it fails the token is revoked again. Returns the display agent's
/// status afterwards (the connection test: nothing is started).
Future<GameStatus> connectGameMode({required Host display, required Host source, required AgentClient displayClient, required AgentClient sourceClient}) async {
  final name = 'Game mode: ${display.name}';
  final created = await sourceClient.post('/v1/service-tokens', {
    'name': name.length > 80 ? name.substring(0, 80) : name,
    'scopes': ['gamemode'],
  }) as Map;
  final tokenId = '${(created['serviceToken'] as Map)['id']}';
  try {
    await displayClient.put('/v1/gamemode', {
      'source': {'url': source.agent!.url, 'token': created['token'] as String},
    });
  } catch (_) {
    try {
      await sourceClient.delete('/v1/service-tokens/$tokenId');
    } catch (_) {
      // The token stays listed on the source PC; it can be revoked there.
    }
    rethrow;
  }
  return GameStatus.fromJson(await displayClient.get('/v1/gamemode'));
}
