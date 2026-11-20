// Fake PC agent routes for "Send to Claude" (PLAN.md §16): the brief, the fix targets, a security session with a sudo
// request, the panel data and the rollback. Everything else is the normal FakeAgent.
import 'package:tiphys/core/agent/agent_client.dart';

import 'harness.dart';

/// State of the fake security fix routes (tests change it, then call [reset]).
class FixState {
  /// Request bodies by route name, for assertions.
  final sent = <String, Object?>{};
  bool investigate = false;
  bool truncated = false;
  AgentError? briefError;
  AgentError? targetsError;
  List<Map<String, dynamic>> targets = [
    {'host': 'orion', 'name': 'orion', 'ssh': 'tiphys@orion.example.org', 'port': 22},
  ];
  int sudoCacheMinutes = 15;
  bool sudoPending = true;
  int sudoAttempt = 1;
  bool sessionDone = false;
  bool rootPermission = false;
  AgentError? startError;
}

class FixAgent extends FakeAgent {
  FixAgent(super.hostId);

  static FixState fix = FixState();
  static void reset() => fix = FixState();

  static Map<String, dynamic> _info() => {
        'hosts': [
          {'host': 'orion', 'name': 'orion', 'ssh': 'tiphys@orion.example.org', 'port': 22},
        ],
        'mode': 'default',
        'investigate': fix.investigate,
        'origin': {'agentHostId': 'argo', 'refs': ['finding:orion:ssh.passwordAuth']},
        'backups': [
          {'host': 'orion', 'path': '/etc/ssh/sshd_config.d/50-hardening.conf', 'backup': '/var/backups/tiphys-fix/sec1/etc/ssh/sshd_config.d/50-hardening.conf', 'existed': false, 'sudo': true, 'at': '2026-11-14T14:01:00Z'},
          {'host': 'orion', 'path': '/etc/ssh/sshd_config', 'backup': '/var/backups/tiphys-fix/sec1/etc/ssh/sshd_config', 'existed': true, 'sudo': true, 'at': '2026-11-14T14:02:00Z'},
        ],
        'changed': [
          {'host': 'orion', 'path': '/etc/ssh/sshd_config.d/50-hardening.conf'},
          {'host': 'orion', 'path': '/etc/ssh/sshd_config'},
        ],
        'timers': [
          {'host': 'orion', 'unit': 'tiphys-fix-rollback-1.timer', 'kind': 'sshd', 'expiresAt': DateTime(2026, 11, 14, 14, 8, 30).toUtc().toIso8601String()},
        ],
        'sudoCached': ['orion'],
      };

  Map<String, dynamic> _session() => {
        'session': {
          'id': 'sec1', 'epoch': 'E9', 'kind': 'security', 'cwd': '~', 'title': 'Güvenlik düzeltmesi', 'status': fix.sessionDone ? 'idle' : 'waiting', 'model': 'claude-opus-5-5', 'costUsd': 0.31,
          'security': {
            'hosts': [{'host': 'orion', 'name': 'orion'}],
            'investigate': fix.investigate,
            'origin': {'agentHostId': 'argo', 'refs': ['finding:orion:ssh.passwordAuth']},
          },
        },
        'events': [
          {'seq': 1, 'kind': 'user', 'text': 'sshd parola girişini kapat', 'images': 0},
          {'seq': 2, 'kind': 'text', 'text': 'sshd ayarını doğruluyorum.'},
          {'seq': 3, 'kind': 'tool_use', 'id': 't1', 'name': 'mcp__tiphys_sec__run', 'input': {'host': 'orion', 'cmd': 'sshd -T | grep passwordauthentication', 'sudo': true}},
          {'seq': 4, 'kind': 'tool_result', 'toolUseId': 't1', 'text': 'passwordauthentication yes', 'isError': false},
          {'seq': 5, 'kind': 'tool_use', 'id': 't2', 'name': 'mcp__tiphys_sec__write_file', 'input': {'host': 'orion', 'path': '/etc/ssh/sshd_config.d/50-hardening.conf', 'content': 'PasswordAuthentication no\n'}},
          {'seq': 6, 'kind': 'tool_result', 'toolUseId': 't2', 'text': '--- a\n+++ b\n+PasswordAuthentication no\n', 'isError': false},
          if (fix.sudoPending) {'seq': 7, 'kind': 'sudo', 'requestId': 'r1', 'host': 'orion', 'attempt': fix.sudoAttempt, if (fix.investigate) 'investigate': true},
          if (fix.rootPermission) {'seq': 9, 'kind': 'permission', 'requestId': 'p7', 'toolName': 'mcp__tiphys_sec__write_file', 'input': {'host': 'orion', 'path': '/etc/ssh/sshd_config.d/50-hardening.conf', 'mode': '644', 'bytes': 26, 'asRoot': true, 'content': 'PasswordAuthentication no\n'}, 'reason': 'As root: write /etc/ssh/sshd_config.d/50-hardening.conf on orion'},
          if (fix.sessionDone) {'seq': 8, 'kind': 'result', 'ok': true, 'text': '', 'costUsd': 0.31, 'turns': 4, 'durationMs': 9000},
        ],
      };

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (method == 'POST' && path == '/v1/security/brief') {
      FakeAgent.calls.add((method, path, body));
      fix.sent['brief'] = body;
      if (fix.briefError != null) throw fix.briefError!;
      final items = (body as Map)['items'] as List;
      return {
        'text': 'TIPHYS BRIEF\nHost orion: ssh.passwordAuth — sshd accepts password logins.\n',
        'bytes': 1234,
        'truncated': fix.truncated,
        'investigate': fix.investigate,
        'hosts': [
          {'id': 'orion', 'name': 'orion', 'role': 'server', 'root': true, 'source': 'ssh'},
          {'id': 'atlas', 'name': 'atlas', 'role': 'server', 'root': null, 'source': 'agent'},
        ],
        'items': [
          for (var i = 0; i < items.length; i++)
            if (i == 2 && items.length > 2) {'ref': 'x$i', 'type': (items[i] as Map)['type'], 'error': 'agent.security.itemNotFound'} else {'ref': 'finding:orion:r$i', 'type': (items[i] as Map)['type'], 'host': 'orion', 'mode': fix.investigate ? 'investigate' : 'fix'},
        ],
      };
    }
    if (path == '/v1/config' && method == 'GET') {
      final c = Map<String, dynamic>.from(await super.request(method, path, body: body, query: query, timeout: timeout, headers: headers) as Map);
      return {...c, 'features': {...c['features'] as Map, 'claude': true, 'securityFix': true}};
    }
    if (path == '/v1/claude/security/targets') {
      FakeAgent.calls.add((method, path, body));
      if (fix.targetsError != null) throw fix.targetsError!;
      if (method == 'PUT') {
        fix.sent['targets'] = body;
        fix.targets = [for (final t in (body as Map)['targets'] as List) Map<String, dynamic>.from(t as Map)];
        fix.sudoCacheMinutes = body['sudoCacheMinutes'] as int;
      }
      return {'targets': fix.targets, 'sudoCacheMinutes': fix.sudoCacheMinutes};
    }
    if (method == 'POST' && path == '/v1/claude/sessions' && body is Map && body['kind'] == 'security') {
      FakeAgent.calls.add((method, path, body));
      fix.sent['session'] = body;
      if (fix.startError != null) throw fix.startError!;
      return {'id': 'sec1', 'status': 'idle', 'title': '', 'kind': 'security'};
    }
    if (path == '/v1/claude/sessions/sec1' && method == 'GET') return _session();
    if (path == '/v1/claude/sessions/sec1/security' && method == 'GET') return _info();
    if (path == '/v1/claude/sessions/sec1/sudo') {
      FakeAgent.calls.add((method, path, body));
      fix.sent['sudo'] = body;
      return {'ok': true};
    }
    if (path == '/v1/claude/sessions/sec1/security/rollback') {
      FakeAgent.calls.add((method, path, body));
      return {'host': 'orion', 'restored': ['/etc/ssh/sshd_config'], 'failed': <Object>[], 'reloaded': ['sshd']};
    }
    return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
  }
}

Harness fixHarness({List<String> extraFeatures = const []}) => Harness(
      agent: (h) async => FixAgent(h.id),
      agentFeatures: [...Harness.defaultAgentFeatures, 'security', 'securityFix', ...extraFeatures],
    );
