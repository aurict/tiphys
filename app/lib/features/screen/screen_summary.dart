// Session summary of a screen mode (PLAN.md §20 "Ek önerilerim" 5, W7): when a mode that ran ≥ 2 min stops, the
// display agent sends ONE `screen.summary` push (numbers only: minutes, modes, focus rounds, commits, finished/failed
// jobs, Claude sessions, approvals asked). The phone adds the count of the notifications its Focus quiet filter held
// (core/push/focus_notices.dart) and shows one notification. Tapping it opens the screen mode screen with a small
// summary card. Nothing of it is stored: the numbers travel in the notification's payload and the route, the card
// lives in memory and is not shown 12 hours after the stop.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import 'screen_texts.dart';

/// The card is not shown this long after the stop.
const screenSummaryKeep = Duration(hours: 12);

@immutable
class ScreenSummary {
  const ScreenSummary({
    required this.host,
    required this.at,
    required this.minutes,
    this.modes = const [],
    this.rounds = 0,
    this.commits = 0,
    this.jobs = 0,
    this.failed = 0,
    this.sessions = 0,
    this.waits = 0,
    this.held = 0,
  });

  /// The display host (the app's host id, or the agent's name when no host matched).
  final String host;

  /// When the phone got it.
  final DateTime at;
  final int minutes;
  final List<String> modes;
  final int rounds, commits, jobs, failed, sessions, waits, held;

  /// The push params (+ the held count of the phone).
  factory ScreenSummary.fromParams(Map<String, dynamic> p, {required String host, required DateTime at, int held = 0}) {
    int n(String k) => (p[k] is num ? (p[k] as num).toInt() : int.tryParse('${p[k] ?? ''}') ?? 0).clamp(0, 1 << 30);
    return ScreenSummary(
      host: host,
      at: at,
      minutes: n('minutes'),
      modes: '${p['modes'] ?? ''}'.split(',').where(screenModeKnown).toList(),
      rounds: n('rounds'),
      commits: n('commits'),
      jobs: n('jobs'),
      failed: n('failed'),
      sessions: n('sessions'),
      waits: n('waits'),
      held: held,
    );
  }

  Map<String, Object> toJson() => {
    'host': host,
    'at': at.millisecondsSinceEpoch,
    'minutes': minutes,
    'modes': modes.join(','),
    'rounds': rounds,
    'commits': commits,
    'jobs': jobs,
    'failed': failed,
    'sessions': sessions,
    'waits': waits,
    'held': held,
  };

  static ScreenSummary? fromJson(Object? raw) {
    try {
      final j = raw is String ? jsonDecode(raw) : raw;
      if (j is! Map) return null;
      final m = Map<String, dynamic>.from(j);
      final at = (m['at'] as num?)?.toInt();
      if (at == null) return null;
      return ScreenSummary.fromParams(m, host: '${m['host'] ?? ''}', at: DateTime.fromMillisecondsSinceEpoch(at), held: (m['held'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  bool fresh(DateTime now) => now.difference(at) < screenSummaryKeep;

  @override
  bool operator ==(Object other) => other is ScreenSummary && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

bool screenModeKnown(String m) => m == 'work' || m == 'focus' || m == 'game';

/// "1 h 12 min" / "45 min".
String summaryDuration(AppLocalizations l, int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return l.durationMinutes(m);
  return m == 0 ? l.durationHours(h) : '${l.durationHours(h)} ${l.durationMinutes(m)}';
}

/// The notification: "Work + Focus ended · 1 h 12 min" and the non-zero numbers.
(String, String) screenSummaryNotice(AppLocalizations l, ScreenSummary s) {
  final modes = s.modes.isEmpty ? l.smTitle : s.modes.map((m) => screenModeName(l, m)).join(' + ');
  final parts = [
    if (s.rounds > 0) l.smSummaryRounds(s.rounds),
    if (s.commits > 0) l.smSummaryCommits(s.commits),
    if (s.jobs > 0) s.failed > 0 ? '${l.smSummaryJobs(s.jobs)} (${l.smSummaryJobsFailed(s.failed)})' : l.smSummaryJobs(s.jobs),
    if (s.sessions > 0) l.smSummarySessions(s.sessions),
    if (s.waits > 0) l.smSummaryWaits(s.waits),
    if (s.held > 0) l.smSummaryHeld(s.held),
  ];
  return (l.smSummaryTitle(modes, summaryDuration(l, s.minutes)), parts.isEmpty ? l.smSummaryNothing : parts.join(' · '));
}

/// The last summary opened from its notification (memory only).
final screenSummaryProvider = NotifierProvider<ScreenSummaryNotifier, ScreenSummary?>(ScreenSummaryNotifier.new);

class ScreenSummaryNotifier extends Notifier<ScreenSummary?> {
  @override
  ScreenSummary? build() => null;
  void show(ScreenSummary? s) => state = s;
}

/// The summary card on the screen mode screen (with a close button).
class ScreenSummaryCard extends StatelessWidget {
  const ScreenSummaryCard({super.key, required this.summary, required this.onClose});
  final ScreenSummary summary;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = summary;
    final modes = s.modes.isEmpty ? l.smTitle : s.modes.map((m) => screenModeName(l, m)).join(' + ');
    final stats = <(IconData, String, String, bool)>[
      (LucideIcons.timer, l.smSummaryDuration, summaryDuration(l, s.minutes), false),
      if (s.modes.contains('focus')) (LucideIcons.target, l.smSummaryRoundsLabel, '${s.rounds}', false),
      (LucideIcons.gitCommitHorizontal, l.smSummaryCommitsLabel, '${s.commits}', false),
      (LucideIcons.listChecks, s.failed > 0 ? '${l.smSummaryJobsLabel} · ${l.smSummaryJobsFailed(s.failed)}' : l.smSummaryJobsLabel, '${s.jobs}', s.failed > 0),
      (LucideIcons.sparkles, l.smSummarySessionsLabel, '${s.sessions}', false),
      (LucideIcons.shieldQuestion, l.smSummaryWaitsLabel, '${s.waits}', false),
      if (s.held > 0) (LucideIcons.bellOff, l.smSummaryHeldLabel, '${s.held}', false),
    ];
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.chartNoAxesColumn, size: 20, color: t.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.smSummaryCardTitle, style: tt.titleMedium),
                    Text(modes, style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(tooltip: l.commonClose, icon: const Icon(LucideIcons.x, size: 20), onPressed: onClose),
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
          const SizedBox(height: 10),
          Text(l.smSummaryCardNote, style: tt.bodySmall?.copyWith(color: t.textSecondary)),
        ],
      ),
    );
  }
}
