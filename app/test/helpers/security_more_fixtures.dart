// Sample data and the fake agent's S-2…S-5 routes (agent/src/security/{vulns,secrets,traps,alerts,blackbox,lockdown,
// exposure,cloudflare}.ts and routes.ts). atlas (server) is the monitoring server with the scanners; argo (PC) has them
// off. Names, addresses and domains are examples only.
import 'package:tiphys/core/agent/agent_client.dart';

final _clock = DateTime(2026, 11, 14, 14, 5);
String _at(Duration ago) => _clock.subtract(ago).toUtc().toIso8601String();

/// Returned by [fakeSecurityMoreRoute] for paths it does not know.
const notMore = Object();

String _hex(String c) => c * 64;

Map<String, dynamic> _vuln(String id, String pkg, String installed, String? fixed, String severity, String title) => {'id': id, 'pkg': pkg, 'installed': installed, 'fixed': fixed, 'severity': severity, 'title': title, 'target': 'debian 12'};

Map<String, dynamic> _image(String c, List<String> refs, String status, {String? source, String? error, int critical = 0, int high = 0, int fixable = 0, List<Map<String, dynamic>> vulns = const [], bool truncated = false, Duration? ago = const Duration(hours: 5)}) => {
      'imageId': 'sha256:${_hex(c)}',
      'refs': refs,
      'hosts': [
        {'hostId': 'self', 'host': 'atlas', 'containers': ['example-web', 'example-worker']},
        if (c == 'b') {'hostId': 'orion', 'host': 'orion', 'containers': ['example-api']},
      ],
      'status': status,
      'source': source,
      'error': error,
      'scannedAt': ago == null ? null : _at(ago),
      'os': status == 'ok' ? 'debian 12.5' : null,
      'counts': {'critical': critical, 'high': high, 'fixable': fixable},
      'vulns': vulns,
      'truncated': truncated,
    };

class FakeSecurityMoreState {
  FakeSecurityMoreState() {
    vulnsEnabled = {'atlas': true, 'argo': false};
    images = [
      _image('a', ['registry.example.org/web:1.4'], 'ok', source: 'remote', critical: 2, high: 3, fixable: 3, truncated: true, vulns: [
        _vuln('CVE-2026-1001', 'libexample', '1.2.3-1', '1.2.4-1', 'CRITICAL', 'Heap overflow in libexample when parsing a crafted header'),
        _vuln('CVE-2026-1002', 'example-tls', '3.0.1', null, 'CRITICAL', 'Certificate validation can be bypassed'),
        _vuln('CVE-2026-2001', 'zlib1g', '1:1.2.13', '1:1.2.14', 'HIGH', 'Out-of-bounds write in inflate'),
        _vuln('CVE-2026-2002', 'openssl', '3.0.11', '3.0.13', 'HIGH', 'Denial of service through a long certificate chain ${'x' * 160}'),
        _vuln('CVE-2026-2003', 'libexample-dev', '1.2.3-1', null, 'HIGH', 'Information disclosure'),
      ]),
      _image('b', ['ghcr.io/example-org/api:2.0'], 'needsCredentials', source: 'remote', error: 'ghcr.io', ago: Duration(hours: 5)),
      _image('c', ['example/worker:latest'], 'pending', source: 'ssh', error: 'nightOnly', ago: null),
      _image('d', ['registry.example.org/old:0.9'], 'failed', source: 'remote', error: 'failed'),
      _image('e', ['postgres:16'], 'ok', source: 'remote', critical: 0, high: 0),
    ];
    secrets = {
      'lastRun': {'at': _at(const Duration(hours: 9)), 'github': null, 'loki': 'agent.security.lokiUnavailable', 'local': null},
      'running': false,
      'repos': [
        {'repo': 'example-org/site', 'head': 'a1b2c3d4e5f6a7b8c9d0', 'scannedAt': _at(const Duration(hours: 9))},
        {'repo': 'example-org/legacy', 'head': 'ffeeddccbbaa99887766', 'scannedAt': _at(const Duration(hours: 9)), 'error': 'cloneFailed'},
      ],
      'findings': [
        {'id': 'a' * 24, 'source': 'github', 'rule': 'aws-access-token', 'where': 'example-org/site', 'file': 'config/old.env', 'line': 12, 'commit': 'deadbeefcafe1234', 'stream': null, 'at': null, 'firstSeenAt': _at(const Duration(days: 2)), 'dismissed': false},
        {'id': 'b' * 24, 'source': 'loki', 'rule': 'generic-api-key', 'where': 'atlas', 'file': null, 'line': null, 'commit': null, 'stream': 'container=example-api', 'at': _at(const Duration(hours: 20)), 'firstSeenAt': _at(const Duration(hours: 19)), 'dismissed': false},
        {'id': 'c' * 24, 'source': 'local', 'rule': 'private-key', 'where': 'projects/example-app', 'file': 'deploy/id_example', 'line': 1, 'commit': null, 'stream': null, 'at': null, 'firstSeenAt': _at(const Duration(days: 5)), 'dismissed': true},
      ],
    };
    scanners = {
      'atlas': {
        'trivy': true,
        'gitleaks': true,
        'javaDb': false,
        'registryAuth': [{'registry': 'ghcr.io', 'username': 'example-user', 'hasToken': true}],
        'github': {'owners': ['example-org'], 'hasToken': true},
        'loki': {'container': 'loki', 'port': 3100},
        'localRoots': ['~/projects'],
        'nightHours': [2, 6],
      },
      'argo': {'trivy': false, 'gitleaks': false, 'javaDb': false, 'registryAuth': <Map>[], 'github': {'owners': <String>[], 'hasToken': false}, 'loki': null, 'localRoots': <String>[], 'nightHours': [2, 6]},
    };
    traps = {
      'tokens': <Map<String, dynamic>>[
        {'id': 'trap-1a2b3c4d', 'name': 'backup-token', 'createdAt': _at(const Duration(days: 3))},
      ],
      'files': <Map<String, dynamic>>[
        {'id': 'trap-f1', 'path': '/home/alice/backup/.env.old', 'kind': 'env', 'createdAt': _at(const Duration(days: 3)), 'status': 'armed', 'lastTriggeredAt': null},
        {'id': 'trap-f2', 'path': '/home/alice/.ssh/id_backup', 'kind': 'sshkey', 'createdAt': _at(const Duration(days: 3)), 'status': 'noatime', 'lastTriggeredAt': _at(const Duration(hours: 2))},
        {'id': 'trap-f3', 'path': '/srv/example/.env.bak', 'kind': 'env', 'createdAt': _at(const Duration(days: 3)), 'status': 'missing', 'lastTriggeredAt': null},
      ],
      'dbUsers': ['app_backup'],
      'auditHosts': <String>[],
    };
    alertRecipient = null;
    exposure = {
      'config': {
        'enabled': true,
        'targets': [
          {'id': 'ip-203-0-113-10', 'kind': 'ip', 'value': '203.0.113.10', 'expectedPorts': [22, 443]},
          {'id': 'domain-www-example-org', 'kind': 'domain', 'value': 'www.example.org', 'expectedPorts': <int>[]},
        ],
        'extraPorts': <int>[],
        'intervalDays': 7,
      },
      'running': false,
      'last': {
        'at': _at(const Duration(days: 2)),
        'targets': [
          {'id': 'ip-203-0-113-10', 'kind': 'ip', 'value': '203.0.113.10', 'openPorts': [22, 443, 5432]},
          {'id': 'domain-www-example-org', 'kind': 'domain', 'value': 'www.example.org'},
        ],
        'findings': [
          {'id': 'exposure.openPort:203.0.113.10:5432', 'rule': 'exposure.openPort', 'severity': 'high', 'target': '203.0.113.10', 'params': {'port': 5432}},
          {'id': 'exposure.leakPath:www.example.org:/.env', 'rule': 'exposure.leakPath', 'severity': 'critical', 'target': 'www.example.org', 'params': {'path': '/.env'}},
          {'id': 'exposure.tlsExpiry:www.example.org:9', 'rule': 'exposure.tlsExpiry', 'severity': 'high', 'target': 'www.example.org', 'params': {'days': 9}},
          {'id': 'exposure.noHsts:www.example.org:', 'rule': 'exposure.noHsts', 'severity': 'low', 'target': 'www.example.org', 'params': <String, dynamic>{}},
          {'id': 'exposure.headers:www.example.org:x', 'rule': 'exposure.headers', 'severity': 'low', 'target': 'www.example.org', 'params': {'missing': 'x-content-type-options,referrer-policy'}},
        ],
      },
      'history': [
        {'at': _at(const Duration(days: 2)), 'findings': 5},
        {'at': _at(const Duration(days: 9)), 'findings': 2},
      ],
    };
    attacksConfigured = true;
    attacks = {
      'lastRun': {'at': _at(const Duration(minutes: 12)), 'zones': 2, 'error': null},
      'offenders': [
        {'zone': 'example.org', 'ip': '198.51.100.23', 'country': 'Examplia', 'errors': 88, 'scannerHits': 14, 'paths': ['/wp-login.php', '/.env', '/phpmyadmin/index.php'], 'firstSeenAt': _at(const Duration(hours: 5)), 'lastSeenAt': _at(const Duration(minutes: 20)), 'blockedUntil': _clock.add(const Duration(hours: 18)).toUtc().toIso8601String()},
        {'zone': 'example.org', 'ip': '198.51.100.99', 'country': '', 'errors': 31, 'scannerHits': 0, 'paths': <String>[], 'firstSeenAt': _at(const Duration(hours: 3)), 'lastSeenAt': _at(const Duration(hours: 1)), 'blockedUntil': null},
      ],
    };
    cloudflare = {'hasReadToken': true, 'hasBlockToken': false, 'block': false, 'blockHours': 24, 'zones': ['example.org'], 'allowIps': ['198.51.100.7']};
    bbMode = 'local';
    bbRecords = [
      {'seq': 3, 'at': _at(const Duration(minutes: 5)), 'source': 'atlas', 'kind': 'audit', 'data': {'method': 'POST', 'path': '/v1/security/vulns/scan', 'status': 202}, 'prev': 'x', 'hash': 'y'},
      {'seq': 2, 'at': _at(const Duration(minutes: 30)), 'source': 'atlas', 'kind': 'event', 'data': {'key': 'security.change', 'params': {}}, 'prev': 'x', 'hash': 'y'},
      {'seq': 1, 'at': _at(const Duration(hours: 2)), 'source': 'service:argo', 'kind': 'lockdown', 'data': {'action': 'recoveryCodeCreated'}, 'prev': 'x', 'hash': 'y'},
    ];
    recoveryConfigured = true;
    lockdownTargets = [
      {'id': 'orion', 'name': 'orion', 'url': 'https://orion.example.org:6767', 'hasToken': true},
    ];
  }

  late Map<String, bool> vulnsEnabled;
  late List<Map<String, dynamic>> images;
  late Map<String, dynamic> secrets;
  late Map<String, Map<String, dynamic>> scanners;
  late Map<String, dynamic> traps;
  String? alertRecipient;
  late Map<String, dynamic> exposure;
  late bool attacksConfigured;
  late Map<String, dynamic> attacks;
  late Map<String, dynamic> cloudflare;
  late String bbMode;
  late List<Map<String, dynamic>> bbRecords;
  Map<String, dynamic>? bbVerify;
  List<Map<String, dynamic>> bbAnchors = [
    {'date': '2026-11-13', 'count': 2, 'hash': 'ab12cd34ef56ab12cd34', 'telegram': true, 'at': '2026-11-13T01:00:00Z'},
    {'date': '2026-11-12', 'count': 1, 'hash': '99aa88bb77cc99aa88bb', 'telegram': false, 'at': '2026-11-12T01:00:00Z'},
  ];
  late bool recoveryConfigured;
  late List<Map<String, dynamic>> lockdownTargets;
  bool restartRequired = true;

  /// "METHOD /path" → error to throw (cleared by the test).
  final errors = <String, AgentError>{};

  /// The code POST /v1/security/recovery hands out.
  String recoveryCode = 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2';

  /// Token of the next decoy token.
  String decoyToken = 'tps_decoyTokenExampleValue0123456789';
}

Map<String, dynamic> _scannersFor(FakeSecurityMoreState st, String agent) => st.scanners[agent] ?? st.scanners['argo']!;

dynamic fakeSecurityMoreRoute(String agent, String method, String path, Object? body, FakeSecurityMoreState st) {
  final err = st.errors['$method $path'];
  if (err != null) throw err;
  final b = body is Map ? body : const {};
  final onAtlas = agent == 'atlas';

  if (path == '/v1/security/vulns' && method == 'GET') {
    return {
      'enabled': st.vulnsEnabled[agent] ?? false,
      'running': false,
      'images': onAtlas ? [for (final i in st.images) {...i}..remove('vulns')] : <Map>[],
    };
  }
  if (path == '/v1/security/vulns/scan' && method == 'POST') {
    if (st.vulnsEnabled[agent] != true) throw const AgentError('agent.security.scannerOff', {'scanner': 'trivy'}, 409);
    final id = b['imageId'];
    if (id == null) return {'started': true};
    final img = st.images.where((i) => i['imageId'] == id).firstOrNull;
    if (img == null) throw const AgentError('agent.security.imageNotFound', {}, 404);
    return {'image': img};
  }
  final vm = RegExp(r'^/v1/security/vulns/([a-f0-9]{64})$').firstMatch(path);
  if (vm != null && method == 'GET') {
    final img = onAtlas ? st.images.where((i) => i['imageId'] == 'sha256:${vm.group(1)}').firstOrNull : null;
    if (img == null) throw const AgentError('agent.security.imageNotFound', {}, 404);
    return {'image': img};
  }

  if (path == '/v1/security/secrets' && method == 'GET') {
    return onAtlas ? st.secrets : {'lastRun': null, 'running': false, 'repos': <Map>[], 'findings': <Map>[]};
  }
  if (path == '/v1/security/secrets/scan' && method == 'POST') return {'started': true};
  if (path == '/v1/security/secrets/dismiss-group' && method == 'POST') {
    // Same matching as agent/src/security/secrets.ts dismissGroup.
    var n = 0;
    for (final f in (st.secrets['findings'] as List).cast<Map<String, dynamic>>()) {
      if (f['source'] != b['source'] || f['where'] != b['where'] || f['rule'] != b['rule']) continue;
      // Files directly in that folder only, not in subfolders.
      if (b['pathPrefix'] != null) {
        final file = '${f['file'] ?? ''}', prefix = '${b['pathPrefix']}';
        if (!file.startsWith(prefix) || file.substring(prefix.length).contains('/')) continue;
      }
      if (b['stream'] != null && f['stream'] != b['stream']) continue;
      if (f['dismissed'] != b['dismissed']) n++;
      f['dismissed'] = b['dismissed'];
    }
    return {'changed': n};
  }
  final sm = RegExp(r'^/v1/security/secrets/([a-f0-9]{24})/dismiss$').firstMatch(path);
  if (sm != null && method == 'POST') {
    final list = (st.secrets['findings'] as List).cast<Map<String, dynamic>>();
    final f = list.where((x) => x['id'] == sm.group(1)).firstOrNull;
    if (f == null) throw const AgentError('agent.security.findingNotFound', {}, 404);
    f['dismissed'] = b['dismissed'];
    return {'finding': f};
  }

  if (path == '/v1/security/scanners') {
    final cur = _scannersFor(st, agent);
    if (method == 'PATCH') {
      for (final e in b.entries) {
        switch (e.key) {
          case 'github':
            final g = Map<String, dynamic>.from(e.value as Map);
            final prev = Map<String, dynamic>.from(cur['github'] as Map);
            cur['github'] = {'owners': g['owners'], 'hasToken': g.containsKey('token') ? g['token'] != null : prev['hasToken']};
          case 'registryAuth':
            final prev = (cur['registryAuth'] as List).cast<Map>();
            cur['registryAuth'] = [
              for (final r in (e.value as List).cast<Map>())
                {
                  'registry': r['registry'],
                  'username': r['username'],
                  'hasToken': r['token'] != null || prev.any((x) => x['registry'] == r['registry'] && x['username'] == r['username']),
                },
            ];
          default:
            cur[e.key as String] = e.value;
        }
      }
      if (b.containsKey('trivy')) st.vulnsEnabled[agent] = b['trivy'] == true;
    }
    return {'scanners': cur};
  }

  if (path == '/v1/security/traps' && method == 'GET') return st.traps;
  if (path == '/v1/security/traps/tokens' && method == 'POST') {
    final tokens = (st.traps['tokens'] as List).cast<Map<String, dynamic>>();
    if (tokens.length >= 20) throw const AgentError('agent.security.tooManyTraps', {}, 409);
    final id = 'trap-${tokens.length + 1}0000';
    tokens.add({'id': id, 'name': b['name'], 'createdAt': _at(Duration.zero)});
    return {'id': id, 'token': st.decoyToken};
  }
  final tm = RegExp(r'^/v1/security/traps/(tokens|files)/([a-z0-9-]+)$').firstMatch(path);
  if (tm != null && method == 'DELETE') {
    final list = (st.traps[tm.group(1)] as List).cast<Map<String, dynamic>>();
    if (!list.any((x) => x['id'] == tm.group(2))) throw const AgentError('agent.security.trapNotFound', {}, 404);
    list.removeWhere((x) => x['id'] == tm.group(2));
    return {'ok': true};
  }
  if (path == '/v1/security/traps/files' && method == 'POST') {
    final files = (st.traps['files'] as List).cast<Map<String, dynamic>>();
    if (files.any((f) => f['path'] == b['path'])) throw const AgentError('agent.security.trapExists', {}, 409);
    final f = {'id': 'trap-f${files.length + 1}', 'path': b['path'], 'kind': b['kind'], 'createdAt': _at(Duration.zero)};
    files.add({...f, 'status': 'armed', 'lastTriggeredAt': null});
    return f;
  }
  if (path == '/v1/security/traps/db-users' && method == 'PUT') {
    st.traps['dbUsers'] = b['users'];
    return st.traps;
  }
  if (path == '/v1/security/traps/test' && method == 'POST') return {'ok': true};
  if (path == '/v1/security/alerts') {
    if (method == 'PUT') st.alertRecipient = b['telegramRecipient'] as String?;
    return {'telegramRecipient': st.alertRecipient};
  }

  if (path == '/v1/security/exposure') {
    if (method == 'PUT') {
      final cfg = Map<String, dynamic>.from(st.exposure['config'] as Map);
      for (final k in ['enabled', 'targets', 'extraPorts', 'intervalDays']) {
        if (b.containsKey(k)) cfg[k] = b[k];
      }
      st.exposure['config'] = cfg;
      return {'config': cfg};
    }
    return onAtlas ? st.exposure : {'config': {'enabled': false, 'targets': <Map>[], 'extraPorts': <int>[], 'intervalDays': 7}, 'running': false, 'last': null, 'history': <Map>[]};
  }
  if (path == '/v1/security/exposure/run' && method == 'POST') return {'started': true};

  if (path == '/v1/security/attacks' && method == 'GET') {
    return onAtlas ? {'configured': st.attacksConfigured, ...st.attacks} : {'configured': false, 'lastRun': null, 'offenders': <Map>[]};
  }
  if (path == '/v1/security/attacks/run' && method == 'POST') {
    if (!st.attacksConfigured) throw const AgentError('agent.security.cloudflareNotConfigured', {}, 409);
    return {'offenders': 1, 'blocked': 0};
  }
  if (path == '/v1/security/cloudflare') {
    if (method == 'PUT') {
      for (final e in b.entries) {
        switch (e.key) {
          case 'readToken':
            st.cloudflare['hasReadToken'] = e.value != null;
          case 'blockToken':
            st.cloudflare['hasBlockToken'] = e.value != null;
          default:
            st.cloudflare[e.key as String] = e.value;
        }
      }
      if (st.cloudflare['block'] == true && st.cloudflare['hasBlockToken'] != true) throw const AgentError('agent.security.tokenRequired', {}, 400);
    }
    return onAtlas ? st.cloudflare : {'hasReadToken': false, 'hasBlockToken': false, 'block': false, 'blockHours': 24, 'zones': <String>[], 'allowIps': <String>[]};
  }

  if (path == '/v1/blackbox/status') {
    final push = st.bbMode == 'push';
    return {
      'mode': st.bbMode,
      'head': st.bbMode == 'local' ? {'count': st.bbRecords.length, 'hash': 'f00dfeedc0de1234f00dfeedc0de1234'} : null,
      'pending': push ? 4 : null,
      'lastError': push ? 'agent.net.unreachable' : null,
      'lastSentAt': push ? _at(const Duration(minutes: 40)) : null,
      'url': push ? 'https://atlas.example.org:6767' : null,
    };
  }
  if (path.startsWith('/v1/blackbox/') && st.bbMode != 'local' && path != '/v1/blackbox/settings') throw const AgentError('agent.blackbox.notLocal', {}, 409);
  if (path == '/v1/blackbox/verify' && method == 'GET') {
    return st.bbVerify ?? {'ok': true, 'count': st.bbRecords.length, 'head': 'f00dfeedc0de1234f00dfeedc0de1234', 'brokenAt': null, 'reason': null, 'anchors': st.bbAnchors, 'anchorMismatch': <String>[]};
  }
  if (path == '/v1/blackbox/recent' && method == 'GET') return {'records': st.bbRecords};
  if (path == '/v1/blackbox/anchor' && method == 'POST') {
    st.bbAnchors = [
      {'date': '2026-11-14', 'count': st.bbRecords.length, 'hash': '0123456789abcdef0123', 'telegram': true, 'at': _at(Duration.zero)},
      ...st.bbAnchors,
    ];
    return {'anchors': st.bbAnchors};
  }
  if (path == '/v1/blackbox/settings' && method == 'PUT') {
    final mode = b['mode'] as String;
    return {'mode': mode, 'url': b['url'], 'hasToken': b['token'] != null, 'restartRequired': mode != st.bbMode};
  }

  if (path == '/v1/security/recovery') {
    if (method == 'POST') {
      if (b['confirm'] != true) throw const AgentError('agent.request.invalid', {}, 400);
      st.recoveryConfigured = true;
      return {'code': st.recoveryCode, 'createdAt': _at(Duration.zero)};
    }
    return {'configured': st.recoveryConfigured, 'createdAt': st.recoveryConfigured ? _at(const Duration(days: 4)) : null};
  }
  if (path == '/v1/security/lockdown/targets') {
    if (method == 'POST') {
      if (st.lockdownTargets.any((t) => t['id'] == b['id'])) throw const AgentError('agent.security.hostExists', {}, 409);
      st.lockdownTargets.add({'id': b['id'], 'name': b['name'], 'url': b['url'], 'hasToken': true});
      return {'target': st.lockdownTargets.last};
    }
    return {'targets': st.lockdownTargets};
  }
  final lm = RegExp(r'^/v1/security/lockdown/targets/([a-z0-9-]+)$').firstMatch(path);
  if (lm != null && method == 'DELETE') {
    st.lockdownTargets.removeWhere((t) => t['id'] == lm.group(1));
    return {'ok': true};
  }
  return notMore;
}

/// Recipients of the agent's Telegram bot (GET /v1/telegram/recipients), for the alert picker.
Map<String, dynamic> fakeTelegramRecipients() => {
      'recipients': [
        {'id': 'r_ayse', 'chatId': 1001, 'firstName': 'Ayşe', 'username': 'ayse', 'status': 'active'},
        {'id': 'r_old', 'chatId': 1003, 'firstName': 'Eski', 'status': 'stopped'},
      ],
    };
