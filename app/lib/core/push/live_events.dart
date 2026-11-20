// Live notifications without ntfy (K9): while the app is in the foreground, every host whose notifications don't
// reach the phone by push (no UnifiedPush on this platform, no distributor, or the host never accepted the endpoint)
// is polled for new events (GET /v1/events?since=…, every 20 s; the agent has no event stream) and each new event is
// shown as a local notification through the same code as a push message (texts, filters, channels, ids). Hosts that
// push does cover are skipped, so nothing is shown twice. Notifications while the app is closed still need ntfy.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/push_section.dart' show pushServiceProvider;
import '../../features/system/agent_providers.dart' show agentClientFactoryProvider;
import '../../state/providers.dart';
import '../agent/agent_client.dart';
import '../profile/model.dart';

const liveEventsInterval = Duration(seconds: 20);

/// At most this many notifications per host and poll (a burst after a long gap shouldn't flood the shade).
const liveEventsMaxPerPoll = 10;

class LiveEventsWatcher {
  LiveEventsWatcher({required this.hosts, required this.clientFor, required this.covered, required this.show, this.interval = liveEventsInterval});

  final List<Host> Function() hosts;
  final Future<AgentClient> Function(Host) clientFor;

  /// Push already brings this host's notifications.
  final Future<bool> Function(Host) covered;

  /// Shows one event ({key, params, link}).
  final Future<void> Function(Map<String, dynamic> event) show;
  final Duration interval;

  /// Host id → the agent's time of the newest event seen (the agent's clock, so phone clock skew doesn't matter).
  final _since = <String, String>{};
  final _seen = <String>{};
  Timer? _timer;
  bool _busy = false;

  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One round over all hosts; returns how many notifications were shown.
  Future<int> tick() async {
    if (_busy) return 0;
    _busy = true;
    var shown = 0;
    try {
      for (final h in hosts()) {
        if (h.agent == null) continue;
        try {
          if (await covered(h)) {
            // Push covers it now; if that stops, start fresh rather than replaying what push already showed.
            _since.remove(h.id);
            continue;
          }
          shown += await _poll(h);
        } catch (_) {
          // Unreachable or refused right now: the next round tries again.
        }
      }
    } finally {
      _busy = false;
    }
    return shown;
  }

  Future<int> _poll(Host h) async {
    final c = await clientFor(h);
    final List<Map<String, dynamic>> events;
    final since = _since[h.id];
    try {
      final j = await c.get('/v1/events', query: {'since': ?since, 'limit': since == null ? '1' : '50'});
      events = [for (final e in (j['events'] as List? ?? const [])) if (e is Map) Map<String, dynamic>.from(e)];
    } finally {
      c.close();
    }
    if (since == null) {
      // First look at this host: only remember where its log stands; what happened before isn't news. An empty log
      // starts at the epoch, so its very first event is shown.
      _since[h.id] = events.firstOrNull?['at'] as String? ?? '1970-01-01T00:00:00.000Z';
      return 0;
    }
    if (events.isEmpty) return 0;
    _since[h.id] = events.first['at'] as String? ?? since;
    var shown = 0;
    // Newest first from the agent: show oldest first, at most the newest few.
    for (final e in events.take(liveEventsMaxPerPoll).toList().reversed) {
      final id = '${h.id}|${e['id']}';
      // Events the phone reported itself (work done over SSH) aren't news to it.
      if (!_seen.add(id) || e['source'] == 'app') continue;
      await show(e);
      shown++;
    }
    if (_seen.length > 2000) _seen.clear();
    return shown;
  }
}

/// null in tests and wherever there is no notification service (pushServiceProvider is null there).
final liveEventsWatcherProvider = Provider<LiveEventsWatcher?>((ref) {
  final push = ref.watch(pushServiceProvider);
  if (push == null) return null;
  final w = LiveEventsWatcher(
    hosts: () => ref.read(profileProvider).hosts,
    clientFor: (h) => ref.read(agentClientFactoryProvider)(h),
    covered: push.covers,
    show: (e) => push.showNotice(
      key: '${e['key'] ?? ''}',
      params: Map<String, dynamic>.from((e['params'] as Map?) ?? const {}),
      link: e['link'] as String?,
    ),
  );
  ref.onDispose(w.stop);
  return w;
});

/// Runs the watcher while the app is in the foreground.
class LiveEventsGate extends ConsumerStatefulWidget {
  const LiveEventsGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<LiveEventsGate> createState() => _LiveEventsGateState();
}

class _LiveEventsGateState extends ConsumerState<LiveEventsGate> {
  late final AppLifecycleListener _life;
  LiveEventsWatcher? _watcher;

  @override
  void initState() {
    super.initState();
    _watcher = ref.read(liveEventsWatcherProvider);
    _life = AppLifecycleListener(onResume: () => _watcher?.start(), onHide: () => _watcher?.stop());
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _watcher?.start();
  }

  @override
  void dispose() {
    _life.dispose();
    _watcher?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
