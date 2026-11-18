// Security center (PLAN.md §15, S-1): the audited hosts of every agent with the `security` feature, each with its score,
// severity counts, pending changes and "last known state" when the host could not be checked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import '../system/agent_providers.dart';
import 'security_data.dart';
import 'security_texts.dart';
import 'security_widgets.dart';

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final feed = ref.watch(securityFeedProvider);
    final agents = ref.watch(securityHostsProvider);
    Future<void> refresh() async {
      ref.invalidate(securityHostsProvider);
      ref.invalidate(securityFeedProvider);
      await ref.read(securityFeedProvider.future).then((_) {}, onError: (_) {});
    }

    return SettingsPage(
      title: l.secTitle,
      onRefresh: refresh,
      actions: [
        IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: refresh),
        PopupMenuButton<String>(
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onSelected: (_) => context.push('/security/settings'),
          itemBuilder: (_) => [PopupMenuItem(value: 'settings', child: Text(l.secMenuSettings))],
        ),
      ],
      children: agents.hasValue && agents.value!.isEmpty
          ? [TCard(child: Text(l.secNoAgents))]
          : feed.when(
              skipLoadingOnRefresh: true,
              loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
              error: (e, _) => [
                TCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(agentErrorText(l, e)),
                    TextButton(onPressed: refresh, child: Text(l.commonRetry)),
                  ]),
                ),
              ],
              data: (f) {
                if (f.agents.isEmpty) return [TCard(child: Text(l.secNoAgents))];
                final multi = f.agents.length > 1;
                return [
                  for (final a in f.agents) ...[
                    if (multi) SectionLabel(a.name),
                    if (f.errors[a.id] case final err?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TCard(
                          child: Row(children: [
                            Icon(LucideIcons.circleAlert, color: t.danger),
                            const SizedBox(width: 10),
                            Expanded(child: Text('${l.secHostFailed(a.name)}\n${agentErrorText(l, err)}')),
                          ]),
                        ),
                      ),
                    for (final o in f.overviews.where((o) => o.agent.id == a.id)) ...[
                      if (o.hosts.isEmpty) TCard(child: Text(l.secNoneAudited)),
                      for (final h in o.hosts) Padding(padding: const EdgeInsets.only(bottom: 10), child: SecurityHostCard(host: h)),
                      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text(l.secInterval(o.intervalMinutes), style: Theme.of(context).textTheme.bodySmall)),
                    ],
                  ],
                ];
              },
            ),
    );
  }
}

class SecurityHostCard extends ConsumerWidget {
  const SecurityHostCard({super.key, required this.host});
  final SecurityHostSummary host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    final h = host;
    final err = h.lastError;
    final last = h.lastOkAt;
    final staleLine = !h.showStale
        ? null
        : last == null
            ? l.secNeverChecked
            : l.secStaleSince(relativeTime(l, last, now));
    final summary = [
      h.name,
      securityRoleName(l, h.role),
      securitySourceName(l, h.source),
      if (h.changes > 0) l.secChangesChip(h.changes),
      if (h.score != null) l.secScoreSemantic(h.score!),
      if (h.running) l.secChecking,
      ?staleLine,
      if (err != null) securityErrorText(l, err.code),
    ].join(', ');
    return TCard(
      semanticLabel: summary,
      onTap: () => context.push(securityRoute(h.id, agentId: h.agent.id)),
      child: ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ScoreBadge(score: h.score),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(h.name, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${securityRoleName(l, h.role)} · ${securitySourceName(l, h.source)}', style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (h.running) const Padding(padding: EdgeInsets.only(left: 8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            const Icon(LucideIcons.chevronRight, size: 18),
          ]),
          if (h.changes > 0 || h.counts.total > 0) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (h.changes > 0) SecChip(l.secChangesChip(h.changes), t.warning, filled: true, icon: LucideIcons.gitCompareArrows),
              for (final s in securityFindingSeverities)
                if (h.counts.of(s) > 0) SecChip(l.secSeverityCount(h.counts.of(s), securitySeverityName(l, s)), securitySeverityColor(t, s)),
            ]),
          ],
          if (staleLine != null || err != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.clockAlert, size: 15, color: t.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [?staleLine, if (err != null) securityErrorText(l, err.code)].join('\n'),
                  style: tt.bodySmall?.copyWith(color: t.textSecondary),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Home screen: only when some host has pending changes or critical findings (follows the open-incidents card).
class HomeSecurityCard extends ConsumerWidget {
  const HomeSecurityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    if (ref.watch(securityHostsProvider).value?.isNotEmpty != true) return const SizedBox.shrink();
    final f = ref.watch(securityFeedProvider).value;
    if (f == null || !f.needsAttention) return const SizedBox.shrink();
    final title = f.changes > 0 && f.critical > 0
        ? l.secHomeBoth(f.changes, f.critical)
        : f.changes > 0
            ? l.secHomeChanges(f.changes)
            : l.secHomeCritical(f.critical);
    final names = [for (final h in f.hosts) if (h.changes > 0 || h.counts.critical > 0) h.name];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GroupedSection(title: l.secRowTitle, children: [
        GroupedRow(
          title: title,
          subtitle: names.join(', '),
          icon: LucideIcons.shieldAlert,
          iconBackground: f.critical > 0 ? t.danger : t.warning,
          onTap: () => context.push('/security'),
        ),
      ]),
    );
  }
}
