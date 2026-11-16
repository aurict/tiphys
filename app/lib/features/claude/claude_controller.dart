// Live state of a Claude session: event stream from the agent over WebSocket, resumes where it left off on disconnect.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/refresh.dart';
import '../desktop/desktop_data.dart' show controlHeader;

class ClaudeEvent {
  ClaudeEvent(this.json);
  final Map<String, dynamic> json;
  int get seq => json['seq'] as int? ?? 0;
  String get kind => json['kind'] as String;
  String get text => json['text'] as String? ?? '';
  T? get<T>(String k) => json[k] as T?;
}

/// Message waiting to be sent (written while offline, or whose connection dropped before the reply came).
class OutboxItem {
  OutboxItem({required this.id, required this.text, this.images = const []});
  final String id; // if the agent sees this id a second time it won't process the message again
  final String text;
  final List<Map<String, String>> images;
  bool sending = false;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'images': images};
  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
        id: j['id'] as String,
        text: j['text'] as String,
        images: [for (final i in (j['images'] as List? ?? const [])) Map<String, String>.from(i as Map)],
      );
}

class ClaudeSessionController extends ChangeNotifier {
  ClaudeSessionController({
    required this.client,
    required this.sessionId,
    this.readOnlyEvents,
    this.stream = true,
    this.outboxDir,
    this.olderAvailable = false,
  }) {
    if (isLive && stream) appVisible.addListener(_onVisibility);
  }

  /// On-disk folder of the outbox (so pending messages survive the app closing). null: memory only.
  final String? outboxDir;

  /// Messages that haven't reached the agent yet (sent in order).
  final outbox = <OutboxItem>[];

  /// Are there messages in Claude's transcript older than those shown ("older" button at the top).
  bool olderAvailable;
  bool loadingOlder = false;

  /// Event types that come from the transcript (the skip count is computed from these).
  static const _transcriptKinds = {'user', 'text', 'tool_use', 'tool_result', 'compacted'};

  /// Loads older messages from Claude's transcript and prepends them.
  Future<void> loadOlder() async {
    final String? sdkId = isLive ? (summary?['sdkSessionId'] as String?) : sessionId;
    if (sdkId == null || loadingOlder) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final skip = events.where((e) => _transcriptKinds.contains(e.kind)).length;
      final j = await client.get('/v1/claude/history/$sdkId', query: {'skip': '$skip', 'limit': '200'});
      final older = [for (final e in (j['events'] as List)) ClaudeEvent({...Map<String, dynamic>.from(e as Map), 'seq': 0})];
      events.insertAll(0, older);
      olderAvailable = j['more'] == true && older.isNotEmpty;
    } finally {
      loadingOlder = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// The live stream is turned off in tests.
  final bool stream;

  final AgentClient client;
  final String sessionId;

  /// Fixed events for a past (non-live) session.
  final List<ClaudeEvent>? readOnlyEvents;

  final events = <ClaudeEvent>[];
  String live = ''; // streaming text
  String status = 'starting';
  Map<String, dynamic>? summary;
  bool connected = false;
  Object? error;

  /// The session no longer exists on the agent (closed, or cleaned up after 6 hours idle).
  bool gone = false;
  WebSocket? _ws;
  Timer? _retry;
  bool _disposed = false;
  int _attempt = 0;

  /// Number of each connection attempt: events/close from an old (closed) connection are ignored.
  int _gen = 0;

  int get lastSeq => events.isEmpty ? 0 : events.last.seq;

  /// "Use the PC" session (Claude uses the PC with screenshot + mouse/keyboard tools).
  bool get isPc => summary?['kind'] == 'pc';

  /// Is the PC session bound to a control session according to the agent (do the tools work)?
  bool get pcControlActive => (summary?['control'] as Map?)?['active'] == true;

  /// Why the control binding last broke (stopped | expired | shutdown | lost); null if bound.
  String? get pcControlEndReason {
    if (pcControlActive) return null;
    final last = events.lastWhere((e) => e.kind == 'control', orElse: () => ClaudeEvent(const {'kind': 'none'}));
    return last.kind == 'control' ? last.get<String>('reason') : null;
  }

  /// Binds the PC session to the phone's control session (opened by asking for the lock again).
  Future<void> bindControl(String token) async {
    final j = await client.request('POST', '/v1/claude/sessions/$sessionId/control', headers: {controlHeader: token}) as Map;
    final sm = summary;
    if (sm != null && j['control'] is Map) sm['control'] = Map<String, dynamic>.from(j['control'] as Map);
    if (!_disposed) notifyListeners();
  }
  bool get isLive => readOnlyEvents == null;
  bool get busy => status == 'running' || status == 'starting';

  /// Permission requests awaiting an answer.
  List<ClaudeEvent> get pendingPermissions {
    final resolved = events.where((e) => e.kind == 'permissionResolved').map((e) => e.get<String>('requestId')).toSet();
    return events.where((e) => e.kind == 'permission' && !resolved.contains(e.get<String>('requestId'))).toList();
  }

  Future<void> start() async {
    if (!isLive) {
      events.addAll(readOnlyEvents!);
      status = 'history';
      notifyListeners();
      return;
    }
    final gen = ++_gen;
    await _loadOutbox();
    try {
      final j = await client.get('/v1/claude/sessions/$sessionId');
      if (_disposed || gen != _gen) return;
      summary = Map<String, dynamic>.from(j['session'] as Map);
      status = summary!['status'] as String;
      // A session whose history came from disk (restored) may have older ones.
      olderAvailable = summary!['sdkSessionId'] != null && (j['events'] as List).any((e) => (e as Map)['kind'] == 'restored');
      events.clear();
      live = '';
      for (final e in (j['events'] as List)) {
        _add(ClaudeEvent(Map<String, dynamic>.from(e as Map)));
      }
      error = null;
      notifyListeners();
      if (stream) await _connect();
    } catch (e) {
      if (_disposed || gen != _gen) return;
      if (e is AgentError && e.code == 'agent.claude.session.notFound') {
        gone = true;
        error = e;
        status = 'stopped';
        notifyListeners();
        return;
      }
      // Network outage on open: instead of showing "typing" forever, retry with increasing intervals.
      error = e;
      notifyListeners();
      _later(start);
    }
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = ++_gen;
    _ws?.close();
    _ws = null;
    final base = Uri.parse(client.baseUrl);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/v1/claude/sessions/$sessionId/stream',
      queryParameters: {'after': '$lastSeq'},
    );
    try {
      final ws = await WebSocket.connect(uri.toString(), headers: {'Authorization': 'Bearer ${client.token}'}).timeout(const Duration(seconds: 10));
      if (_disposed || gen != _gen) {
        ws.close(); // the screen closed or a new connection started meanwhile
        return;
      }
      // On mobile network changes/in Doze, TCP can die silently: if a ping goes unanswered the connection closes and
      // reconnects.
      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      connected = true;
      _attempt = 0;
      error = null;
      live = ''; // chunks missed while disconnected; the full text comes with the "text" event
      notifyListeners();
      unawaited(_flush()); // messages pending while there was no connection
      ws.listen(
        (data) {
          if (gen != _gen) return;
          final e = ClaudeEvent(Map<String, dynamic>.from(jsonDecode(data as String) as Map));
          if (e.kind == 'hello') {
            // If the agent restarted (different instance) or sequence numbers went backwards: reload from scratch.
            final known = summary?['epoch'];
            final serverLast = e.get<int>('lastSeq') ?? 0;
            if ((known != null && e.get<String>('epoch') != known) || serverLast < lastSeq) _resync();
            return;
          }
          _add(e);
          notifyListeners();
        },
        onDone: () {
          if (gen != _gen) return;
          if (ws.closeCode == 4404) {
            gone = true;
            connected = false;
            notifyListeners();
            return;
          }
          _scheduleReconnect();
        },
        onError: (_) {
          if (gen == _gen) _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_disposed || gen != _gen) return;
      error = e;
      _scheduleReconnect();
    }
  }

  /// Drops the events and reloads the session from scratch (when the agent restarts).
  void _resync() {
    _gen++;
    _ws?.close();
    _ws = null;
    connected = false;
    unawaited(start());
  }

  void _scheduleReconnect() {
    connected = false;
    if (_disposed) return;
    notifyListeners();
    _later(_connect);
  }

  void _later(Future<void> Function() fn) {
    _retry?.cancel();
    final delay = Duration(seconds: [1, 2, 5, 10, 20][_attempt.clamp(0, 4)]);
    _attempt++;
    _retry = Timer(delay, fn);
  }

  /// When the app comes to the foreground: reconnect right away even if the connection looks healthy (it may have
  /// died in the background).
  void _onVisibility() {
    if (!appVisible.value || _disposed || gone) return;
    _retry?.cancel();
    _attempt = 0;
    unawaited(_flush());
    if (summary == null) {
      unawaited(start());
    } else {
      unawaited(_connect());
    }
  }

  void _add(ClaudeEvent e) {
    if (e.kind == 'delta') {
      live += e.text;
      return;
    }
    if (e.seq != 0 && e.seq <= lastSeq) return; // duplicate (on reconnect)
    if (e.kind == 'text') live = '';
    if (e.kind == 'status') status = e.get<String>('status') ?? status;
    if (e.kind == 'control') summary?['control'] = {'active': e.get<bool>('active') ?? false, 'expiresAt': e.get<String>('expiresAt')};
    if (e.kind == 'result') {
      live = '';
      // Keep cost and context usage up to date in the header.
      final sm = summary;
      if (sm != null) {
        for (final k in const ['costUsd', 'contextTokens', 'contextWindow']) {
          if (e.json[k] != null) sm[k] = e.json[k];
        }
      }
    }
    events.add(e);
  }

  /// Puts the message in the outbox and tries to send it. Doesn't error when offline: the message stays as
  /// "waiting"
  /// and goes out by itself when the connection returns. Throws if the agent rejects the message (e.g. session closed).
  Future<void> send(String text, {List<Map<String, String>> images = const []}) async {
    outbox.add(OutboxItem(id: _newId(), text: text, images: images));
    await _saveOutbox();
    notifyListeners();
    await _flush(throwOnReject: true);
  }

  /// Cancels and deletes a pending message.
  Future<void> discard(OutboxItem item) async {
    outbox.remove(item);
    await _saveOutbox();
    notifyListeners();
  }

  bool _flushing = false;

  Future<void> _flush({bool throwOnReject = false}) async {
    if (_flushing || _disposed) return;
    _flushing = true;
    Object? rejected;
    try {
      while (outbox.isNotEmpty && !_disposed) {
        final item = outbox.first;
        item.sending = true;
        notifyListeners();
        try {
          await client.post('/v1/claude/sessions/$sessionId/messages', {
            'text': item.text,
            if (item.images.isNotEmpty) 'images': item.images,
            'clientId': item.id,
          });
          outbox.remove(item); // delivered (or had been delivered before: duplicate)
        } on AgentError catch (e) {
          item.sending = false;
          if (e.code.startsWith('net.')) break; // no network: will retry later
          outbox.remove(item); // agent rejected: no point in holding it
          rejected = e;
        }
        await _saveOutbox();
      }
    } finally {
      _flushing = false;
      if (!_disposed) notifyListeners();
    }
    if (rejected != null && throwOnReject) throw rejected;
  }

  static final _rand = Random.secure();
  static String _newId() => List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  File? get _outboxFile => outboxDir == null ? null : File('$outboxDir/claude-outbox-$sessionId.json');

  Future<void> _loadOutbox() async {
    final f = _outboxFile;
    if (f == null || outbox.isNotEmpty || !await f.exists()) return;
    try {
      outbox.addAll([for (final j in jsonDecode(await f.readAsString()) as List) OutboxItem.fromJson(Map<String, dynamic>.from(j as Map))]);
    } catch (_) {
      // corrupt file: ignore
    }
  }

  Future<void> _saveOutbox() async {
    final f = _outboxFile;
    if (f == null) return;
    if (outbox.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode([for (final i in outbox) i.toJson()]));
  }

  Future<void> interrupt() => client.post('/v1/claude/sessions/$sessionId/interrupt');

  Future<void> decide(String requestId, bool allow) =>
      client.post('/v1/claude/sessions/$sessionId/permissions/$requestId', {'allow': allow});

  Future<void> setMode(String mode) => client.post('/v1/claude/sessions/$sessionId/mode', {'permissionMode': mode});

  Future<void> close() => client.delete('/v1/claude/sessions/$sessionId');

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    appVisible.removeListener(_onVisibility);
    _retry?.cancel();
    _ws?.close();
    client.close();
    super.dispose();
  }
}

/// Simple line diff from Edit/Write/MultiEdit tool input (- old, + new).
List<(String, String)> toolDiff(String tool, Map<String, dynamic> input) {
  List<(String, String)> lines(String sign, String? text) =>
      (text ?? '').split('\n').map((l) => (sign, l)).toList();
  switch (tool) {
    case 'Write':
      return lines('+', input['content'] as String?);
    case 'Edit':
      return [...lines('-', input['old_string'] as String?), ...lines('+', input['new_string'] as String?)];
    case 'MultiEdit':
      return [
        for (final e in (input['edits'] as List? ?? const []).cast<Map>()) ...[
          ...lines('-', e['old_string'] as String?),
          ...lines('+', e['new_string'] as String?),
          (' ', '⋯'),
        ],
      ];
    default:
      return const [];
  }
}

/// Name of a PC tool ("mcp__tiphys_pc__click" → "click"); null if not a PC tool.
String? pcToolName(String tool) => tool.startsWith('mcp__tiphys_pc__') ? tool.substring('mcp__tiphys_pc__'.length) : null;

/// One-line summary of a tool call. [result]: the result's text (for 11.5 ui_* / page_text tools the name of the
/// widget or page isn't in the input but in the first quoted part of the result's first line).
String toolSummary(String tool, Map<String, dynamic> input, {String? result}) {
  String s(String k) => (input[k] ?? '').toString();
  final quoted = result == null ? null : RegExp(r'"([^"\n]+)"').firstMatch(result.split('\n').first)?.group(1);
  String named(String fallback) => quoted ?? fallback;
  String pt(Object? p) => p is Map ? '${(p['x'] as num?)?.round()}, ${(p['y'] as num?)?.round()}' : '';
  final pc = pcToolName(tool);
  final v = switch (pc ?? tool) {
    'click' || 'double_click' || 'move' => '${pt(input)}${input['button'] != null && input['button'] != 'left' ? ' · ${s('button')}' : ''}',
    'drag' => '${pt(input['from'])} → ${pt(input['to'])}',
    'scroll' => '${pt(input)} · ${(input['dy'] as num? ?? 0) > 0 ? '↓' : '↑'}${((input['dy'] as num?) ?? (input['dx'] as num?) ?? 0).abs()}',
    'type' => s('text'),
    'key' => s('combo'),
    'focus_window' => s('address'),
    'launch_app' => s('id'),
    'wait' => '${s('ms')} ms',
    'confirm' => s('reason'),
    'browser_open' => switch (Uri.tryParse(s('url'))?.host ?? '') { '' => s('url'), final h => h.replaceFirst(RegExp(r'^www\.'), '') },
    'browser_activate' || 'page_text' => named('#${s('tab')}'),
    'browser_close' => [for (final t in (input['tabs'] as List? ?? const [])) '#$t'].join(', '),
    'ui_tree' => named(s('address')),
    'ui_press' => named(s('id')),
    'ui_set_text' => '${named(s('id'))} ← ${s('text')}',
    'ui_set_value' => '${named(s('id'))} = ${s('value')}',
    'browser_tabs' when pc != null => '',
    'screenshot' || 'windows' when pc != null => '',
    'Bash' => s('command'),
    'Read' || 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => s('file_path'),
    'Glob' => s('pattern'),
    'Grep' => '${s('pattern')}${input['path'] == null ? '' : '  ${s('path')}'}',
    'WebFetch' => s('url'),
    'WebSearch' => s('query'),
    'Agent' || 'Task' => s('description'),
    'TodoWrite' => '${(input['todos'] as List?)?.length ?? 0} madde',
    _ => jsonEncode(input),
  };
  return v.length > 200 ? '${v.substring(0, 200)}…' : v;
}

@visibleForTesting
ClaudeEvent ev(Map<String, dynamic> j) => ClaudeEvent(j);
