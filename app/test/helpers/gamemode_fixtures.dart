// Fake game-mode routes (PLAN.md §19 contract): the display agent (argo) answers /v1/gamemode*, the source agent
// (atlas) answers /v1/gamemode/source and /v1/gamemode/plugin; /v1/service-tokens creates a token. Sample data is
// synthetic; nothing leaves the test.
import 'package:tiphys/core/agent/agent_client.dart';

const gameDisplayHost = 'argo';
const gameSourceHost = 'atlas';

class FakeGameState {
  bool running = false;
  bool configured = true;
  String sourceState = 'off';
  Map<String, dynamic> settings = {
    'scene': 'auto',
    'lyrics': true,
    'spectrum': true,
    'motion': 'normal',
    'brightness': null,
    'clock24': true,
    'dimIdleMinutes': 10,
  };
  Map<String, dynamic>? music = {'title': 'Mavi Mavi', 'artist': 'Sezen Aksu', 'playing': true};
  Map<String, dynamic>? truck = {'state': 'none', 'from': null, 'to': null, 'speedKmh': null};

  /// Thrown by every route of the display agent when set (e.g. unreachable); [startError] only by start.
  AgentError? error;
  AgentError? startError;
  AgentError? putError;

  /// The source agent's answer of GET /v1/gamemode/source.
  Map<String, dynamic> sourceInfo = {
    'velour': true,
    'audio': true,
    'ets2': {'gameDir': '/games/ets2', 'plugin': 'missing', 'version': null, 'running': false, 'telemetry': 'none'},
  };

  /// Map files on the display host (GET /v1/gamemode → map.present).
  bool mapPresent = false;

  /// What the display agent was given as source (the token never comes back out).
  Map<String, dynamic>? storedSource;
  final tokensCreated = <Map<String, dynamic>>[];
  final tokensRevoked = <String>[];

  void drive() {
    running = true;
    sourceState = 'ok';
    truck = {'state': 'driving', 'from': 'Bursa', 'to': 'Münih', 'speedKmh': 84};
  }

  void on() {
    running = true;
    sourceState = 'ok';
  }

  Map<String, dynamic> _status(String hostId) {
    final display = hostId == gameDisplayHost;
    return {
      'running': display && running,
      'startedAt': display && running ? '2026-11-14T13:00:00Z' : null,
      'settings': settings,
      'source': {
        'configured': display && configured,
        'url': display && configured ? 'https://atlas.example.ts.net:7443' : null,
        'state': display && configured ? sourceState : 'off',
      },
      'map': {'present': display && mapPresent},
      'live': {'music': display && running ? music : null, 'truck': display && running ? truck : null},
    };
  }

  dynamic route(String hostId, String method, String path, Object? body) {
    if (path == '/v1/service-tokens') {
      final b = body as Map;
      tokensCreated.add(Map<String, dynamic>.from(b));
      return {
        'token': 'tps_secret_${tokensCreated.length}',
        'serviceToken': {'id': 'game-mode-${tokensCreated.length}', 'name': b['name'], 'scopes': b['scopes'], 'createdAt': '2026-11-14T13:05:00Z'},
      };
    }
    if (path.startsWith('/v1/service-tokens/') && method == 'DELETE') {
      tokensRevoked.add(path.split('/').last);
      return {'ok': true};
    }
    if (path == '/v1/gamemode/source') {
      if (hostId != gameSourceHost) throw const AgentError('agent.route.notFound', {}, 404);
      return sourceInfo;
    }
    if (path == '/v1/gamemode/plugin') {
      final ets2 = Map<String, dynamic>.from(sourceInfo['ets2'] as Map);
      final install = (body as Map)['action'] == 'install';
      ets2['plugin'] = install ? 'installed' : 'missing';
      ets2['version'] = install ? '1.12.1' : null;
      sourceInfo = {...sourceInfo, 'ets2': ets2};
      return {'ok': true};
    }
    if (error != null) throw error!;
    if (path == '/v1/gamemode') {
      if (method == 'PUT') {
        if (putError != null) throw putError!;
        final b = body as Map;
        if (b['settings'] is Map) settings = {...settings, ...(b['settings'] as Map).cast<String, dynamic>()};
        if (b.containsKey('source')) {
          storedSource = b['source'] == null ? null : Map<String, dynamic>.from(b['source'] as Map);
          configured = storedSource != null;
          sourceState = configured ? 'connecting' : 'off';
        }
      }
      return _status(hostId);
    }
    if (path == '/v1/gamemode/start') {
      if (startError != null) throw startError!;
      if (!configured) throw const AgentError('agent.gamemode.noSource', {}, 409);
      on();
      return _status(hostId);
    }
    if (path == '/v1/gamemode/stop') {
      running = false;
      sourceState = 'off';
      return _status(hostId);
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }
}
