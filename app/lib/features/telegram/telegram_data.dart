// Telegram newsletters (agent feature "telegram", /v1/telegram/*): providers per host and small helpers shared by the
// screens. Shapes follow docs/agent/api.md#telegram.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../claude/schedules.dart' show scheduleWhenText, scheduleTimeText;
import '../system/agent_providers.dart';

typedef Json = Map<String, dynamic>;

List<Json> _list(Json j, String key) => [for (final x in (j[key] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];

/// Hosts whose agent reports the given feature in its health response (in profile order).
final hostsWithFeatureProvider = FutureProvider.autoDispose.family<List<Host>, String>((ref, feature) async {
  final hosts = ref.watch(profileProvider.select((p) => p.hosts)).where((h) => h.agent != null).toList();
  final out = <Host>[];
  for (final h in hosts) {
    try {
      final health = await ref.watch(healthProvider(h.id).future);
      if ((health['features'] as Map?)?[feature] == true) out.add(h);
    } catch (_) {
      // Unreachable agent: not offered.
    }
  }
  return out;
});

final telegramStatusProvider = FutureProvider.autoDispose.family<Json, String>((ref, hostId) {
  return withAgent(ref, hostId, (c) => c.get('/v1/telegram/status'));
});

final telegramRecipientsProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  return _list(await withAgent(ref, hostId, (c) => c.get('/v1/telegram/recipients')), 'recipients');
});

final telegramInvitesProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  return _list(await withAgent(ref, hostId, (c) => c.get('/v1/telegram/invites')), 'invites');
});

final telegramFeedsProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  return _list(await withAgent(ref, hostId, (c) => c.get('/v1/telegram/feeds')), 'feeds');
});

final telegramTemplatesProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  return _list(await withAgent(ref, hostId, (c) => c.get('/v1/telegram/templates')), 'templates');
});

/// Archive of one feed (feedId) or of all feeds (null), newest first.
final telegramIssuesProvider = FutureProvider.autoDispose.family<List<Json>, (String, String?)>((ref, key) async {
  final (hostId, feedId) = key;
  autoRefresh(ref, const Duration(seconds: 20));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/telegram/issues', query: {'feedId': ?feedId, 'limit': '60'}));
  return _list(j, 'issues');
});

final telegramDeliveriesProvider = FutureProvider.autoDispose.family<List<Json>, (String, String)>((ref, key) async {
  final (hostId, recipientId) = key;
  return _list(await withAgent(ref, hostId, (c) => c.get('/v1/telegram/recipients/$recipientId/deliveries', query: {'limit': '20'})), 'deliveries');
});

/// Issue statuses that still change on the agent (the issue screen polls while in one of them).
const telegramBusyStatuses = {'researching', 'sending'};

/// Errors worth retrying: network failures and 5xx. 404 (issue gone), auth and other 4xx are final.
bool isTransientAgentError(Object e) => e is AgentError && (e.code.startsWith('net.') || (e.status ?? 0) >= 500);

/// Delay before the next fetch after [failures] consecutive transient errors: 3 s → 10 s → 30 s.
Duration retryBackoff(int failures) => switch (failures) {
      <= 1 => const Duration(seconds: 3),
      2 => const Duration(seconds: 10),
      _ => const Duration(seconds: 30),
    };

/// Consecutive transient failures per issue key (survives the provider's rebuilds; cleared on success / final error).
final _issueFailures = <(String?, String), int>{};

/// Full issue. Without a host (deep link from a notification) every agent with the telegram feature is asked; the
/// first one that knows the id wins. Returns (hostId, issue). Polls every 5 s while busy; a transient error keeps
/// polling with backoff instead of stopping it (Riverpod's own retry is off so the two don't stack).
final telegramIssueProvider = FutureProvider.autoDispose.family<(String, Json), (String?, String)>(retry: (_, _) => null, (ref, key) async {
  final (hostId, issueId) = key;
  final hosts = hostId != null ? [hostId] : [for (final h in await ref.watch(hostsWithFeatureProvider('telegram').future)) h.id];
  if (hosts.isEmpty) throw const AgentError('agent.route.notFound');
  Object? last;
  for (final h in hosts) {
    try {
      final j = await withAgent(ref, h, (c) => c.get('/v1/telegram/issues/$issueId'));
      final issue = Map<String, dynamic>.from(j['issue'] as Map);
      _issueFailures.remove(key);
      if (telegramBusyStatuses.contains(issue['status'])) autoRefresh(ref, const Duration(seconds: 5));
      return (h, issue);
    } catch (e) {
      last = e;
    }
  }
  if (isTransientAgentError(last!)) {
    final n = _issueFailures[key] = (_issueFailures[key] ?? 0) + 1;
    autoRefresh(ref, retryBackoff(n));
  } else {
    _issueFailures.remove(key);
  }
  throw last;
});

/// "Ayşe Yılmaz (@ayse)".
String recipientName(Json r) {
  final name = [r['firstName'], r['lastName']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
  final user = r['username'];
  if (name.isEmpty) return user == null ? '${r['id']}' : '@$user';
  return name;
}

String recipientStatusText(AppLocalizations l, String status) => switch (status) {
      'active' => l.tgStatusActive,
      'paused' => l.tgStatusPaused,
      'stopped' => l.tgStatusStopped,
      _ => l.tgStatusUnreachable,
    };

Color recipientStatusColor(TiphysTokens t, String status) => switch (status) {
      'active' => t.success,
      'paused' => t.warning,
      _ => t.danger,
    };

String issueStatusText(AppLocalizations l, String status) => switch (status) {
      'researching' => l.tgIssueResearching,
      'awaiting_approval' => l.tgIssueAwaiting,
      'sending' => l.tgIssueSending,
      'sent' => l.tgIssueSent,
      'skipped' => l.tgIssueSkipped,
      'failed' => l.tgIssueFailed,
      'expired' => l.tgIssueExpired,
      'rejected' => l.tgIssueRejected,
      'preview' => l.tgIssuePreview,
      _ => status,
    };

Color issueStatusColor(TiphysTokens t, String status) => switch (status) {
      'sent' => t.success,
      'researching' || 'sending' || 'preview' => t.accent,
      'awaiting_approval' => t.warning,
      'failed' || 'expired' => t.danger,
      _ => t.textSecondary,
    };

String approvalText(AppLocalizations l, Map approval) => switch (approval['mode']) {
      'auto' => l.tgApprovalAuto,
      'ask' => l.tgApprovalAsk,
      _ => l.tgApprovalFirstN((approval['n'] as num?)?.toInt() ?? 3),
    };

/// One-line summary of a feed for lists: schedule · next run.
String feedScheduleSummary(AppLocalizations l, String locale, Json feed, DateTime now) {
  final when = scheduleWhenText(l, locale, feed['when'] as Map);
  if (feed['enabled'] != true) return '$when · ${l.claudeScheduleOff}';
  final next = feed['nextRun'] == null ? null : DateTime.parse('${feed['nextRun']}').toLocal();
  return next == null ? when : '$when · ${l.claudeScheduleNext(scheduleTimeText(l, locale, next, now))}';
}

/// Editable fields of a feed (the agent's strict feed input; server-side fields dropped).
Json feedInput(Json f) => {
      'name': f['name'],
      'enabled': f['enabled'] ?? true,
      'when': f['when'],
      'topic': f['topic'],
      if (f['instructions'] != null && '${f['instructions']}'.isNotEmpty) 'instructions': f['instructions'],
      'windowHours': f['windowHours'] ?? 24,
      'language': f['language'] ?? 'tr',
      'minItems': f['minItems'] ?? 5,
      'maxItems': f['maxItems'] ?? 8,
      'maxSourcesPerItem': f['maxSourcesPerItem'] ?? 3,
      'allowDomains': f['allowDomains'] ?? const [],
      'blockDomains': f['blockDomains'] ?? const [],
      'skipIfNothingNew': f['skipIfNothingNew'] ?? true,
      'approval': {'mode': (f['approval'] as Map?)?['mode'] ?? 'firstN', 'n': (f['approval'] as Map?)?['n'] ?? 3},
      'deadlineMinutes': f['deadlineMinutes'] ?? 30,
    };

/// Hostnames from free text (comma, space or newline separated), lower case, without scheme/path/"www.".
List<String> parseDomains(String text) => {
      for (final raw in text.split(RegExp(r'[\s,;]+')))
        if (raw.trim().isNotEmpty)
          raw.trim().toLowerCase().replaceFirst(RegExp(r'^[a-z]+://'), '').split('/').first.replaceFirst(RegExp(r'^www\.'), ''),
    }.where((d) => d.isNotEmpty).toList();

/// Recipients whose subscriptions must change so that exactly [selected] get feed [feedId]: (id, new subscriptions).
List<(String, List<String>)> subscriptionChanges(List<Json> recipients, String feedId, Set<String> selected) => [
      for (final r in recipients)
        if (((r['subscriptions'] as List?) ?? const []).contains(feedId) != selected.contains(r['id']))
          (
            '${r['id']}',
            selected.contains(r['id'])
                ? [...((r['subscriptions'] as List?) ?? const []).cast<String>(), feedId]
                : [for (final s in ((r['subscriptions'] as List?) ?? const []).cast<String>()) if (s != feedId) s],
          ),
    ];

/// Seconds between two ISO times (null if either is missing).
int? secondsBetween(Object? from, Object? to) {
  if (from == null || to == null) return null;
  return DateTime.parse('$to').difference(DateTime.parse('$from')).inSeconds;
}

String shortDuration(AppLocalizations l, int seconds) => seconds < 60 ? l.durationSeconds(seconds) : l.durationMinutes((seconds / 60).round());

/// "last 24 hours" / "last 7 days" / "last N h".
String windowText(AppLocalizations l, int hours) => switch (hours) {
      24 => l.tgWindowDay,
      168 => l.tgWindowWeek,
      _ => l.tgWindowHours(hours),
    };
