// Fake screen mode routes (PLAN.md §20 contract): the display agent (argo) answers /v1/screen*, the source agent (atlas)
// answers /v1/screen/game/source and /v1/screen/game/plugin and its own GET/PUT /v1/screen (code sharing); with [legacy]
// the display is an agent older than §20 and only /v1/gamemode* exists (the §19 shapes). /v1/service-tokens creates and
// lists tokens. Sample data is synthetic; nothing leaves the test.
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/focus_notices.dart';
import 'package:tiphys/features/screen/screen_focus.dart';

const screenDisplayHost = 'argo';
const screenSourceHost = 'atlas';

Map<String, dynamic> _layout(String mode, String source, List<String> kinds) => {
  'template': mode,
  'cards': [
    for (final k in kinds) {'kind': k, 'source': source, 'enabled': true},
  ],
};

class FakeScreenState {
  /// An agent older than §20 (Game mode only, /v1/gamemode).
  bool legacy = false;
  bool running = false;
  String? mode;
  bool veil = false;
  String placement = 'fullscreen';

  /// Named sources on the display agent (name → url); the tokens never come back out.
  Map<String, String> sources = {'atlas': 'https://atlas.example.ts.net:7443'};
  final storedTokens = <String, String>{};
  Map<String, String> sourceStates = {'atlas': 'off'};

  /// Code sharing of each host as a source (its own `screen.share.code`).
  final shareCode = <String, bool>{'argo': false, 'atlas': false};

  Map<String, dynamic> settings = {
    'placement': 'fullscreen',
    'scratchBind': 'SUPER,grave',
    'lastMode': 'work',
    'batterySaver': true,
    'modes': {
      'game': {
        'scene': 'auto', 'lyrics': true, 'spectrum': true, 'motion': 'normal', 'brightness': null, 'clock24': true, 'dimIdleMinutes': 10, //
        'layout': _layout('game', 'atlas', ['map', 'cockpit', 'music', 'lyrics']),
      },
      'work': {
        'project': 'auto', 'city': '3d', 'diff': true, 'ci': false, 'motion': 'normal', 'brightness': null, 'dimIdleMinutes': 10, 'clock24': true, //
        'layout': _layout('work', 'atlas', ['city', 'day', 'system', 'jobs', 'git', 'music', 'servers']),
      },
      'focus': {
        'focusMin': 25, 'shortMin': 5, 'longMin': 15, 'longEvery': 4, 'ambient': 'off', 'ambientVolume': 30, 'chime': true, 'quietPhone': true, //
        'motion': 'normal', 'brightness': null, 'clock24': true,
        'layout': _layout('focus', 'self', ['focus', 'task', 'day', 'music']),
      },
    },
  };

  /// Focus timer: phase, ms left (ticking from the moment of each answer), paused, round, task.
  String phase = 'idle';
  int leftMs = 0;
  bool paused = false;
  int round = 0;
  String? task;

  Map<String, dynamic>? music = {'title': 'Mavi Mavi', 'artist': 'Sezen Aksu', 'playing': true};
  Map<String, dynamic>? truck = {'state': 'none', 'from': null, 'to': null, 'speedKmh': null};
  int? claudeSessions = 2;
  int? claudeWaiting = 0;
  int? jobs = 1;

  /// W7: the agent sends a `screen.summary` push when it stops (`lastStop.summary`).
  bool summaryOnStop = false;
  Map<String, dynamic>? lastStop;

  /// Thrown by every route of the display agent when set (e.g. unreachable); the others by their route.
  AgentError? error;
  AgentError? startError;
  AgentError? putError;

  /// The source agent's answer of GET /v1/screen/game/source.
  Map<String, dynamic> sourceInfo = {
    'velour': true,
    'audio': true,
    'ets2': {'gameDir': '/games/ets2', 'plugin': 'missing', 'version': null, 'running': false, 'telemetry': 'none'},
  };
  bool mapPresent = false;

  final tokensCreated = <Map<String, dynamic>>[];
  final tokensRevoked = <String>[];
  final tokens = <Map<String, dynamic>>[];

  /// What a §19 display agent was given as its source.
  Map<String, dynamic>? legacySource = {'url': 'https://atlas.example.ts.net:7443', 'token': 'tps_old'};

  void work() {
    running = true;
    mode = 'work';
    sourceStates['atlas'] = 'ok';
  }

  void focus({String phase = 'focus', bool paused = false, String? task = 'Ekran modları W6 uygulaması'}) {
    running = true;
    mode = 'focus';
    this.phase = phase;
    this.paused = paused;
    round = 2;
    leftMs = 872 * 1000; // 14:32
    this.task = task;
  }

  void game({bool drive = false}) {
    running = true;
    mode = 'game';
    sourceStates['atlas'] = 'ok';
    if (drive) truck = {'state': 'driving', 'from': 'Bursa', 'to': 'Münih', 'speedKmh': 84};
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> _focus() {
    final idle = phase == 'idle' || !running || mode != 'focus';
    final total = switch (phase) {
      'short' => 5 * 60000,
      'long' => 15 * 60000,
      _ => 25 * 60000,
    };
    return {
      'phase': idle ? 'idle' : phase,
      'endsAt': idle || paused ? null : _now + leftMs,
      'pausedLeft': !idle && paused ? leftMs : null,
      'total': idle ? null : total,
      'round': idle ? 0 : round,
      'longEvery': (settings['modes']['focus'] as Map)['longEvery'],
      'task': idle ? null : task,
      'now': _now,
    };
  }

  Map<String, dynamic> status(String hostId) {
    final display = hostId == screenDisplayHost;
    final on = display && running;
    return {
      'running': on,
      'mode': on ? mode : null,
      'startedAt': on ? DateTime.now().subtract(const Duration(minutes: 102)).toUtc().toIso8601String() : null,
      'placement': settings['placement'],
      'visible': on ? true : null,
      'settings': {
        ...settings,
        'share': {'code': shareCode[hostId] ?? false},
      },
      'sources': [
        {'name': 'self', 'url': null, 'state': on ? 'ok' : 'off', 'topics': <String>[]},
        if (display)
          for (final e in sources.entries) {'name': e.key, 'url': e.value, 'state': on ? (sourceStates[e.key] ?? 'off') : 'off', 'topics': <String>[]},
      ],
      'veil': on && veil,
      'power': {'saver': false},
      'lastStop': lastStop,
      'focus': _focus(),
      'map': {'present': display && mapPresent},
      'live': {
        'music': on && mode != 'focus' ? music : null,
        'truck': on && mode == 'game' ? truck : null,
        'claude': on && claudeSessions != null ? {'sessions': claudeSessions, 'waiting': claudeWaiting} : null,
        'jobs': on ? jobs : null,
      },
    };
  }

  Map<String, dynamic> _legacyStatus(String hostId) {
    final display = hostId == screenDisplayHost;
    final configured = display && legacySource != null;
    final on = display && running;
    return {
      'running': on,
      'startedAt': on ? '2026-11-14T13:00:00Z' : null,
      'settings': Map<String, dynamic>.from(settings['modes']['game'] as Map)..remove('layout'),
      'source': {'configured': configured, 'url': configured ? legacySource!['url'] : null, 'state': configured ? (on ? 'ok' : 'connecting') : 'off'},
      'map': {'present': display && mapPresent},
      'live': {'music': on ? music : null, 'truck': on ? truck : null},
    };
  }

  static Map<String, dynamic> _merge(Map a, Map b) => {
    ...a.cast<String, dynamic>(),
    for (final e in b.entries) '${e.key}': e.value is Map && a[e.key] is Map && e.key != 'layout' && e.key != 'project' ? _merge(a[e.key] as Map, e.value as Map) : e.value,
  };

  dynamic route(String hostId, String method, String path, Object? body) {
    if (path == '/v1/service-tokens') {
      if (method == 'GET') return {'tokens': tokens};
      final b = body as Map;
      tokensCreated.add(Map<String, dynamic>.from(b));
      final t = {'id': 'screen-${tokensCreated.length}', 'name': b['name'], 'scopes': b['scopes'], 'createdAt': '2026-11-21T13:05:00Z'};
      tokens.add(t);
      return {'token': 'tps_secret_${tokensCreated.length}', 'serviceToken': t};
    }
    if (path.startsWith('/v1/service-tokens/') && method == 'DELETE') {
      final id = path.split('/').last;
      tokensRevoked.add(id);
      tokens.removeWhere((t) => t['id'] == id);
      return {'ok': true};
    }
    if (path == '/v1/screen/game/source' || path == '/v1/gamemode/source') {
      if (hostId != screenSourceHost) throw const AgentError('agent.route.notFound', {}, 404);
      return sourceInfo;
    }
    if (path == '/v1/screen/game/plugin' || path == '/v1/gamemode/plugin') {
      final ets2 = Map<String, dynamic>.from(sourceInfo['ets2'] as Map);
      final install = (body as Map)['action'] == 'install';
      ets2['plugin'] = install ? 'installed' : 'missing';
      ets2['version'] = install ? '1.12.1' : null;
      sourceInfo = {...sourceInfo, 'ets2': ets2};
      return {'ok': true};
    }
    if (hostId == screenSourceHost && path == '/v1/screen') {
      // The source host's own screen settings (code sharing).
      if (method == 'PUT') {
        final share = ((body as Map)['settings'] as Map?)?['share'] as Map?;
        if (share != null) shareCode[hostId] = share['code'] == true;
      }
      return status(hostId);
    }
    if (error != null) throw error!;
    if (path.startsWith('/v1/gamemode')) return _legacy(hostId, method, path, body);
    if (legacy) throw const AgentError('agent.route.notFound', {}, 404);
    switch (path) {
      case '/v1/screen':
        if (method == 'PUT') {
          if (putError != null) throw putError!;
          final b = body as Map;
          if (b['settings'] is Map) settings = _merge(settings, b['settings'] as Map);
          final share = (b['settings'] as Map?)?['share'] as Map?;
          if (share != null) shareCode[hostId] = share['code'] == true;
          if (b['sources'] is Map) {
            for (final e in (b['sources'] as Map).entries) {
              if (e.value == null) {
                sources.remove(e.key);
              } else {
                sources['${e.key}'] = '${(e.value as Map)['url']}';
                storedTokens['${e.key}'] = '${(e.value as Map)['token']}';
                sourceStates['${e.key}'] = 'off';
              }
            }
          }
        }
        return status(hostId);
      case '/v1/screen/start' || '/v1/screen/mode':
        if (startError != null) throw startError!;
        final m = (body as Map)['mode'] as String? ?? settings['lastMode'] as String;
        if (path == '/v1/screen/start' || running) {
          running = true;
          mode = m;
          if (m != 'focus') phase = 'idle';
        }
        settings['lastMode'] = m;
        return status(hostId);
      case '/v1/screen/stop':
        lastStop = {'at': _now, 'summary': summaryOnStop};
        running = false;
        mode = null;
        veil = false;
        phase = 'idle';
        return status(hostId);
      case '/v1/screen/veil':
        if (!running) throw const AgentError('agent.screen.notRunning', {}, 409);
        veil = (body as Map)['on'] == true;
        return status(hostId);
      case '/v1/screen/focus':
        if (!running || mode != 'focus') throw const AgentError('agent.screen.notFocus', {}, 409);
        final b = body as Map;
        if (b.containsKey('task')) task = (b['task'] as String?)?.isEmpty == true ? null : b['task'] as String?;
        switch (b['action']) {
          case 'start' || 'resume':
            if (phase == 'idle') {
              phase = 'focus';
              round = 1;
              leftMs = 25 * 60000;
            }
            paused = false;
          case 'pause':
            paused = true;
          case 'skip':
            phase = phase == 'focus' ? 'short' : 'focus';
            leftMs = (phase == 'short' ? 5 : 25) * 60000;
            paused = false;
          case 'reset':
            phase = 'idle';
            paused = false;
        }
        return {'focus': _focus()};
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }

  dynamic _legacy(String hostId, String method, String path, Object? body) {
    if (path == '/v1/gamemode') {
      if (method == 'PUT') {
        if (putError != null) throw putError!;
        final b = body as Map;
        if (b['settings'] is Map) {
          final game = _merge(settings['modes']['game'] as Map, b['settings'] as Map);
          settings = _merge(settings, {
            'modes': {'game': game},
          });
        }
        if (b.containsKey('source')) legacySource = b['source'] == null ? null : Map<String, dynamic>.from(b['source'] as Map);
      }
      return _legacyStatus(hostId);
    }
    if (path == '/v1/gamemode/start') {
      if (startError != null) throw startError!;
      if (legacySource == null) throw const AgentError('agent.gamemode.noSource', {}, 409);
      running = true;
      mode = 'game';
      return _legacyStatus(hostId);
    }
    if (path == '/v1/gamemode/stop') {
      running = false;
      mode = null;
      return _legacyStatus(hostId);
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }
}

/// Records what the app asked of the Focus notification surface.
class FakeFocusNotifications implements FocusNotifications {
  final shown = <FocusOngoing?>[];
  final summaries = <int>[];
  @override
  Future<void> ongoing(FocusOngoing? o) async => shown.add(o);
  @override
  Future<void> summary(int held) async => summaries.add(held);
}
