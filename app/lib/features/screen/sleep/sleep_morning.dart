// Sleep mode morning summary (PLAN.md §21 A6/U4): when the alarm is dismissed (or the mode stops without one) the
// leader sends ONE `sleep.morning` push: how long the night was, the jobs that finished (and failed), the backups, the
// server incidents and the notifications that waited (their count and the first three titles). Tapping it opens the
// sleep screen with this card; the home screen shows a small card for 12 hours. Nothing is stored: the numbers ride in
// the notification's payload and the route, the card lives in memory; the agent keeps the last one in memory too
// (GET /v1/sleep/summary, 12 h), which the home card reads when the app wasn't opened from the notification.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/surfaces.dart';
import '../../system/agent_providers.dart';
import '../screen_summary.dart' show summaryDuration;
import 'sleep_data.dart';
import 'sleep_widgets.dart';

/// The card is not shown this long after the summary arrived.
const sleepMorningKeep = Duration(hours: 12);

@immutable
class SleepMorning {
  const SleepMorning({
    required this.at,
    this.host = '',
    this.minutes = 0,
    this.jobs = 0,
    this.jobsFailed = 0,
    this.backups = 0,
    this.backupsFailed = 0,
    this.incidents = 0,
    this.held = 0,
    this.titles = const [],
  });

  /// When it was made (the agent's `at`) or arrived.
  final DateTime at;

  /// The leader (the app's host id, or the agent's name when no host matched).
  final String host;
  final int minutes, jobs, jobsFailed, backups, backupsFailed, incidents, held;

  /// The first (up to three) titles of the notifications that waited.
  final List<String> titles;

  /// The push params (or GET /v1/sleep/summary's `summary`): numbers, `titles` as a list or one text per line.
  factory SleepMorning.fromParams(Map p, {required DateTime at, String host = ''}) {
    int n(String k) => (p[k] is num ? (p[k] as num).toInt() : int.tryParse('${p[k] ?? ''}') ?? 0).clamp(0, 1 << 30);
    final t = p['titles'];
    final titles = t is List ? [for (final x in t) '$x'] : (t is String ? t.split('\n') : const <String>[]);
    return SleepMorning(
      at: at,
      host: host,
      minutes: n('minutes'),
      jobs: n('jobs'),
      jobsFailed: n('jobsFailed'),
      backups: n('backups'),
      backupsFailed: n('backupsFailed'),
      incidents: n('incidents'),
      held: n('held'),
      titles: [
        for (final x in titles)
          if (x.trim().isNotEmpty) x.trim().length > 120 ? x.trim().substring(0, 120) : x.trim(),
      ].take(3).toList(),
    );
  }

  Map<String, Object> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'host': host,
    'minutes': minutes,
    'jobs': jobs,
    'jobsFailed': jobsFailed,
    'backups': backups,
    'backupsFailed': backupsFailed,
    'incidents': incidents,
    'held': held,
    'titles': titles,
  };

  static SleepMorning? fromJson(Object? raw) {
    try {
      final j = raw is String ? jsonDecode(raw) : raw;
      if (j is! Map) return null;
      final at = (j['at'] as num?)?.toInt();
      if (at == null) return null;
      return SleepMorning.fromParams(j, at: DateTime.fromMillisecondsSinceEpoch(at), host: '${j['host'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  bool fresh(DateTime now) => now.difference(at) < sleepMorningKeep && !at.isAfter(now.add(const Duration(minutes: 10)));

  @override
  bool operator ==(Object other) => other is SleepMorning && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The notification: "Günaydın · 7 sa 40 dk uyku" and the non-zero numbers.
(String, String) sleepMorningNotice(AppLocalizations l, SleepMorning s) {
  final parts = [
    if (s.jobs > 0) s.jobsFailed > 0 ? '${l.slMorningJobs(s.jobs)} (${l.smSummaryJobsFailed(s.jobsFailed)})' : l.slMorningJobs(s.jobs),
    if (s.backups > 0) s.backupsFailed > 0 ? '${l.slMorningBackups(s.backups)} (${l.smSummaryJobsFailed(s.backupsFailed)})' : l.slMorningBackups(s.backups),
    if (s.incidents > 0) l.slMorningIncidents(s.incidents),
    if (s.held > 0) l.slMorningHeld(s.held),
  ];
  return (l.slMorningTitle(summaryDuration(l, s.minutes)), parts.isEmpty ? l.slMorningQuiet : parts.join(' · '));
}

/// The summary opened from its notification (memory only).
final sleepMorningShownProvider = NotifierProvider<SleepMorningNotifier, SleepMorning?>(SleepMorningNotifier.new);

class SleepMorningNotifier extends Notifier<SleepMorning?> {
  @override
  SleepMorning? build() => null;
  void show(SleepMorning? s) => state = s;
}

/// The morning summary to show now: the one from the notification, else the leader's (GET /v1/sleep/summary; an agent
/// without it: none). Null when there is none or it is older than 12 h.
final sleepMorningProvider = FutureProvider.autoDispose<SleepMorning?>((ref) async {
  final now = DateTime.now();
  final shown = ref.watch(sleepMorningShownProvider);
  if (shown != null) return shown.fresh(now) ? shown : null;
  final g = await ref.watch(sleepGroupProvider.future);
  final leader = g.leader;
  if (leader == null) return null;
  try {
    final j = await withAgent(ref, leader.host.id, (c) => c.get('/v1/sleep/summary'));
    final raw = j['summary'] is Map ? j['summary'] as Map : null;
    final at = (raw?['at'] as num?)?.toInt();
    if (raw == null || at == null) return null;
    final s = SleepMorning.fromParams(raw, at: DateTime.fromMillisecondsSinceEpoch(at - (leader.status?.skewMs ?? 0)), host: leader.host.id);
    return s.fresh(now) ? s : null;
  } catch (_) {
    return null;
  }
});

/// The summary card (sleep screen; on the home screen [compact]).
class SleepMorningCard extends StatelessWidget {
  const SleepMorningCard({super.key, required this.summary, this.onClose, this.compact = false});
  final SleepMorning summary;
  final VoidCallback? onClose;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = summary;
    final sun = sleepSunColor(t);
    if (compact) {
      final (_, body) = sleepMorningNotice(l, s);
      return TCard(
        onTap: () => context.push('/screen/sleep?morning=${Uri.encodeQueryComponent(jsonEncode(s.toJson()))}'),
        semanticLabel: l.slMorningCardTitle,
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: sun.withValues(alpha: t.isDark ? 0.18 : 0.16), borderRadius: BorderRadius.circular(12)),
              child: Icon(LucideIcons.sunrise, size: 20, color: t.isDark ? sun : Color.lerp(sun, Colors.black, 0.3)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.slMorningTitle(summaryDuration(l, s.minutes)), style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(body, style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 18, color: t.textSecondary),
          ],
        ),
      );
    }
    final stats = <(IconData, String, String, bool)>[
      (LucideIcons.bedDouble, l.slMorningSlept, summaryDuration(l, s.minutes), false),
      (LucideIcons.listChecks, s.jobsFailed > 0 ? '${l.smSummaryJobsLabel} · ${l.smSummaryJobsFailed(s.jobsFailed)}' : l.smSummaryJobsLabel, '${s.jobs}', s.jobsFailed > 0),
      (LucideIcons.archive, s.backupsFailed > 0 ? '${l.slMorningBackupsLabel} · ${l.smSummaryJobsFailed(s.backupsFailed)}' : l.slMorningBackupsLabel, '${s.backups}', s.backupsFailed > 0),
      (LucideIcons.siren, l.slMorningIncidentsLabel, '${s.incidents}', s.incidents > 0),
      (LucideIcons.bellOff, l.slMorningHeldLabel, '${s.held}', false),
    ];
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.sunrise, size: 20, color: t.isDark ? sun : Color.lerp(sun, Colors.black, 0.3)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.slMorningCardTitle, style: tt.titleMedium),
                    Text(l.slMorningTitle(summaryDuration(l, s.minutes)), style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (onClose != null) IconButton(tooltip: l.commonClose, icon: const Icon(LucideIcons.x, size: 20), onPressed: onClose),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - 10) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (icon, label, value, bad) in stats)
                      SizedBox(
                        width: w,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(14)),
                          child: Row(
                            children: [
                              Icon(icon, size: 18, color: bad ? t.danger : t.textSecondary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      value,
                                      style: tt.titleMedium?.copyWith(color: bad ? t.danger : null, fontFeatures: const [FontFeature.tabularFigures()]),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(label, style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          if (s.titles.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(l.slMorningHeldFirst, style: tt.bodySmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final x in s.titles)
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 7), child: StatusDot(color: t.textSecondary, size: 5)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(x, style: tt.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 10),
          Text(l.smSummaryCardNote, style: tt.bodySmall?.copyWith(color: t.textSecondary)),
        ],
      ),
    );
  }
}
