// Sample data and the fake agent's /v1/security/* routes (agent/src/security/routes.ts, service.ts). Machine names are
// examples: argo (PC) audits itself and orion over SSH; atlas (server) audits itself.
import 'package:tiphys/core/agent/agent_client.dart';

final _clock = DateTime(2026, 11, 14, 14, 5);
String _at(Duration ago) => _clock.subtract(ago).toUtc().toIso8601String();

Map<String, dynamic> _report({bool full = false, bool root = true, List<Map<String, dynamic>>? listen}) => {
      'firewall': root ? {'source': 'nft', 'defaultDeny': false, 'inputChains': 2} : null,
      'mode': full ? 'report-full' : 'report',
      'root': root,
      'meta': {'hostname': 'orion', 'kernel': '6.12.0-example', 'arch': 'aarch64', 'os': 'Debian GNU/Linux 13', 'uptimeSec': 90061, 'ipv6Global': 1, 'time': _at(const Duration(minutes: 7))},
      'listen': listen ??
          [
            {'proto': 'tcp', 'addr': '0.0.0.0', 'iface': null, 'port': 22, 'scope': 'wildcard', 'process': 'sshd', 'firewall': 'open'},
            {'proto': 'tcp', 'addr': '0.0.0.0', 'iface': null, 'port': 9000, 'scope': 'wildcard', 'process': 'example-admin', 'firewall': 'filtered'},
            {'proto': 'tcp', 'addr': '0.0.0.0', 'iface': null, 'port': 2222, 'scope': 'wildcard', 'process': 'example-app', 'firewall': 'open'},
            {'proto': 'tcp', 'addr': '100.64.0.7', 'iface': 'tailscale0', 'port': 8443, 'scope': 'tailscale', 'process': null},
            {'proto': 'tcp', 'addr': '127.0.0.1', 'iface': null, 'port': 5432, 'scope': 'loopback', 'process': 'postgres'},
          ],
      'sshd': {
        'mode': 'effective',
        'settings': {
          'passwordauthentication': ['yes'],
          'permitrootlogin': ['prohibit-password'],
          'maxauthtries': ['6'],
          'allowusers': ['alice', 'deploy'],
        },
      },
      'users': [
        {'name': 'root', 'uid': 0, 'gid': 0, 'shell': '/bin/bash'},
        {'name': 'alice', 'uid': 1000, 'gid': 1000, 'shell': '/bin/zsh'},
      ],
      'passwords': root ? [{'name': 'alice', 'status': 'set'}, {'name': 'kiosk', 'status': 'empty'}] : null,
      'groups': {'sudo': ['alice'], 'docker': <String>[]},
      'sudoers': root ? [{'path': '/etc/sudoers.d/90-example', 'sha256': 'a' * 64}] : null,
      'authKeys': [
        {'user': 'alice', 'path': '/home/alice/.ssh/authorized_keys', 'bits': 256, 'fingerprint': 'SHA256:EXAMPLEFINGERPRINTEXAMPLEFINGERPRINT0001', 'comment': 'alice@argo', 'type': 'ED25519'},
      ],
      'cron': [{'path': '/etc/cron.d/example-backup', 'sha256': 'b' * 64}],
      'timers': [{'scope': 'system', 'name': 'apt-daily.timer', 'unit': 'apt-daily.service'}, {'scope': 'user', 'name': 'sync.timer', 'unit': 'sync.service'}],
      'autostart': root ? [{'path': '/home/alice/.config/autostart/example.desktop', 'sha256': 'c' * 64}] : null,
      'updates': {'pending': 12, 'security': 3, 'unattended': false, 'listsUpdatedAt': _at(const Duration(days: 2)), 'rebootRequiredSince': _at(const Duration(days: 9))},
      'services': {'ufw': {'active': 'inactive', 'enabled': 'disabled'}, 'auditd': {'active': 'active', 'enabled': 'enabled'}},
      'sysctl': {'kernel.kptr_restrict': '0', 'fs.suid_dumpable': '0'},
      'logins': [{'user': 'alice', 'tty': 'pts/0', 'from': '100.64.0.9', 'raw': 'alice pts/0 100.64.0.9 Fri Nov 13 09:12 - 10:30'}],
      'docker': {
        'version': '27.3.1',
        'containers': [
          {
            'name': 'example-web',
            'image': 'registry.example.org/web:1.4',
            'imageId': 'sha256:1',
            'privileged': true,
            'networkMode': 'bridge',
            'pidMode': '',
            'readOnlyRootfs': false,
            'user': '',
            'capAdd': ['NET_ADMIN'],
            'mounts': [{'source': '/var/run/docker.sock', 'destination': '/var/run/docker.sock', 'rw': true}],
            'ports': [{'hostIp': '0.0.0.0', 'hostPort': 8080, 'container': '80/tcp'}],
            'project': null,
            'service': null,
          },
          {'name': 'example-db', 'image': 'postgres:16', 'imageId': 'sha256:2', 'privileged': false, 'networkMode': 'bridge', 'pidMode': '', 'readOnlyRootfs': false, 'user': '', 'capAdd': <String>[], 'mounts': <Map>[], 'ports': <Map>[], 'project': null, 'service': null},
        ],
        'images': [{'id': 'sha256:1'}, {'id': 'sha256:2'}],
      },
      'suid': full ? [{'mode': '4755', 'owner': 'root', 'path': '/usr/bin/sudo'}] : null,
      'worldWritable': full ? <Map>[] : null,
      'agentFiles': [{'path': '/home/alice/.config/tiphys/agent.json', 'mode': '644'}],
      'unavailable': root ? <String>[] : ['passwords', 'sudoers', 'autostart'],
    };

Map<String, dynamic> _finding(String rule, String severity, Map<String, dynamic> params, [String? id]) => {'id': id ?? rule, 'rule': rule, 'severity': severity, 'params': params};

class FakeSecHost {
  FakeSecHost(this.id, this.name, this.source, {this.role = 'server', this.score, List<Map<String, dynamic>>? findings, List<Map<String, dynamic>>? changes, this.report, this.lastError, this.stale = false, this.running = false, this.lastOkAgo = const Duration(minutes: 7)})
      : findings = findings ?? [],
        changes = changes ?? [];
  final String id;
  String name;
  final String source;
  String role;
  int? score;
  List<Map<String, dynamic>> findings;
  List<Map<String, dynamic>> changes;
  Map<String, dynamic>? report;
  Map<String, dynamic>? lastError;
  bool stale;
  bool running;
  Duration? lastOkAgo;
  List<String> allowedPorts = [];
  // Settings (SSH or agent source).
  Map<String, dynamic>? sourceConfig;

  Map<String, dynamic> summary() {
    final counts = {'critical': 0, 'high': 0, 'medium': 0, 'low': 0};
    for (final f in findings) {
      counts[f['severity'] as String] = counts[f['severity']]! + 1;
    }
    return {
      'id': id,
      'name': name,
      'role': role,
      'source': source,
      'score': score,
      'counts': counts,
      'changes': changes.length,
      'lastOkAt': lastOkAgo == null ? null : _at(lastOkAgo!),
      'lastAttemptAt': lastOkAgo == null ? null : _at(lastOkAgo!),
      'lastFullAt': report?['mode'] == 'report-full' ? _at(const Duration(hours: 3)) : null,
      'lastError': lastError,
      'stale': stale,
      'running': running,
    };
  }

  Map<String, dynamic> detail() => {
        'host': summary(),
        'policy': {'role': role, 'allowedPorts': allowedPorts},
        'findings': findings,
        'changes': changes,
        'baselineAt': report == null ? null : _at(const Duration(days: 3)),
        'report': report,
      };
}

class FakeSecurityState {
  FakeSecurityState() {
    hosts = {
      'argo': [
        FakeSecHost('self', 'argo', 'local', role: 'desktop', score: 91, report: _report(root: false), findings: [_finding('ssh.maxAuthTries', 'low', {'value': 6})]),
        FakeSecHost(
          'orion',
          'orion',
          'ssh',
          score: 52,
          report: _report(full: true),
          findings: [
            _finding('users.emptyPassword', 'critical', {'user': 'kiosk'}, 'users.emptyPassword:kiosk'),
            _finding('ssh.passwordAuth', 'high', {}),
            _finding('port.exposed', 'medium', {'proto': 'tcp', 'port': 2222, 'addr': '0.0.0.0', 'process': 'example-app'}, 'port.exposed:tcp/2222'),
            _finding('updates.security', 'medium', {'count': 3}),
            _finding('docker.privileged', 'medium', {'container': 'example-web'}, 'docker.privileged:example-web'),
            _finding('some.futureRule', 'low', {}),
          ],
          changes: [
            {'id': 'ports|tcp/2222', 'category': 'ports', 'item': 'tcp/2222', 'kind': 'added', 'firstSeenAt': _at(const Duration(hours: 5))},
            {'id': 'authKeys|alice SHA256:EXAMPLE', 'category': 'authKeys', 'item': 'alice SHA256:EXAMPLE', 'kind': 'added', 'firstSeenAt': _at(const Duration(hours: 5))},
          ],
        )..allowedPorts = ['tcp/22']
          ..sourceConfig = {'kind': 'ssh', 'host': 'orion.example.org', 'user': 'tiphys-audit', 'port': 22, 'keyPath': '/home/alice/.ssh/example_audit'},
      ],
      'atlas': [
        FakeSecHost('self', 'atlas', 'local', score: 100, report: _report(full: true), findings: []),
      ],
    };
    selfSettings = {
      'argo': {'role': 'desktop', 'allowedPorts': <String>[], 'sudo': false},
      'atlas': {'role': 'server', 'allowedPorts': ['tcp/22'], 'sudo': false},
    };
  }

  late final Map<String, List<FakeSecHost>> hosts;
  late final Map<String, Map<String, dynamic>> selfSettings;

  /// Error thrown by POST …/check (e.g. rateLimited); the host is marked with it like the agent does.
  AgentError? checkError;

  /// Error of GET /v1/security/overview per agent.
  final overviewErrors = <String, AgentError>{};

  FakeSecHost? find(String agent, String id) => hosts[agent]?.where((h) => h.id == id).firstOrNull;
}

dynamic fakeSecurityRoute(String agentId, String method, String path, Object? body, FakeSecurityState st) {
  if (path == '/v1/security/overview') {
    final err = st.overviewErrors[agentId];
    if (err != null) throw err;
    return {'intervalMinutes': 15, 'hosts': [for (final h in st.hosts[agentId] ?? const <FakeSecHost>[]) h.summary()]};
  }
  if (path == '/v1/security/hosts') {
    if (method == 'POST') {
      final b = body as Map;
      if (st.find(agentId, b['id'] as String) != null) throw const AgentError('agent.security.hostExists', {}, 409);
      final h = FakeSecHost(b['id'] as String, b['name'] as String, (b['source'] as Map)['kind'] as String, role: b['role'] as String);
      h.allowedPorts = [for (final p in b['allowedPorts'] as List) '$p'];
      h.sourceConfig = Map<String, dynamic>.from(b['source'] as Map)..remove('token');
      st.hosts[agentId]!.add(h);
      return {'host': _publicHost(h)};
    }
    return {
      'self': st.selfSettings[agentId],
      'hosts': [for (final h in st.hosts[agentId] ?? const <FakeSecHost>[]) if (h.id != 'self') _publicHost(h)],
    };
  }
  final m = RegExp(r'^/v1/security/hosts/([^/]+)(/check|/baseline)?$').firstMatch(path);
  if (m == null) throw const AgentError('agent.route.notFound', {}, 404);
  final id = Uri.decodeComponent(m.group(1)!);
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(id)) throw const AgentError('agent.request.invalid', {}, 400);
  final host = st.find(agentId, id);
  if (host == null) throw const AgentError('agent.security.hostNotFound', {'id': 'x'}, 404);
  switch (m.group(2)) {
    case '/check':
      if (st.checkError != null) throw st.checkError!;
      host.lastOkAgo = Duration.zero;
      host.lastError = null;
      host.stale = false;
      return host.detail();
    case '/baseline':
      if ((body as Map)['confirm'] != true) throw const AgentError('agent.request.invalid', {}, 400);
      final n = host.changes.length;
      host.changes = [];
      return {'accepted': n, ...host.detail()};
  }
  if (method == 'GET') return host.detail();
  if (method == 'DELETE') {
    if (id == 'self') throw const AgentError('agent.security.selfPermanent', {}, 409);
    st.hosts[agentId]!.remove(host);
    return {'ok': true};
  }
  final b = body as Map;
  if (id == 'self') {
    st.selfSettings[agentId] = {...st.selfSettings[agentId]!, ...b};
    return {'self': st.selfSettings[agentId]};
  }
  if (b['name'] != null) host.name = b['name'] as String;
  if (b['role'] != null) host.role = b['role'] as String;
  if (b['allowedPorts'] != null) host.allowedPorts = [for (final p in b['allowedPorts'] as List) '$p'];
  if (b['source'] != null) host.sourceConfig = Map<String, dynamic>.from(b['source'] as Map)..remove('token');
  return {'host': _publicHost(host)};
}

Map<String, dynamic> _publicHost(FakeSecHost h) {
  final s = h.sourceConfig ?? {'kind': 'ssh', 'host': 'h.example.org', 'user': 'u', 'port': 22, 'keyPath': '/k'};
  return {
    'id': h.id,
    'name': h.name,
    'role': h.role,
    'allowedPorts': h.allowedPorts,
    'source': s['kind'] == 'agent' ? {'kind': 'agent', 'url': s['url'], 'hasToken': true} : s,
  };
}
