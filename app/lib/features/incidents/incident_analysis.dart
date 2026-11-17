// AI analysis of an incident (PLAN.md §13.1, phase I-3): the models of `incident.analysis`, the polling rule while a
// job is queued or running, and how an evidence reference of a hypothesis maps to something on screen. The
// widgets are in incident_analysis_view.dart (only the poller looks at the app lifecycle). All model text is plain text: the agent already strips markdown/links,
// and the app never renders it as anything else.
import 'dart:async';

import '../../core/util/refresh.dart' show appVisible;

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : const [];
DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

class Hypothesis {
  Hypothesis(Map<String, dynamic> j)
      : cause = '${j['cause'] ?? ''}',
        confidence = ((j['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        evidenceRefs = [for (final e in (j['evidenceRefs'] as List? ?? const [])) '$e'],
        unsupported = j['unsupported'] == true;
  final String cause;

  /// 0..1
  final double confidence;
  final List<String> evidenceRefs;

  /// No valid evidence reference: shown with a "kanıtsız" badge.
  final bool unsupported;
}

class SuggestedAction {
  SuggestedAction(Map<String, dynamic> j)
      : candidateId = '${j['candidateId'] ?? ''}',
        kind = '${j['kind'] ?? ''}',
        why = '${j['why'] ?? ''}';

  /// One of the agent's own candidates (the model can only pick, never invent).
  final String candidateId;
  final String kind;
  final String why;
}

class AnalysisResult {
  AnalysisResult(Map<String, dynamic> j)
      : summary = '${j['summary'] ?? ''}',
        hypotheses = [for (final e in _maps(j['hypotheses'])) Hypothesis(e)],
        suggestedActions = [for (final e in _maps(j['suggestedActions'])) SuggestedAction(e)],
        questions = [for (final e in (j['questions'] as List? ?? const [])) '$e'];
  final String summary;
  final List<Hypothesis> hypotheses;
  final List<SuggestedAction> suggestedActions;
  final List<String> questions;
}

/// `incident.analysis`: queued | running | done | failed | unavailable.
class IncidentAnalysis {
  IncidentAnalysis(Map<String, dynamic> j)
      : status = '${j['status']}',
        mode = '${j['mode'] ?? ''}',
        by = j['by'] as String?,
        requestedAt = _time(j['requestedAt']),
        finishedAt = _time(j['finishedAt']),
        result = j['result'] is Map ? AnalysisResult(_map(j['result'])) : null,
        errorCode = _map(j['error'])['code'] as String?,
        reason = j['reason'] as String?;
  final String status;
  final String mode;
  final String? by;
  final DateTime? requestedAt;
  final DateTime? finishedAt;
  final AnalysisResult? result;

  /// `agent.analysis.*` for a failed job, `agent.incident.analysis.<reason>` for an unavailable one.
  final String? errorCode;

  /// unreachable | unauthorized | busy | rejected | badResponse | timeout | lost (status `unavailable`)
  final String? reason;

  bool get active => status == 'queued' || status == 'running';
  bool get done => status == 'done' && result != null;
  bool get failed => status == 'failed';
  bool get unavailable => status == 'unavailable';
}

/// Polls while an analysis is queued or running and stops by itself as soon as it is not (done, failed, unavailable,
/// none) or after [maxPolls] ticks (the agent gives up after 5 minutes, so this is only a safety net). [sync] is called
/// with the analysis of every fresh read of the incident.
class AnalysisPoller {
  AnalysisPoller({required this.refresh, this.interval = const Duration(seconds: 3), this.maxPolls = 150, bool Function()? isVisible}) : isVisible = isVisible ?? (() => appVisible.value);
  final void Function() refresh;

  /// Is the app in the foreground (overridable in tests)?
  final bool Function() isVisible;
  final Duration interval;
  final int maxPolls;
  Timer? _timer;
  int _polls = 0;

  bool get polling => _timer != null;

  void sync(IncidentAnalysis? a) {
    if (a == null || !a.active) {
      stop();
      _polls = 0;
      return;
    }
    _timer ??= Timer.periodic(interval, (_) {
      // In the background nothing is asked (and the round doesn't count); the next tick after returning refreshes.
      if (!isVisible()) return;
      if (++_polls > maxPolls) return stop();
      refresh();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Where an evidence reference points: the tab to switch to and what to scroll to and highlight inside it.
class EvidenceTarget {
  const EvidenceTarget(this.tab, {this.kind, this.index, this.name});

  /// logs | container | deploys | git | events | timeline | metrics
  final String tab;

  /// log | deploy | event | config | git | metric (null = the whole tab)
  final String? kind;

  /// Zero-based position in the collected list (log line, deploy, event, config change).
  final int? index;

  /// Commit hash prefix or metric name.
  final String? name;

  @override
  bool operator ==(Object other) => other is EvidenceTarget && other.tab == tab && other.kind == kind && other.index == index && other.name == name;
  @override
  int get hashCode => Object.hash(tab, kind, index, name);
  @override
  String toString() => 'EvidenceTarget($tab, $kind, $index, $name)';
}

/// An [EvidenceTarget] to act on now. [nonce] changes on every tap so tapping the same chip twice scrolls again.
class EvidenceFocus {
  const EvidenceFocus(this.target, this.nonce);
  final EvidenceTarget target;
  final int nonce;
}

/// The sizes of the collected lists an evidence id counts into (ids are 1-based positions in them).
class EvidenceIndex {
  const EvidenceIndex({this.logLines = 0, this.deploys = 0, this.events = 0, this.configChanges = 0, this.signals = 0, this.hasInspect = false, this.gitHashes = const [], this.hasGitStatus = false, this.metricNames = const []});
  final int logLines;
  final int deploys;
  final int events;
  final int configChanges;
  final int signals;
  final bool hasInspect;
  final List<String> gitHashes;
  final bool hasGitStatus;
  final List<String> metricNames;
}

/// Resolves an evidence id of the bundle (`log:SOURCE#LINE`, `signal:N`, `inspect:container`, `deploy:N`,
/// `event:N`, `metric:NAME`, `git:HASH`, `git:status`, `config:N`) against what the app has collected. null when
/// it does not point at anything the app shows (unknown form, number out of range, missing data).
EvidenceTarget? resolveEvidenceRef(String ref, EvidenceIndex idx) {
  final colon = ref.indexOf(':');
  if (colon <= 0) return null;
  final kind = ref.substring(0, colon), rest = ref.substring(colon + 1);
  int? n(String s) => RegExp(r'^[1-9][0-9]{0,5}$').hasMatch(s) ? int.parse(s) : null;
  switch (kind) {
    case 'log':
      final line = n(rest.substring(rest.lastIndexOf('#') + 1));
      return rest.contains('#') && line != null && line <= idx.logLines ? EvidenceTarget('logs', kind: 'log', index: line - 1) : null;
    case 'signal':
      final i = n(rest);
      return i != null && i <= idx.signals ? const EvidenceTarget('timeline') : null;
    case 'inspect':
      return rest == 'container' && idx.hasInspect ? const EvidenceTarget('container') : null;
    case 'deploy':
      final i = n(rest);
      return i != null && i <= idx.deploys ? EvidenceTarget('deploys', kind: 'deploy', index: i - 1) : null;
    case 'event':
      final i = n(rest);
      return i != null && i <= idx.events ? EvidenceTarget('events', kind: 'event', index: i - 1) : null;
    case 'config':
      final i = n(rest);
      return i != null && i <= idx.configChanges ? EvidenceTarget('deploys', kind: 'config', index: i - 1) : null;
    case 'git':
      if (rest == 'status') return idx.hasGitStatus ? const EvidenceTarget('git', kind: 'git') : null;
      final hit = idx.gitHashes.where((h) => rest.isNotEmpty && h.startsWith(rest)).firstOrNull;
      return hit == null ? null : EvidenceTarget('git', kind: 'git', name: hit);
    case 'metric':
      return idx.metricNames.contains(rest) ? EvidenceTarget('metrics', kind: 'metric', name: rest) : null;
  }
  return null;
}

/// The names of the metric series the agent's bundle can reference (`metric:NAME`), in display order, for the
/// context's metrics ring excerpt: host.cpu, host.load1, host.memPct, host.swapPct, disk:MOUNT, container.*.
List<MetricSeries> metricSeries(Map<String, dynamic>? metrics) {
  if (metrics == null) return const [];
  final host = _maps(metrics['host']);
  final out = <MetricSeries>[];
  void add(String name, List<(double, double)> points) {
    if (points.length >= 2) out.add(MetricSeries(name, points));
  }

  List<(double, double)> hostSeries(num? Function(Map<String, dynamic>) f) => [
        for (final s in host)
          if (s['t'] is num && f(s) != null) ((s['t'] as num).toDouble(), f(s)!.toDouble()),
      ];
  add('host.cpu', hostSeries((s) => s['cpu'] as num?));
  add('host.load1', hostSeries((s) => s['load1'] as num?));
  add('host.memPct', hostSeries((s) => s['memPct'] as num?));
  add('host.swapPct', hostSeries((s) => s['swapPct'] as num?));
  final mounts = <String>{for (final s in host) for (final d in _maps(s['disks'])) '${d['mount']}'};
  for (final m in mounts.take(10)) {
    add('disk:$m', [
      for (final s in host)
        for (final d in _maps(s['disks']))
          if ('${d['mount']}' == m && s['t'] is num && d['pct'] is num) ((s['t'] as num).toDouble(), (d['pct'] as num).toDouble()),
    ]);
  }
  final samples = _maps(_map(metrics['container'])['samples']);
  List<(double, double)> cs(num? Function(Map<String, dynamic>) f) => [
        for (final s in samples)
          if (s['t'] is num && f(s) != null) ((s['t'] as num).toDouble(), f(s)!.toDouble()),
      ];
  add('container.cpu', cs((s) => s['cpu'] as num?));
  add('container.memPct', cs((s) => s['memPct'] as num?));
  add('container.memMB', cs((s) => s['memBytes'] is num ? (s['memBytes'] as num) / 1048576 : null));
  return out;
}

/// One metric of the incident's metrics tab: (time in epoch ms, value) points.
class MetricSeries {
  const MetricSeries(this.name, this.points);
  final String name;
  final List<(double, double)> points;
  double get min => points.map((p) => p.$2).reduce((a, b) => a < b ? a : b);
  double get max => points.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
  double get last => points.last.$2;
}
