// Screen modes (PLAN.md §20 U; was Game mode, §19): the data side. A display host's agent runs the modes: GET/PUT
// /v1/screen, POST /v1/screen/{start,mode,stop,focus,veil}. An agent older than §20 (no /v1/screen: 404) only has Game
// mode under /v1/gamemode: then this falls back to it ([ScreenStatus.legacy]) and Work/Focus say the agent needs an
// update. The status is polled every 2 s while a screen or card watches it (and the app is in front); settings changes
// show at once (optimistic) and are sent in order. Source tokens are only ever in the request that stores them.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../state/providers.dart';
import '../system/agent_providers.dart';
import 'screen_focus.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// The modes in the app's order (Çalışma · Odak · Oyun).
const screenModes = ['work', 'focus', 'game'];

/// Card kinds each mode's template holds, in the template's order (agent: screen/topics.ts TEMPLATES).
const screenTemplates = <String, List<String>>{
  'work': ['city', 'day', 'system', 'jobs', 'git', 'music', 'servers'],
  'focus': ['focus', 'task', 'day', 'music', 'servers'],
  'game': ['map', 'cockpit', 'music', 'lyrics'],
};

/// The agent's own name for this host as a source.
const selfSource = 'self';

/// An agent route the old agent doesn't have.
bool isNotFound(Object e) => e is AgentError && (e.code == 'agent.route.notFound' || e.status == 404);

/// Thrown locally when an older agent (Game mode only) is asked for something only the screen modes have.
const needsUpdateCode = 'app.screen.needsUpdate';

@immutable
class LayoutCard {
  const LayoutCard(this.kind, this.source, this.enabled);
  factory LayoutCard.fromJson(Map j) => LayoutCard('${j['kind']}', '${j['source'] ?? selfSource}', j['enabled'] != false);
  final String kind;
  final String source;
  final bool enabled;
  Map<String, Object?> toJson() => {'kind': kind, 'source': source, 'enabled': enabled};
  LayoutCard copyWith({String? source, bool? enabled}) => LayoutCard(kind, source ?? this.source, enabled ?? this.enabled);
  @override
  bool operator ==(Object other) => other is LayoutCard && other.kind == kind && other.source == source && other.enabled == enabled;
  @override
  int get hashCode => Object.hash(kind, source, enabled);
}

@immutable
class ScreenLayout {
  const ScreenLayout(this.template, this.cards);
  factory ScreenLayout.fromJson(String mode, Object? j) {
    if (j is! Map) return ScreenLayout.template(mode, selfSource);
    return ScreenLayout('${j['template'] ?? mode}', [for (final c in (j['cards'] as List? ?? const [])) LayoutCard.fromJson(c as Map)]);
  }

  /// The mode's template: every card on, all reading [source].
  factory ScreenLayout.template(String mode, String source) => ScreenLayout(mode, [for (final k in screenTemplates[mode]!) LayoutCard(k, source, true)]);

  final String template;
  final List<LayoutCard> cards;

  Map<String, Object?> toJson() => {'template': template, 'cards': [for (final c in cards) c.toJson()]};

  /// The layout's cards, then the template's kinds it doesn't list (off), so each can be turned on.
  List<LayoutCard> complete(String mode) {
    final fallback = commonSource ?? selfSource;
    return [
      ...cards,
      for (final k in screenTemplates[mode] ?? const <String>[])
        if (!cards.any((c) => c.kind == k)) LayoutCard(k, fallback, false),
    ];
  }

  /// The source every card reads, or null when they differ (a custom layout).
  String? get commonSource {
    final s = cards.map((c) => c.source).toSet();
    return s.length == 1 ? s.single : null;
  }

  ScreenLayout withSource(String source) => ScreenLayout(template, [for (final c in cards) c.copyWith(source: source)]);

  @override
  bool operator ==(Object other) => other is ScreenLayout && other.template == template && listEquals(other.cards, cards);
  @override
  int get hashCode => Object.hash(template, Object.hashAll(cards));
}

/// One mode's settings (`config.screen.modes.<mode>`), read from the agent's JSON with its defaults.
@immutable
class ModeSettings {
  const ModeSettings(this.mode, this.raw);
  final String mode;
  final Map<String, dynamic> raw;

  T _v<T>(String k, T def) => raw[k] is T ? raw[k] as T : def;
  int _i(String k, int def) => (raw[k] as num?)?.round() ?? def;

  /// low | normal | high
  String get motion => _v('motion', 'normal');

  /// 5..100; null: the backlight is not touched.
  int? get brightness => (raw['brightness'] as num?)?.round();
  bool get clock24 => _v('clock24', true);

  /// 0: never (Game and Work).
  int get dimIdleMinutes => _i('dimIdleMinutes', 10);
  ScreenLayout get layout => ScreenLayout.fromJson(mode, raw['layout']);

  // Game (§19)
  String get scene => _v('scene', 'auto');
  bool get lyrics => _v('lyrics', true);
  bool get spectrum => _v('spectrum', true);

  // Work
  /// null: automatic (the last active Claude session's or the focused terminal's repository).
  String? get projectPath => raw['project'] is Map ? '${(raw['project'] as Map)['path']}' : null;
  String get city => _v('city', '3d');
  bool get diff => _v('diff', true);
  bool get ci => _v('ci', false);

  // Focus
  int get focusMin => _i('focusMin', 25);
  int get shortMin => _i('shortMin', 5);
  int get longMin => _i('longMin', 15);
  int get longEvery => _i('longEvery', 4);

  /// off | brown | pink | rain
  String get ambient => _v('ambient', 'off');
  int get ambientVolume => _i('ambientVolume', 30);
  bool get chime => _v('chime', true);
  bool get quietPhone => _v('quietPhone', true);
}

/// `settings` of GET /v1/screen.
@immutable
class ScreenSettings {
  const ScreenSettings([this.raw = const {}]);
  final Map<String, dynamic> raw;

  /// fullscreen | scratch
  String get placement => '${raw['placement'] ?? 'fullscreen'}';
  String get scratchBind => '${raw['scratchBind'] ?? 'SUPER,grave'}';
  String get lastMode => screenModes.contains(raw['lastMode']) ? raw['lastMode'] as String : 'work';

  /// This host as a source sends real file names and approval diffs.
  bool get shareCode => (raw['share'] as Map?)?['code'] == true;
  ModeSettings mode(String m) => ModeSettings(m, Map<String, dynamic>.from((raw['modes'] as Map?)?[m] as Map? ?? const {}));

  /// A copy with [patch] (the shape of PUT's `settings`) laid over it.
  ScreenSettings apply(Map<String, Object?> patch) => ScreenSettings(mergeSettings(raw, patch));

  @override
  bool operator ==(Object other) => other is ScreenSettings && mapEquals(other.raw, raw);
  @override
  int get hashCode => Object.hashAll(raw.keys);
}

/// Deep merge of a settings patch: nested objects merge, except `layout` and `project` which are replaced whole (as the
/// agent does). A key mapped to null stays null (brightness "don't touch").
Map<String, dynamic> mergeSettings(Map a, Map b) => {
  ...a.cast<String, dynamic>(),
  for (final e in b.entries)
    '${e.key}': e.value is Map && a[e.key] is Map && e.key != 'layout' && e.key != 'project' ? mergeSettings(a[e.key] as Map, e.value as Map) : e.value,
};

@immutable
class ScreenSource {
  const ScreenSource({required this.name, this.url, this.state = 'off', this.topics = const []});
  factory ScreenSource.fromJson(Map j) =>
      ScreenSource(name: '${j['name']}', url: j['url'] as String?, state: '${j['state'] ?? 'off'}', topics: [for (final t in (j['topics'] as List? ?? const [])) '$t']);
  final String name;
  final String? url;

  /// off | connecting | ok | down
  final String state;
  final List<String> topics;
  bool get isSelf => name == selfSource;
}

/// The Focus timer (GET /v1/screen `focus`). Times are the agent's: [remaining] corrects for clock skew with `now`.
@immutable
class FocusState {
  const FocusState({this.phase = 'idle', this.endsAt, this.pausedLeft, this.total, this.round = 0, this.longEvery = 4, this.task, this.agentNow, this.receivedAt});
  factory FocusState.fromJson(Map? j, DateTime receivedAt) {
    if (j == null) return FocusState(receivedAt: receivedAt);
    int? i(String k) => (j[k] as num?)?.round();
    return FocusState(
      phase: '${j['phase'] ?? 'idle'}',
      endsAt: i('endsAt'),
      pausedLeft: i('pausedLeft'),
      total: i('total'),
      round: i('round') ?? 0,
      longEvery: i('longEvery') ?? 4,
      task: j['task'] as String?,
      agentNow: i('now'),
      receivedAt: receivedAt,
    );
  }

  /// idle | focus | short | long
  final String phase;
  final int? endsAt;
  final int? pausedLeft;
  final int? total;
  final int round;
  final int longEvery;
  final String? task;

  /// The agent's clock when it answered, and the phone's when the answer arrived.
  final int? agentNow;
  final DateTime? receivedAt;

  bool get idle => phase == 'idle';
  bool get paused => !idle && pausedLeft != null;
  bool get ticking => !idle && endsAt != null;
  bool get isBreak => phase == 'short' || phase == 'long';

  /// The phase's end on the phone's clock.
  DateTime? get endsAtLocal {
    if (endsAt == null) return null;
    final skew = agentNow == null || receivedAt == null ? 0 : agentNow! - receivedAt!.millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(endsAt! - skew);
  }

  Duration remaining(DateTime now) {
    if (paused) return Duration(milliseconds: pausedLeft!);
    final end = endsAtLocal;
    if (end == null) return Duration.zero;
    final left = end.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 0..1 of the phase done, in steps of 0.5 % (a ring or bar doesn't need more; it redraws only when it moves).
  double progress(DateTime now) {
    final t = total;
    if (t == null || t <= 0) return 0;
    return ((1 - remaining(now).inMilliseconds / t).clamp(0.0, 1.0) * 200).floor() / 200;
  }

  FocusState withTask(String? t) =>
      FocusState(phase: phase, endsAt: endsAt, pausedLeft: pausedLeft, total: total, round: round, longEvery: longEvery, task: t, agentNow: agentNow, receivedAt: receivedAt);
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
class ScreenStatus {
  const ScreenStatus({
    this.legacy = false,
    required this.running,
    this.mode,
    this.startedAt,
    this.placement = 'fullscreen',
    this.settings = const ScreenSettings(),
    this.sources = const [ScreenSource(name: selfSource, state: 'off')],
    this.veil = false,
    this.focus = const FocusState(),
    this.mapPresent = false,
    this.music,
    this.truck,
    this.claudeSessions,
    this.claudeWaiting,
    this.jobs,
  });

  factory ScreenStatus.fromJson(Map j, {DateTime? receivedAt}) {
    final live = (j['live'] as Map?) ?? const {};
    final music = live['music'], truck = live['truck'], claude = live['claude'];
    return ScreenStatus(
      running: j['running'] == true,
      mode: j['mode'] as String?,
      startedAt: _date(j['startedAt']),
      placement: '${j['placement'] ?? 'fullscreen'}',
      settings: ScreenSettings(Map<String, dynamic>.from((j['settings'] as Map?) ?? const {})),
      sources: [for (final s in (j['sources'] as List? ?? const [])) ScreenSource.fromJson(s as Map)],
      veil: j['veil'] == true,
      focus: FocusState.fromJson(j['focus'] as Map?, receivedAt ?? DateTime.now()),
      mapPresent: (j['map'] as Map?)?['present'] == true,
      music: music is Map ? GameMusic(music) : null,
      truck: truck is Map ? GameTruck(truck) : null,
      claudeSessions: claude is Map ? (claude['sessions'] as num?)?.round() : null,
      claudeWaiting: claude is Map ? (claude['waiting'] as num?)?.round() : null,
      jobs: (live['jobs'] as num?)?.round(),
    );
  }

  /// GET /v1/gamemode of an agent older than §20: Game mode only, its one source is `main`.
  factory ScreenStatus.fromLegacy(Map j) {
    final src = (j['source'] as Map?) ?? const {};
    final live = (j['live'] as Map?) ?? const {};
    final music = live['music'], truck = live['truck'];
    final configured = src['configured'] == true;
    final running = j['running'] == true;
    return ScreenStatus(
      legacy: true,
      running: running,
      mode: running ? 'game' : null,
      startedAt: _date(j['startedAt']),
      settings: ScreenSettings({
        'lastMode': 'game',
        'modes': {
          'game': {
            ...Map<String, dynamic>.from((j['settings'] as Map?) ?? const {}),
            'layout': ScreenLayout.template('game', 'main').toJson(),
          },
        },
      }),
      sources: [
        const ScreenSource(name: selfSource),
        if (configured) ScreenSource(name: 'main', url: src['url'] as String?, state: '${src['state'] ?? 'off'}'),
      ],
      mapPresent: (j['map'] as Map?)?['present'] == true,
      music: music is Map ? GameMusic(music) : null,
      truck: truck is Map ? GameTruck(truck) : null,
    );
  }

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : (v is num ? DateTime.fromMillisecondsSinceEpoch(v.round()) : null);

  /// An agent older than §20: only Game mode, through /v1/gamemode.
  final bool legacy;
  final bool running;

  /// game | work | focus (null while off).
  final String? mode;
  final DateTime? startedAt;
  final String placement;
  final ScreenSettings settings;

  /// `self` first, then the named source agents.
  final List<ScreenSource> sources;
  final bool veil;
  final FocusState focus;

  /// Map files (PMTiles) present on the display host.
  final bool mapPresent;
  final GameMusic? music;
  final GameTruck? truck;

  /// Live counts (newer agents only): Claude sessions, waiting ones, running jobs.
  final int? claudeSessions;
  final int? claudeWaiting;
  final int? jobs;

  List<ScreenSource> get remoteSources => sources.where((s) => !s.isSelf).toList();
  ScreenSource? source(String name) => sources.where((s) => s.name == name).firstOrNull;

  /// The mode the screen shows, or would start with.
  String get shownMode => mode ?? settings.lastMode;

  ScreenStatus copyWith({bool? running, String? Function()? mode, ScreenSettings? settings, bool? veil, FocusState? focus}) => ScreenStatus(
    legacy: legacy,
    running: running ?? this.running,
    mode: mode != null ? mode() : this.mode,
    startedAt: startedAt,
    placement: placement,
    settings: settings ?? this.settings,
    sources: sources,
    veil: veil ?? this.veil,
    focus: focus ?? this.focus,
    mapPresent: mapPresent,
    music: music,
    truck: truck,
    claudeSessions: claudeSessions,
    claudeWaiting: claudeWaiting,
    jobs: jobs,
  );

  /// Game: what the kiosk shows right now (scene "auto": driving when the truck is driving, else music or standby).
  String get activeScene => switch (settings.mode('game').scene) {
    'drive' => 'drive',
    'music' => 'music',
    _ => truck?.driving == true ? 'drive' : (music != null ? 'music' : 'idle'),
  };
}

/// Polls GET /v1/screen (or GET /v1/gamemode on an older agent); actions update the state from the agent's answer.
class ScreenNotifier extends AsyncNotifier<ScreenStatus> {
  ScreenNotifier(this.hostId);
  final String hostId;
  VoidCallback? _cancelTimer;
  bool _closed = false;
  bool _paused = false;
  bool _legacy = false;

  /// Settings sent but not confirmed yet: laid over every status that arrives meanwhile (so a poll doesn't undo a drag).
  Map<String, Object?> _pending = {};
  int _inflight = 0;
  Future<void> _chain = Future.value();

  @override
  Future<ScreenStatus> build() async {
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
      return _emit(_merge(await _fetch()));
    } finally {
      _schedule();
    }
  }

  Future<ScreenStatus> _fetch() => withAgent(ref, hostId, (c) async {
    if (!_legacy) {
      try {
        return ScreenStatus.fromJson(await c.get('/v1/screen'), receivedAt: DateTime.now());
      } catch (e) {
        if (!isNotFound(e)) rethrow;
        _legacy = true;
      }
    }
    return ScreenStatus.fromLegacy(await c.get('/v1/gamemode'));
  });

  ScreenStatus _merge(ScreenStatus s) => _pending.isEmpty ? s : s.copyWith(settings: s.settings.apply(_pending));

  /// Every status that arrives also drives the Focus side effects (ongoing notification, quiet notifications).
  ScreenStatus _emit(ScreenStatus s) {
    final host = ref.read(profileProvider).host(hostId);
    unawaited(ref.read(focusSyncProvider).sync(hostId, host?.name ?? hostId, s));
    return s;
  }

  void _set(ScreenStatus s) {
    if (!_closed) state = AsyncData(_emit(s));
  }

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
        if (_inflight == 0) _set(s);
      } catch (e, st) {
        if (!_closed) state = AsyncError(e, st);
      }
    }
    _schedule();
  }

  /// Another read right away (after a failed action, or the retry button).
  void retry() => ref.invalidateSelf();

  Future<Map> _call(String method, String path, Object body, {Duration timeout = const Duration(seconds: 15)}) =>
      withAgent(ref, hostId, (c) async => (await c.request(method, path, body: body, timeout: timeout)) as Map);

  /// Sends changed settings (the shape of PUT's `settings`, e.g. `{'modes': {'work': {'city': '2d'}}}`). The new values
  /// show at once; on failure the real state is read again and the error is thrown to the caller (for a toast).
  Future<void> saveSettings(Map<String, Object?> patch) {
    final cur = state.value;
    if (cur == null || _closed) return Future.value();
    final game = (patch['modes'] as Map?)?['game'];
    if (cur.legacy && (patch.length != 1 || (patch['modes'] as Map).length != 1 || game == null)) return Future.error(const AgentError(needsUpdateCode));
    _pending = mergeSettings(_pending, patch);
    state = AsyncData(cur.copyWith(settings: cur.settings.apply(patch)));
    _inflight++;
    final done = _chain.then((_) async {
      try {
        final s = cur.legacy
            ? ScreenStatus.fromLegacy(await _call('PUT', '/v1/gamemode', {'settings': game}))
            : ScreenStatus.fromJson(await _call('PUT', '/v1/screen', {'settings': patch}), receivedAt: DateTime.now());
        if (--_inflight == 0) _pending = {};
        if (_inflight == 0) _set(s);
      } catch (_) {
        if (--_inflight == 0) _pending = {};
        if (!_closed) retry();
        rethrow;
      }
    });
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Adds (`{url, token}`) or removes (null) named sources on the display agent.
  Future<void> putSources(Map<String, Object?> sources) async {
    final s = ScreenStatus.fromJson(await _call('PUT', '/v1/screen', {'sources': sources}), receivedAt: DateTime.now());
    _set(_merge(s));
  }

  /// Starts [mode]; while another mode runs this is the hot switch (POST /v1/screen/mode).
  Future<void> start(String mode) async {
    final cur = state.value;
    if (_closed) return;
    if (cur != null && cur.legacy && mode != 'game') throw const AgentError(needsUpdateCode);
    final switching = cur?.running == true && !cur!.legacy;
    if (cur != null) state = AsyncData(cur.copyWith(running: true, mode: () => mode));
    try {
      final j = cur?.legacy == true
          ? await _call('POST', '/v1/gamemode/start', const {}, timeout: const Duration(seconds: 25))
          : await _call('POST', switching ? '/v1/screen/mode' : '/v1/screen/start', {'mode': mode}, timeout: const Duration(seconds: 25));
      _set(_merge(cur?.legacy == true ? ScreenStatus.fromLegacy(j) : ScreenStatus.fromJson(j, receivedAt: DateTime.now())));
    } catch (_) {
      if (!_closed) retry();
      rethrow;
    }
  }

  /// Stops everything. Idempotent on the agent.
  Future<void> stop() async {
    final cur = state.value;
    if (_closed) return;
    if (cur != null) state = AsyncData(cur.copyWith(running: false, mode: () => null));
    try {
      final j = await _call('POST', cur?.legacy == true ? '/v1/gamemode/stop' : '/v1/screen/stop', const {}, timeout: const Duration(seconds: 25));
      _set(_merge(cur?.legacy == true ? ScreenStatus.fromLegacy(j) : ScreenStatus.fromJson(j, receivedAt: DateTime.now())));
    } catch (_) {
      if (!_closed) retry();
      rethrow;
    }
  }

  /// Focus timer: `start|pause|resume|skip|reset` and/or the task line (`''` clears it).
  Future<void> focus({String? action, String? task}) async {
    final j = await _call('POST', '/v1/screen/focus', {'action': ?action, 'task': ?task});
    final cur = state.value;
    if (cur != null) _set(cur.copyWith(focus: FocusState.fromJson(j['focus'] as Map?, DateTime.now())));
  }

  /// Privacy veil on the display.
  Future<void> veil(bool on) async {
    final cur = state.value;
    if (cur != null) state = AsyncData(cur.copyWith(veil: on));
    try {
      _set(_merge(ScreenStatus.fromJson(await _call('POST', '/v1/screen/veil', {'on': on}), receivedAt: DateTime.now())));
    } catch (_) {
      if (!_closed) retry();
      rethrow;
    }
  }
}

final screenProvider = AsyncNotifierProvider.autoDispose.family<ScreenNotifier, ScreenStatus, String>(ScreenNotifier.new, retry: _noRetry);

/// Hosts whose agent reports the screen modes (`screen`, or `gamemode` on an agent older than §20).
final screenHostsProvider = FutureProvider.autoDispose<List<Host>>((ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final found = await Future.wait([
    for (final h in hosts)
      ref.watch(healthProvider(h.id).future).then<Host?>((j) {
        final f = j['features'] as Map?;
        return f?['screen'] == true || f?['gamemode'] == true ? h : null;
      }, onError: (_) => null),
  ]);
  return [for (final h in found) ?h];
});

/// The display host for the home card: the first host whose mode runs, otherwise the first host with the feature.
/// `ready` is false for an older agent (Game mode only) without a source yet: the card then leads to the setup.
class ScreenTarget {
  const ScreenTarget(this.host, {this.ready = true});
  final Host host;
  final bool ready;
}

final screenTargetProvider = FutureProvider.autoDispose<ScreenTarget?>(retry: _noRetry, (ref) async {
  autoRefresh(ref, const Duration(seconds: 60));
  final hosts = await ref.watch(screenHostsProvider.future);
  ScreenTarget? first;
  var anyFailed = false;
  for (final h in hosts) {
    try {
      final s = await withAgent(ref, h.id, (c) async {
        try {
          return ScreenStatus.fromJson(await c.get('/v1/screen'));
        } catch (e) {
          if (!isNotFound(e)) rethrow;
          return ScreenStatus.fromLegacy(await c.get('/v1/gamemode'));
        }
      });
      if (s.running) return ScreenTarget(h);
      first ??= ScreenTarget(h, ready: !s.legacy || s.remoteSources.isNotEmpty);
    } catch (_) {
      anyFailed = true;
    }
  }
  return first ?? (hosts.isEmpty || anyFailed ? null : ScreenTarget(hosts.first, ready: false));
});

/// The profile host whose agent URL is [url] (the display agent only reports its sources' URLs).
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

/// The profile host a source name stands for on [display] (`self` = the display host itself), or null.
Host? hostForSource(Profile p, Host display, ScreenStatus s, String name) =>
    name == selfSource ? display : hostForAgentUrl(p, s.source(name)?.url);

/// A readable name for a source: its profile host's name, else the URL's host, else the source's own name.
String sourceLabel(Profile p, Host display, ScreenStatus s, String name) {
  final h = hostForSource(p, display, s, name);
  if (h != null) return h.name;
  final url = s.source(name)?.url;
  return (url == null ? null : Uri.tryParse(url)?.host) ?? name;
}

/// A source name for [h] on a display agent (`[a-z0-9-]{1,32}`, never `self`).
String sourceNameFor(Host h) {
  final n = h.id.replaceAll(RegExp(r'[^a-z0-9-]'), '-');
  final cut = n.length > 32 ? n.substring(0, 32) : n;
  return cut.isEmpty || cut == selfSource ? 'src-${cut.isEmpty ? 'host' : cut}' : cut;
}

/// Name of the service token the wizard creates on a source host (found again to revoke it when the source is removed).
String screenTokenName(Host display) {
  final name = 'Screen mode: ${display.name}';
  return name.length > 80 ? name.substring(0, 80) : name;
}

/// Connects [display] to [source]: a service token (scope `screen`, or `gamemode` for an older display agent) is created
/// on the source host, handed to the display agent and nothing else keeps it. If storing it fails the token is revoked
/// again. Returns the source name on the display.
Future<String> connectScreenSource({required Host display, required Host source, required AgentClient displayClient, required AgentClient sourceClient, required bool legacy}) async {
  final created = await sourceClient.post('/v1/service-tokens', {
    'name': screenTokenName(display),
    'scopes': [legacy ? 'gamemode' : 'screen'],
  }) as Map;
  final tokenId = '${(created['serviceToken'] as Map)['id']}';
  final name = legacy ? 'main' : sourceNameFor(source);
  final entry = {'url': source.agent!.url, 'token': created['token'] as String};
  try {
    await displayClient.put(legacy ? '/v1/gamemode' : '/v1/screen', legacy ? {'source': entry} : {'sources': {name: entry}});
  } catch (_) {
    try {
      await sourceClient.delete('/v1/service-tokens/$tokenId');
    } catch (_) {
      // The token stays listed on the source host; it can be revoked there.
    }
    rethrow;
  }
  return name;
}

/// Removing a source: the tokens the wizard made for [display] on [source] are revoked (best effort).
Future<void> revokeScreenTokens({required Host display, required AgentClient sourceClient}) async {
  final j = await sourceClient.get('/v1/service-tokens');
  for (final t in [...(j['tokens'] as List? ?? const [])].cast<Map>()) {
    final scopes = (t['scopes'] as List? ?? const []);
    if (t['name'] == screenTokenName(display) && (scopes.contains('screen') || scopes.contains('gamemode'))) {
      await sourceClient.delete('/v1/service-tokens/${t['id']}');
    }
  }
}

/// `screen.share.code` of a source host (its own GET /v1/screen); null when unknown (older agent, unreachable).
final shareCodeProvider = FutureProvider.autoDispose.family<bool?, String>(retry: _noRetry, (ref, hostId) async {
  try {
    return ScreenStatus.fromJson(await withAgent(ref, hostId, (c) => c.get('/v1/screen'))).settings.shareCode;
  } catch (_) {
    return null;
  }
});

/// Turns code sharing on (or off) on a SOURCE host, through that host's own agent. Called only after the user agreed
/// in a confirmation dialog (PLAN.md §20 Decision 2).
Future<void> setShareCode(AgentClient sourceClient, bool on) => sourceClient.put('/v1/screen', {
  'settings': {
    'share': {'code': on},
  },
});

/// `GET /v1/screen/game/source` (or `/v1/gamemode/source` on an older agent) on the Game source host.
class GameSourceInfo {
  GameSourceInfo(Map j)
    : velour = j['velour'] == true,
      audio = j['audio'] == true,
      gameDir = (j['ets2'] as Map?)?['gameDir'] as String?,
      plugin = '${(j['ets2'] as Map?)?['plugin'] ?? 'missing'}',
      pluginVersion = (j['ets2'] as Map?)?['version'] as String?,
      ets2Running = (j['ets2'] as Map?)?['running'] == true,
      telemetry = '${(j['ets2'] as Map?)?['telemetry'] ?? 'none'}';
  final bool velour;
  final bool audio;
  final String? gameDir;

  /// installed | missing | outdated
  final String plugin;
  final String? pluginVersion;
  final bool ets2Running;

  /// ok | unsupported | none
  final String telemetry;
}

final gameSourceProvider = FutureProvider.autoDispose.family<GameSourceInfo, String>(retry: _noRetry, (ref, hostId) async {
  return GameSourceInfo(
    await withAgent(ref, hostId, (c) async {
      try {
        return await c.get('/v1/screen/game/source');
      } catch (e) {
        if (!isNotFound(e)) rethrow;
        return c.get('/v1/gamemode/source');
      }
    }),
  );
});

/// Installs / removes the ETS2 plugin on the Game source host.
Future<void> gamePlugin(AgentClient c, String action) async {
  try {
    await c.request('POST', '/v1/screen/game/plugin', body: {'action': action}, timeout: const Duration(seconds: 90));
  } catch (e) {
    if (!isNotFound(e)) rethrow;
    await c.request('POST', '/v1/gamemode/plugin', body: {'action': action}, timeout: const Duration(seconds: 90));
  }
}
