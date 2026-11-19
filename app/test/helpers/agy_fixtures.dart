// Fake agent for agy sessions (agent/src/agy/routes.ts, manager.ts; the agent's own fake is agent/test/fake_agy_acp.mjs).
// Events are versioned like the agent's: a streamed message keeps its eid and gets a new seq; GET with `wait` holds the
// request until something changes (or the time is up). Names and paths are examples only.
import 'dart:async';

import 'package:tiphys/core/agent/agent_client.dart';

const agyCwd = '/home/user/Desktop/tiphys';
const agySessionId = 'agy-aaaaaaaaaaaa';
const agyConversationId = 's-new-0001';

String agyResume(String cwd, String id) => "cd '${cwd.replaceAll("'", "'\\''")}' && agy --conversation $id";

class FakeAgyState {
  FakeAgyState() {
    reset();
  }

  /// Summary of the one live session (`agy-aaaaaaaaaaaa`).
  late Map<String, dynamic> session;
  late List<Map<String, dynamic>> events;
  late List<Map<String, dynamic>> conversations;
  int _seq = 0, _eid = 0;
  var _waiters = <Completer<void>>[];

  /// "METHOD /path" → error to throw.
  final errors = <String, AgentError>{};

  /// true: POST messages answers 409 agent.agy.busy whatever the status (a turn started meanwhile).
  bool forceBusy = false;

  /// Requests that changed things, in order ("POST cancel", "DELETE", "POST permissions/r1 allow", …).
  final log = <String>[];

  static Map<String, dynamic> summaryOf(
    String id,
    String status, {
    String title = 'Durum raporu',
    String cwd = agyCwd,
    String conv = agyConversationId,
    String mode = 'default',
  }) => {
    'id': id,
    'conversationId': conv,
    'cwd': cwd,
    'title': title,
    'status': status,
    'modeId': mode,
    'modes': [
      {'id': 'default', 'name': 'Default', 'description': 'Ask before acting'},
      {'id': 'auto', 'name': 'Auto', 'description': 'Act without asking'},
      {'id': 'plan', 'name': 'Plan', 'description': 'Plan only'},
    ],
    'model': 'gemini-4-neon',
    'models': [
      {'value': 'gemini-4-neon', 'name': 'Gemini 4 Neon'},
      {'value': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash'},
    ],
    'usage': {'used': 38, 'size': 100},
    'commands': <Map>[],
    'createdAt': '2026-11-14T13:00:00.000Z',
    'lastActivity': '2026-11-14T14:03:00.000Z',
    'pendingPermissions': <Map>[],
    'resumeCommand': conv.isEmpty ? null : agyResume(cwd, conv),
  };

  void reset() {
    _seq = 0;
    _eid = 0;
    _waiters = [];
    errors.clear();
    log.clear();
    forceBusy = false;
    events = [];
    session = summaryOf(agySessionId, 'idle');
    conversations = [
      {'sessionId': 's-old-0002', 'cwd': agyCwd, 'title': 'Docker mimarisi', 'updatedAt': '2026-11-14T10:05:00Z', 'liveId': null},
      {'sessionId': agyConversationId, 'cwd': agyCwd, 'title': 'Durum raporu', 'updatedAt': '2026-11-14T14:03:00Z', 'liveId': agySessionId},
    ];
  }

  /// The scenario of the chat golden: a replayed pair, a thought, an answer, a command waiting for permission.
  void waitingScenario() {
    reset();
    emit({'kind': 'user', 'text': 'Önceki soru', 'replay': true});
    emit({'kind': 'agent', 'text': 'Önceki cevap', 'replay': true});
    emit({'kind': 'user', 'text': 'Testleri çalıştır ve raporla'});
    emit({'kind': 'thought', 'text': 'Önce test komutunu bulmalıyım.'});
    emit({'kind': 'agent', 'text': 'Testleri **çalıştırıyorum**:'});
    emit({
      'kind': 'plan',
      'entries': [
        {'content': 'Testleri çalıştır', 'status': 'in_progress', 'priority': 'high'},
        {'content': 'Sonucu raporla', 'status': 'pending', 'priority': 'medium'},
      ],
    });
    emit({
      'kind': 'tool',
      'toolCallId': 't1',
      'title': 'npm test',
      'toolKind': 'execute',
      'status': 'pending',
      'paths': ['/home/user/Desktop/tiphys/agent'],
      'command': 'npm test -- --run',
    });
    emit({
      'kind': 'permission',
      'requestId': 'a1b2c3d4e5f6',
      'toolCallId': 't1',
      'title': 'npm test',
      'toolKind': 'execute',
      'command': 'npm test -- --run',
      'options': [
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
      ],
    });
    session = {
      ...summaryOf(agySessionId, 'waiting'),
      'pendingPermissions': [
        {
          'requestId': 'a1b2c3d4e5f6',
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
          ],
        },
      ],
    };
  }

  Map<String, dynamic> emit(Map<String, dynamic> e) {
    final ev = {...e, 'eid': ++_eid, 'seq': ++_seq, 'at': '2026-11-14T14:00:00.000Z'};
    events.add(ev);
    _wake();
    return ev;
  }

  /// A streamed chunk: same eid, new seq.
  void appendText(int eid, String more) {
    final e = events.firstWhere((x) => x['eid'] == eid);
    e['text'] = '${e['text']}$more';
    e['seq'] = ++_seq;
    _wake();
  }

  void setStatus(String status) {
    session = {...session, 'status': status};
    _wake();
  }

  void _wake() {
    final w = _waiters;
    _waiters = [];
    for (final c in w) {
      if (!c.isCompleted) c.complete();
    }
  }

  Future<void> _changed() {
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  List<Map<String, dynamic>> since(int after) => [
    for (final e in events)
      if ((e['seq'] as int) > after) e,
  ];

  Future<Object?> route(String method, String path, Object? body, Map<String, String>? query) async {
    final err = errors['$method $path'];
    if (err != null) throw err;
    final b = body is Map ? body : const {};
    if (path == '/v1/agy/conversations' && method == 'GET') return {'conversations': conversations};
    if (path == '/v1/agy/sessions' && method == 'GET') {
      return {
        'sessions': session['status'] == 'ended' ? <Map>[] : [session],
      };
    }
    if (path == '/v1/agy/sessions' && method == 'POST') {
      log.add('POST sessions ${b['resume'] ?? ''}');
      final resume = b['resume'] as String?;
      if (resume != null && session['conversationId'] == resume && session['status'] != 'ended') {
        throw const AgentError('agent.agy.alreadyOpen', {}, 409);
      }
      if (b['modeId'] != null && !(session['modes'] as List).any((m) => (m as Map)['id'] == b['modeId'])) {
        throw const AgentError('agent.agy.unknownMode', {}, 400);
      }
      return summaryOf(
        'agy-bbbbbbbbbbbb',
        'idle',
        title: 'agy',
        cwd: '${b['cwd']}',
        conv: resume ?? 's-new-0003',
        mode: '${b['modeId'] ?? 'default'}',
      );
    }
    final m = RegExp(r'^/v1/agy/sessions/(agy-[a-f0-9]{12})(/.*)?$').firstMatch(path);
    if (m == null) throw const AgentError('agent.route.notFound', {}, 404);
    if (m.group(1) != agySessionId && !(m.group(1) == 'agy-bbbbbbbbbbbb')) throw const AgentError('agent.agy.sessionNotFound', {}, 404);
    final rest = m.group(2) ?? '';
    if (method == 'GET' && rest.isEmpty) {
      final after = int.tryParse(query?['after'] ?? '') ?? 0;
      final wait = int.tryParse(query?['wait'] ?? '') ?? 0;
      var out = since(after);
      if (out.isEmpty && wait > 0 && session['status'] != 'ended') {
        await Future.any([Future<void>.delayed(Duration(milliseconds: wait)), _changed()]);
        out = since(after);
      }
      return {'session': session, 'events': out};
    }
    if (m.group(1) == 'agy-bbbbbbbbbbbb') {
      return method == 'GET' ? {'session': summaryOf('agy-bbbbbbbbbbbb', 'idle', title: 'agy'), 'events': <Map>[]} : {'ok': true};
    }
    if (method == 'DELETE' && rest.isEmpty) {
      log.add('DELETE');
      setStatus('ended');
      return {'ok': true};
    }
    if (rest == '/messages') {
      final status = session['status'];
      if (forceBusy || status == 'running' || status == 'waiting' || status == 'starting') throw const AgentError('agent.agy.busy', {}, 409);
      log.add('POST messages ${b['text']}');
      emit({'kind': 'user', 'text': b['text']});
      setStatus('running');
      return {'ok': true};
    }
    if (rest == '/cancel') {
      log.add('POST cancel');
      for (final p in (session['pendingPermissions'] as List).cast<Map>()) {
        emit({'kind': 'permissionResolved', 'requestId': p['requestId'], 'optionId': 'cancelled'});
      }
      session = {...session, 'pendingPermissions': <Map>[]};
      emit({'kind': 'turnEnd', 'stopReason': 'cancelled'});
      setStatus('idle');
      return {'ok': true};
    }
    final pm = RegExp(r'^/permissions/([a-f0-9]{12})$').firstMatch(rest);
    if (pm != null) {
      final pending = (session['pendingPermissions'] as List).cast<Map>().where((p) => p['requestId'] == pm.group(1)).firstOrNull;
      if (pending == null) throw const AgentError('agent.agy.permissionNotFound', {}, 404);
      final opt = '${b['optionId']}';
      if (!(pending['options'] as List).any((o) => (o as Map)['optionId'] == opt)) throw const AgentError('agent.request.invalid', {}, 400);
      log.add('POST permissions/${pm.group(1)} $opt');
      session = {...session, 'pendingPermissions': <Map>[]};
      emit({'kind': 'permissionResolved', 'requestId': pm.group(1), 'optionId': opt});
      setStatus('running');
      return {'ok': true};
    }
    if (rest == '/mode') {
      final id = '${b['modeId']}';
      if (!(session['modes'] as List).any((x) => (x as Map)['id'] == id)) throw const AgentError('agent.agy.unknownMode', {}, 400);
      log.add('POST mode $id');
      session = {...session, 'modeId': id};
      emit({'kind': 'mode', 'modeId': id});
      return session;
    }
    if (rest == '/model') {
      log.add('POST model ${b['model']}');
      session = {...session, 'model': b['model']};
      _wake();
      return session;
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }
}
