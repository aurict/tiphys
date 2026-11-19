// Security center S-2…S-5 (PLAN.md §15): models of the agent's scanner, trap, outside-view, attack, black box and
// recovery endpoints, and the providers behind the screens. Everything is read as plain JSON; tokens never come back
// from the agent (only `hasToken` flags), and secret findings never contain a value.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../incidents/incidents_data.dart' show exactHostFor;
import '../incidents/host_picker.dart' show AmbiguousHostError;
import '../system/agent_providers.dart';
import 'security_data.dart';

Duration? _noRetry(int retryCount, Object error) => null;

DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];
List<String> _strs(Object? v) => v is List ? [for (final e in v) '$e'] : const [];
int _int(Object? v, [int d = 0]) => v is num ? v.toInt() : d;
String? _str(Object? v) => v == null ? null : '$v';

// ---------------------------------------------------------------------------------------------------------------------
// Providers

/// (agent id, path): a GET of one agent, polled like the other security screens.
typedef SecPath = (String, String);

final securityGetProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, SecPath>(retry: _noRetry, (ref, key) async {
  autoRefresh(ref, const Duration(seconds: 20));
  return withAgent(ref, key.$1, (c) => c.get(key.$2)).timeout(const Duration(seconds: 25));
});

/// The agents a section screen shows: the one a deep link names (id or name), else every agent with the feature.
final securityAgentsProvider = FutureProvider.autoDispose.family<List<Host>, String?>(retry: _noRetry, (ref, hint) async {
  final all = await ref.watch(securityHostsProvider.future);
  final exact = exactHostFor(all, hint);
  return exact != null ? [exact] : all;
});

const secVulnsPath = '/v1/security/vulns';
const secSecretsPath = '/v1/security/secrets';
const secScannersPath = '/v1/security/scanners';
const secTrapsPath = '/v1/security/traps';
const secAlertsPath = '/v1/security/alerts';
const secExposurePath = '/v1/security/exposure';
const secAttacksPath = '/v1/security/attacks';
const secCloudflarePath = '/v1/security/cloudflare';
const secBlackboxStatusPath = '/v1/blackbox/status';
const secBlackboxRecentPath = '/v1/blackbox/recent?limit=100';
const secRecoveryPath = '/v1/security/recovery';
const secLockdownTargetsPath = '/v1/security/lockdown/targets';

/// "/security/vulns/<64 hex>?host=atlas"
String securityVulnRoute(String hex, {String? agentId}) => '/security/vulns/$hex${agentId == null || agentId.isEmpty ? '' : '?host=${Uri.encodeQueryComponent(agentId)}'}';

/// "/security/traps?host=atlas": a section route of the security center.
String securitySectionRoute(String section, {String? agentId}) => '/security/$section${agentId == null || agentId.isEmpty ? '' : '?host=${Uri.encodeQueryComponent(agentId)}'}';

// ---------------------------------------------------------------------------------------------------------------------
// S-2 vulnerabilities

const vulnStatuses = ['ok', 'failed', 'needsCredentials', 'notAvailable', 'pending'];

class VulnHostRef {
  VulnHostRef(Map<String, dynamic> j)
      : hostId = '${j['hostId']}',
        host = '${j['host']}',
        containers = _strs(j['containers']);
  final String hostId, host;
  final List<String> containers;
}

class VulnItem {
  VulnItem(Map<String, dynamic> j)
      : id = '${j['id']}',
        pkg = '${j['pkg']}',
        installed = '${j['installed'] ?? ''}',
        fixed = _str(j['fixed']),
        severity = '${j['severity']}'.toLowerCase(),
        title = '${j['title'] ?? ''}',
        target = '${j['target'] ?? ''}';
  final String id, pkg, installed, severity, title, target;
  final String? fixed;
}

class VulnImage {
  VulnImage(Map<String, dynamic> j)
      : imageId = '${j['imageId']}',
        refs = _strs(j['refs']),
        hosts = [for (final e in _maps(j['hosts'])) VulnHostRef(e)],
        status = '${j['status']}',
        source = _str(j['source']),
        error = _str(j['error']),
        scannedAt = _time(j['scannedAt']),
        os = _str(j['os']),
        critical = _int(_map(j['counts'])['critical']),
        high = _int(_map(j['counts'])['high']),
        fixable = _int(_map(j['counts'])['fixable']),
        vulns = [for (final e in _maps(j['vulns'])) VulnItem(e)],
        truncated = j['truncated'] == true;
  final String imageId;
  final List<String> refs;
  final List<VulnHostRef> hosts;

  /// ok | failed | needsCredentials | notAvailable | pending
  final String status;

  /// remote | local | ssh
  final String? source;

  /// failed: reason id; needsCredentials: the registry; pending: nightOnly | saveLimit.
  final String? error;
  final DateTime? scannedAt;
  final String? os;
  final int critical, high, fixable;
  final List<VulnItem> vulns;
  final bool truncated;

  String get hex => imageId.startsWith('sha256:') ? imageId.substring(7) : imageId;
  String get title => refs.isNotEmpty ? refs.first : hex.substring(0, hex.length < 12 ? hex.length : 12);
}

class VulnList {
  VulnList(Map<String, dynamic> j)
      : enabled = j['enabled'] == true,
        running = j['running'] == true,
        images = [for (final e in _maps(j['images'])) VulnImage(e)];
  final bool enabled, running;
  final List<VulnImage> images;
}

/// One image of the agents with the feature. With a hint only that agent is asked; without one every agent is, and an
/// image found on several ends in [AmbiguousHostError].
final vulnImageProvider = FutureProvider.autoDispose.family<(Host, VulnImage), (String, String?)>(retry: _noRetry, (ref, key) async {
  autoRefresh(ref, const Duration(seconds: 20));
  final (hex, hint) = key;
  final agents = await ref.watch(securityAgentsProvider(hint).future);
  if (agents.isEmpty) throw const AgentError('agent.route.notFound', {}, 404);
  final answers = await Future.wait([
    for (final a in agents)
      withAgent(ref, a.id, (c) => c.get('$secVulnsPath/$hex')).timeout(const Duration(seconds: 25)).then<(Host, VulnImage?, AgentError?)>(
            (j) => (a, VulnImage(_map(j['image'])), null),
            onError: (Object e) => e is AgentError ? (a, null, e) : throw e,
          ),
  ]);
  final hits = [for (final a in answers) if (a.$2 != null) a];
  if (hits.length == 1) return (hits.single.$1, hits.single.$2!);
  if (hits.length > 1) throw AmbiguousHostError([for (final a in hits) a.$1]);
  throw answers.map((a) => a.$3).nonNulls.firstOrNull ?? const AgentError('agent.security.imageNotFound', {}, 404);
});

// ---------------------------------------------------------------------------------------------------------------------
// S-2 secrets and scanner settings

class SecretFindingItem {
  SecretFindingItem(Map<String, dynamic> j)
      : id = '${j['id']}',
        source = '${j['source']}',
        rule = '${j['rule']}',
        where = '${j['where'] ?? ''}',
        file = _str(j['file']),
        line = j['line'] is num ? (j['line'] as num).toInt() : null,
        commit = _str(j['commit']),
        stream = _str(j['stream']),
        at = _time(j['at']),
        firstSeenAt = _time(j['firstSeenAt']),
        dismissed = j['dismissed'] == true;
  final String id, source, rule, where;
  final String? file, commit, stream;
  final int? line;
  final DateTime? at, firstSeenAt;
  final bool dismissed;

  String? get location => file == null ? null : (line == null ? file : '$file:$line');

  /// Folder of the file up to and including the last "/" (null: no folder or no file); for Loki the log stream is used.
  String? get dir {
    final f = file;
    if (f == null) return null;
    final i = f.lastIndexOf('/');
    return i < 0 ? null : f.substring(0, i + 1);
  }
}

/// Findings of one source + place + rule + folder (or Loki stream); what "dismiss this group" acts on.
class SecretGroup {
  SecretGroup(this.source, this.where, this.rule, {this.dir, this.stream});
  final String source, where, rule;

  /// Folder prefix incl. the trailing "/" (github/local); null if the files are in the root or it is a log finding.
  final String? dir;
  final String? stream;
  final items = <SecretFindingItem>[];

  String get key => '$source|$where|$rule|${dir ?? ''}|${stream ?? ''}';
  bool get dismissed => items.every((f) => f.dismissed);

  /// Body of POST /v1/security/secrets/dismiss-group (without `dismissed`).
  Map<String, dynamic> body() => {
        'source': source,
        'where': where,
        'rule': rule,
        if (source == 'loki' ? (stream != null && stream!.isNotEmpty) : dir != null) ...(source == 'loki' ? {'stream': stream} : {'pathPrefix': dir}),
      };
}

/// Groups findings by source + where + rule + folder (Loki: stream), in order of first appearance.
List<SecretGroup> groupSecretFindings(Iterable<SecretFindingItem> findings) {
  final out = <String, SecretGroup>{};
  for (final f in findings) {
    final loki = f.source == 'loki';
    final g = SecretGroup(f.source, f.where, f.rule, dir: loki ? null : f.dir, stream: loki ? f.stream : null);
    out.putIfAbsent(g.key, () => g).items.add(f);
  }
  return out.values.toList();
}

class SecretRepo {
  SecretRepo(Map<String, dynamic> j)
      : repo = '${j['repo']}',
        head = '${j['head'] ?? ''}',
        scannedAt = _time(j['scannedAt']),
        error = _str(j['error']);
  final String repo, head;
  final DateTime? scannedAt;
  final String? error;
}

class SecretsData {
  SecretsData(Map<String, dynamic> j)
      : lastRunAt = _time(_map(j['lastRun'])['at']),
        hasRun = j['lastRun'] is Map,
        sourceErrors = {
          for (final s in const ['github', 'loki', 'local']) s: _str(_map(j['lastRun'])[s]),
        },
        running = j['running'] == true,
        repos = [for (final e in _maps(j['repos'])) SecretRepo(e)],
        findings = [for (final e in _maps(j['findings'])) SecretFindingItem(e)];
  final DateTime? lastRunAt;
  final bool hasRun, running;

  /// github | loki | local → agent error code of the last run (null = fine).
  final Map<String, String?> sourceErrors;
  final List<SecretRepo> repos;
  final List<SecretFindingItem> findings;

  List<SecretFindingItem> get open => [for (final f in findings) if (!f.dismissed) f];
  List<SecretFindingItem> get dismissed => [for (final f in findings) if (f.dismissed) f];
}

class RegistryAuthItem {
  RegistryAuthItem(Map<String, dynamic> j)
      : registry = '${j['registry']}',
        username = '${j['username']}',
        hasToken = j['hasToken'] == true;
  final String registry, username;
  final bool hasToken;
}

class ScannersConfig {
  ScannersConfig(Map<String, dynamic> j)
      : trivy = j['trivy'] == true,
        gitleaks = j['gitleaks'] == true,
        javaDb = j['javaDb'] == true,
        registryAuth = [for (final e in _maps(j['registryAuth'])) RegistryAuthItem(e)],
        owners = _strs(_map(j['github'])['owners']),
        githubToken = _map(j['github'])['hasToken'] == true,
        lokiContainer = _str(_map(j['loki'])['container']),
        lokiPort = _int(_map(j['loki'])['port'], 3100),
        lokiUrl = _str(_map(j['loki'])['url']),
        localRoots = _strs(j['localRoots']),
        nightFrom = j['nightHours'] is List && (j['nightHours'] as List).length == 2 ? _int((j['nightHours'] as List)[0], 2) : 2,
        nightTo = j['nightHours'] is List && (j['nightHours'] as List).length == 2 ? _int((j['nightHours'] as List)[1], 6) : 6;
  final bool trivy, gitleaks, javaDb;
  final List<RegistryAuthItem> registryAuth;
  final List<String> owners;
  final bool githubToken;

  /// Loki: a container (+ port) on the agent's machine, or a URL; both null = not configured.
  final String? lokiContainer, lokiUrl;
  final int lokiPort;
  final List<String> localRoots;
  final int nightFrom, nightTo;

  /// container | url | off
  String get lokiMode => lokiContainer != null ? 'container' : (lokiUrl != null ? 'url' : 'off');
}

final _ownerRe = RegExp(r'^[A-Za-z0-9-]{1,39}$');
final _registryRe = RegExp(r'^[a-z0-9.-]+(:\d+)?$');
final _containerRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$');

bool validGithubOwner(String v) => _ownerRe.hasMatch(v);
bool validRegistry(String v) => _registryRe.hasMatch(v);
bool validContainerName(String v) => _containerRe.hasMatch(v);

/// The agent's tokens: `tps_` + 20 or more URL-safe characters.
final _tpsRe = RegExp(r'^tps_[A-Za-z0-9_-]{20,}$');
bool validServiceToken(String v) => _tpsRe.hasMatch(v);

/// PATCH body of the registry list: tokens only for rows where one was typed (the agent keeps the old one otherwise).
List<Map<String, dynamic>> registryAuthBody(List<(String registry, String username, String? token)> rows) => [
      for (final (registry, username, token) in rows) {'registry': registry, 'username': username, if (token != null && token.isNotEmpty) 'token': token},
    ];

/// Loki body: container + port, url, or null (off).
Map<String, dynamic>? lokiBody(String mode, {String container = '', int port = 3100, String url = ''}) => switch (mode) {
      'container' => {'container': container.trim(), 'port': port},
      'url' => {'url': url.trim()},
      _ => null,
    };

// ---------------------------------------------------------------------------------------------------------------------
// S-3 traps

class TrapToken {
  TrapToken(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        createdAt = _time(j['createdAt']);
  final String id, name;
  final DateTime? createdAt;
}

const trapFileStatuses = ['armed', 'noatime', 'missing', 'error'];

class TrapFile {
  TrapFile(Map<String, dynamic> j)
      : id = '${j['id']}',
        path = '${j['path']}',
        kind = '${j['kind']}',
        createdAt = _time(j['createdAt']),
        status = '${j['status'] ?? 'missing'}',
        lastTriggeredAt = _time(j['lastTriggeredAt']);
  final String id, path;

  /// env | sshkey
  final String kind;
  final DateTime? createdAt;

  /// armed | noatime | missing | error
  final String status;
  final DateTime? lastTriggeredAt;
}

class TrapsData {
  TrapsData(Map<String, dynamic> j)
      : tokens = [for (final e in _maps(j['tokens'])) TrapToken(e)],
        files = [for (final e in _maps(j['files'])) TrapFile(e)],
        dbUsers = _strs(j['dbUsers']),
        auditHosts = _strs(j['auditHosts']);
  final List<TrapToken> tokens;
  final List<TrapFile> files;
  final List<String> dbUsers, auditHosts;
}

final _dbUserRe = RegExp(r'^[a-z_][a-z0-9_]{2,62}$');
bool validDbTrapUser(String v) => _dbUserRe.hasMatch(v);

/// Telegram recipient id of the owner alerts (null = off).
String? alertRecipientOf(Map<String, dynamic> j) => _str(j['telegramRecipient']);

// ---------------------------------------------------------------------------------------------------------------------
// S-5 outside view

const exposureRules = ['exposure.openPort', 'exposure.leakPath', 'exposure.tlsExpiry', 'exposure.noHttps', 'exposure.noHsts', 'exposure.headers', 'exposure.unreachable'];

class ExposureTarget {
  const ExposureTarget({required this.id, required this.kind, required this.value, this.expectedPorts = const []});
  ExposureTarget.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        kind = '${j['kind']}',
        value = '${j['value']}',
        expectedPorts = [for (final p in (j['expectedPorts'] as List? ?? const [])) if (p is num) p.toInt()];
  final String id, kind, value;
  final List<int> expectedPorts;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'value': value, if (kind == 'ip') 'expectedPorts': expectedPorts};
}

class ExposureFindingItem {
  ExposureFindingItem(Map<String, dynamic> j)
      : id = '${j['id']}',
        rule = '${j['rule']}',
        severity = '${j['severity']}',
        target = '${j['target']}',
        params = _map(j['params']);
  final String id, rule, severity, target;
  final Map<String, dynamic> params;
}

class ExposureRunTarget {
  ExposureRunTarget(Map<String, dynamic> j)
      : id = '${j['id']}',
        kind = '${j['kind']}',
        value = '${j['value']}',
        openPorts = [for (final p in (j['openPorts'] as List? ?? const [])) if (p is num) p.toInt()],
        scannedPorts = j['openPorts'] is List,
        error = _str(j['error']);
  final String id, kind, value;
  final List<int> openPorts;
  final bool scannedPorts;
  final String? error;
}

class ExposureRunData {
  ExposureRunData(Map<String, dynamic> j)
      : at = _time(j['at']),
        targets = [for (final e in _maps(j['targets'])) ExposureRunTarget(e)],
        findings = [for (final e in _maps(j['findings'])) ExposureFindingItem(e)];
  final DateTime? at;
  final List<ExposureRunTarget> targets;
  final List<ExposureFindingItem> findings;
}

class ExposureData {
  ExposureData(Map<String, dynamic> j)
      : enabled = _map(j['config'])['enabled'] == true,
        targets = [for (final e in _maps(_map(j['config'])['targets'])) ExposureTarget.fromJson(e)],
        extraPorts = [for (final p in (_map(j['config'])['extraPorts'] as List? ?? const [])) if (p is num) p.toInt()],
        intervalDays = _int(_map(j['config'])['intervalDays'], 7),
        running = j['running'] == true,
        last = j['last'] is Map ? ExposureRunData(_map(j['last'])) : null,
        history = [for (final e in _maps(j['history'])) (_time(e['at']), _int(e['findings']))];
  final bool enabled, running;
  final List<ExposureTarget> targets;
  final List<int> extraPorts;
  final int intervalDays;
  final ExposureRunData? last;
  final List<(DateTime?, int)> history;
}

/// PUT body of the outside-view settings.
Map<String, dynamic> exposureBody({required bool enabled, required List<ExposureTarget> targets, required List<int> extraPorts, required int intervalDays}) =>
    {'enabled': enabled, 'targets': [for (final t in targets) t.toJson()], 'extraPorts': extraPorts, 'intervalDays': intervalDays};

/// An id for a new target ("example.org" → "domain-example-org"), unique among [taken].
String exposureTargetId(String kind, String value, Iterable<String> taken) {
  final slug = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  var base = '${kind == 'ip' ? 'ip' : 'domain'}-${slug.isEmpty ? 'x' : slug}';
  if (base.length > 60) base = base.substring(0, 60);
  var id = base, n = 2;
  while (taken.contains(id)) {
    id = '$base-${n++}';
  }
  return id;
}

final _hostRe = RegExp(r'^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(\.(?!-)[A-Za-z0-9-]{1,63})*$');
final _ipv4Re = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

bool validExposureValue(String kind, String v) {
  if (kind == 'ip') return _ipv4Re.hasMatch(v) && v.split('.').every((p) => int.parse(p) <= 255);
  return _hostRe.hasMatch(v) && !_ipv4Re.hasMatch(v);
}

/// "22, 443" → [22, 443]; null if anything is not a port number.
List<int>? parsePortList(String text) {
  final out = <int>[];
  for (final p in text.split(RegExp(r'[,\s]+')).where((p) => p.isNotEmpty)) {
    final n = int.tryParse(p);
    if (n == null || n < 1 || n > 65535) return null;
    if (!out.contains(n)) out.add(n);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// S-5 attacks (Cloudflare)

class Offender {
  Offender(Map<String, dynamic> j)
      : zone = '${j['zone']}',
        ip = '${j['ip']}',
        country = '${j['country'] ?? ''}',
        errors = _int(j['errors']),
        scannerHits = _int(j['scannerHits']),
        paths = _strs(j['paths']),
        firstSeenAt = _time(j['firstSeenAt']),
        lastSeenAt = _time(j['lastSeenAt']),
        blockedUntil = _time(j['blockedUntil']);
  final String zone, ip, country;
  final int errors, scannerHits;
  final List<String> paths;
  final DateTime? firstSeenAt, lastSeenAt, blockedUntil;
}

class AttacksData {
  AttacksData(Map<String, dynamic> j)
      : configured = j['configured'] == true,
        hasRun = j['lastRun'] is Map,
        lastRunAt = _time(_map(j['lastRun'])['at']),
        zones = _int(_map(j['lastRun'])['zones']),
        error = _str(_map(j['lastRun'])['error']),
        offenders = [for (final e in _maps(j['offenders'])) Offender(e)];
  final bool configured, hasRun;
  final DateTime? lastRunAt;
  final int zones;

  /// Agent error code of the last run.
  final String? error;
  final List<Offender> offenders;
}

class CloudflareConfig {
  CloudflareConfig(Map<String, dynamic> j)
      : hasReadToken = j['hasReadToken'] == true,
        hasBlockToken = j['hasBlockToken'] == true,
        block = j['block'] == true,
        blockHours = _int(j['blockHours'], 24),
        zones = _strs(j['zones']),
        allowIps = _strs(j['allowIps']);
  final bool hasReadToken, hasBlockToken, block;
  final int blockHours;
  final List<String> zones, allowIps;
}

final _allowIpRe = RegExp(r'^[0-9a-fA-F:.]{3,45}$');
bool validAllowIp(String v) => _allowIpRe.hasMatch(v);

// ---------------------------------------------------------------------------------------------------------------------
// S-4 black box

class BlackboxStatus {
  BlackboxStatus(Map<String, dynamic> j)
      : mode = '${j['mode']}',
        count = j['head'] is Map ? _int(_map(j['head'])['count']) : null,
        hash = _str(_map(j['head'])['hash']),
        pending = j['pending'] is num ? (j['pending'] as num).toInt() : null,
        lastError = _str(j['lastError']),
        lastSentAt = _time(j['lastSentAt']),
        url = _str(j['url']);

  /// off | local | push (read by the agent at start).
  final String mode;
  final int? count, pending;
  final String? hash, lastError, url;
  final DateTime? lastSentAt;
}

class BlackboxAnchor {
  BlackboxAnchor(Map<String, dynamic> j)
      : date = '${j['date']}',
        count = _int(j['count']),
        hash = '${j['hash'] ?? ''}',
        telegram = j['telegram'] == true;
  final String date, hash;
  final int count;
  final bool telegram;
}

class BlackboxVerify {
  BlackboxVerify(Map<String, dynamic> j)
      : ok = j['ok'] == true,
        count = _int(j['count']),
        head = '${j['head'] ?? ''}',
        brokenAt = j['brokenAt'] is num ? (j['brokenAt'] as num).toInt() : null,
        reason = _str(j['reason']),
        anchors = [for (final e in _maps(j['anchors'])) BlackboxAnchor(e)],
        anchorMismatch = _strs(j['anchorMismatch']);
  final bool ok;
  final int count;
  final String head;
  final int? brokenAt;

  /// sequence | link | hash | truncated | unreadable
  final String? reason;
  final List<BlackboxAnchor> anchors;

  /// Dates of anchors that are no longer in the chain.
  final List<String> anchorMismatch;

  bool get trustworthy => ok && anchorMismatch.isEmpty;
}

class BlackboxRecord {
  BlackboxRecord(Map<String, dynamic> j)
      : seq = _int(j['seq']),
        at = _time(j['at']),
        source = '${j['source'] ?? ''}',
        kind = '${j['kind']}',
        data = _map(j['data']);
  final int seq;
  final DateTime? at;
  final String source, kind;
  final Map<String, dynamic> data;

  /// What the record says, as plain text: audit "METHOD /path", event key, lockdown action.
  String get summary {
    String d(String k) => '${data[k] ?? ''}';
    return switch (kind) {
      'audit' => '${d('method')} ${d('path')}'.trim(),
      'event' => d('key'),
      'lockdown' => d('action'),
      _ => kind,
    };
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// S-4 lost phone

class RecoveryStatus {
  RecoveryStatus(Map<String, dynamic> j)
      : configured = j['configured'] == true,
        createdAt = _time(j['createdAt']);
  final bool configured;
  final DateTime? createdAt;
}

class LockdownTarget {
  LockdownTarget(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        url = '${j['url']}',
        hasToken = j['hasToken'] == true;
  final String id, name, url;
  final bool hasToken;
}

class LockdownResult {
  LockdownResult(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        ok = j['ok'] == true,
        status = j['status'] is num ? (j['status'] as num).toInt() : null;
  final String id, name;
  final bool ok;

  /// HTTP status of the target (null = unreachable).
  final int? status;
}

/// Groups of 5 characters, upper-case, dashes where the agent has them ("ABCDE-FGHJK-…"): what is typed into the field.
String normalizeRecoveryInput(String v) => v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// The agent's code is 25 characters (5 groups of 5).
bool recoveryCodeComplete(String v) => normalizeRecoveryInput(v).length == 25;

/// "ABCDEFGHJKLMNPQRSTUVWXYZ2" → "ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2"
String formatRecoveryCode(String v) {
  final n = normalizeRecoveryInput(v);
  return [for (var i = 0; i < n.length; i += 5) n.substring(i, i + 5 > n.length ? n.length : i + 5)].join('-');
}

/// Anonymous POST of the lost-phone lockdown to [url] (no token): the response is the agent's `{ok, targets}`.
typedef LockdownCall = Future<List<LockdownResult>> Function(String url, String code);

final lockdownCallProvider = Provider<LockdownCall>((ref) => (url, code) async {
      final base = url.trim();
      // The recovery code is a secret: never over plain http.
      if (Uri.tryParse(base)?.scheme != 'https') throw const AgentError('agent.security.lockdownHttps');
      final c = AgentClient(baseUrl: base, token: '', timeout: const Duration(seconds: 60));
      try {
        final j = await c.request('POST', '/v1/security/lockdown', body: {'code': code}, timeout: const Duration(seconds: 90));
        return [for (final e in _maps(_map(j)['targets'])) LockdownResult(e)];
      } finally {
        c.close();
      }
    });

/// The monitoring server's URL as the phone knows it: the first agent with the feature (prefilled in the lockdown form).
String? lockdownUrlFor(List<Host> agents) => agents.map((h) => h.agent?.url).nonNulls.firstOrNull;

// ---------------------------------------------------------------------------------------------------------------------
// Home entries

const securitySections = ['vulns', 'secrets', 'traps', 'exposure', 'attacks', 'blackbox', 'recovery'];

/// With a single agent the sections open on it; with several the screens list every agent.
String? securitySectionAgent(List<Host> agents) => agents.length == 1 ? agents.single.id : null;

/// `GET /v1/security/hosts` → traps flag per SSH host (id → on). Reads the config model of S-1.
Map<String, bool> sshTrapFlags(SecuritySettings s) => {for (final h in s.hosts) if (h.isSsh) h.id: h.traps};
