// Security center (PLAN.md §15, S-1): models of the agent's /v1/security responses, the providers that gather them from
// every agent with the `security` feature, and the pure helpers behind the screens (score bands, host lookup by id or
// name, request bodies, port validation). Tokens never come back from the agent: settings only know `hasToken`.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../state/providers.dart';
import '../incidents/host_picker.dart' show AmbiguousHostError;
import '../incidents/incidents_data.dart' show exactHostFor;
import '../system/agent_providers.dart';

/// The screens poll anyway (autoRefresh); no hidden retry loop on top of it.
Duration? _noRetry(int retryCount, Object error) => null;

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];
List<String> _strings(Object? v) => v is List ? [for (final e in v) '$e'] : const [];
int? _int(Object? v) => v is num ? v.toInt() : null;

const securityFindingSeverities = ['critical', 'high', 'medium', 'low'];

/// Change categories of the agent's baseline (agent/src/security/baseline.ts).
const securityCategories = ['ports', 'users', 'passwords', 'sudoers', 'authKeys', 'cron', 'timers', 'autostart', 'sshd', 'containers', 'suid', 'services'];

/// Ports every host may expose (agent/src/security/rules.ts DEFAULT_ALLOWED): WireGuard of Tailscale, DHCP, mDNS.
const securityDefaultAllowed = ['udp/41641', 'udp/68', 'udp/546', 'udp/5353'];

// ---------------------------------------------------------------------------------------------------------------------
// Overview

enum SecurityBand { good, warn, bad, none }

/// ≥85 good, ≥60 warn, below bad; no score (never checked) none.
SecurityBand securityBand(int? score) => score == null
    ? SecurityBand.none
    : score >= 85
        ? SecurityBand.good
        : score >= 60
            ? SecurityBand.warn
            : SecurityBand.bad;

class SecurityCounts {
  SecurityCounts(Map<String, dynamic> j)
      : critical = _int(j['critical']) ?? 0,
        high = _int(j['high']) ?? 0,
        medium = _int(j['medium']) ?? 0,
        low = _int(j['low']) ?? 0;
  final int critical, high, medium, low;

  int of(String severity) => switch (severity) {
        'critical' => critical,
        'high' => high,
        'medium' => medium,
        _ => low,
      };
  int get total => critical + high + medium + low;
}

class SecurityLastError {
  SecurityLastError(Map<String, dynamic> j)
      : code = '${j['code']}',
        at = _timeOrNull(j['at']);
  final String code;
  final DateTime? at;
}

/// One audited host in the list (summary of the agent).
class SecurityHostSummary {
  SecurityHostSummary(this.agent, Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        role = '${j['role']}',
        source = '${j['source']}',
        score = _int(j['score']),
        counts = SecurityCounts(_map(j['counts'])),
        changes = _int(j['changes']) ?? 0,
        lastOkAt = _timeOrNull(j['lastOkAt']),
        lastAttemptAt = _timeOrNull(j['lastAttemptAt']),
        lastFullAt = _timeOrNull(j['lastFullAt']),
        lastError = j['lastError'] is Map ? SecurityLastError(_map(j['lastError'])) : null,
        stale = j['stale'] == true,
        running = j['running'] == true;

  /// The agent this host is audited by.
  final Host agent;
  final String id;
  final String name;

  /// server | desktop
  final String role;

  /// local | ssh | agent
  final String source;
  final int? score;
  final SecurityCounts counts;
  final int changes;
  final DateTime? lastOkAt;
  final DateTime? lastAttemptAt;
  final DateTime? lastFullAt;
  final SecurityLastError? lastError;
  final bool stale;
  final bool running;

  SecurityBand get band => securityBand(score);

  /// The last report is old or the last attempt failed: the screen says "last known state".
  bool get showStale => stale || lastError != null;
}

class SecurityOverview {
  SecurityOverview(this.agent, Map<String, dynamic> j)
      : intervalMinutes = _int(j['intervalMinutes']) ?? 15,
        hosts = [for (final e in _maps(j['hosts'])) SecurityHostSummary(agent, e)];
  final Host agent;
  final int intervalMinutes;
  final List<SecurityHostSummary> hosts;
}

class SecurityFeed {
  const SecurityFeed({required this.overviews, required this.errors, required this.agents});
  final List<SecurityOverview> overviews;

  /// Agent id → error of that agent's request.
  final Map<String, Object> errors;
  final List<Host> agents;

  Iterable<SecurityHostSummary> get hosts => overviews.expand((o) => o.hosts);

  /// Pending changes over every host.
  int get changes => hosts.fold(0, (a, h) => a + h.changes);

  /// Critical findings over every host.
  int get critical => hosts.fold(0, (a, h) => a + h.counts.critical);

  /// The home card only appears when something needs a look.
  bool get needsAttention => changes > 0 || critical > 0;
}

/// Agent hosts whose health response lists the `security` feature.
final securityHostsProvider = FutureProvider.autoDispose<List<Host>>(retry: _noRetry, (ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final checked = await Future.wait(hosts.map((h) async {
    try {
      final j = await ref.watch(healthProvider(h.id).future);
      return (j['features'] as Map?)?['security'] == true ? h : null;
    } catch (_) {
      return null;
    }
  }));
  return [...checked.nonNulls];
});

final securityFeedProvider = FutureProvider.autoDispose<SecurityFeed>(retry: _noRetry, (ref) async {
  autoRefresh(ref, const Duration(seconds: 30));
  final agents = await ref.watch(securityHostsProvider.future);
  final results = await Future.wait(agents.map((h) async {
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/security/overview')).timeout(const Duration(seconds: 15));
      return (h, SecurityOverview(h, j), null as Object?);
    } catch (e) {
      return (h, null, e as Object?);
    }
  }));
  return SecurityFeed(
    overviews: [for (final r in results) if (r.$2 != null) r.$2!],
    errors: {for (final r in results) if (r.$3 != null) r.$1.id: r.$3!},
    agents: agents,
  );
});

// ---------------------------------------------------------------------------------------------------------------------
// Detail

class SecFinding {
  SecFinding(Map<String, dynamic> j)
      : id = '${j['id']}',
        rule = '${j['rule']}',
        severity = '${j['severity']}',
        params = _map(j['params']);
  final String id;
  final String rule;
  final String severity;
  final Map<String, dynamic> params;
}

class SecChange {
  SecChange(Map<String, dynamic> j)
      : id = '${j['id']}',
        category = '${j['category']}',
        item = '${j['item']}',
        kind = '${j['kind']}',
        firstSeenAt = _timeOrNull(j['firstSeenAt']);
  final String id;
  final String category;
  final String item;

  /// added | removed | changed
  final String kind;
  final DateTime? firstSeenAt;
}

class SecListener {
  SecListener(Map<String, dynamic> j)
      : proto = '${j['proto']}',
        addr = '${j['addr']}',
        iface = j['iface'] as String?,
        port = _int(j['port']) ?? 0,
        scope = '${j['scope']}',
        process = j['process'] as String?,
        firewall = j['firewall'] as String?;
  final String proto;
  final String addr;
  final String? iface;
  final int port;

  /// loopback | tailscale | wildcard | private | linklocal | public
  final String scope;
  final String? process;

  /// open | filtered for wildcard/public listeners when the host firewall is known; null = unknown.
  final String? firewall;

  String get spec => '$proto/$port';

  /// Reachable from outside the host (before the allowed-ports policy).
  bool get exposed => scope == 'wildcard' || scope == 'public';

  /// Exposed and the firewall blocks new outside connections.
  bool get filtered => exposed && firewall == 'filtered';
}

class SecUser {
  SecUser(Map<String, dynamic> j)
      : name = '${j['name']}',
        uid = _int(j['uid']) ?? -1,
        shell = '${j['shell'] ?? ''}';
  final String name;
  final int uid;
  final String shell;
}

class SecAuthKey {
  SecAuthKey(Map<String, dynamic> j)
      : user = '${j['user']}',
        path = '${j['path'] ?? ''}',
        bits = _int(j['bits']) ?? 0,
        fingerprint = '${j['fingerprint']}',
        comment = '${j['comment'] ?? ''}',
        type = '${j['type'] ?? ''}';
  final String user, path, fingerprint, comment, type;
  final int bits;
}

class SecHashed {
  SecHashed(Map<String, dynamic> j)
      : path = '${j['path']}',
        sha256 = '${j['sha256'] ?? ''}';
  final String path, sha256;
}

class SecTimer {
  SecTimer(Map<String, dynamic> j)
      : scope = '${j['scope']}',
        name = '${j['name']}',
        unit = '${j['unit'] ?? ''}';
  final String scope, name, unit;
}

class SecLogin {
  SecLogin(Map<String, dynamic> j)
      : user = '${j['user']}',
        tty = '${j['tty'] ?? ''}',
        from = '${j['from'] ?? ''}',
        raw = '${j['raw'] ?? ''}';
  final String user, tty, from, raw;
}

class SecContainer {
  SecContainer(Map<String, dynamic> j)
      : name = '${j['name']}',
        image = '${j['image'] ?? ''}',
        privileged = j['privileged'] == true,
        networkMode = '${j['networkMode'] ?? ''}',
        pidMode = '${j['pidMode'] ?? ''}',
        capAdd = _strings(j['capAdd']),
        socketMounted = _maps(j['mounts']).any((m) => RegExp(r'(^|/)docker\.sock$').hasMatch('${m['source']}')),
        ports = [for (final p in _maps(j['ports'])) '${p['hostIp'] == null || p['hostIp'] == '' ? '' : '${p['hostIp']}:'}${p['hostPort']}'];
  final String name, image, networkMode, pidMode;
  final bool privileged, socketMounted;
  final List<String> capAdd;
  final List<String> ports;

  bool get hostPid => pidMode == 'host';
  bool get hostNetwork => networkMode == 'host';
  bool get risky => privileged || socketMounted || hostPid || hostNetwork || capAdd.isNotEmpty;
}

class SecDocker {
  SecDocker(Map<String, dynamic> j)
      : version = '${j['version'] ?? ''}',
        containers = [for (final c in _maps(j['containers'])) SecContainer(c)],
        images = (j['images'] as List?)?.length ?? 0;
  final String version;
  final List<SecContainer> containers;
  final int images;
}

class SecUpdates {
  SecUpdates(Map<String, dynamic> j)
      : pending = _int(j['pending']),
        security = _int(j['security']),
        unattended = j['unattended'] as bool?,
        listsUpdatedAt = _timeOrNull(j['listsUpdatedAt']),
        rebootRequiredSince = _timeOrNull(j['rebootRequiredSince']);
  final int? pending;
  final int? security;
  final bool? unattended;
  final DateTime? listsUpdatedAt;
  final DateTime? rebootRequiredSince;
}

class SecFile {
  SecFile(Map<String, dynamic> j)
      : path = '${j['path']}',
        mode = '${j['mode'] ?? ''}',
        owner = '${j['owner'] ?? ''}';
  final String path, mode, owner;
}

/// The host's last report. Sections that are `null` were not available (root needed, or not scanned in a quick check).
class SecurityReportData {
  SecurityReportData(Map<String, dynamic> j)
      : mode = '${j['mode']}',
        root = j['root'] == true,
        meta = _map(j['meta']),
        firewall = j['firewall'] is Map ? SecFirewall(_map(j['firewall'])) : null,
        listen = j['listen'] is List ? [for (final e in _maps(j['listen'])) SecListener(e)] : null,
        sshdMode = j['sshd'] is Map ? '${_map(j['sshd'])['mode']}' : null,
        sshd = j['sshd'] is Map
            ? {
                for (final e in _map(_map(j['sshd'])['settings']).entries) e.key: _strings(e.value),
              }
            : null,
        users = [for (final e in _maps(j['users'])) SecUser(e)],
        passwords = j['passwords'] is List ? {for (final e in _maps(j['passwords'])) '${e['name']}': '${e['status']}'} : null,
        groups = {for (final e in _map(j['groups']).entries) e.key: _strings(e.value)},
        sudoers = j['sudoers'] is List ? [for (final e in _maps(j['sudoers'])) SecHashed(e)] : null,
        authKeys = [for (final e in _maps(j['authKeys'])) SecAuthKey(e)],
        cron = [for (final e in _maps(j['cron'])) SecHashed(e)],
        timers = [for (final e in _maps(j['timers'])) SecTimer(e)],
        autostart = j['autostart'] is List ? [for (final e in _maps(j['autostart'])) SecHashed(e)] : null,
        updates = SecUpdates(_map(j['updates'])),
        services = {for (final e in _map(j['services']).entries) e.key: '${_map(e.value)['active']}'},
        sysctl = {for (final e in _map(j['sysctl']).entries) e.key: '${e.value}'},
        logins = [for (final e in _maps(j['logins'])) SecLogin(e)],
        docker = j['docker'] is Map ? SecDocker(_map(j['docker'])) : null,
        suid = j['suid'] is List ? [for (final e in _maps(j['suid'])) SecFile(e)] : null,
        worldWritable = j['worldWritable'] is List ? [for (final e in _maps(j['worldWritable'])) SecFile(e)] : null,
        agentFiles = j['agentFiles'] is List ? [for (final e in _maps(j['agentFiles'])) SecFile(e)] : null,
        unavailable = _strings(j['unavailable']);
  final String mode;
  final bool root;
  final Map<String, dynamic> meta;

  /// null = not readable (needs root).
  final SecFirewall? firewall;
  final List<SecListener>? listen;

  /// effective | config
  final String? sshdMode;
  final Map<String, List<String>>? sshd;
  final List<SecUser> users;

  /// user → empty | set
  final Map<String, String>? passwords;
  final Map<String, List<String>> groups;
  final List<SecHashed>? sudoers;
  final List<SecAuthKey> authKeys;
  final List<SecHashed> cron;
  final List<SecTimer> timers;
  final List<SecHashed>? autostart;
  final SecUpdates updates;

  /// unit → active state
  final Map<String, String> services;
  final Map<String, String> sysctl;
  final List<SecLogin> logins;
  final SecDocker? docker;
  final List<SecFile>? suid;
  final List<SecFile>? worldWritable;
  final List<SecFile>? agentFiles;
  final List<String> unavailable;

  String? metaString(String key) {
    final v = meta[key];
    return v == null || '$v'.isEmpty ? null : '$v';
  }

  int? get ipv6Global => _int(meta['ipv6Global']);
  int? get uptimeSec => _int(meta['uptimeSec']);
  DateTime? get reportTime => _timeOrNull(meta['time']);
}

class SecFirewall {
  SecFirewall(Map<String, dynamic> j)
      : defaultDeny = j['defaultDeny'] == true,
        inputChains = _int(j['inputChains']) ?? 0;
  final bool defaultDeny;
  final int inputChains;
}

class SecurityPolicy {
  SecurityPolicy(Map<String, dynamic> j)
      : role = '${j['role'] ?? 'server'}',
        allowedPorts = _strings(j['allowedPorts']);
  final String role;
  final List<String> allowedPorts;
}

class SecurityDetail {
  SecurityDetail(Host agent, Map<String, dynamic> j)
      : agent = agent,
        summary = SecurityHostSummary(agent, _map(j['host'])),
        policy = SecurityPolicy(_map(j['policy'])),
        findings = [for (final e in _maps(j['findings'])) SecFinding(e)],
        changes = [for (final e in _maps(j['changes'])) SecChange(e)],
        baselineAt = _timeOrNull(j['baselineAt']),
        report = j['report'] is Map ? SecurityReportData(_map(j['report'])) : null;
  final Host agent;
  final SecurityHostSummary summary;
  final SecurityPolicy policy;
  final List<SecFinding> findings;
  final List<SecChange> changes;
  final DateTime? baselineAt;
  final SecurityReportData? report;

  List<SecFinding> findingsOf(String severity) => [for (final f in findings) if (f.severity == severity) f];

  /// "tcp/22" of the exposed-port findings: those listeners are highlighted in the port table.
  Set<String> get flaggedPorts => {
        for (final f in findings)
          if (f.rule == 'port.exposed') '${f.params['proto']}/${f.params['port']}',
      };
}

/// (host id or display name, agent hint: id or name of the agent; null = look on every agent with the feature)
typedef SecurityRef = (String, String?);

/// The audited host whose name equals [name] (case-insensitive), when exactly one does. Notifications and incidents
/// name a host by its display name.
SecurityHostSummary? securityHostByName(Iterable<SecurityHostSummary> hosts, String name) {
  final lower = name.toLowerCase();
  final hit = hosts.where((h) => h.name.toLowerCase() == lower).toList();
  return hit.length == 1 ? hit.single : null;
}

bool _notFoundHere(AgentError e) => e.code == 'agent.security.hostNotFound' || e.code == 'agent.request.invalid';

Future<SecurityDetail> _fetchDetail(Ref ref, Host agent, String hostId) async {
  Future<SecurityDetail> byId(String id) async =>
      SecurityDetail(agent, await withAgent(ref, agent.id, (c) => c.get('/v1/security/hosts/${Uri.encodeComponent(id)}')).timeout(const Duration(seconds: 20)));
  try {
    return await byId(hostId);
  } on AgentError catch (e) {
    if (!_notFoundHere(e)) rethrow;
    // Not an id: a link from the incident room carries the host's name.
    final ov = SecurityOverview(agent, await withAgent(ref, agent.id, (c) => c.get('/v1/security/overview')).timeout(const Duration(seconds: 15)));
    final byName = securityHostByName(ov.hosts, hostId);
    if (byName == null) throw const AgentError('agent.security.hostNotFound', {}, 404);
    return byId(byName.id);
  }
}

/// A host's detail. With an agent hint (id or name) only that agent is asked; without one every agent with the feature
/// is, and a host found on several of them ends in [AmbiguousHostError] (the screen asks which).
final securityDetailProvider = FutureProvider.autoDispose.family<SecurityDetail, SecurityRef>(retry: _noRetry, (ref, key) async {
  autoRefresh(ref, const Duration(seconds: 20));
  final (hostId, hint) = key;
  final agents = await ref.watch(securityHostsProvider.future);
  if (agents.isEmpty) throw const AgentError('agent.route.notFound', {}, 404);
  final exact = exactHostFor(agents, hint);
  if (exact != null) return _fetchDetail(ref, exact, hostId);
  final answers = await Future.wait([
    for (final a in agents) _fetchDetail(ref, a, hostId).then<(Host, SecurityDetail?, AgentError?)>((d) => (a, d, null), onError: (Object e) => e is AgentError ? (a, null, e) : throw e),
  ]);
  final hits = [for (final a in answers) if (a.$2 != null) a];
  if (hits.length == 1) return hits.single.$2!;
  if (hits.length > 1) throw AmbiguousHostError([for (final a in hits) a.$1]);
  AgentError? error;
  for (final a in answers) {
    final cur = error;
    if (cur == null || cur.code == 'agent.security.hostNotFound') error = a.$3;
  }
  throw error ?? const AgentError('agent.security.hostNotFound', {}, 404);
});

/// One-off call to an agent (check, baseline, settings) with its own timeout; the response is the decoded JSON.
Future<dynamic> securityCall(WidgetRef ref, String agentId, String method, String path, {Object? body, Duration? timeout}) async {
  final host = ref.read(profileProvider).host(agentId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await c.request(method, path, body: body, timeout: timeout);
  } finally {
    c.close();
  }
}

/// A full check runs the SUID and world-writable scans (up to ~5 minutes on the agent).
Duration securityCheckTimeout({required bool full}) => Duration(seconds: full ? 330 : 120);

String securityHostPath(String hostId) => '/v1/security/hosts/${Uri.encodeComponent(hostId)}';

/// "/security/orion?host=atlas" — [agentId] is the agent that audits the host (omitted: every agent is asked).
String securityRoute(String hostId, {String? agentId}) =>
    '/security/${Uri.encodeComponent(hostId)}${agentId == null || agentId.isEmpty ? '' : '?host=${Uri.encodeQueryComponent(agentId)}'}';

// ---------------------------------------------------------------------------------------------------------------------
// Settings (GET/POST/PATCH/DELETE /v1/security/hosts)

class SecuritySelf {
  SecuritySelf(Map<String, dynamic> j)
      : role = '${j['role'] ?? 'server'}',
        allowedPorts = _strings(j['allowedPorts']),
        sudo = j['sudo'] == true;
  final String role;
  final List<String> allowedPorts;
  final bool sudo;
}

class SecurityHostConfig {
  SecurityHostConfig(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        role = '${j['role'] ?? 'server'}',
        allowedPorts = _strings(j['allowedPorts']),
        kind = '${_map(j['source'])['kind']}',
        sshHost = _map(j['source'])['host'] as String?,
        sshUser = _map(j['source'])['user'] as String?,
        sshPort = _int(_map(j['source'])['port']),
        keyPath = _map(j['source'])['keyPath'] as String?,
        url = _map(j['source'])['url'] as String?,
        hasToken = _map(j['source'])['hasToken'] == true,
        traps = j['traps'] == true;
  final String id, name, role;
  final List<String> allowedPorts;

  /// ssh | agent
  final String kind;
  final String? sshHost, sshUser, keyPath, url;
  final int? sshPort;
  final bool hasToken;

  /// SSH hosts: the agent polls the auditd decoy-file events of this host.
  final bool traps;

  bool get isSsh => kind == 'ssh';
}

class SecuritySettings {
  SecuritySettings(this.agent, Map<String, dynamic> j)
      : self = SecuritySelf(_map(j['self'])),
        hosts = [for (final e in _maps(j['hosts'])) SecurityHostConfig(e)];
  final Host agent;
  final SecuritySelf self;
  final List<SecurityHostConfig> hosts;
}

final securitySettingsProvider = FutureProvider.autoDispose.family<SecuritySettings, String>(retry: _noRetry, (ref, agentId) async {
  final host = ref.watch(profileProvider).host(agentId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final j = await withAgent(ref, agentId, (c) => c.get('/v1/security/hosts')).timeout(const Duration(seconds: 20));
  return SecuritySettings(host, j);
});

final _portSpec = RegExp(r'^(tcp|udp)/\d{1,5}$');

/// "tcp/22" / "udp/53": the agent's pattern, and a real port number.
bool validPortSpec(String v) {
  if (!_portSpec.hasMatch(v)) return false;
  final n = int.parse(v.substring(4));
  return n >= 1 && n <= 65535;
}

/// Source of a host to add or edit. The token is only sent when entered (the agent keeps the old one when the URL is
/// unchanged; a new URL needs one).
Map<String, dynamic> securitySourceBody({required bool ssh, String host = '', String user = '', int port = 22, String keyPath = '', String url = '', String token = ''}) =>
    ssh ? {'kind': 'ssh', 'host': host.trim(), 'user': user.trim(), 'port': port, 'keyPath': keyPath.trim()} : {'kind': 'agent', 'url': url.trim(), if (token.trim().isNotEmpty) 'token': token.trim()};

/// Whether the agent's check can run for hosts this old (used by the list: "checked N minutes ago").
Duration? securityAge(SecurityHostSummary h, DateTime now) => h.lastOkAt == null ? null : now.difference(h.lastOkAt!);
