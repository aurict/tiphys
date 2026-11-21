// Providers for agent data (per host). Metrics refresh every 5 s.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/refresh.dart';
import '../../core/agent/agent_client.dart';
import '../../core/push/push_service.dart' show telegramReasonText;
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../agy/agy_texts.dart';
import '../configfiles/configfiles_texts.dart';
import '../databases/db_texts.dart';
import '../screen/screen_texts.dart';
import '../screen/sleep/sleep_texts.dart' show sleepErrorText;
import '../incidents/incident_texts.dart';
import '../security/security_fix.dart' show fixErrorCodes, fixErrorText;
import '../security/security_texts.dart';
import 'agent_update.dart' show updateErrorText;

/// Overridden in tests.
final agentClientFactoryProvider = Provider<Future<AgentClient> Function(Host)>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  return (h) => AgentClient.forHost(h, secrets);
});

Future<T> withAgent<T>(Ref ref, String hostId, Future<T> Function(AgentClient c) body) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await body(c);
  } finally {
    c.close();
  }
}

/// One-off call (for buttons).
Future<dynamic> agentCall(WidgetRef ref, String hostId, String method, String path, [Object? body, Map<String, String>? headers]) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await c.request(method, path, body: body, headers: headers);
  } finally {
    c.close();
  }
}

final systemProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 5));
  return withAgent(ref, hostId, (c) => c.get('/v1/system'));
});

final servicesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, (String, String)>((ref, key) async {
  final (hostId, scope) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/services/$scope'));
  return (j['units'] as List).cast<Map<String, dynamic>>();
});

final containersProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 15));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/docker/containers'));
  return (j['containers'] as List).cast<Map<String, dynamic>>();
});

/// The agent's own status: version, uptime, memory, unexpected restarts (0.3.0+).
final agentStatusProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  return withAgent(ref, hostId, (c) => c.get('/v1/agent/status'));
});

/// Tokenless health check (overridden in tests).
final agentHealthFnProvider = Provider<Future<Map<String, dynamic>> Function(String url)>((ref) => AgentClient.health);

final healthProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  final h = ref.read(profileProvider).host(hostId);
  if (h?.agent == null) throw const AgentError('agent.notConfigured');
  return ref.read(agentHealthFnProvider)(h!.agent!.url);
});

/// PC metrics for the home screen (the Claude agent host or the first agent host).
final homeMetricsProvider = FutureProvider.autoDispose<(double, double)?>((ref) async {
  final p = ref.watch(profileProvider);
  final host = p.host(p.claude.agentHostId) ?? p.hosts.where((h) => h.agent != null).firstOrNull;
  if (host == null) return null;
  final s = await ref.watch(systemProvider(host.id).future);
  final cpu = ((s['cpu'] as Map)['loadPercent'] as num).toDouble() / 100;
  final mem = s['memory'] as Map;
  return (cpu, (mem['usedBytes'] as num) / (mem['totalBytes'] as num));
});

String agentErrorText(AppLocalizations l, Object e) {
  if (e is! AgentError) return '${l.commonError}: $e';
  return switch (e.code) {
    'net.unreachable' => l.agentUnreachable,
    'net.timeout' => l.sshTimeout,
    'net.tls' => l.agentTls,
    'agent.auth.missingToken' || 'agent.auth.invalidToken' => l.agentBadToken,
    'agent.auth.tailnetUserNotAllowed' => l.agentWrongTailnetUser,
    'agent.tokenMissing' => l.secretMissing('${e.params['id']}'),
    'agent.notConfigured' => l.hostAgentNone,
    'agent.services.permissionDenied' => l.agentPermissionDenied,
    'agent.power.confirmRequired' => l.commonConfirm,
    'agent.route.notFound' => l.agentFeatureOff,
    'agent.claude.notGitRepo' => l.gitNotRepo,
    'agent.claude.terminalBusy' => l.claudeTerminalBusy,
    'agent.claude.terminalNotFound' => l.claudeTerminalGone,
    'agent.claude.terminalStuck' => l.claudeTerminalStuck,
    'agent.claude.historyNotFound' || 'agent.claude.session.notFound' => l.claudeSessionGone,
    'agent.path.notAllowed' || 'agent.claude.folderNotAllowed' => l.agentPathNotAllowed,
    'agent.claude.folderNotFound' => l.claudeFolderNotFound,
    'agent.claude.scheduleRunning' => l.claudeScheduleBusy,
    'agent.desktop.noDisplay' => l.agentNoDisplay,
    'agent.desktop.noHyprland' => l.desktopNoHyprland,
    'agent.desktop.windowNotFound' => l.desktopWindowGone,
    'agent.desktop.badAddress' => l.desktopBadAddress,
    'agent.desktop.hyprctlFailed' => l.desktopHyprctlFailed,
    'agent.desktop.appNotFound' => l.desktopAppsEmpty,
    // Portable desktop backend (P1): helper missing, OS permission, capability the backend lacks.
    'agent.desktop.unsupported' => l.desktopErrUnsupported,
    'agent.desktop.permission' => desktopPermissionText(l, '${e.params['permission'] ?? ''}'),
    'agent.desktop.helperMissing' => l.desktopErrHelperMissing,
    'agent.desktop.helperFailed' => l.desktopErrHelperFailed,
    'agent.request.invalid' => l.agentRequestInvalid,
    'agent.config.passwordRequired' => l.agentPasswordRequired,
    'agent.control.disabled' => l.desktopControlOffHint,
    'agent.claude.pcUnavailable' => l.claudePcUnavailable,
    'agent.control.sessionRequired' => l.desktopControlEnded,
    'agent.control.busy' => l.desktopControlBusy('${e.params['device'] ?? ''}'),
    'agent.control.rateLimited' => l.desktopControlRateLimited,
    'agent.control.indicatorFailed' => l.desktopControlIndicatorFailed,
    'agent.desktop.badUrl' => l.openOnPcBadUrl,
    'agent.desktop.streamFailed' || 'agent.desktop.screenshotFailed' => l.liveErrStreamFailed,
    'agent.desktop.streamReplaced' => l.liveErrReplaced,
    'agent.desktop.windowNotVisible' => l.liveErrWindowNotVisible,
    'agent.desktop.monitorNotFound' => l.liveErrMonitorNotFound,
    'agent.desktop.badKey' => l.liveErrBadKey,
    'agent.desktop.badText' => l.liveErrBadText,
    'agent.desktop.inputFailed' => l.liveErrInputFailed,
    'agent.desktop.streamFallback' => l.liveFallback,
    'agent.browser.notConnected' => l.browserErrNotConnected,
    'agent.browser.permissionRequired' => l.browserErrPermission,
    'agent.browser.badUrl' => l.browserErrBadUrl,
    'agent.browser.tabNotFound' => l.browserErrTabNotFound,
    'agent.browser.passwordField' => l.browserErrPassword,
    'agent.browser.noMedia' => l.browserErrNoMedia,
    'agent.browser.noInput' => l.browserErrNoInput,
    'agent.browser.noArticle' => l.browserErrNoArticle,
    'agent.browser.unsupported' => l.browserErrUnsupported,
    'agent.browser.timeout' => l.browserErrTimeout,
    'agent.browser.failed' || 'agent.browser.badRequest' => l.browserErrFailed,
    'agent.ui.unsupported' => l.uiErrUnsupported,
    'agent.ui.stale' => l.uiErrStale,
    'agent.ui.timeout' => l.uiErrTimeout,
    'agent.ui.helperMissing' => l.uiErrHelperMissing,
    'agent.ui.helperFailed' => l.uiErrHelperFailed,
    'agent.ui.confirmRequired' => l.uiErrConfirm,
    'agent.ui.noAction' => l.uiErrNoAction,
    'agent.ui.a11yBus' => l.uiErrA11yBus,
    'agent.ui.failed' => l.uiErrFailed,
    'agent.sunshine.noCredentials' => l.sunshineNoCredentials,
    'agent.sunshine.unauthorized' => l.sunshineUnauthorized,
    'agent.sunshine.setupRequired' => l.sunshineSetupRequired,
    'agent.sunshine.noPendingPairing' => l.sunshineNoPending,
    'agent.sunshine.pairFailed' => l.sunshinePairFailed,
    'agent.sunshine.badPin' => l.sunshineBadPin,
    'agent.sunshine.badRequest' => l.sunshineBadRequest('${e.params['message'] ?? ''}'),
    'agent.sunshine.notInstalled' => l.sunshineNotInstalledTitle,
    'agent.sunshine.unitFailed' => l.sunshineUnitFailed,
    'agent.sunshine.certMismatch' => l.sunshineCertMismatch,
    'agent.sunshine.unreachable' || 'agent.sunshine.timeout' || 'agent.sunshine.apiFailed' || 'agent.sunshine.forbidden' => l.sunshineUnreachable,
    'agent.media.noPlayer' => l.mediaNothingPlaying,
    'agent.media.failed' => l.mediaFailed,
    'agent.media.volumeFailed' => l.mediaVolumeFailed,
    'agent.ports.alreadyPublic' => l.agentPortPublic,
    'agent.processes.permissionDenied' => l.agentPermissionDenied,
    // Telegram newsletters, research jobs and service tokens (PLAN.md §12).
    'agent.auth.scopeDenied' || 'agent.serviceToken.notFound' => telegramReasonText(l, e.code, e.params),
    final c when c.startsWith('agent.telegram.') || c.startsWith('agent.research.') => telegramReasonText(l, c, e.params),
    // Incident room (PLAN.md §13.1).
    final c when c.startsWith('agent.incident.') || c == 'agent.preview.invalid' => incidentErrorText(l, c, e.params),
    // Security fix sessions (PLAN.md §16).
    final c when fixErrorCodes.contains(c) => fixErrorText(l, c, e.params),
    // Config files and secrets (PLAN.md §13.3).
    final c when c.startsWith('agent.security.') || c.startsWith('agent.blackbox.') => securityErrorText(l, c, e.params),
    final c when c.startsWith('agent.agy.') => agyErrorText(l, c),
    // Screen modes (PLAN.md §20) and Game mode's older codes (§19).
    final c when c.startsWith('agent.sleep.') => sleepErrorText(l, c, e.params),
    final c when c.startsWith('agent.screen.') || c.startsWith('agent.gamemode.') || c == 'app.screen.needsUpdate' => screenErrorText(l, c, e.params),
    final c when c.startsWith('agent.update.') => updateErrorText(l, c, e.params),
    final c when c.startsWith('agent.db.') => dbErrorText(l, c, e.params),
    final c when c.startsWith('agent.configfiles.') => configErrorText(l, c, e.params),
    _ => '${l.commonError} (${e.code})',
  };
}


/// The OS permission the desktop helper was refused (its message names it, e.g. macOS "Accessibility permission is
/// missing (System Settings → …)"): the known ones in the user's language, otherwise the helper's own words.
String desktopPermissionText(AppLocalizations l, String message) {
  final m = message.toLowerCase();
  if (m.contains('accessibility')) return l.desktopErrPermission(l.desktopPermAccessibility);
  if (m.contains('screen recording')) return l.desktopErrPermission(l.desktopPermScreenRecording);
  return l.desktopErrPermissionOther(message.isEmpty ? '—' : message);
}
