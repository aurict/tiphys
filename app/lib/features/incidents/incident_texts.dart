// Texts of the incident room (PLAN.md §13.1): titles from the signal key, action names, hints, error codes.
// Pure functions of the localizations, shared by the screens, the notifications and agentErrorText.
import '../../l10n/gen/app_localizations.dart';

/// Kind family of a signal key (the chips of the list): container, service, disk, site, alert, backup, host, other.
String incidentFamily(String kind) => switch (kind) {
      final k when k.startsWith('docker.') => 'container',
      'service.failed' || 'service.recovered' => 'service',
      'disk.full' || 'disk.ok' => 'disk',
      final k when k.startsWith('uptime.') => 'site',
      final k when k.startsWith('grafana.') => 'alert',
      final k when k.startsWith('backup.') => 'backup',
      final k when k.startsWith('host.') => 'host',
      _ => 'other',
    };

const incidentFamilies = ['container', 'service', 'disk', 'site', 'alert', 'backup', 'host', 'other'];

String incidentFamilyName(AppLocalizations l, String family) => switch (family) {
      'container' => l.incKindContainer,
      'service' => l.incKindService,
      'disk' => l.incKindDisk,
      'site' => l.incKindSite,
      'alert' => l.incKindAlert,
      'backup' => l.incKindBackup,
      'host' => l.incKindHost,
      _ => l.incKindOther,
    };

/// "Container crashed: web" from the key of the first signal and its target.
String incidentTitle(AppLocalizations l, String kind, String target) => switch (kind) {
      'docker.died' => l.incTitleDockerDied(target),
      'docker.oom' => l.incTitleDockerOom(target),
      'docker.unhealthy' => l.incTitleUnhealthy(target),
      'docker.restartLoop' => l.incTitleRestartLoop(target),
      'disk.full' => l.incTitleDisk(target),
      'service.failed' => l.incTitleService(target),
      'grafana.alert' => l.incTitleAlert(target),
      'host.offline' => l.incTitleHost(target),
      'backup.failed' || 'backup.stale' => l.incTitleBackup(target),
      'uptime.down' => l.incTitleSite(target),
      _ => l.incTitleOther(kind, target),
    };

/// Name of an action kind (container.restart, compose.recreate, unit.restart).
String incidentActionName(AppLocalizations l, String kind) => switch (kind) {
      'container.restart' => l.incActionKindRestart,
      'compose.recreate' => l.incActionKindRecreate,
      'unit.restart' => l.incActionKindUnit,
      'compose.rollback' => l.incActionKindRollback,
      'disk.cleanup' => l.incActionKindCleanup,
      _ => kind,
    };

/// One-line label of an action candidate: "Restart container web".
String incidentActionLabel(AppLocalizations l, String kind, Map<String, dynamic> target) {
  String s(String k) => '${target[k] ?? ''}';
  return switch (kind) {
    'container.restart' => l.incActionRestart(s('container')),
    'compose.recreate' => l.incActionRecreate(s('service')),
    'unit.restart' => l.incActionUnit(s('unit')),
    'compose.rollback' => l.incActionRollback(s('service')),
    'disk.cleanup' => l.incActionCleanup(s('mount')),
    _ => l.incActionOther(kind, target.values.join(' ')),
  };
}

/// Who did it: "device:ab12" → "device ab12", "auto" → "automatic".
String incidentActor(AppLocalizations l, String by) => switch (by) {
      'auto' => l.incActorAuto,
      'agent' => l.incActorAgent,
      final b when b.startsWith('device:') => l.incActorDevice(b.substring(7)),
      _ => by,
    };

/// Rule-based hint → sentence. Plain text from the agent's code and params, never model output.
String incidentHintText(AppLocalizations l, String code, Map<String, dynamic> p) {
  String s(String k) => '${p[k] ?? ''}';
  return switch (code) {
    'oom' => l.incHintOom,
    'exitCode' => l.incHintExitCode(s('exitCode')),
    'restartLoop' => p['restartCount'] is num ? l.incHintRestartLoopCount((p['restartCount'] as num).toInt()) : l.incHintRestartLoop,
    'unhealthy' => l.incHintUnhealthy,
    'recentDeploy' => l.incHintRecentDeploy(s('image')),
    'diskFull' => l.incHintDiskFull(s('mount'), (p['percent'] as num?)?.round() ?? 0),
    'portInUse' => l.incHintPortInUse,
    'portUnreachable' => l.incHintPortUnreachable,
    _ => l.incHintUnknown(code),
  };
}

/// agent.incident.* and agent.preview.invalid → text.
String incidentErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
      'agent.incident.notFound' => l.errIncNotFound,
      'agent.incident.action.notFound' => l.errIncActionNotFound,
      'agent.incident.badState' => l.errIncBadState('${params['status'] ?? ''}'),
      'agent.incident.confirmRequired' => l.errIncConfirmRequired,
      'agent.incident.actionRunning' => l.errIncActionRunning,
      'agent.incident.actionUnavailable' => l.errIncActionUnavailable,
      'agent.incident.rateLimited' => l.errIncRateLimited,
      'agent.incident.analysisUnavailable' => l.incAnalyzeSoon,
      'agent.incident.analysisOff' => l.errIncAnalysisOff,
      'agent.incident.analysisRateLimited' => l.errIncAnalysisRateLimited((params['limit'] as num?)?.toInt() ?? 3, ((params['windowSeconds'] as num?)?.toInt() ?? 600) ~/ 60),
      'agent.incident.bundleRateLimited' => l.errIncBundleRateLimited,
      'agent.incident.cleanupOptionUnavailable' => l.errIncCleanupOption(cleanupOptionName(l, '${params['option'] ?? ''}')),
      'agent.preview.invalid' => l.errPreviewInvalid,
      _ => '${l.commonError} ($code)',
    };

/// Name of a disk.cleanup option.
String cleanupOptionName(AppLocalizations l, String option) => switch (option) {
      'builder' => l.incCleanBuilder,
      'images' => l.incCleanImages,
      'containers' => l.incCleanContainers,
      'userJournal' => l.incCleanUserJournal,
      'systemJournal' => l.incCleanSystemJournal,
      _ => option,
    };

/// What an option does, in one line (never `-a`; volumes are never touched).
String cleanupOptionHint(AppLocalizations l, String option) => switch (option) {
      'builder' => l.incCleanBuilderHint,
      'images' => l.incCleanImagesHint,
      'containers' => l.incCleanContainersHint,
      'userJournal' => l.incCleanUserJournalHint,
      _ => '',
    };

/// Why an option can't be chosen.
String cleanupReasonText(AppLocalizations l, String? reason) => switch (reason) {
      'needsRoot' => l.incCleanNeedsRoot,
      'noUserJournal' => l.incCleanNoUserJournal,
      'noDocker' => l.incCleanNoDocker,
      _ => l.incCleanUnavailable,
    };

/// `details.warnings` code → text.
String previewWarningText(AppLocalizations l, String code) => switch (code) {
      'dbMigrationsNotReverted' => l.incWarnDbMigrations,
      _ => code,
    };

/// Why a job failed (`agent.analysis.*` error code of the job).
String analysisFailedText(AppLocalizations l, String? code) => switch (code) {
      'agent.analysis.toolMissing' => l.incAiErrToolMissing,
      'agent.analysis.toolFailed' => l.incAiErrToolFailed,
      'agent.analysis.invalidOutput' => l.incAiErrInvalidOutput,
      'agent.analysis.timeout' => l.incAiErrTimeout,
      'agent.analysis.cancelled' => l.incAiErrCancelled,
      'agent.analysis.interrupted' => l.incAiErrInterrupted,
      _ => l.incAiErrOther,
    };

/// Why the analysis PC could not answer (`reason` of an unavailable analysis).
String analysisReasonText(AppLocalizations l, String? reason) => switch (reason) {
      'unreachable' => l.incAiReasonUnreachable,
      'unauthorized' => l.incAiReasonUnauthorized,
      'busy' => l.incAiReasonBusy,
      'rejected' => l.incAiReasonRejected,
      'badResponse' => l.incAiReasonBadResponse,
      'timeout' => l.incAiReasonTimeout,
      'lost' => l.incAiReasonLost,
      _ => l.incAiErrOther,
    };

/// Label of an evidence chip from the evidence id (`log:docker#12` → "Log line 12"). Unknown forms show the id itself.
String evidenceRefLabel(AppLocalizations l, String ref) {
  final colon = ref.indexOf(':');
  if (colon <= 0) return ref;
  final kind = ref.substring(0, colon), rest = ref.substring(colon + 1);
  return switch (kind) {
    'log' when rest.contains('#') => l.incEvLog(rest.substring(rest.lastIndexOf('#') + 1)),
    'signal' => l.incEvSignal(rest),
    'inspect' => l.incEvContainer,
    'deploy' => l.incEvDeploy(rest),
    'event' => l.incEvEvent(rest),
    'config' => l.incEvConfig(rest),
    'git' when rest == 'status' => l.incEvGitStatus,
    'git' => l.incEvGit(rest.length > 7 ? rest.substring(0, 7) : rest),
    'metric' => l.incEvMetric(rest),
    _ => ref,
  };
}

/// Title of a metric series (`host.memPct`, `disk:/`, `container.cpu`, …).
String metricTitle(AppLocalizations l, String name) => switch (name) {
      'host.cpu' => l.incMetricHostCpu,
      'host.load1' => l.incMetricHostLoad,
      'host.memPct' => l.incMetricHostMem,
      'host.swapPct' => l.incMetricHostSwap,
      'container.cpu' => l.incMetricContainerCpu,
      'container.memPct' => l.incMetricContainerMem,
      'container.memMB' => l.incMetricContainerMemMb,
      final n when n.startsWith('disk:') => l.incMetricDisk(n.substring(5)),
      _ => name,
    };
