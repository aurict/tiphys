// Notifications: UnifiedPush (distributor = the ntfy app on the phone). Agents send encrypted JSON;
// here we take the decrypted version and show it as a local notification in the selected language. Works even when
// the app is closed (UnifiedPush starts the app in the background with the "--unifiedpush-bg" argument).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../../features/incidents/incident_texts.dart';
import '../../l10n/gen/app_localizations.dart';
import '../agent/agent_client.dart';
import '../profile/model.dart';
import '../security/app_lock.dart';
import '../secrets/secret_store.dart';
import 'clipboard.dart';

const pushInstance = 'tiphys';
const _clipboardChannel = 'tiphys-clipboard';
const _endpointKey = 'app:pushEndpoint';

/// Title/body in the selected language from notification key + params. null for unknown keys.
(String, String)? noticeText(AppLocalizations l, String key, Map<String, dynamic> p) {
  String s(String k) => '${p[k] ?? ''}';
  int n(String k) => (p[k] as num?)?.toInt() ?? 0;
  return switch (key) {
    'claude.done' => (l.notifClaudeDoneTitleWith(s('title')), claudeDoneBody(l, p)),
    'claude.waiting' => (l.notifClaudeWaitingTitle, l.notifClaudeWaitingBody(s('title'), s('tool'))),
    'claude.error' => (l.notifClaudeErrorTitle, s('title')),
    // Claude using the PC: control ended (while Claude is running) / ends within 2 min (with an "Extend" button).
    'claude.pcEnded' => (l.notifPcEndedTitle, s('reason') == 'expired' ? l.notifPcEndedExpired(s('title')) : l.notifPcEndedOther(s('title'))),
    'claude.pcExpiring' => (l.notifPcExpiringTitle(n('minutes')), s('title')),
    'host.offline' => (l.notifHostOfflineTitle(s('host')), l.notifHostOfflineBody(n('minutes'))),
    'host.online' => (l.notifHostOnlineTitle(s('host')), ''),
    'agent.restarted' => (l.notifAgentRestartedTitle(s('host')), l.notifAgentRestartedBody),
    'push.test' => (l.notifTestTitle, s('device')),
    'disk.full' => (l.notifDiskFullTitle(s('host')), l.notifDiskFullBody(s('mount'), n('percent'))),
    'disk.ok' => (l.notifDiskOkTitle(s('host')), s('name')),
    'service.failed' => (l.notifServiceFailedTitle(s('host')), s('unit')),
    'service.recovered' => (l.notifServiceRecoveredTitle(s('host')), s('name')),
    'grafana.alert' => (l.notifGrafanaAlertTitle(s('name')), s('severity')),
    'grafana.resolved' => (l.notifGrafanaResolvedTitle(s('name')), ''),
    'command.done' => (l.notifCommandDoneTitle(s('host')), l.notifCommandBody(s('command'), n('seconds'))),
    'command.failed' => (l.notifCommandFailedTitle(s('host'), n('code')), l.notifCommandBody(s('command'), n('seconds'))),
    'docker.died' => (l.notifDockerDiedTitle(s('host')), p['code'] == null ? s('container') : l.notifDockerDiedBody(s('container'), n('code'))),
    'docker.oom' => (l.notifDockerOomTitle(s('host')), s('container')),
    'docker.restarted' => (l.notifDockerRestartedTitle(s('host')), s('container')),
    'backup.stale' => (l.notifBackupStaleTitle(s('name')), p['hours'] == null ? s('host') : l.notifBackupStaleBody(s('host'), n('hours'))),
    'backup.failed' => (l.notifBackupFailedTitle(s('name')), '${s('host')} · ${backupReasonText(l, s('reason'))}'),
    'backup.ok' => (l.notifBackupOkTitle(s('name')), s('host')),
    'compose.updated' => (
        l.notifComposeUpdatedTitle(s('stack')),
        [s('host'), if (s('services') == '*') l.composeRecreated else if (s('services').isNotEmpty) s('services')].join(' · '),
      ),
    'compose.failed' => (l.notifComposeFailedTitle(s('stack')), p['step'] == null ? s('host') : l.notifComposeFailedBody(s('host'), s('step'), s('code'))),
    'claude.scheduled' => (l.notifClaudeScheduledTitle(s('name')), p['manual'] == null ? '' : l.claudeScheduleManual),
    'claude.scheduleSkipped' => (l.notifClaudeScheduleSkippedTitle(s('name')), l.notifClaudeScheduleSkippedBody),
    'claude.scheduleFailed' => (l.notifClaudeScheduleFailedTitle(s('name')), scheduleReasonText(l, s('reason'))),
    'clipboard.pc' => (l.notifClipboardTitle, clipboardPreview(s('text'))),
    'git.committed' => (l.notifGitCommittedTitle(s('repo'), s('branch')), [s('subject'), s('hash')].where((x) => x.isNotEmpty).join(' · ')),
    'git.pushed' => (l.notifGitPushedTitle(s('repo')), s('branch')),
    // Only in the event stream (not a notification): desktop control session opened / closed, mobile view opened.
    'control.started' => (l.notifControlStartedTitle, '${s('device')} · ${l.durationMinutes(n('minutes'))}'),
    'control.ended' => (
        l.notifControlEndedTitle,
        [
          s('device'),
          n('seconds') < 60 ? l.durationSeconds(n('seconds')) : l.durationMinutes((n('seconds') / 60).round()),
          if (s('reason') == 'expired') l.notifControlExpired,
        ].join(' · '),
      ),
    'ui.opened' => (l.notifUiOpenedTitle, s('class')),
    'telegram.stateCorrupt' => (l.notifTgStateCorruptTitle, l.notifTgStateCorruptBody),
    // Telegram newsletters (atlas): approval request (Send / Cancel buttons), sent, failed, research PC unreachable.
    'telegram.approval' => (l.notifTgApprovalTitle(s('feed')), l.notifTgApprovalBody(n('items'), n('recipients'))),
    'telegram.sent' => (
        l.notifTgSentTitle(s('feed')),
        [l.notifTgApprovalBody(n('items'), n('recipients')), if (n('failed') > 0) l.notifTgSentFailed(n('failed'))].join(' · '),
      ),
    'telegram.failed' => (
        s('reason') == 'agent.telegram.approvalExpired' ? l.notifTgExpiredTitle(s('feed')) : l.notifTgFailedTitle(s('feed')),
        telegramReasonText(l, s('reason')),
      ),
    'telegram.pcUnreachable' => (l.notifTgPcUnreachableTitle, l.notifTgPcUnreachableBody(s('feed'))),
    // Incident room (PLAN.md §13.1): the other incident notifications are the alert notifications themselves.
    'incident.resolved' => (l.notifIncidentResolvedTitle(s('host')), incidentTitle(l, s('kind'), s('target'))),
    'incident.actionFailed' => (
        l.notifIncidentActionFailedTitle(s('host')),
        s('stage') == 'postCheck'
            ? l.notifIncidentActionPostCheck(incidentActionName(l, s('action')), s('target'))
            : l.notifIncidentActionCommand(incidentActionName(l, s('action')), s('target')),
      ),
    // Config files and secrets (PLAN.md §13.3): file and key names only.
    'secret.rotationDue' => (l.notifRotationDueTitle(s('host')), l.notifRotationDueBody(s('file'), s('keys'))),
    'config.restartFailed' => (l.notifConfigRestartFailedTitle(s('host')), l.notifConfigRestartFailedBody(s('file'), s('services'))),
    'secret.changedExternally' => (l.evSecretChangedTitle, l.notifRotationDueBody(s('file'), s('keys'))),
    'config.saved' => (l.evConfigSavedTitle, '${s('file')} · ${s('keys')}'),
    'config.restored' => (l.evConfigRestoredTitle, '${s('file')} · ${s('keys')}'),
    'uptime.down' => (l.notifUptimeDownTitle(s('monitor')), s('host')),
    'uptime.up' => (l.notifUptimeUpTitle(s('monitor')), s('host')),
    'docker.unhealthy' => (l.notifDockerUnhealthyTitle(s('host')), s('container')),
    'docker.restartLoop' => (l.notifDockerRestartLoopTitle(s('host')), l.notifDockerRestartLoopBody(s('container'), n('count'))),
    _ => null,
  };
}

/// Reason a scheduled task couldn't start (agent error code) → text.
String scheduleReasonText(AppLocalizations l, String reason) => switch (reason) {
      'agent.claude.folderNotFound' => l.claudeFolderNotFound,
      'agent.claude.folderNotAllowed' => l.agentPathNotAllowed,
      _ => '${l.commonError} ($reason)',
    };

/// Telegram / research error codes (agent: telegram/*.ts, research/*.ts) → text; also used by agentErrorText.
String telegramReasonText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) {
  String s(String k) => '${params[k] ?? ''}';
  return switch (code) {
    'agent.auth.scopeDenied' => l.errScopeDenied,
    'agent.serviceToken.notFound' => l.errServiceTokenNotFound,
    'agent.research.busy' || 'agent.telegram.research.busy' => l.errResearchBusy,
    'agent.research.notFound' => l.errResearchNotFound,
    'agent.research.toolMissing' => l.errResearchToolMissing(s('tool')),
    'agent.research.mcpMissing' => l.errResearchMcpMissing(s('server')),
    'agent.research.toolFailed' => l.errResearchToolFailed(s('tool')),
    'agent.research.invalidOutput' => l.errResearchInvalidOutput(s('tool')),
    'agent.research.timeout' => l.errResearchTimeout,
    'agent.research.cancelled' => l.errResearchCancelled,
    'agent.research.interrupted' || 'agent.telegram.interrupted' || 'agent.telegram.aborted' || 'agent.telegram.shutdown' => l.errInterrupted,
    'agent.telegram.notConfigured' => l.errTgNotConfigured,
    'agent.telegram.invalidToken' => l.errTgInvalidToken,
    'agent.telegram.blocked' => l.errTgBlocked,
    'agent.telegram.unreachable' || 'agent.telegram.timeout' || 'agent.telegram.apiFailed' || 'agent.telegram.badResponse' => l.errTgUnreachable,
    'agent.telegram.badRequest' => l.errTgBadRequest(s('description')),
    'agent.telegram.apiRateLimited' || 'agent.telegram.rateLimited' => l.errTgRateLimited,
    'agent.telegram.feed.notFound' || 'agent.telegram.recipient.notFound' || 'agent.telegram.invite.notFound' || 'agent.telegram.issue.notFound' => l.tgGone,
    'agent.telegram.feedRunning' => l.tgFeedRunning,
    'agent.telegram.noRecipients' => l.errTgNoRecipients,
    'agent.telegram.recipientStopped' => l.tgStoppedHint,
    'agent.telegram.issueNotAwaiting' => l.errTgIssueNotAwaiting,
    'agent.telegram.issueExpired' || 'agent.telegram.approvalExpired' => l.errTgApprovalExpired,
    'agent.telegram.issueNotRendered' => l.errTgIssueNotRendered,
    'agent.telegram.tooManyFeeds' => l.errTgTooManyFeeds,
    'agent.telegram.tooManyInvites' => l.errTgTooManyInvites,
    'agent.telegram.research.notConfigured' => l.tgResearchNotSet,
    'agent.telegram.research.unreachable' => l.errTgResearchUnreachable,
    'agent.telegram.research.timeout' => l.errTgResearchTimeout,
    'agent.telegram.research.failed' => l.errTgResearchFailed,
    'agent.telegram.research.unauthorized' => l.errTgResearchUnauthorized,
    'agent.telegram.research.rejected' || 'agent.telegram.research.badResponse' => l.errTgResearchRejected,
    'agent.telegram.noItems' => l.errTgNoItems,
    'agent.telegram.deliveryFailed' || 'agent.telegram.sendFailed' => l.errTgDeliveryFailed,
    _ => '${l.commonError} ($code)',
  };
}

/// Machine-readable detail of the backup check (agent: backups.ts) → text.
String backupReasonText(AppLocalizations l, String? reason) => switch (reason) {
      null || '' => l.backupsStatusFailed,
      'too-small' => l.backupsReasonTooSmall,
      'no-match' || 'missing' => l.backupsReasonNoMatch,
      'not-found' => l.backupsReasonNotFound,
      'never-ran' => l.backupsReasonNeverRan,
      _ => l.backupsReasonUnit(reason),
    };

/// "Claude finished" body: first line of the answer, below it changed file count · cost · duration.
/// Old agents send only the title and cost; missing parts are skipped.
String claudeDoneBody(AppLocalizations l, Map<String, dynamic> p) {
  final files = (p['files'] as num?)?.toInt() ?? 0;
  final cost = (p['cost'] as num?)?.toDouble();
  final seconds = (p['seconds'] as num?)?.toInt() ?? 0;
  final stats = [
    if (files > 0) l.notifFilesChanged(files),
    if (cost != null && cost > 0) '\$${cost.toStringAsFixed(2)}',
    if (seconds > 0) seconds < 60 ? l.durationSeconds(seconds) : l.durationMinutes((seconds / 60).round()),
  ].join(' · ');
  final summary = '${p['summary'] ?? ''}'.trim();
  return [if (summary.isNotEmpty) summary, if (stats.isNotEmpty) stats].join('\n');
}

/// Should it be shown according to the profile preferences?
bool noticeAllowed(Profile p, String key, [Map<String, dynamic> params = const {}]) => switch (key) {
      'claude.done' => p.claude.notifyDone,
      'claude.waiting' => p.claude.notifyWaiting,
      'claude.error' || 'claude.scheduleFailed' || 'claude.pcEnded' => p.claude.notifyError,
      'claude.pcExpiring' => p.claude.notifyWaiting,
      'host.offline' || 'host.online' => p.notifications.pcOffline,
      'service.failed' || 'service.recovered' || 'agent.restarted' => p.notifications.serviceDown,
      'grafana.alert' || 'grafana.resolved' => p.notifications.grafanaAlerts,
      'docker.died' || 'docker.oom' || 'docker.restarted' => p.notifications.serviceDown,
      'backup.stale' || 'backup.failed' || 'backup.ok' => p.notifications.backupAlerts,
      'incident.resolved' || 'incident.actionFailed' || 'uptime.down' || 'uptime.up' || 'docker.unhealthy' || 'docker.restartLoop' => p.notifications.incidents,
      // "Long-running command" threshold: 0 = off; successful commands shorter than the threshold aren't notified,
      // a failing command is always notified (if enabled).
      'command.done' => p.notifications.longCommandSeconds > 0 && ((params['seconds'] as num?) ?? 0) >= p.notifications.longCommandSeconds,
      'command.failed' => p.notifications.longCommandSeconds > 0,
      'clipboard.pc' => p.notifications.clipboardFromPc,
      'telegram.sent' => p.notifications.telegramSent,
      'telegram.approval' || 'telegram.failed' || 'telegram.pcUnreachable' => p.notifications.telegramAlerts,
      _ => true,
    };

/// Notification never shown on the lock screen (secret): those whose buttons run in the background without unlocking
/// and affect the PC — a PC session's permission request ("Allow": payment, sending a message, command) and "Extend".
/// PC session: the agent's `pc: 1` param or the PC session held on the phone ([heldPcSession]). "Stop" (ongoing
/// notification) stays on the lock screen: stopping is safe. A Telegram approval too: "Send" messages other people.
NotificationVisibility? lockScreenVisibility(String key, Map<String, dynamic> params, String? sessionId, String? heldPcSession) {
  final pc = key == 'claude.pcExpiring' || (key == 'claude.waiting' && (params['pc'] == 1 || (sessionId != null && sessionId == heldPcSession)));
  return pc || key == 'telegram.approval' ? NotificationVisibility.secret : null;
}

/// Notification id. Ones on the same topic replace each other (offline → back online, disk full → resolved, last
/// state of a Claude session); the others are unique. Since the background notification handler may start from
/// scratch on every message, it is derived from the topic (stable hash) or from the time, not from a counter.
int noticeId(String key, Map<String, dynamic> p, {String? link, String? requestId}) {
  String s(String k) => '${p[k] ?? ''}';
  final topic = switch (key) {
    'claude.done' || 'claude.error' || 'claude.pcEnded' => 'claude|$link',
    'claude.pcExpiring' => 'claude-pc-expiring|$link',
    'claude.waiting' => 'claude-wait|$link|$requestId',
    'host.offline' || 'host.online' => 'host|${s('host')}',
    'disk.full' => 'disk|${s('host')}|${s('mount')}',
    'disk.ok' => 'disk|${s('host')}|${s('name')}',
    'service.failed' => 'service|${s('host')}|${s('unit')}',
    'service.recovered' => 'service|${s('host')}|${s('name')}',
    'grafana.alert' || 'grafana.resolved' => 'grafana|${s('name')}',
    'agent.restarted' => 'agent|${s('host')}',
    'docker.died' || 'docker.oom' || 'docker.restarted' || 'docker.unhealthy' || 'docker.restartLoop' => 'docker|${s('host')}|${s('container')}',
    'incident.resolved' || 'incident.actionFailed' => 'incident|${s('incidentId')}',
    'secret.rotationDue' || 'config.restartFailed' => 'config|${s('host')}|${s('file')}',
    'uptime.down' || 'uptime.up' => 'uptime|${s('host')}|${s('monitorId')}',
    'backup.stale' || 'backup.failed' || 'backup.ok' => 'backup|${s('host')}|${s('id')}',
    'compose.updated' || 'compose.failed' => 'compose|${s('host')}|${s('stack')}',
    'claude.scheduleFailed' => 'claude-schedule|${s('id')}',
    // One notification per issue: the approval request is replaced by its outcome.
    'telegram.approval' || 'telegram.sent' || 'telegram.failed' || 'telegram.pcUnreachable' => 'telegram|${s('issueId')}',
    'push.test' => 'test',
    // PC clipboard: each new text replaces the previous one.
    'clipboard.pc' => 'clipboard',
    _ => null,
  };
  // Topic ids are 0..2^30, unique ones above 2^30: the two never collide.
  if (topic == null) return 0x40000000 + (DateTime.now().millisecondsSinceEpoch % 0x3fffffff);
  var h = 0x811c9dc5; // FNV-1a
  for (final c in utf8.encode(topic)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h & 0x3fffffff;
}

/// Notification buttons (Claude permission request).
const actionAllow = 'claude-allow';
const actionDeny = 'claude-deny';

/// Notification buttons (Telegram issue approval).
const actionTgApprove = 'telegram-approve';
const actionTgReject = 'telegram-reject';

/// Notification payload: a plain link, or for a notification with buttons, JSON {link, sessionId, requestId} /
/// {link, issueId}.
String? routeForPayload(String? payload) {
  if (payload != null && payload.startsWith('{')) {
    try {
      final j = jsonDecode(payload) as Map;
      final route = routeForLink(j['link'] as String?);
      // Incident notifications also carry the agent's host name; the incident screen maps it to a host.
      final host = j['host'];
      // Config notifications: open the file (the host is the agent's name; the screen maps it to a host).
      if (j['fileId'] is String && host is String && host.isNotEmpty && RegExp(r'^cf-[a-f0-9]{24}$').hasMatch(j['fileId'] as String)) {
        return '/configfiles/file?host=${Uri.encodeQueryComponent(host)}&id=${j['fileId']}';
      }
      return route != null && route.startsWith('/incidents/') && host is String && host.isNotEmpty
          ? '$route?host=${Uri.encodeQueryComponent(host)}'
          : route;
    } catch (_) {
      return null;
    }
  }
  return routeForLink(payload);
}

/// Payload of an incident notification: the link plus the agent's host name (so the app opens the incident on the right
/// host). null for other links.
String? incidentPayload(String? link, Map<String, dynamic> params) {
  final host = params['host'];
  if (link == null || !link.startsWith('tiphys://incidents/') || host is! String || host.isEmpty) return null;
  return jsonEncode({'link': link, 'host': host});
}

/// Payload of a config notification: the link plus the file id and the agent's host name. null for other keys.
String? configPayload(String key, Map<String, dynamic> params, Map<String, dynamic>? data) {
  final host = params['host'], fileId = data?['fileId'];
  if (key != 'secret.rotationDue' && key != 'config.restartFailed') return null;
  if (host is! String || host.isEmpty || fileId is! String) return null;
  return jsonEncode({'link': 'tiphys://configfiles', 'host': host, 'fileId': fileId});
}

/// "Allow / Deny" in the notification: sends the decision to the Claude agent without opening the app. True on
/// success.
Future<bool> decideFromNotification(
  String payload,
  bool allow, {
  required Profile profile,
  required SecretStore secrets,
  AgentClient Function(String url, String token)? clientFor,
}) async {
  final Map j;
  try {
    j = jsonDecode(payload) as Map;
  } catch (_) {
    return false;
  }
  final host = profile.host(profile.claude.agentHostId) ?? profile.hosts.where((h) => h.agent != null).firstOrNull;
  final agent = host?.agent;
  if (agent == null || j['sessionId'] == null || j['requestId'] == null) return false;
  final token = await secrets.read(secretIdOf(agent.tokenRef));
  if (token == null) return false;
  final c = (clientFor ?? (u, t) => AgentClient(baseUrl: u, token: t))(agent.url, token);
  try {
    await c.post('/v1/claude/sessions/${j['sessionId']}/permissions/${j['requestId']}', {'allow': allow});
    return true;
  } catch (_) {
    return false;
  } finally {
    c.close();
  }
}

/// "Send / Cancel" in a telegram.approval notification: approves or rejects the issue without opening the app. The
/// push doesn't say which agent sent it, so agents are tried in turn (the ones whose saved config has the telegram
/// feature first); issue ids are random, so another agent can only answer "not found". True on success.
Future<bool> telegramDecideFromNotification(
  String payload,
  bool approve, {
  required Profile profile,
  required SecretStore secrets,
  AgentClient Function(String url, String token)? clientFor,
}) async {
  final String issueId;
  try {
    issueId = '${(jsonDecode(payload) as Map)['issueId']}';
  } catch (_) {
    return false;
  }
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(issueId)) return false;
  bool tg(Host h) => (profile.agentConfigs[h.id]?['features'] as Map?)?['telegram'] == true;
  final hosts = profile.hosts.where((h) => h.agent != null).toList()..sort((a, b) => (tg(a) ? 0 : 1).compareTo(tg(b) ? 0 : 1));
  for (final h in hosts) {
    final token = await secrets.read(secretIdOf(h.agent!.tokenRef));
    if (token == null) continue;
    final c = (clientFor ?? (u, t) => AgentClient(baseUrl: u, token: t))(h.agent!.url, token);
    try {
      await c.post('/v1/telegram/issues/$issueId/${approve ? 'approve' : 'reject'}');
      return true;
    } on AgentError catch (e) {
      // This agent doesn't have the issue (or the feature): try the next one. Any other answer is final.
      if (e.code != 'agent.telegram.issue.notFound' && e.code != 'agent.route.notFound' && !e.code.startsWith('net.') && !e.code.startsWith('agent.auth.')) return false;
    } catch (_) {
      // Unreachable agent: next.
    } finally {
      c.close();
    }
  }
  return false;
}

Future<void> _showTelegramDecisionFailed(FlutterLocalNotificationsPlugin n, Profile profile, {bool init = false}) async {
  if (init) await n.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')));
  final l = lookupAppLocalizations(_localeOf(profile));
  await n.show(
    id: 9003,
    title: l.notifTgDecisionFailedTitle,
    body: l.notifTgDecisionFailedBody,
    notificationDetails: const NotificationDetails(android: AndroidNotificationDetails('tiphys-urgent', 'Tiphys · acil', importance: Importance.high)),
  );
}

// ---- Claude using the PC (10.3) ----

/// "Stop" in the ongoing "Claude is using the PC" notification and "Extend" in the 2-minute warning.
const actionPcStop = 'claude-pc-stop';
const actionPcExtend = 'claude-pc-extend';

/// Id of the ongoing notification (single PC session: there is one control session per device).
const pcOngoingId = 9100;

/// Control token of the open PC session: kept in secure storage for "Stop"/"Extend" while the app is closed, only
/// for the duration of the session (deleted when it ends). Not shown in the Settings › Keys list.
const pcControlSecretId = 'app-pc-control';

/// PC session held on the phone: host, Claude session, control token and end time.
class PcHold {
  const PcHold({required this.hostId, required this.sessionId, required this.title, required this.token, required this.expiresAt});
  final String hostId;
  final String sessionId;
  final String title;
  final String token;
  final DateTime expiresAt;

  PcHold copyWith({String? token, DateTime? expiresAt}) =>
      PcHold(hostId: hostId, sessionId: sessionId, title: title, token: token ?? this.token, expiresAt: expiresAt ?? this.expiresAt);
  Map<String, dynamic> toJson() => {'hostId': hostId, 'sessionId': sessionId, 'title': title, 'token': token, 'expiresAt': expiresAt.toUtc().toIso8601String()};
  static PcHold? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return PcHold(hostId: '${j['hostId']}', sessionId: '${j['sessionId']}', title: '${j['title'] ?? ''}', token: '${j['token']}', expiresAt: DateTime.parse('${j['expiresAt']}').toLocal());
    } catch (_) {
      return null;
    }
  }
}

/// Ongoing notification: not dismissible, silent, countdown (remaining time runs even if the app isn't running),
/// "Stop" button.
AndroidNotificationDetails pcOngoingDetails(AppLocalizations l, DateTime expiresAt) => AndroidNotificationDetails(
      'tiphys-pc',
      'Tiphys · PC kontrolü',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      silent: true,
      showWhen: true,
      when: expiresAt.millisecondsSinceEpoch,
      usesChronometer: true,
      chronometerCountDown: true,
      category: AndroidNotificationCategory.service,
      color: const Color(0xFFFF3B30),
      // The notification is removed only if stopping succeeds (handlePcAction / PcOngoing.release); otherwise it stays.
      actions: [AndroidNotificationAction(actionPcStop, l.desktopControlStop, cancelNotification: false)],
    );

/// Shows/updates the "Claude is using the PC" notification; tapping the body opens the PC chat.
Future<void> showPcOngoing(FlutterLocalNotificationsPlugin n, AppLocalizations l, PcHold h) => n.show(
      id: pcOngoingId,
      title: l.pcOngoingTitle,
      body: l.pcOngoingBody(h.title, DateFormat.Hm().format(h.expiresAt)),
      payload: jsonEncode({'link': 'tiphys://claude/${h.sessionId}', 'sessionId': h.sessionId}),
      notificationDetails: NotificationDetails(android: pcOngoingDetails(l, h.expiresAt)),
    );

AgentClient? _pcClient(Profile profile, PcHold h, String? deviceToken, AgentClient Function(String url, String token)? clientFor) {
  final agent = profile.host(h.hostId)?.agent;
  if (agent == null || deviceToken == null) return null;
  return (clientFor ?? (u, t) => AgentClient(baseUrl: u, token: t))(agent.url, deviceToken);
}

/// "Stop" in the notification: interrupts Claude without opening the app and closes the control session (the PC
/// indicator goes away). The stored token is deleted. True on success.
Future<bool> pcStopFromNotification({required Profile profile, required SecretStore secrets, AgentClient Function(String url, String token)? clientFor}) async {
  final h = PcHold.fromJson(await secrets.read(pcControlSecretId));
  if (h == null) return false;
  final agent = profile.host(h.hostId)?.agent;
  final c = _pcClient(profile, h, agent == null ? null : await secrets.read(secretIdOf(agent.tokenRef)), clientFor);
  if (c == null) return false;
  try {
    try {
      await c.post('/v1/claude/sessions/${h.sessionId}/interrupt');
    } catch (_) {
      // session already idle / closed: closing control is still needed
    }
    // Closing is open to every paired device; the token is sent anyway. When control ends the agent stops Claude too.
    await c.request('DELETE', '/v1/desktop/control/session', headers: {'X-Tiphys-Control': h.token});
    await secrets.delete(pcControlSecretId);
    return true;
  } catch (_) {
    return false;
  } finally {
    c.close();
  }
}

/// "Extend" in the 2-minute warning: extends control by 15 min with the stored token; returns the updated record with
/// the new end time (null otherwise).
Future<PcHold?> pcExtendFromNotification({required Profile profile, required SecretStore secrets, AgentClient Function(String url, String token)? clientFor}) async {
  final h = PcHold.fromJson(await secrets.read(pcControlSecretId));
  if (h == null) return null;
  final agent = profile.host(h.hostId)?.agent;
  final c = _pcClient(profile, h, agent == null ? null : await secrets.read(secretIdOf(agent.tokenRef)), clientFor);
  if (c == null) return null;
  try {
    final j = await c.request('POST', '/v1/desktop/control/session/extend', body: const {'minutes': 15}, headers: {'X-Tiphys-Control': h.token}) as Map;
    final next = h.copyWith(expiresAt: DateTime.parse('${j['expiresAt']}').toLocal());
    await secrets.write(pcControlSecretId, jsonEncode(next.toJson()));
    return next;
  } catch (_) {
    return null;
  } finally {
    c.close();
  }
}

/// PC buttons while the app is closed (or there is no UI).
Future<void> handlePcAction(String action, FlutterLocalNotificationsPlugin n, {required Profile profile, required SecretStore secrets, AgentClient Function(String url, String token)? clientFor}) async {
  final l = lookupAppLocalizations(_localeOf(profile));
  if (action == actionPcStop) {
    if (await pcStopFromNotification(profile: profile, secrets: secrets, clientFor: clientFor)) {
      await n.cancel(id: pcOngoingId);
    } else {
      await _showPcFailed(n, l);
    }
    return;
  }
  final next = await pcExtendFromNotification(profile: profile, secrets: secrets, clientFor: clientFor);
  if (next != null) {
    await showPcOngoing(n, l, next);
  } else {
    await _showPcFailed(n, l);
  }
}

Future<void> _showPcFailed(FlutterLocalNotificationsPlugin n, AppLocalizations l) => n.show(
      id: 9002,
      title: l.pcActionFailedTitle,
      body: l.pcActionFailedBody,
      notificationDetails: const NotificationDetails(android: AndroidNotificationDetails('tiphys-urgent', 'Tiphys · acil', importance: Importance.high)),
    );

/// Entry point Android runs when a notification button is pressed while the app is closed (separate isolate).
@pragma('vm:entry-point')
Future<void> onNotificationActionBackground(NotificationResponse r) async {
  const handled = {actionAllow, actionDeny, actionCopyClipboard, actionPcStop, actionPcExtend, actionTgApprove, actionTgReject};
  if (!handled.contains(r.actionId)) return;
  DartPluginRegistrant.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  if (r.actionId == actionTgApprove || r.actionId == actionTgReject) {
    final profile = Profile.fromJson(jsonDecode(await File('${docs.path}/profile.json').readAsString()) as Map<String, dynamic>);
    final ok = await telegramDecideFromNotification(r.payload ?? '', r.actionId == actionTgApprove, profile: profile, secrets: KeystoreSecretStore());
    if (!ok) await _showTelegramDecisionFailed(FlutterLocalNotificationsPlugin(), profile, init: true);
    return;
  }
  if (r.actionId == actionPcStop || r.actionId == actionPcExtend) {
    final n = FlutterLocalNotificationsPlugin();
    await n.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')));
    Profile profile;
    try {
      profile = Profile.fromJson(jsonDecode(await File('${docs.path}/profile.json').readAsString()) as Map<String, dynamic>);
    } catch (_) {
      profile = Profile.empty;
    }
    await handlePcAction(r.actionId!, n, profile: profile, secrets: KeystoreSecretStore());
    return;
  }
  if (r.actionId == actionCopyClipboard) {
    // Flutter's Clipboard channel doesn't respond in this background engine; the native plugin (tiphys_native) writes.
    if (!await copyFromNotification(r.payload, seen: ClipboardSeen(() async => docs.path))) await _showCopyFailed(FlutterLocalNotificationsPlugin(), docs.path);
    return;
  }
  final profile = Profile.fromJson(jsonDecode(await File('${docs.path}/profile.json').readAsString()) as Map<String, dynamic>);
  final ok = await decideFromNotification(r.payload ?? '', r.actionId == actionAllow, profile: profile, secrets: KeystoreSecretStore());
  if (!ok) await _showDecisionFailed(FlutterLocalNotificationsPlugin(), profile, init: true);
}

Future<void> _showDecisionFailed(FlutterLocalNotificationsPlugin n, Profile profile, {bool init = false}) async {
  if (init) await n.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')));
  final l = lookupAppLocalizations(_localeOf(profile));
  await n.show(
    id: 9000,
    title: l.claudeDecisionFailedTitle,
    body: l.claudeDecisionFailedBody,
    notificationDetails: const NotificationDetails(android: AndroidNotificationDetails('tiphys-urgent', 'Tiphys · acil', importance: Importance.high)),
  );
}

Future<void> _showCopyFailed(FlutterLocalNotificationsPlugin n, String docs) async {
  await n.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')));
  Profile profile;
  try {
    profile = Profile.fromJson(jsonDecode(await File('$docs/profile.json').readAsString()) as Map<String, dynamic>);
  } catch (_) {
    profile = Profile.empty;
  }
  final l = lookupAppLocalizations(_localeOf(profile));
  await n.show(
    id: 9001,
    title: l.clipboardCopyFailed,
    notificationDetails: const NotificationDetails(android: AndroidNotificationDetails(_clipboardChannel, 'Tiphys · pano', importance: Importance.low)),
  );
}

Locale _localeOf(Profile profile) => switch (profile.app.language) {
      LanguagePref.tr => const Locale('tr'),
      LanguagePref.en => const Locale('en'),
      LanguagePref.system => Platform.localeName.startsWith('tr') ? const Locale('tr') : const Locale('en'),
    };

/// `tiphys://claude/ID` → `/claude/session/ID`; `tiphys://system` → `/system`
String? routeForLink(String? link) {
  if (link == null || !link.startsWith('tiphys://')) return null;
  final rest = link.substring('tiphys://'.length);
  if (rest == 'claude/schedules') return '/claude/schedules';
  if (rest.startsWith('claude/')) return '/claude/session/${rest.substring(7)}';
  if (rest == 'system') return '/system';
  if (rest == 'system/backups') return '/system/backups';
  if (rest == 'system/events') return '/system/events';
  if (rest == 'system/compose') return '/system/compose';
  if (rest == 'sites') return '/monitor/sites';
  if (rest == 'monitor/grafana') return '/monitor/grafana';
  if (rest == 'terminal') return '/terminal';
  if (rest == 'telegram') return '/system/telegram';
  if (rest == 'incidents') return '/incidents';
  if (rest == 'configfiles') return '/configfiles';
  final incident = RegExp(r'^incidents/([A-Za-z0-9_-]{1,64})$').firstMatch(rest);
  if (incident != null) return '/incidents/${incident.group(1)}';
  final issue = RegExp(r'^telegram/issues/([A-Za-z0-9_-]{1,64})$').firstMatch(rest);
  if (issue != null) return '/telegram/issues/${issue.group(1)}';
  return null;
}

class PushService {
  PushService({required this.vault, required this.loadProfile, required this.secrets});
  final KeyValueVault vault;
  final Future<Profile> Function() loadProfile;
  final SecretStore secrets;
  final notifications = FlutterLocalNotificationsPlugin();
  void Function(String route)? onOpen;

  /// While the app is open, let a PC button (Stop/Extend) go through the UI state (true: handled). Otherwise straight
  /// to the agent.
  Future<bool> Function(String action)? onPcAction;

  /// The agent reported that control of the PC session ended (clear the state if the app is open).
  void Function(String sessionId)? onPcEnded;

  Future<void> init({required bool background}) async {
    await notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
      onDidReceiveNotificationResponse: (r) async {
        if (r.actionId == actionCopyClipboard) {
          await copyFromNotification(r.payload, seen: ClipboardSeen(() async => (await getApplicationDocumentsDirectory()).path));
          return;
        }
        if (r.actionId == actionPcStop || r.actionId == actionPcExtend) {
          if (await onPcAction?.call(r.actionId!) ?? false) return;
          await handlePcAction(r.actionId!, notifications, profile: await loadProfile(), secrets: secrets);
          return;
        }
        if (r.actionId == actionTgApprove || r.actionId == actionTgReject) {
          final profile = await loadProfile();
          final ok = await telegramDecideFromNotification(r.payload ?? '', r.actionId == actionTgApprove, profile: profile, secrets: secrets);
          if (!ok) await _showTelegramDecisionFailed(notifications, profile);
          return;
        }
        if (r.actionId == actionAllow || r.actionId == actionDeny) {
          final profile = await loadProfile();
          final ok = await decideFromNotification(r.payload ?? '', r.actionId == actionAllow, profile: profile, secrets: secrets);
          if (!ok) await _showDecisionFailed(notifications, profile);
          return;
        }
        final route = routeForPayload(r.payload);
        if (route != null) onOpen?.call(route);
      },
      onDidReceiveBackgroundNotificationResponse: onNotificationActionBackground,
    );
    final registered = await UnifiedPush.initialize(
      onNewEndpoint: (e, _) => _saveEndpoint(e),
      onMessage: (m, _) => _onMessage(m),
      onUnregistered: (_) => vault.delete(_endpointKey),
    );
    // Re-registration with the distributor continues in the background; it shouldn't hold up the first screen.
    if (registered && !background) unawaited(UnifiedPush.register(instance: pushInstance));
  }

  /// Route to navigate to if the app was opened by tapping a notification.
  Future<String?> launchRoute() async {
    final d = await notifications.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true ? routeForPayload(d!.notificationResponse?.payload) : null;
  }

  Future<List<String>> distributors() => UnifiedPush.getDistributors();
  Future<String?> distributor() => UnifiedPush.getDistributor();

  Future<bool> enable(String distributor) async {
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await UnifiedPush.saveDistributor(distributor);
    await UnifiedPush.register(instance: pushInstance);
    return true;
  }

  Future<void> disable() async {
    await UnifiedPush.unregister(pushInstance);
    await vault.delete(_endpointKey);
  }

  Future<Map<String, dynamic>?> endpoint() async {
    final raw = await vault.read(_endpointKey);
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> _saveEndpoint(PushEndpoint e) async {
    final j = {'url': e.url, 'pubKey': e.pubKeySet?.pubKey, 'auth': e.pubKeySet?.auth};
    await vault.write(_endpointKey, jsonEncode(j));
    await registerWithAgents();
  }

  /// Reports the endpoint to all hosts with an agent; returns the ids of the hosts that succeeded.
  Future<List<String>> registerWithAgents() async {
    final ep = await endpoint();
    if (ep == null) return const [];
    final p = await loadProfile();
    final ok = <String>[];
    for (final h in p.hosts.where((h) => h.agent != null)) {
      try {
        final c = await AgentClient.forHost(h, secrets);
        await c.put('/v1/push/endpoint', {'url': ep['url'], if (ep['pubKey'] != null) 'pubKey': ep['pubKey'], if (ep['auth'] != null) 'auth': ep['auth']});
        c.close();
        ok.add(h.id);
      } catch (_) {
        // If the agent is down right now, it is retried on the next launch.
      }
    }
    return ok;
  }

  Future<void> _cancelWaiting(String link) async {
    try {
      for (final n in await notifications.getActiveNotifications()) {
        if (n.tag == link && n.id != null) await notifications.cancel(id: n.id!, tag: link);
      }
    } catch (_) {
      // Couldn't get the active notification list: the old approval notification stays; tapping it the app shows the
      // current state.
    }
  }

  Future<void> _onMessage(PushMessage m) async {
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(m.content)) as Map);
    } catch (_) {
      return;
    }
    final key = j['key'] as String? ?? '';
    final params = Map<String, dynamic>.from((j['params'] as Map?) ?? {});
    final link = j['link'] as String?;
    final data = j['data'] is Map ? Map<String, dynamic>.from(j['data'] as Map) : null;
    if (key == 'claude.pcEnded') {
      // Control ended: the ongoing notification and stored token are removed in any case (the app may be closed).
      await clearPcHold(notifications, secrets, sessionId: data?['sessionId'] as String?);
      final sid = data?['sessionId'];
      if (sid is String) onPcEnded?.call(sid);
      // The user's own stop or an idle session isn't notified.
      if (params['working'] != 1 || params['reason'] == 'stopped') return;
    }
    final profile = await loadProfile();
    if (!noticeAllowed(profile, key, params)) return;
    final l = lookupAppLocalizations(_localeOf(profile));
    final text = noticeText(l, key, params);
    if (text == null) return;
    final high = const {'claude.pcExpiring', 'claude.pcEnded', 'claude.waiting', 'host.offline', 'disk.full', 'service.failed', 'grafana.alert', 'agent.restarted', 'docker.died', 'docker.oom', 'docker.unhealthy', 'docker.restartLoop', 'uptime.down', 'incident.actionFailed', 'config.restartFailed', 'backup.stale', 'backup.failed', 'claude.scheduleFailed', 'telegram.approval', 'telegram.pcUnreachable'}.contains(key) ||
        (key == 'telegram.failed' && params['reason'] != 'agent.telegram.approvalExpired');
    // Telegram issue waiting for approval: "Send / Cancel" buttons (decision without opening the app).
    final tgDecision = key == 'telegram.approval' && data?['issueId'] != null;
    // Claude permission request: "Allow / Deny" buttons in the notification (decision without opening the app).
    final extend = key == 'claude.pcExpiring' && data?['sessionId'] != null;
    final decision = key == 'claude.waiting' && data?['sessionId'] != null && data?['requestId'] != null;
    final held = key == 'claude.waiting' ? PcHold.fromJson(await secrets.read(pcControlSecretId))?.sessionId : null;
    final visibility = lockScreenVisibility(key, params, data?['sessionId']?.toString(), held);
    // Session ended/failed: that session's remaining approval notifications are now invalid (their buttons do nothing).
    if ((key == 'claude.done' || key == 'claude.error') && link != null) await _cancelWaiting(link);
    if (key == 'clipboard.pc') return _showClipboard(l, '${params['text'] ?? ''}');
    await notifications.show(
      id: noticeId(key, params, link: link, requestId: data?['requestId'] as String?),
      title: text.$1,
      body: text.$2,
      payload: decision
          ? jsonEncode({'link': link, 'sessionId': data!['sessionId'], 'requestId': data['requestId']})
          : extend
              ? jsonEncode({'link': link, 'sessionId': data!['sessionId']})
              : tgDecision
                  ? jsonEncode({'link': link, 'issueId': data!['issueId'], 'feedId': data['feedId']})
                  : incidentPayload(link, params) ?? configPayload(key, params, data) ?? link,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          high ? 'tiphys-urgent' : 'tiphys',
          high ? 'Tiphys · acil' : 'Tiphys',
          importance: high ? Importance.high : Importance.defaultImportance,
          priority: high ? Priority.high : Priority.defaultPriority,
          tag: key == 'claude.waiting' ? link : null,
          visibility: visibility,
          // Show the whole multi-line body (e.g. Claude summary + stats) when expanded.
          styleInformation: text.$2.contains('\n') || text.$2.length > 60 ? BigTextStyleInformation(text.$2) : null,
          color: const Color(0xFF4338CA), // brand indigo (notification icon accent)
          actions: decision
              ? [
                  AndroidNotificationAction(actionAllow, l.claudeAllow, cancelNotification: true),
                  AndroidNotificationAction(actionDeny, l.claudeDeny, cancelNotification: true),
                ]
              : extend
                  ? [AndroidNotificationAction(actionPcExtend, l.pcExtend, cancelNotification: true)]
                  : tgDecision
                      ? [
                          AndroidNotificationAction(actionTgApprove, l.tgApprove, cancelNotification: true),
                          AndroidNotificationAction(actionTgReject, l.tgReject, cancelNotification: true),
                        ]
                      : null,
        ),
      ),
    );
  }

  /// PC clipboard: silent notification never shown on the lock screen (secret); "Copy" writes to the clipboard
  /// without opening the app.
  Future<void> _showClipboard(AppLocalizations l, String text) async {
    if (text.isEmpty) return;
    await notifications.show(
      id: noticeId('clipboard.pc', const {}),
      title: l.notifClipboardTitle,
      body: clipboardPreview(text),
      payload: jsonEncode({'clipboard': text}),
      notificationDetails: NotificationDetails(android: clipboardNotificationDetails(l)),
    );
  }
}

/// PC session ended: the ongoing notification is removed and the stored token deleted (only that session's if
/// [sessionId] is given).
Future<void> clearPcHold(FlutterLocalNotificationsPlugin n, SecretStore secrets, {String? sessionId}) async {
  final h = PcHold.fromJson(await secrets.read(pcControlSecretId));
  if (sessionId != null && h != null && h.sessionId != sessionId) return;
  await secrets.delete(pcControlSecretId);
  await n.cancel(id: pcOngoingId);
}

/// Android details of the "clipboard.pc" notification (verified in tests).
AndroidNotificationDetails clipboardNotificationDetails(AppLocalizations l) => AndroidNotificationDetails(
      _clipboardChannel,
      'Tiphys · pano',
      importance: Importance.low,
      priority: Priority.low,
      silent: true,
      onlyAlertOnce: true,
      visibility: NotificationVisibility.secret,
      color: const Color(0xFF4338CA),
      actions: [AndroidNotificationAction(actionCopyClipboard, l.commonCopy, cancelNotification: true)],
    );
