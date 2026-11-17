// Incident room data (PLAN.md §13.1, phase I-1): models of the agent's /v1/incidents responses, providers that gather
// them from every agent with the `incidents` feature, and the pure helpers (filtering, grouping, preview expiry).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../state/providers.dart';
import '../system/agent_providers.dart';
import 'incident_analysis.dart';
import 'incident_texts.dart';

/// The screens poll anyway (autoRefresh); no hidden retry loop on top of it.
Duration? _noRetry(int retryCount, Object error) => null;

const incidentStatuses = ['open', 'acknowledged', 'resolved'];

DateTime _time(Object? v) => DateTime.tryParse('$v')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];

/// One row of the list (the agent's summary; also parsed from a full incident).
class IncidentSummary {
  IncidentSummary(this.host, Map<String, dynamic> j)
      : id = '${j['id']}',
        status = '${j['status']}',
        severity = '${j['severity']}',
        kind = '${j['kind']}',
        target = '${j['target']}',
        stack = j['stack'] as String?,
        service = j['service'] as String?,
        openedAt = _time(j['openedAt']),
        updatedAt = _time(j['updatedAt']),
        lastSignalAt = _time(j['lastSignalAt']),
        resolvedAt = _timeOrNull(j['resolvedAt']),
        signalCount = (j['signalCount'] as num?)?.toInt() ?? 0,
        resolutionNote = j['resolutionNote'] as String?,
        workedAction = j['workedAction'] as String?,
        test = j['test'] == true;
  final Host host;
  final String id;
  final String status;
  final String severity;

  /// Key of the first signal (docker.died, …).
  final String kind;
  final String target;
  final String? stack;
  final String? service;
  final DateTime openedAt;
  final DateTime updatedAt;
  final DateTime lastSignalAt;
  final DateTime? resolvedAt;
  final int signalCount;
  final String? resolutionNote;
  final String? workedAction;
  final bool test;

  String get family => incidentFamily(kind);

  /// The moment the row is sorted and grouped by: the resolution for a resolved incident, else the last signal.
  DateTime get sortTime => status == 'resolved' ? (resolvedAt ?? updatedAt) : lastSignalAt;
}

/// Tab filter + host chip + kind chip. [hostId] / [family] null = all.
List<IncidentSummary> filterIncidents(List<IncidentSummary> all, {required String status, String? hostId, String? family}) => [
      for (final i in all)
        if (i.status == status && (hostId == null || i.host.id == hostId) && (family == null || i.family == family)) i,
    ]..sort(compareIncidents);

/// Critical before warning (while unresolved), then newest first.
int compareIncidents(IncidentSummary a, IncidentSummary b) {
  if (a.status != 'resolved' && a.severity != b.severity) return a.severity == 'critical' ? -1 : 1;
  return b.sortTime.compareTo(a.sortTime);
}

/// Incidents of one calendar day (local time).
class IncidentDay {
  IncidentDay(this.day, this.items);
  final DateTime day;
  final List<IncidentSummary> items;
}

/// Groups an already sorted list by the day of [IncidentSummary.sortTime], keeping the order.
List<IncidentDay> groupIncidentsByDay(List<IncidentSummary> sorted) {
  final out = <IncidentDay>[];
  for (final i in sorted) {
    final d = DateTime(i.sortTime.year, i.sortTime.month, i.sortTime.day);
    if (out.isEmpty || out.last.day != d) out.add(IncidentDay(d, []));
    out.last.items.add(i);
  }
  return out;
}

class IncidentsFeed {
  const IncidentsFeed({required this.incidents, required this.errors, required this.hosts});
  final List<IncidentSummary> incidents;

  /// Hosts whose list couldn't be fetched (hostId → error); the others are still shown.
  final Map<String, Object> errors;

  /// Hosts whose agent reports the `incidents` feature.
  final List<Host> hosts;

  int count(String status) => incidents.where((i) => i.status == status).length;
}

/// Agent hosts whose health response lists the `incidents` feature.
final incidentHostsProvider = FutureProvider.autoDispose<List<Host>>(retry: _noRetry, (ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final checked = await Future.wait(hosts.map((h) async {
    try {
      final j = await ref.watch(healthProvider(h.id).future);
      return (j['features'] as Map?)?['incidents'] == true ? h : null;
    } catch (_) {
      return null;
    }
  }));
  return [...checked.nonNulls];
});

/// Incidents of all hosts with the feature, in parallel. One host's error doesn't break the others.
final incidentsFeedProvider = FutureProvider.autoDispose<IncidentsFeed>(retry: _noRetry, (ref) async {
  autoRefresh(ref, const Duration(seconds: 30));
  final hosts = await ref.watch(incidentHostsProvider.future);
  final results = await Future.wait(hosts.map((h) async {
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/incidents', query: {'limit': '200'})).timeout(const Duration(seconds: 15));
      return (h, [for (final e in _maps(j['incidents'])) IncidentSummary(h, e)], null as Object?);
    } catch (e) {
      return (h, const <IncidentSummary>[], e as Object?);
    }
  }));
  return IncidentsFeed(
    incidents: [for (final r in results) ...r.$2],
    errors: {for (final r in results) if (r.$3 != null) r.$1.id: r.$3!},
    hosts: hosts,
  );
});

class TimelineItem {
  TimelineItem(Map<String, dynamic> j)
      : at = _time(j['at']),
        type = '${j['type']}',
        by = j['by'] as String?,
        key = j['key'] as String?,
        text = j['text'] as String?,
        data = _map(j['data']);
  final DateTime at;
  final String type;
  final String? by;
  final String? key;
  final String? text;
  final Map<String, dynamic> data;
}

class HintItem {
  HintItem(Map<String, dynamic> j)
      : code = '${j['code']}',
        params = _map(j['params']),
        evidence = [for (final e in (j['evidence'] as List? ?? const [])) '$e'];
  final String code;
  final Map<String, dynamic> params;
  final List<String> evidence;
}

/// The full incident: summary + timeline, hints and the collected context.
class IncidentDetail {
  IncidentDetail(this.host, Map<String, dynamic> j, {this.responseSimilar})
      : summary = IncidentSummary(host, j),
        analysis = j['analysis'] is Map ? IncidentAnalysis(_map(j['analysis'])) : null,
        resolvedBy = j['resolvedBy'] as String?,
        acknowledgedAt = _timeOrNull(j['acknowledgedAt']),
        timeline = [for (final e in _maps(j['timeline'])) TimelineItem(e)],
        hints = [for (final e in _maps(j['hints'])) HintItem(e)],
        signalEntries = (j['signals'] as List?)?.length ?? 0,
        context = j['context'] is Map ? _map(j['context']) : null;
  final Host host;
  final IncidentSummary summary;
  final String? resolvedBy;
  final DateTime? acknowledgedAt;
  final List<TimelineItem> timeline;
  final List<HintItem> hints;

  /// Number of signals the agent kept on the incident (the bundle's `signal:<n>` ids count into it).
  final int signalEntries;

  /// The AI analysis (I-3), null when none was ever requested.
  final IncidentAnalysis? analysis;

  /// `similar` of the GET response (recomputed on every read), null when the response had none.
  final List<Map<String, dynamic>>? responseSimilar;

  /// Collected context (logs, inspect, git, metrics, events, similar, errors); null while it is being collected.
  final Map<String, dynamic>? context;

  Map<String, dynamic>? get logs => context?['logs'] is Map ? _map(context!['logs']) : null;
  Map<String, dynamic>? get inspect => context?['inspect'] is Map ? _map(context!['inspect']) : null;
  Map<String, dynamic>? get git => context?['git'] is Map ? _map(context!['git']) : null;
  List<Map<String, dynamic>> get events => _maps(context?['events']);

  /// Similar incidents: the response's own `similar` (recomputed on every read), else the ones collected with the context.
  List<Map<String, dynamic>> get similar => responseSimilar ?? _maps(context?['similar']);

  /// Metrics ring excerpt around the opening (host samples and the container's), null when the agent has none.
  Map<String, dynamic>? get metrics => context?['metrics'] is Map ? _map(context!['metrics']) : null;
  Map<String, dynamic> get errors => _map(context?['errors']);

  /// What an evidence id of the analysis can point at, from the collected context.
  EvidenceIndex get evidenceIndex => EvidenceIndex(
        logLines: (logs?['lines'] as List?)?.length ?? 0,
        deploys: deploys.length,
        events: events.length,
        configChanges: configChanges.length,
        signals: signalEntries,
        hasInspect: inspect != null,
        gitHashes: [for (final c in _maps(git?['log'])) '${c['hash']}'],
        hasGitStatus: ((git?['status'] as List?)?.isNotEmpty ?? false),
        metricNames: [for (final m in metricSeries(metrics)) m.name],
      );

  /// Deploys of the incident's compose project (last 7 days), newest first.
  List<DeployRecord> get deploys => [for (final e in _maps(context?['deploys'])) DeployRecord(e)];

  /// `config.saved` / `config.restored` of the last 48 hours; key names only.
  List<ConfigChangeRecord> get configChanges => [for (final e in _maps(context?['configChanges'])) ConfigChangeRecord(e)];
}

/// A record of the agent's deploy history: a service's image was first seen, or changed.
class DeployRecord {
  DeployRecord(Map<String, dynamic> j)
      : at = _time(j['at']),
        kind = '${j['kind']}',
        project = '${j['project'] ?? ''}',
        service = '${j['service'] ?? ''}',
        imageId = '${j['imageId'] ?? ''}',
        imageRef = '${j['imageRef'] ?? ''}',
        createdAt = _timeOrNull(j['createdAt']),
        prevImageId = j['prevImageId'] as String?,
        prevImageRef = j['prevImageRef'] as String?,
        rollbackTag = j['rollbackTag'] as String?;
  final DateTime at;

  /// seen (first time the agent saw the service) | changed (its image id changed)
  final String kind;
  final String project;
  final String service;
  final String imageId;
  final String imageRef;
  final DateTime? createdAt;
  final String? prevImageId;
  final String? prevImageRef;

  /// The `tiphys-rollback/…:prev` tag put on the previous image, null when there is none.
  final String? rollbackTag;

  bool get changed => kind == 'changed';

  /// Same deploy seen twice (context and history).
  String get identity => '${at.toUtc().toIso8601String()}|$project|$service|$imageId';
}

/// Both sources of an incident's deploys in one list: the history of its stack/service and the ones collected with it.
/// Duplicates are dropped; newest first.
List<DeployRecord> mergeDeploys(List<DeployRecord> history, List<DeployRecord> context) {
  final seen = <String>{};
  return [
    for (final d in [...history, ...context])
      if (seen.add(d.identity)) d,
  ]..sort((a, b) => b.at.compareTo(a.at));
}

/// An agent-made config change near an incident: which file, which keys (names only).
class ConfigChangeRecord {
  ConfigChangeRecord(Map<String, dynamic> j)
      : at = _time(j['at']),
        restored = j['key'] == 'config.restored',
        file = '${j['file'] ?? ''}',
        keys = [for (final k in (j['keys'] as List? ?? const [])) '$k'];
  final DateTime at;
  final bool restored;
  final String file;
  final List<String> keys;
}

/// Family key: (host id, stack, service); null filters are left out of the request.
typedef DeployFilter = (String, String?, String?);

/// GET /v1/incidents/deploys for a stack/service (empty without the `docker` feature on the agent).
final incidentDeploysProvider = FutureProvider.autoDispose.family<List<DeployRecord>, DeployFilter>(retry: _noRetry, (ref, key) async {
  final (hostId, stack, service) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/incidents/deploys', query: {'stack': ?stack, 'service': ?service, 'limit': '50'}));
  return [for (final e in _maps(j['deploys'])) DeployRecord(e)];
});

/// Hosts to look for an incident on: the one named by [hint] (a host id or the agent's host name) when it matches,
/// else every agent host (the notification doesn't say which app host sent it). `exact`: the hint matched.
({List<Host> hosts, bool exact}) incidentHostsFor(Profile p, String? hint) {
  final agents = p.hosts.where((h) => h.agent != null).toList();
  if (hint != null && hint.isNotEmpty) {
    final byId = agents.where((h) => h.id == hint).toList();
    if (byId.isNotEmpty) return (hosts: byId, exact: true);
    final lower = hint.toLowerCase();
    final byName = agents.where((h) => h.name.toLowerCase() == lower || h.name.toLowerCase().startsWith('$lower ')).toList();
    if (byName.length == 1) return (hosts: byName, exact: true);
  }
  return (hosts: agents, exact: false);
}

/// Family key: (incident id, host hint).
typedef IncidentRef = (String, String?);

final incidentDetailProvider = FutureProvider.autoDispose.family<IncidentDetail, IncidentRef>(retry: _noRetry, (ref, key) async {
  autoRefresh(ref, const Duration(seconds: 10));
  final (id, hint) = key;
  final found = incidentHostsFor(ref.watch(profileProvider), hint);
  Object? error;
  for (final h in found.hosts) {
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/incidents/$id'));
      return IncidentDetail(h, _map(j['incident']), responseSimilar: j['similar'] is List ? _maps(j['similar']) : null);
    } on AgentError catch (e) {
      // An exact host's error is the answer; while searching, keep the most informative one (not found beats the rest).
      if (found.exact) rethrow;
      final cur = error;
      if (cur is! AgentError || cur.code != 'agent.incident.notFound') error = e;
    }
  }
  throw error ?? const AgentError('agent.incident.notFound');
});

/// `incidents.analysis.mode` of a host from GET /v1/config: local | remote | off; null when it can't be read (then the
/// analyze button is shown and the agent's own 409 answers).
final incidentAnalysisModeProvider = FutureProvider.autoDispose.family<String?, String>(retry: _noRetry, (ref, hostId) async {
  try {
    final j = await withAgent(ref, hostId, (c) => c.get('/v1/config')).timeout(const Duration(seconds: 10));
    final mode = _map(_map(_map(j)['incidents'])['analysis'])['mode'];
    return mode is String ? mode : null;
  } catch (_) {
    return null;
  }
});

/// An action the agent offers for an incident.
class ActionCandidate {
  ActionCandidate(Map<String, dynamic> j)
      : id = '${j['id']}',
        kind = '${j['kind']}',
        target = _map(j['target']),
        risk = '${j['risk']}';
  final String id;
  final String kind;
  final Map<String, dynamic> target;
  final String risk;
}

class IncidentActions {
  IncidentActions(Map<String, dynamic> j)
      : actions = [for (final e in _maps(j['actions'])) ActionCandidate(e)],
        running = j['running'] as String?;
  final List<ActionCandidate> actions;

  /// Id of the candidate running right now (one at a time per incident), else null.
  final String? running;
}

final incidentActionsProvider = FutureProvider.autoDispose.family<IncidentActions, (String, String)>(retry: _noRetry, (ref, key) async {
  autoRefresh(ref, const Duration(seconds: 10));
  final (hostId, id) = key;
  return IncidentActions(await withAgent(ref, hostId, (c) => c.get('/v1/incidents/$id/actions')));
});

class PreviewStep {
  PreviewStep(Map<String, dynamic> j)
      : argv = [for (final a in (j['argv'] as List? ?? const [])) '$a'],
        cwd = j['cwd'] as String?;
  final List<String> argv;
  final String? cwd;
}

/// A preview token lives 120 s on the agent and works once.
const previewLifetime = Duration(seconds: 120);

/// When a preview token stops working, on this phone's clock. Uses the agent's expiry; if the phone's clock is far off
/// from the agent's (the expiry is already past or further ahead than a token lives), counts the nominal lifetime from
/// receipt instead. The agent has the last word anyway (agent.preview.invalid).
DateTime previewDeadline(DateTime? expiresAt, DateTime receivedAt) {
  if (expiresAt != null) {
    final left = expiresAt.difference(receivedAt);
    if (left > Duration.zero && left <= previewLifetime + const Duration(seconds: 10)) return expiresAt;
  }
  return receivedAt.add(previewLifetime);
}

/// One side of a rollback: an image id and when it was built.
class ImageRef {
  ImageRef(Map<String, dynamic> j)
      : imageId = '${j['imageId'] ?? ''}',
        created = _timeOrNull(j['created']);
  final String imageId;
  final DateTime? created;

  /// "9f8e7d6c5b4a": the id without `sha256:`, 12 characters.
  String get shortId => shortImageId(imageId);
}

String shortImageId(String id) {
  final bare = id.startsWith('sha256:') ? id.substring(7) : id;
  return bare.length > 12 ? bare.substring(0, 12) : bare;
}

/// `details.rollback` of a compose.rollback preview.
class RollbackDetails {
  RollbackDetails(Map<String, dynamic> j)
      : tag = '${j['tag'] ?? ''}',
        imageRef = '${j['imageRef'] ?? ''}',
        current = ImageRef(_map(j['current'])),
        previous = ImageRef(_map(j['previous']));
  final String tag;
  final String imageRef;
  final ImageRef current;
  final ImageRef previous;
}

/// One disk.cleanup option with its estimate.
class CleanupOption {
  CleanupOption(Map<String, dynamic> j)
      : option = '${j['option']}',
        available = j['available'] == true,
        reason = j['reason'] as String?,
        reclaimableBytes = (j['reclaimableBytes'] as num?)?.toInt(),
        usageBytes = (j['usageBytes'] as num?)?.toInt();
  final String option;
  final bool available;

  /// needsRoot | noUserJournal | noDocker
  final String? reason;

  /// Estimated bytes freed; null when unknown.
  final int? reclaimableBytes;
  final int? usageBytes;
}

/// `details.cleanup` of a disk.cleanup preview.
class CleanupDetails {
  CleanupDetails(Map<String, dynamic> j)
      : options = [for (final e in _maps(j['options'])) CleanupOption(e)],
        selected = [for (final s in (j['selected'] as List? ?? const [])) '$s'];
  final List<CleanupOption> options;

  /// The options the preview was made for (by default every available one).
  final List<String> selected;

  /// Estimated bytes of the selected options; null when none of them has an estimate.
  int? get selectedBytes => estimateTotal(options, selected.toSet());
}

/// Sum of the estimates of the chosen, available options; null when none of them has one.
int? estimateTotal(List<CleanupOption> options, Set<String> chosen) {
  int? total;
  for (final o in options) {
    if (o.available && chosen.contains(o.option) && o.reclaimableBytes != null) total = (total ?? 0) + o.reclaimableBytes!;
  }
  return total;
}

class ActionPreview {
  ActionPreview(Map<String, dynamic> j, DateTime receivedAt)
      : steps = [for (final s in _maps(j['steps'])) PreviewStep(s)],
        risk = '${j['risk']}',
        token = '${j['previewToken']}',
        deadline = previewDeadline(_timeOrNull(j['expiresAt']), receivedAt),
        rollback = _map(j['details'])['rollback'] is Map ? RollbackDetails(_map(_map(j['details'])['rollback'])) : null,
        cleanup = _map(j['details'])['cleanup'] is Map ? CleanupDetails(_map(_map(j['details'])['cleanup'])) : null,
        warnings = [for (final w in (_map(j['details'])['warnings'] as List? ?? const [])) '$w'];
  final List<PreviewStep> steps;
  final String risk;
  final String token;

  /// When the token stops working, on this phone's clock.
  final DateTime deadline;

  /// compose.rollback: the images involved.
  final RollbackDetails? rollback;

  /// disk.cleanup: the options and their estimates.
  final CleanupDetails? cleanup;

  /// Codes of `details.warnings` (dbMigrationsNotReverted).
  final List<String> warnings;

  Duration remaining(DateTime now) {
    final d = deadline.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  bool expired(DateTime now) => remaining(now) == Duration.zero;
}

/// "2:05": the preview countdown.
String formatCountdown(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// A command for display: arguments with spaces or shell characters are single-quoted. Display only; the agent runs
/// the argv without a shell.
String formatArgv(List<String> argv) =>
    argv.map((a) => a.isEmpty || RegExp(r'[^A-Za-z0-9_@%+=:,./-]').hasMatch(a) ? "'${a.replaceAll("'", r"'\''")}'" : a).join(' ');

/// Result of an executed action.
class ActionResult {
  ActionResult(Map<String, dynamic> j)
      : ok = j['ok'] == true,
        code = '${j['code'] ?? ''}',
        stderr = j['stderr'] as String?;
  final bool ok;
  final String code;
  final String? stderr;
}
