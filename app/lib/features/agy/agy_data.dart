// agy (Antigravity CLI) sessions ("agy" agent feature, /v1/agy/*; contract: agent/src/agy/routes.ts): the host that
// offers them, the lists, the event model and the live controller. Events are polled with a long poll and merged by
// `eid` (a streamed message keeps its eid while its text grows and gets a new `seq`).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../incidents/incidents_data.dart' show exactHostFor;
import '../system/agent_providers.dart';
import '../telegram/telegram_data.dart' show hostsWithFeatureProvider;

/// The agent rate-limits the conversations list (10/min): a failure is shown, not retried in the background.
Duration? _noRetry(int retries, Object error) => null;

typedef AgyJson = Map<String, dynamic>;

/// Long-poll wait the app asks for (the agent allows up to 25 s). Tests override it.
final agyPollWaitProvider = Provider<int>((ref) => 20000);

/// Whether the chat runs the long poll (tests turn it off and drive polls themselves).
final agyPollEnabledProvider = Provider<bool>((ref) => true);

/// Agent hosts that report the `agy` feature; the Claude host first.
final agyHostsProvider = FutureProvider.autoDispose<List<Host>>((ref) async {
  final hosts = await ref.watch(hostsWithFeatureProvider('agy').future);
  final claude = ref.watch(claudeHostProvider);
  return [...hosts.where((h) => h.id == claude?.id), ...hosts.where((h) => h.id != claude?.id)];
});

/// The host agy sessions are used on: the one a link names (`hint`: id or name); without a hint the first that has the
/// feature. A hint that names no host is never guessed (only when there is exactly one agy host): null → the screen says
/// it couldn't tell which agent. null also when no agent reports `agy`.
final agyHostProvider = FutureProvider.autoDispose.family<Host?, String?>((ref, hint) async {
  final hosts = await ref.watch(agyHostsProvider.future);
  if (hint == null || hint.isEmpty) return hosts.firstOrNull;
  return exactHostFor(hosts, hint) ?? (hosts.length == 1 ? hosts.single : null);
});

final agySessionsProvider = FutureProvider.autoDispose.family<List<AgyJson>, String>(retry: _noRetry, (ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 10));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/agy/sessions'));
  return _maps(j['sessions']);
});

/// Earlier conversations of a folder (agy's own list; the agent rate-limits it to 10/min, so it is only fetched when a
/// folder is shown and never auto-refreshed).
final agyConversationsProvider = FutureProvider.autoDispose.family<List<AgyJson>, (String, String)>(retry: _noRetry, (ref, key) async {
  final (hostId, cwd) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/agy/conversations', query: {'cwd': cwd}));
  return _maps(j['conversations']);
});

List<AgyJson> _maps(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

class AgyEvent {
  AgyEvent(this.json);
  final AgyJson json;
  int get eid => (json['eid'] as num?)?.toInt() ?? 0;
  int get seq => (json['seq'] as num?)?.toInt() ?? 0;
  String get kind => json['kind'] as String? ?? '';
  String get text => json['text'] as String? ?? '';
  bool get replay => json['replay'] == true;
  T? get<T>(String k) => json[k] as T?;
}

/// Merges polled events into [events] (kept in eid order): an event with a known eid replaces the old version, a new
/// one is added. Returns the highest `seq` seen (the next poll's `after`), at least [after].
int upsertAgyEvents(List<AgyEvent> events, Iterable<dynamic> incoming, {int after = 0}) {
  var max = after;
  var added = false;
  final index = {for (var i = 0; i < events.length; i++) events[i].eid: i};
  for (final raw in incoming) {
    final e = AgyEvent(Map<String, dynamic>.from(raw as Map));
    if (e.seq > max) max = e.seq;
    final at = index[e.eid];
    if (at != null) {
      // Two polls can overlap (long poll + one after send): an older answer must not overwrite a newer version.
      if (e.seq >= events[at].seq) events[at] = e;
    } else {
      index[e.eid] = events.length;
      events.add(e);
      added = true;
    }
  }
  if (added) events.sort((a, b) => a.eid.compareTo(b.eid));
  // The agent keeps at most 3000 events per session; the app doesn't keep more either.
  if (events.length > maxAgyEvents) events.removeRange(0, events.length - maxAgyEvents);
  return max;
}

const maxAgyEvents = 3000;

/// Latest state of each tool call: the `tool` event's fields overlaid with its `toolUpdate`s (same toolCallId).
Map<String, AgyJson> agyToolStates(Iterable<AgyEvent> events) {
  final out = <String, AgyJson>{};
  for (final e in events) {
    final id = e.get<String>('toolCallId');
    if (id == null || id.isEmpty) continue;
    if (e.kind == 'tool') {
      out[id] = {...out[id] ?? const {}, ...e.json};
    } else if (e.kind == 'toolUpdate') {
      final cur = out[id] ?? <String, dynamic>{};
      out[id] = {
        ...cur,
        if (e.get<String>('status') != null && e.get<String>('status')!.isNotEmpty) 'status': e.get<String>('status'),
        if (e.get<String>('title') != null && e.get<String>('title')!.isNotEmpty) 'title': e.get<String>('title'),
      };
    }
  }
  return out;
}

/// requestId → chosen optionId ("cancelled" when the turn was cancelled) for answered permission requests.
Map<String, String> agyResolvedPermissions(Iterable<AgyEvent> events) => {
  for (final e in events)
    if (e.kind == 'permissionResolved') e.get<String>('requestId') ?? '': e.get<String>('optionId') ?? '',
};

/// The option to press for a notification's "Allow" / "Deny": only one-time choices (kind allow_once / reject_once, or
/// agy's own ids "allow" / "deny"). Never allow_always / reject_always: a lock-screen tap must not grant a lasting
/// permission for a command the user didn't see. null → the user has to decide in the app.
String? agyOptionFor(List<dynamic> options, bool allow) {
  final list = [for (final o in options) Map<String, dynamic>.from(o as Map)];
  final kind = allow ? 'allow_once' : 'reject_once';
  final hit = list.where((o) => o['kind'] == kind).firstOrNull;
  if (hit != null) return '${hit['optionId']}';
  final id = allow ? 'allow' : 'deny';
  final plain = list.where((o) => o['optionId'] == id && !'${o['kind']}'.endsWith('_always')).firstOrNull;
  return plain == null ? null : id;
}

bool agyActive(String status) => status == 'running' || status == 'waiting' || status == 'starting';

/// Live state of one agy session: summary + merged events, kept fresh with a long poll while the screen is visible.
class AgyController extends ChangeNotifier {
  AgyController({required this.client, required this.sessionId, this.waitMs = 20000, this.poll = true}) {
    appVisible.addListener(_onVisibility);
  }

  final AgentClient client;
  final String sessionId;
  final int waitMs;

  /// false: only the first load (tests drive [pollOnce] themselves).
  final bool poll;

  final events = <AgyEvent>[];
  AgyJson? summary;
  Object? error;

  /// The session no longer exists on the agent.
  bool gone = false;

  /// The chat route is the one on top (another screen pushed over it pauses the long poll, like the app going to the
  /// background does).
  bool _foreground = true;
  void setForeground(bool v) {
    if (v == _foreground) return;
    _foreground = v;
    if (v && poll && !_disposed && !gone && !ended && appVisible.value) unawaited(_loop());
  }
  int after = 0;
  bool _disposed = false;
  bool _looping = false;
  int _attempt = 0;
  Timer? _retry;

  String get status => gone ? 'ended' : (summary?['status'] as String? ?? 'starting');
  bool get active => agyActive(status);
  bool get ended => status == 'ended' || status == 'error';
  List<AgyJson> get modes => _maps(summary?['modes']);
  List<AgyJson> get models => _maps(summary?['models']);
  String? get resumeCommand => summary?['resumeCommand'] as String?;

  /// First load, then (unless [poll] is off) the long poll.
  Future<void> start() async {
    await pollOnce(wait: 0);
    if (poll) unawaited(_loop());
  }

  /// One request: events after the highest seq seen, waiting up to [wait] ms for news. Returns false on a failure.
  Future<bool> pollOnce({int? wait}) async {
    final w = wait ?? waitMs;
    try {
      final j = await client.request(
        'GET',
        '/v1/agy/sessions/$sessionId',
        query: {'after': '$after', if (w > 0) 'wait': '$w'},
        timeout: Duration(milliseconds: w + 20000),
      ) as Map;
      if (_disposed) return false;
      summary = Map<String, dynamic>.from(j['session'] as Map);
      after = upsertAgyEvents(events, j['events'] as List, after: after);
      error = null;
      _attempt = 0;
      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed) return false;
      if (e is AgentError && e.code == 'agent.agy.sessionNotFound') gone = true;
      error = e;
      notifyListeners();
      return false;
    }
  }

  Future<void> _loop() async {
    if (_looping) return;
    _looping = true;
    try {
      while (!_disposed && !gone && appVisible.value && _foreground) {
        if (!await pollOnce()) {
          if (gone || _disposed) break;
          await Future<void>.delayed(Duration(seconds: [1, 2, 5, 10, 20][(_attempt++).clamp(0, 4)]));
          continue;
        }
        if (ended) break; // nothing more will come (an ended session answers at once)
      }
    } finally {
      _looping = false;
    }
  }

  /// Back in the foreground: poll again (it stops while the app is in the background).
  void _onVisibility() {
    if (appVisible.value && _foreground && poll && !_disposed && !gone && !ended) unawaited(_loop());
  }

  /// Sends a message. The agent answers 409 `agent.agy.busy` while running/waiting (thrown to the caller).
  Future<void> send(String text) async {
    await client.post('/v1/agy/sessions/$sessionId/messages', {'text': text});
    summary?['status'] = 'running';
    notifyListeners();
    if (poll && !_looping && _foreground) unawaited(_loop());
  }

  Future<void> cancel() => client.post('/v1/agy/sessions/$sessionId/cancel');

  Future<void> decide(String requestId, String optionId) => client.post('/v1/agy/sessions/$sessionId/permissions/$requestId', {'optionId': optionId});

  Future<void> setMode(String modeId) async {
    final j = await client.post('/v1/agy/sessions/$sessionId/mode', {'modeId': modeId}) as Map;
    summary = Map<String, dynamic>.from(j);
    notifyListeners();
  }

  Future<void> setModel(String model) async {
    final j = await client.post('/v1/agy/sessions/$sessionId/model', {'model': model}) as Map;
    summary = Map<String, dynamic>.from(j);
    notifyListeners();
  }

  Future<void> close() => client.delete('/v1/agy/sessions/$sessionId');

  @override
  void dispose() {
    _disposed = true;
    appVisible.removeListener(_onVisibility);
    _retry?.cancel();
    client.close();
    super.dispose();
  }
}
