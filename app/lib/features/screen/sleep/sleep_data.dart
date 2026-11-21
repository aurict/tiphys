// Sleep mode (PLAN.md §21 U): the data side. Every display host of the screen modes runs the sleep mode on its own
// agent (GET/PUT /v1/sleep, POST /v1/sleep/{start,stop,alarm,preview}); the phone keeps them together as one group:
// group-wide settings (times, layers, Velour list, alarm, notifications, reminder, `group`) are written to every
// machine with the same values, per-machine settings (join, side, distance, volume, brightness, extras) only to that
// machine. "Uykuya geç" builds ONE session object (no plan) and posts it to the leader first; the leader answers with
// the session and its `plan` (the group's phases and alarm, PLAN.md §21 S4), which goes unchanged to every other member;
// "Uyan" stops all. The alarm's clock time is the leader's local time; the app shows it from the leader's `alarm.next`
// (epoch ms) in the phone's time zone.
// An agent older than §21 (no /v1/sleep: 404) is listed as needing an update; a block the agent doesn't report yet
// (alarm, notify, reminder) shows the same in its section. Nothing of a session is stored on the phone except the
// small run record of sleep_notices.dart (members and alarm time, for the alarm buttons and the backup alarm).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/agent/agent_client.dart';
import '../../../core/profile/model.dart';
import '../../../core/util/refresh.dart';
import '../../../state/providers.dart';
import '../../system/agent_providers.dart';
import '../screen_data.dart' show isNotFound, mergeSettings, screenHostsProvider;
import 'sleep_sync.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// The agent's id for a host in a session (agent: sleep.ts hostIdOf): its configured name, other characters as `-`.
String sleepIdOf(String name) {
  final s = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');
  final cut = s.length > 64 ? s.substring(0, 64) : s;
  return cut.isEmpty ? 'host' : cut;
}

const sleepSides = ['left', 'right', 'foot', 'head'];
const sleepDistances = ['near', 'mid', 'far'];
const sleepLayers = ['hum', 'crackle', 'logs', 'wind', 'rain'];
const sleepCriticalKinds = ['hostDown', 'securityTrap', 'incident', 'diskFull'];

/// `screen.modes.sleep` of one machine (the agent's JSON with the contract's defaults).
@immutable
class SleepSettings {
  const SleepSettings([this.raw = const {}]);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => raw[k] is Map ? Map<String, dynamic>.from(raw[k] as Map) : const {};
  static int _i(Map m, String k, int def) => (m[k] as num?)?.round() ?? def;
  static bool _b(Map m, String k, bool def) => m[k] is bool ? m[k] as bool : def;
  static String _s(Map m, String k, String def) => m[k] is String ? m[k] as String : def;

  // Per machine.
  bool get join => _b(raw, 'join', true);
  String get side => sleepSides.contains(raw['side']) ? raw['side'] as String : 'left';
  String get distance => sleepDistances.contains(raw['distance']) ? raw['distance'] as String : 'mid';
  int get volume => _i(raw, 'volume', 35);
  int get brightnessStart => _i(_m('brightness'), 'start', 25);
  int get brightnessNight => _i(_m('brightness'), 'night', 3);
  int get brightnessMorning => _i(_m('brightness'), 'morning', 70);
  bool get quietPower => _b(raw, 'quietPower', false);

  /// null: the system volume is not touched.
  int? get holdVolume => (raw['holdVolume'] as num?)?.round();
  bool get leds => _b(raw, 'leds', false);

  // Group-wide.
  /// Agent ids of the group and its leader; null: no group set up yet.
  (List<String>, String)? get group {
    final g = raw['group'];
    if (g is! Map) return null;
    final members = [for (final m in (g['members'] as List? ?? const [])) '$m'];
    final leader = g['leader'];
    return members.isEmpty || leader is! String ? null : (members, leader);
  }

  int get settleMin => _i(_m('times'), 'settleMin', 3);
  int get fadeMin => _i(_m('times'), 'fadeMin', 30);
  int get soundFadeMin => _i(_m('times'), 'soundFadeMin', 45);

  /// hum | off
  String get nightSound => _s(_m('times'), 'nightSound', 'off') == 'hum' ? 'hum' : 'off';
  bool layer(String k) => _b(_m('layers'), k, k == 'hum' || k == 'crackle' || k == 'logs');

  bool get hasVelour => raw['velour'] is Map;
  String? get velourPlaylist => _m('velour')['playlistId'] as String?;
  int get velourVolume => _i(_m('velour'), 'volume', 30);
  int get velourFadeMin => _i(_m('velour'), 'fadeMin', 30);

  /// The agent knows the alarm settings (a block it doesn't report: it needs an update).
  bool get hasAlarm => raw['alarm'] is Map;
  bool get alarmEnabled => _b(_m('alarm'), 'enabled', false);
  String get alarmTime => validHm(_m('alarm')['time']) ?? '07:00';

  /// once | weekdays | daily | [0..6] (0 = Sunday, as the agent's JavaScript counts).
  Object get alarmDays {
    final d = _m('alarm')['days'];
    if (d is List) return [for (final x in d) (x as num).toInt()]..sort();
    return d == 'weekdays' || d == 'daily' ? d as String : 'once';
  }

  int get sunriseMin => _i(_m('alarm'), 'sunriseMin', 25);

  /// birds | chime | velour
  String get alarmSound => const ['birds', 'chime', 'velour'].contains(_m('alarm')['sound']) ? _m('alarm')['sound'] as String : 'birds';
  int get rampMin => _i(_m('alarm'), 'rampMin', 3);
  int get snoozeMin => _i(_m('alarm'), 'snoozeMin', 9);
  int get autoStopMin => _i(_m('alarm'), 'autoStopMin', 20);
  bool get morningScreen => _b(_m('alarm'), 'morningScreen', false);

  bool get hasNotify => raw['notify'] is Map;
  List<String> get critical {
    final c = _m('notify')['critical'];
    return c is List ? [for (final x in c) '$x'] : const ['hostDown', 'securityTrap', 'incident', 'diskFull'];
  }

  bool get morningSummary => _b(_m('notify'), 'morningSummary', true);

  bool get hasReminder => raw['reminder'] is Map;
  bool get reminderEnabled => _b(_m('reminder'), 'enabled', false);
  String get reminderTime => validHm(_m('reminder')['time']) ?? '22:30';

  SleepSettings apply(Map<String, Object?> patch) => SleepSettings(mergeSleep(raw, patch));

  @override
  bool operator ==(Object other) => other is SleepSettings && mapEquals(other.raw, raw);
  @override
  int get hashCode => Object.hashAll(raw.keys);
}

/// Like the agent's PUT: nested blocks merge, arrays and `group` are replaced whole.
Map<String, dynamic> mergeSleep(Map a, Map b) => {
  ...a.cast<String, dynamic>(),
  for (final e in b.entries) '${e.key}': e.value is Map && a[e.key] is Map && e.key != 'group' ? mergeSettings(a[e.key] as Map, e.value as Map) : e.value,
};

String? validHm(Object? v) => v is String && RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(v) ? v : null;

/// GET /v1/sleep. Times are the agent's ms; `…Local` correct them for the clock skew with `now`.
@immutable
class SleepStatus {
  const SleepStatus({
    this.running = false,
    this.session,
    this.phase,
    this.phaseStartedAt,
    this.phaseEndsAt,
    this.alarmNext,
    this.ringing = false,
    this.snoozedUntil,
    this.members = const [],
    this.dimming,
    this.hardware,
    this.warning,
    this.settings = const SleepSettings(),
    this.skewMs = 0,
    this.groupLink,
    this.groupError,
    this.alarmHm,
  });

  factory SleepStatus.fromJson(Map j, {DateTime? receivedAt}) {
    int? i(Object? v) => (v as num?)?.round();
    final alarm = j['alarm'] is Map ? j['alarm'] as Map : const {};
    final b = j['brightness'] is Map ? j['brightness'] as Map : null;
    final now = i(j['now']);
    return SleepStatus(
      running: j['running'] == true,
      session: j['session'] is Map ? Map<String, dynamic>.from(j['session'] as Map) : null,
      phase: j['phase'] as String?,
      phaseStartedAt: i(j['phaseStartedAt']),
      phaseEndsAt: i(j['phaseEndsAt']),
      alarmNext: i(alarm['next']),
      ringing: alarm['ringing'] == true,
      snoozedUntil: i(alarm['snoozedUntil']),
      members: [
        for (final m in (j['members'] as List? ?? const []))
          if (m is Map) ('${m['host']}', '${m['state'] ?? 'unknown'}'),
      ],
      dimming: b?['dimming'] as String?,
      hardware: i(b?['hardware']),
      warning: j['warning'] as String?,
      settings: SleepSettings(Map<String, dynamic>.from((j['settings'] as Map?) ?? const {})),
      skewMs: now == null ? 0 : now - (receivedAt ?? DateTime.now()).millisecondsSinceEpoch,
      groupLink: (j['group'] as Map?)?['link'] as String?,
      groupError: (j['group'] as Map?)?['error'] as String?,
      alarmHm: validHm(((j['settings'] as Map?)?['alarm'] as Map?)?['time']),
    );
  }

  final bool running;
  final Map<String, dynamic>? session;

  /// settle | fade | night | sunrise | ring | snoozed | morning (null while off).
  final String? phase;
  final int? phaseStartedAt;
  final int? phaseEndsAt;
  /// The next or current ring (agent ms; off: the next one the settings would ring).
  final int? alarmNext;
  final bool ringing;
  final int? snoozedUntil;

  /// (agent id, state) of the session's members (S3: running | connecting | down | stopped | unknown; off alone).
  final List<(String, String)> members;

  /// S3: a member's link to the leader (connecting | ok | down; null on the leader or alone) and the group's error
  /// (`agent.sleep.memberDown`).
  final String? groupLink;
  final String? groupError;

  /// backlight | ddc | content
  final String? dimming;
  final int? hardware;
  final String? warning;
  final SleepSettings settings;

  /// The agent's clock minus the phone's.
  final int skewMs;

  /// `alarm.time` as the agent reported it with [alarmNext] (the shown settings may hold an edit not answered yet).
  final String? alarmHm;

  /// The group's plan (S4: the leader's, sent with the session); null before S4 or while off.
  Map<String, dynamic>? get plan => session?['plan'] is Map ? Map<String, dynamic>.from(session!['plan'] as Map) : null;

  /// The plan's first ring (agent ms), null without an alarm.
  int? get planRingAt => (plan?['ringAt'] as num?)?.round();

  DateTime? local(int? agentMs) => agentMs == null ? null : DateTime.fromMillisecondsSinceEpoch(agentMs - skewMs);
  DateTime? get phaseEndsLocal => local(phaseEndsAt);
  bool get isRinging => ringing || phase == 'ring';
  String? get sessionId => session?['id'] as String?;

  SleepStatus copyWith({bool? running, SleepSettings? settings, bool? ringing, String? Function()? phase}) => SleepStatus(
    running: running ?? this.running,
    session: session,
    phase: phase != null ? phase() : this.phase,
    phaseStartedAt: phaseStartedAt,
    phaseEndsAt: phaseEndsAt,
    alarmNext: alarmNext,
    ringing: ringing ?? this.ringing,
    snoozedUntil: snoozedUntil,
    members: members,
    dimming: dimming,
    hardware: hardware,
    warning: warning,
    settings: settings ?? this.settings,
    skewMs: skewMs,
    groupLink: groupLink,
    groupError: groupError,
    alarmHm: alarmHm,
  );
}

/// One display host in the sleep group view.
@immutable
class SleepMachine {
  const SleepMachine({required this.host, required this.agentId, this.status, this.error, this.unsupported = false, this.velour = false});
  final Host host;

  /// The id the agents use for it in a session (its configured name).
  final String agentId;
  final SleepStatus? status;

  /// The last read failed (unreachable): the old status is kept, if any.
  final Object? error;

  /// The agent has no /v1/sleep (older than §21).
  final bool unsupported;

  /// Velour runs here (the default leader: the sleep list and the alarm song).
  final bool velour;

  bool get ok => status != null && !unsupported;
  bool get joined => ok && status!.settings.join;
  bool get running => status?.running == true;

  SleepMachine copyWith({SleepStatus? status, Object? Function()? error, bool? unsupported}) =>
      SleepMachine(host: host, agentId: agentId, status: status ?? this.status, error: error != null ? error() : this.error, unsupported: unsupported ?? this.unsupported, velour: velour);
}

/// Every display host and its sleep state.
@immutable
class SleepGroup {
  const SleepGroup(this.machines);
  final List<SleepMachine> machines;

  List<SleepMachine> get supported => machines.where((m) => m.ok).toList();

  /// The machines that join the sleep mode.
  List<SleepMachine> get members => machines.where((m) => m.joined).toList();
  bool get anySupported => machines.any((m) => m.ok);
  bool get allUnsupported => machines.isNotEmpty && machines.every((m) => m.unsupported);

  /// The wizard ran (some machine has a `group`).
  bool get configured => supported.any((m) => m.status!.settings.group != null);
  bool get running => machines.any((m) => m.running);
  List<SleepMachine> get runningMachines => machines.where((m) => m.running).toList();
  bool get ringing => machines.any((m) => m.status?.isRinging == true);

  SleepMachine? byHost(String hostId) => machines.where((m) => m.host.id == hostId).firstOrNull;
  SleepMachine? byAgent(String id) => machines.where((m) => m.agentId == id).firstOrNull;

  /// A member's state as the group sees it (the leader's view, S3), null when no running machine reports it.
  String? memberState(SleepMachine m) {
    for (final s in [?phaseSource, for (final x in runningMachines) x.status!]) {
      final e = s.members.where((x) => x.$1 == m.agentId).firstOrNull;
      if (e != null && e.$2 != 'unknown') return e.$2;
    }
    return null;
  }

  /// The group's error (a member down), from any running machine.
  String? get groupError => runningMachines.map((m) => m.status!.groupError).whereType<String>().firstOrNull;

  /// The leader: the group's, else the Velour host, else the first member.
  SleepMachine? get leader {
    for (final m in supported) {
      final g = m.status!.settings.group;
      if (g != null) {
        final l = byAgent(g.$2);
        if (l != null && l.ok) return l;
      }
    }
    final pool = members.isNotEmpty ? members : supported;
    return pool.where((m) => m.velour).firstOrNull ?? pool.firstOrNull;
  }

  /// Group-wide values as the leader holds them (every member holds the same).
  SleepSettings get settings => (leader ?? supported.firstOrNull)?.status?.settings ?? const SleepSettings();

  /// The running machine to read the phase from (the leader when it runs).
  SleepStatus? get phaseSource {
    final l = leader;
    if (l != null && l.running) return l.status;
    return runningMachines.firstOrNull?.status;
  }

  /// Minutes the leader's clock time is ahead of the phone's (its time zone minus the phone's; 0 when the same), from
  /// its `alarm.next` and the `alarm.time` it rang from; null when unknown (no alarm, an agent before S4).
  int? get leaderZoneMin {
    final s = leader?.status;
    if (s == null || !s.settings.alarmEnabled) return null;
    // Off: `alarm.next` comes from the settings. Running: the plan's first ring (set from the settings at the start).
    final next = s.running ? s.planRingAt : s.alarmNext;
    return next == null || s.alarmHm == null ? null : zoneDiffMin(s.alarmHm!, DateTime.fromMillisecondsSinceEpoch(next));
  }

  /// The alarm on the phone's clock: tonight's ring of the running group (the plan's, else `alarm.next`), else the
  /// leader's next one; null when unknown.
  DateTime? get alarmLocal {
    final p = phaseSource;
    if (p != null) return p.local(p.planRingAt ?? p.alarmNext);
    final s = leader?.status;
    if (s == null || !s.settings.alarmEnabled) return null;
    // An edit not answered yet: the new time moved by the leader's zone.
    if (s.alarmHm != s.settings.alarmTime) return null;
    return s.local(s.alarmNext);
  }

  /// "07:30" on the phone's clock: [alarmLocal], else the setting moved by the leader's zone (as is when unknown).
  String get alarmHmLocal {
    final at = alarmLocal;
    return at != null ? hmOf(at) : shiftHm(settings.alarmTime, -(leaderZoneMin ?? 0));
  }

  /// The ring sounding now (or next) on the phone's clock: `alarm.next` of the running group, else [alarmHmLocal].
  String get ringHmLocal {
    final p = phaseSource;
    final at = p?.local(p.alarmNext);
    return at != null ? hmOf(at) : alarmHmLocal;
  }

  SleepGroup replace(SleepMachine m) => SleepGroup([for (final x in machines) x.host.id == m.host.id ? m : x]);
}

/// The next ring of [s]'s alarm after [from] on the phone's clock (only for an agent before S4, which reports no
/// `alarm.next`; it assumes the machine's time zone is the phone's): the time on the allowed days (`once`: the next
/// time it comes round).
DateTime? nextAlarm(SleepSettings s, DateTime from) {
  if (!s.hasAlarm || !s.alarmEnabled) return null;
  final parts = s.alarmTime.split(':');
  final h = int.parse(parts[0]), m = int.parse(parts[1]);
  final days = s.alarmDays;
  bool allowed(DateTime d) {
    final js = d.weekday % 7; // Dart: Monday 1 … Sunday 7; JavaScript: Sunday 0 … Saturday 6
    return switch (days) {
      'weekdays' => js >= 1 && js <= 5,
      List<int> l => l.contains(js),
      _ => true,
    };
  }

  for (var i = 0; i < 8; i++) {
    final c = DateTime(from.year, from.month, from.day + i, h, m);
    if (c.isAfter(from) && allowed(c)) return c;
  }
  return null;
}

String hmOf(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// HH:MM moved by [minutes] round the clock.
String shiftHm(String hm, int minutes) {
  final p = hm.split(':');
  final m = ((int.parse(p[0]) * 60 + int.parse(p[1]) + minutes) % 1440 + 1440) % 1440;
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// The clock time [hm] of a machine at the moment [at] minus the phone's clock time then, in minutes (-720, 720]; null
/// when it isn't a time zone step (15 min): e.g. a snooze ring, or a time moved past a daylight saving gap.
int? zoneDiffMin(String hm, DateTime at) {
  final p = hm.split(':');
  var d = ((int.parse(p[0]) * 60 + int.parse(p[1])) - (at.hour * 60 + at.minute)) % 1440;
  if (d > 720) d -= 1440;
  return d % 15 == 0 ? d : null;
}

/// A session id the agent accepts (`[A-Za-z0-9_-]{8,64}`).
String newSessionId(math.Random r) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
  return String.fromCharCodes([for (var i = 0; i < 16; i++) chars.codeUnitAt(r.nextInt(chars.length))]);
}

/// The session object the leader gets: id, seed, t0 (the leader's clock when known), the members with their place in
/// the room, the leader (listed first). No `plan`: the leader makes it, and the others get the leader's session.
Map<String, Object> buildSession(SleepGroup g, List<SleepMachine> members, {required DateTime now, math.Random? random}) {
  final r = random ?? math.Random.secure();
  final leader = g.leader != null && members.contains(g.leader) ? g.leader! : members.first;
  final skew = leader.status?.skewMs ?? 0;
  return {
    'id': newSessionId(r),
    'seed': r.nextInt(1 << 32),
    't0': now.millisecondsSinceEpoch + skew,
    'members': [
      for (final m in [leader, ...members.where((x) => x != leader)]) {'host': m.agentId, 'side': m.status!.settings.side, 'distance': m.status!.settings.distance},
    ],
    'leader': leader.agentId,
  };
}

/// The same session in the S2 agent's shape (members as an id list, no plan; the room layout comes from each machine's
/// own settings there).
Map<String, Object> sessionIdsOnly(Map<String, Object> s) => {
  for (final e in s.entries)
    if (e.key != 'plan') e.key: e.value,
  'members': [for (final m in s['members'] as List) m is Map ? m['host'] : m],
};

/// A member not started because the leader didn't start (members only ever get the leader's plan).
class SleepLeaderNotStarted implements Exception {
  const SleepLeaderNotStarted();
}

/// What a group start ended with: the hosts that failed and why.
class SleepStartResult {
  const SleepStartResult(this.failed, this.started);
  final Map<String, Object> failed;
  final List<String> started;
  bool get ok => failed.isEmpty;
}

/// Several hosts answered with errors (a group-wide write, stop or alarm action).
class SleepPartialError implements Exception {
  const SleepPartialError(this.failed);

  /// host id → error
  final Map<String, Object> failed;
  @override
  String toString() => 'SleepPartialError(${failed.keys.join(', ')})';
}

/// Polls GET /v1/sleep on every display host (5 s while watched and the app is in front); actions update the state from
/// the agents' answers. Settings show at once (optimistic) and are sent in order per host.
class SleepGroupNotifier extends AsyncNotifier<SleepGroup> {
  VoidCallback? _cancelTimer;
  bool _closed = false;
  bool _paused = false;
  final _pending = <String, Map<String, Object?>>{};
  final _inflight = <String, int>{};
  final _chain = <String, Future<void>>{};

  @override
  Future<SleepGroup> build() async {
    _closed = false;
    _paused = false;
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
    final hosts = await ref.watch(screenHostsProvider.future);
    try {
      return _emit(SleepGroup(await Future.wait([for (final h in hosts) _read(h, null)])));
    } finally {
      _schedule();
    }
  }

  Future<SleepMachine> _read(Host h, SleepMachine? old) async {
    Map<String, dynamic>? health;
    try {
      health = await ref.read(healthProvider(h.id).future);
    } catch (_) {}
    final features = health?['features'] as Map?;
    final name = health?['name'];
    final base = SleepMachine(host: h, agentId: name is String && name.isNotEmpty ? sleepIdOf(name) : sleepIdOf(h.id), status: old?.status, velour: features?['velour'] == true);
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/sleep'));
      return base.copyWith(status: _merged(h.id, SleepStatus.fromJson(j, receivedAt: DateTime.now())), error: () => null);
    } catch (e) {
      if (isNotFound(e)) return base.copyWith(unsupported: true, error: () => null);
      return base.copyWith(error: () => e);
    }
  }

  SleepStatus _merged(String hostId, SleepStatus s) {
    final p = _pending[hostId];
    return p == null || p.isEmpty ? s : s.copyWith(settings: s.settings.apply(p));
  }

  SleepGroup _emit(SleepGroup g) {
    unawaited(ref.read(sleepSyncProvider).sync(g));
    return g;
  }

  void _set(SleepGroup g) {
    if (!_closed) state = AsyncData(_emit(g));
  }

  void _schedule() {
    _cancelTimer?.call();
    if (_closed || _paused) return;
    _cancelTimer = whenVisibleAfter(const Duration(seconds: 5), _poll);
  }

  Future<void> _poll() async {
    if (_closed) return;
    final cur = state.value;
    if (cur != null && _inflight.values.every((n) => n == 0)) {
      try {
        final next = await Future.wait([for (final m in cur.machines) _read(m.host, m)]);
        if (_inflight.values.every((n) => n == 0)) _set(SleepGroup(next));
      } catch (e, st) {
        if (!_closed) state = AsyncError(e, st);
      }
    }
    _schedule();
  }

  /// Another read right away.
  void retry() => ref.invalidateSelf();

  Future<Map> _call(String hostId, String method, String path, Object body, {Duration timeout = const Duration(seconds: 20)}) =>
      withAgent(ref, hostId, (c) async => (await c.request(method, path, body: body, timeout: timeout)) as Map);

  void _apply(String hostId, Map j) {
    final cur = state.value;
    final m = cur?.byHost(hostId);
    if (cur == null || m == null) return;
    _set(cur.replace(m.copyWith(status: _merged(hostId, SleepStatus.fromJson(j, receivedAt: DateTime.now())), error: () => null)));
  }

  /// PUT /v1/sleep on one machine; the value shows at once.
  Future<void> _put(String hostId, Map<String, Object?> patch) {
    final cur = state.value;
    final m = cur?.byHost(hostId);
    if (cur == null || m?.status == null || _closed) return Future.value();
    _pending[hostId] = mergeSleep(_pending[hostId] ?? {}, patch);
    state = AsyncData(cur.replace(m!.copyWith(status: m.status!.copyWith(settings: m.status!.settings.apply(patch)))));
    _inflight[hostId] = (_inflight[hostId] ?? 0) + 1;
    final done = (_chain[hostId] ?? Future.value()).then((_) async {
      try {
        final j = await _call(hostId, 'PUT', '/v1/sleep', {'settings': patch});
        _inflight[hostId] = _inflight[hostId]! - 1;
        if (_inflight[hostId] == 0) {
          _pending.remove(hostId);
          _apply(hostId, j);
        }
      } catch (_) {
        _inflight[hostId] = _inflight[hostId]! - 1;
        if (_inflight[hostId] == 0) _pending.remove(hostId);
        rethrow;
      }
    });
    _chain[hostId] = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<void> _all(Iterable<String> hostIds, Future<void> Function(String hostId) f) async {
    final failed = <String, Object>{};
    await Future.wait([
      for (final id in hostIds)
        f(id).catchError((Object e) {
          failed[id] = e;
        }),
    ]);
    if (failed.isNotEmpty) {
      if (!_closed) unawaited(_poll());
      throw SleepPartialError(failed);
    }
  }

  /// A group-wide setting: the same patch to every machine that has the sleep mode.
  Future<void> saveGroup(Map<String, Object?> patch) async {
    final g = state.value;
    if (g == null) return;
    await _all([for (final m in g.supported) m.host.id], (id) => _put(id, patch));
  }

  /// A setting of one machine only.
  Future<void> saveMachine(String hostId, Map<String, Object?> patch) => _put(hostId, patch);

  /// `group` from the machines that join and [leader] (default: the current one), written to every machine.
  Future<void> writeGroup({String? leader}) async {
    final g = state.value;
    if (g == null) return;
    final members = g.members;
    if (members.isEmpty) return saveGroup({'group': null});
    final l = leader ?? (g.leader != null && members.contains(g.leader) ? g.leader!.agentId : (members.where((m) => m.velour).firstOrNull ?? members.first).agentId);
    await saveGroup({
      'group': {
        'members': [for (final m in members) m.agentId],
        'leader': l,
      },
    });
  }

  /// A machine joins or leaves the group (its `join`, then `group` everywhere).
  Future<void> setJoin(String hostId, bool join) async {
    await saveMachine(hostId, {'join': join});
    await writeGroup();
  }

  /// The wizard's result: who joins, the leader, each machine's place in the room.
  Future<void> setup({required Map<String, bool> join, required String leaderHost, required Map<String, (String, String)> layout}) async {
    final g = state.value;
    if (g == null) return;
    await _all([for (final m in g.supported) m.host.id], (id) {
      final (side, distance) = layout[id] ?? (g.byHost(id)!.status!.settings.side, g.byHost(id)!.status!.settings.distance);
      return _put(id, {'join': join[id] ?? false, 'side': side, 'distance': distance});
    });
    await writeGroup(leader: state.value?.byHost(leaderHost)?.agentId);
  }

  /// Starts the group: the leader first with [session] (default: a new one, without a plan); its answer's session (with
  /// the leader's `plan`) then goes unchanged to the other members at once. A member that fails doesn't stop the
  /// others; when the leader fails, the others aren't started ([SleepLeaderNotStarted]: they'd run a plan of their
  /// own). With [only] just those hosts are (re)tried with [session] ([lastSession]: the leader's, when it started).
  Future<SleepStartResult> start({List<String>? only, Map<String, Object>? session}) async {
    final g = state.value;
    if (g == null) return const SleepStartResult({}, []);
    final members = g.members.isEmpty ? [?g.leader] : g.members;
    if (members.isEmpty) return const SleepStartResult({}, []);
    var s = session ?? buildSession(g, members, now: ref.read(clockProvider)());
    final order = [for (final m in s['members'] as List) g.byAgent('${m is Map ? m['host'] : m}')].whereType<SleepMachine>().where((m) => only == null || only.contains(m.host.id)).toList();
    final failed = <String, Object>{};
    final started = <String>[];
    Future<Map?> one(SleepMachine m) async {
      try {
        Map j;
        try {
          j = await _call(m.host.id, 'POST', '/v1/sleep/start', {'session': s}, timeout: const Duration(seconds: 30));
        } on AgentError catch (e) {
          // An S2 agent takes the members as an id list only.
          if (e.code != 'agent.request.invalid') rethrow;
          j = await _call(m.host.id, 'POST', '/v1/sleep/start', {'session': sessionIdsOnly(s)}, timeout: const Duration(seconds: 30));
        }
        started.add(m.host.id);
        _apply(m.host.id, j);
        return j;
      } catch (e) {
        failed[m.host.id] = e;
        return null;
      }
    }

    final leader = order.where((m) => m.agentId == s['leader']).firstOrNull;
    var rest = order;
    if (leader != null && s['plan'] == null) {
      rest = order.where((m) => m != leader).toList();
      final j = await one(leader);
      if (j == null) {
        for (final m in rest) {
          failed[m.host.id] = const SleepLeaderNotStarted();
        }
        rest = const [];
      } else if (j['session'] is Map && (j['session'] as Map)['plan'] is Map) {
        // The leader's session, plan included, as it answered it (an agent before S4 has no plan: the same session).
        s = Map<String, Object>.from(j['session'] as Map);
      }
    }
    await Future.wait([for (final m in rest) one(m)]);
    if (failed.isNotEmpty && !_closed) unawaited(_poll());
    _lastSession = s;
    return SleepStartResult(failed, started);
  }

  /// The session of the last start (a retry sends the same one): the leader's, with its plan, once it started.
  Map<String, Object>? get lastSession => _lastSession;
  Map<String, Object>? _lastSession;

  /// "Tek makineyle sür" when nothing started: one machine with a one-member session (it leads itself). The leader,
  /// unless it failed itself and another member only waited for it.
  Future<SleepStartResult> startAlone([SleepStartResult? last]) async {
    final g = state.value;
    final l = g?.leader;
    if (g == null || l == null) return const SleepStartResult({}, []);
    final leaderFailed = last != null && last.failed.containsKey(l.host.id) && last.failed[l.host.id] is! SleepLeaderNotStarted;
    final m = leaderFailed ? (g.members.where((x) => x != l && last.failed[x.host.id] is SleepLeaderNotStarted).firstOrNull ?? l) : l;
    return start(only: [m.host.id], session: buildSession(g, [m], now: ref.read(clockProvider)()));
  }

  /// Stops every machine that runs it (and every member, in case a status is stale).
  Future<void> stop() async {
    final g = state.value;
    if (g == null) return;
    final ids = {for (final m in [...g.runningMachines, ...g.members]) m.host.id};
    await ref.read(sleepSyncProvider).ended();
    await _all(ids, (id) async => _apply(id, await _call(id, 'POST', '/v1/sleep/stop', const {}, timeout: const Duration(seconds: 30))));
  }

  /// Ertele / Kapat: the phone's own alarm follows at once, then ONE running machine is told (the agents pass it to
  /// the whole group), the leader first; the next is tried only when one can't be reached or no longer sleeps.
  /// `409 agent.sleep.notRinging` (nothing to snooze or dismiss now) is thrown after the state is read again (the
  /// phone's backup follows the machines' state then).
  Future<void> alarm(String action) async {
    final g = state.value;
    if (g == null) return;
    final l = g.leader;
    final order = [if (l != null && l.running) l, ...g.runningMachines.where((m) => m != l)];
    if (action == 'dismiss') await ref.read(sleepSyncProvider).dismissed();
    if (action == 'snooze') await ref.read(sleepSyncProvider).snoozed(g.settings.snoozeMin);
    final failed = <String, Object>{};
    for (final m in order) {
      try {
        _apply(m.host.id, await _call(m.host.id, 'POST', '/v1/sleep/alarm', {'action': action}));
        // The others took it from the group: their state is read again now, not at the next poll.
        if (!_closed) unawaited(_poll());
        return;
      } on AgentError catch (e) {
        if (e.code == 'agent.sleep.notRinging') {
          if (!_closed) await _poll();
          rethrow;
        }
        failed[m.host.id] = e;
      } catch (e) {
        failed[m.host.id] = e;
      }
    }
    if (failed.isNotEmpty) {
      if (!_closed) unawaited(_poll());
      throw SleepPartialError(failed);
    }
  }

  /// 5 s at [brightness] on that machine (the hardware, and the page when running).
  Future<Map> preview(String hostId, int brightness) async {
    final j = await _call(hostId, 'POST', '/v1/sleep/preview', {'brightness': brightness});
    _apply(hostId, j);
    return j;
  }
}

final sleepGroupProvider = AsyncNotifierProvider.autoDispose<SleepGroupNotifier, SleepGroup>(SleepGroupNotifier.new, retry: _noRetry);
