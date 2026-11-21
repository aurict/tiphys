// Fake sleep mode routes (PLAN.md §21 contract + the S2 additions): every display host (argo, atlas) answers
// GET/PUT /v1/sleep, POST /v1/sleep/{start,stop,alarm,preview} and GET /v1/sleep/summary on its own state. Hosts in
// [FakeSleepState.unsupported] are agents older than §21 (404). Sample data is synthetic; nothing leaves the test.
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/screen/sleep/sleep_sync.dart';

/// The agents' own names (the health check's `name`), which the sessions use as member ids.
const sleepAgentNames = {'argo': 'theloth', 'atlas': 'laptop'};

/// Health answers with each host's own name (the default harness answers "argo" for every host).
Future<Map<String, dynamic>> sleepHealth(String url, List<String> features) async {
  final host = Uri.parse(url).host.split('.').first;
  return {
    'name': sleepAgentNames[host] ?? host,
    'version': '0.6.0',
    'features': {for (final f in features) f: true, if (host == 'argo') 'velour': true},
  };
}

Map<String, dynamic> sleepDefaults({String side = 'left', bool alarm = true}) => {
  'join': true,
  'side': side,
  'distance': 'mid',
  'volume': 35,
  'brightness': {'start': 25, 'night': 3, 'morning': 70},
  'ddc': {'bus': null, 'min': 0},
  'quietPower': false,
  'holdVolume': null,
  'leds': false,
  'group': null,
  'times': {'settleMin': 3, 'fadeMin': 30, 'soundFadeMin': 45, 'nightSound': 'hum'},
  'layers': {'hum': true, 'crackle': true, 'logs': true, 'wind': false, 'rain': false},
  'velour': {'playlistId': null, 'volume': 30, 'fadeMin': 30},
  if (alarm) 'alarm': {'enabled': false, 'time': '07:00', 'days': 'once', 'sunriseMin': 25, 'sound': 'birds', 'velourTrack': null, 'rampMin': 3, 'snoozeMin': 9, 'autoStopMin': 20, 'morningScreen': false},
  'notify': {'critical': ['hostDown', 'securityTrap', 'incident', 'diskFull'], 'morningSummary': true},
  'reminder': {'enabled': false, 'time': '22:30'},
};

Map<String, dynamic> _merge(Map a, Map b) => {
  ...a.cast<String, dynamic>(),
  for (final e in b.entries) '${e.key}': e.value is Map && a[e.key] is Map && e.key != 'group' ? _merge(a[e.key] as Map, e.value as Map) : e.value,
};

class FakeSleepHost {
  FakeSleepHost(this.name, this.settings);
  final String name;
  Map<String, dynamic> settings;
  bool running = false;
  Map<String, dynamic>? session;
  String phase = 'fade';
  int phaseLeftMs = 18 * 60000;
  bool ringing = false;
  int? snoozedUntil;
  int? alarmNext;
  String? warning;

  /// S3: what the group reports (the leader's view of the members, a member down).
  Map<String, String> memberStates = {};
  String? groupError;
  String dimming = 'backlight';
  int? hardware = 14;
  AgentError? startError;
  AgentError? error;
  int previews = 0;
}

class FakeSleepState {
  /// Agents older than §21 (no /v1/sleep).
  final unsupported = <String>{};

  /// Agents that take the S2 session shape only (members as an id list): objects → 400.
  bool idsOnly = false;

  final hosts = <String, FakeSleepHost>{
    'argo': FakeSleepHost('theloth', sleepDefaults()),
    'atlas': FakeSleepHost('laptop', sleepDefaults(side: 'right')),
  };

  /// GET /v1/sleep/summary of the leader (null: none).
  Map<String, dynamic>? summary;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// A set-up group: both join, theloth leads, the alarm at 07:30 on weekdays.
  void configured({bool alarm = true}) {
    for (final h in hosts.values) {
      h.settings = _merge(h.settings, {
        'group': {
          'members': ['theloth', 'laptop'],
          'leader': 'theloth',
        },
        if (alarm)
          'alarm': {'enabled': true, 'time': '07:30', 'days': 'weekdays'},
      });
    }
  }

  /// Both machines sleeping (fade, 18 min left) in one session.
  void sleeping({String phase = 'fade', bool ringing = false}) {
    configured();
    final session = {
      'id': 'sessFake0001',
      'seed': 42,
      't0': _now - 12 * 60000,
      'members': [
        {'host': 'theloth', 'side': 'left', 'distance': 'mid'},
        {'host': 'laptop', 'side': 'right', 'distance': 'mid'},
      ],
      'leader': 'theloth',
    };
    for (final h in hosts.values) {
      h.running = true;
      h.session = session;
      h.phase = ringing ? 'ring' : phase;
      h.ringing = ringing;
    }
    hosts['argo']!.warning = 'agent.sleep.ddcUnavailable';
    hosts['argo']!.dimming = 'content';
    hosts['argo']!.hardware = null;
  }

  Map<String, dynamic> status(String hostId) {
    final h = hosts[hostId]!;
    final open = h.phase == 'night' || h.phase == 'ring';
    return {
      'running': h.running,
      'session': h.running ? h.session : null,
      'phase': h.running ? h.phase : null,
      'phaseStartedAt': h.running ? _now - 60000 : null,
      'phaseEndsAt': h.running && !open ? _now + h.phaseLeftMs : null,
      'alarm': {'next': h.running ? h.alarmNext : null, 'ringing': h.ringing, 'snoozedUntil': h.snoozedUntil},
      'members': h.running
          ? [
              for (final m in (h.session!['members'] as List))
                if (m is Map)
                  {...m, 'leader': m['host'] == h.session!['leader'], 'state': h.memberStates['${m['host']}'] ?? 'running'}
                else
                  {'host': m, 'side': 'left', 'distance': 'mid', 'leader': m == h.session!['leader'], 'state': h.memberStates['$m'] ?? 'running'},
            ]
          : [
              {'host': h.name, 'state': 'off'},
            ],
      'group': h.running
          ? {'role': h.name == h.session!['leader'] ? 'leader' : 'member', 'link': h.name == h.session!['leader'] ? null : 'ok', 'offsetMs': 3, 'rttMs': 12, 'error': h.groupError}
          : null,
      'brightness': h.running ? {'dimming': h.dimming, 'hardware': h.hardware, 'content': 0.4, 'preview': null} : null,
      'warning': h.running ? h.warning : null,
      'page': h.running ? {'heartbeatAt': _now - 4000} : null,
      'scale': 1,
      'settings': h.settings,
      'now': _now,
    };
  }

  dynamic route(String hostId, String method, String path, Object? body) {
    if (unsupported.contains(hostId) || !hosts.containsKey(hostId)) throw const AgentError('agent.route.notFound', {}, 404);
    final h = hosts[hostId]!;
    if (h.error != null) throw h.error!;
    switch (path) {
      case '/v1/sleep':
        if (method == 'PUT') h.settings = _merge(h.settings, (body as Map)['settings'] as Map);
        return status(hostId);
      case '/v1/sleep/start':
        if (h.startError != null) throw h.startError!;
        final s = (body as Map)['session'] as Map?;
        final members = (s?['members'] as List?) ?? const [];
        if (idsOnly && members.any((m) => m is Map)) throw const AgentError('agent.request.invalid', {}, 400);
        if (!h.running) {
          h.running = true;
          h.phase = 'settle';
          h.session = s == null ? null : Map<String, dynamic>.from(s);
        }
        return status(hostId);
      case '/v1/sleep/stop':
        h.running = false;
        h.ringing = false;
        h.session = null;
        return status(hostId);
      case '/v1/sleep/alarm':
        if (!h.running) throw const AgentError('agent.sleep.notRunning', {}, 409);
        final a = (body as Map)['action'];
        h.ringing = false;
        if (a == 'snooze') {
          h.phase = 'snoozed';
          h.snoozedUntil = _now + 9 * 60000;
        } else {
          h.phase = 'morning';
        }
        return status(hostId);
      case '/v1/sleep/preview':
        h.previews++;
        final pct = (body as Map)['brightness'] as int;
        if (!h.running && h.dimming == 'content') throw const AgentError('agent.sleep.ddcUnavailable', {'reason': 'failed'}, 409);
        return {
          ...status(hostId),
          if (!h.running) 'preview': {'dimming': h.dimming, 'hardware': pct, 'until': _now + 5000},
        };
      case '/v1/sleep/summary':
        return {'summary': hostId == 'argo' ? summary : null};
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }
}

/// Records what the app asked of the phone's alarm surface.
class FakeSleepAlarms implements SleepAlarms {
  final backups = <DateTime?>[];
  final reminders = <String?>[];
  int cleared = 0;
  SleepPhoneAlarm phoneState = const SleepPhoneAlarm(supported: true, exact: true);
  @override
  Future<void> backup(DateTime? at, {int snoozeMin = 9}) async => backups.add(at);
  @override
  Future<void> clearRinging() async => cleared++;
  @override
  Future<void> reminder(String? hm) async => reminders.add(hm);
  @override
  Future<SleepPhoneAlarm> phone() async => phoneState;
  @override
  Future<void> requestExact() async {}
  @override
  Future<void> requestFullScreen() async {}
}
