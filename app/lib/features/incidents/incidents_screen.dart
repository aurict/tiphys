// System › Monitoring › Incidents (PLAN.md §13.1): the incidents of every agent with the `incidents` feature, tabs
// Open / Acknowledged / Resolved, host and kind chips. The "Open incidents" card on the home screen lives here too.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import '../system/agent_providers.dart';
import '../system/events.dart' show ChipRow, filterChip;
import 'incident_texts.dart';
import 'incidents_data.dart';

String incidentStatusName(AppLocalizations l, String status) => switch (status) {
      'open' => l.incStatusOpen,
      'acknowledged' => l.incStatusAck,
      _ => l.incStatusResolved,
    };

/// Color of a status: open red, acknowledged amber, resolved green.
Color incidentStatusColor(TiphysTokens t, String status) => switch (status) {
      'open' => t.danger,
      'acknowledged' => t.warning,
      _ => t.success,
    };

/// Row icon by kind family and its color by state (resolved green, else severity).
(IconData, Color) incidentVisual(TiphysTokens t, IncidentSummary i) {
  final icon = switch (i.family) {
    'container' => LucideIcons.box,
    'service' => LucideIcons.cog,
    'disk' => LucideIcons.hardDrive,
    'site' => LucideIcons.activity,
    'alert' => LucideIcons.chartLine,
    'backup' => LucideIcons.archive,
    'host' => LucideIcons.server,
    _ => LucideIcons.triangleAlert,
  };
  final color = i.status == 'resolved' ? t.success : (i.severity == 'critical' ? t.danger : t.warning);
  return (icon, color);
}

/// Small status pill.
class IncidentStatusChip extends StatelessWidget {
  const IncidentStatusChip(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = incidentStatusColor(context.tokens, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
      child: Text(incidentStatusName(AppLocalizations.of(context), status),
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

void openIncident(BuildContext context, IncidentSummary i) => context.push('/incidents/${i.id}?host=${i.host.id}');

class IncidentRow extends ConsumerWidget {
  const IncidentRow({super.key, required this.incident, this.showHost = true});
  final IncidentSummary incident;
  final bool showHost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final i = incident;
    final (icon, color) = incidentVisual(t, i);
    final age = relativeTime(l, i.sortTime, ref.watch(clockProvider)());
    return GroupedRow(
      title: incidentTitle(l, i.kind, i.target),
      subtitle: [if (showHost) i.host.name, incidentStatusName(l, i.status), age, l.incSignals(i.signalCount)].join(' · '),
      icon: icon,
      iconBackground: color,
      onTap: () => openIncident(context, i),
    );
  }
}

class IncidentsScreen extends ConsumerStatefulWidget {
  const IncidentsScreen({super.key});
  @override
  ConsumerState<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends ConsumerState<IncidentsScreen> {
  String _status = 'open';
  String? _host; // null = all
  String? _family;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final hosts = ref.watch(incidentHostsProvider);
    final feed = ref.watch(incidentsFeedProvider);
    final now = ref.watch(clockProvider)();
    String day(DateTime d) {
      final today = DateTime(now.year, now.month, now.day);
      if (d == today) return l.eventsToday;
      if (d == today.subtract(const Duration(days: 1))) return l.eventsYesterday;
      return DateFormat('d MMMM EEEE', locale).format(d);
    }

    Future<void> refresh() async {
      ref.invalidate(incidentHostsProvider);
      ref.invalidate(incidentsFeedProvider);
      await ref.read(incidentsFeedProvider.future).catchError((_) => const IncidentsFeed(incidents: [], errors: {}, hosts: []));
    }

    return SettingsPage(
      title: l.incTitle,
      onRefresh: refresh,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: refresh)],
      children: hosts.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (hs) {
          if (hs.isEmpty) return [TCard(child: Text(l.incNoAgents))];
          return feed.when(
            skipLoadingOnRefresh: true,
            loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
            data: (f) {
              final inStatus = f.incidents.where((i) => i.status == _status).toList();
              final families = incidentFamilies.where((k) => inStatus.any((i) => i.family == k)).toList();
              final shown = filterIncidents(f.incidents, status: _status, hostId: _host, family: _family);
              final groups = groupIncidentsByDay(shown);
              return [
                const SizedBox(height: 6),
                _StatusTabs(feed: f, selected: _status, onSelect: (s) => setState(() => _status = s)),
                if (f.hosts.length > 1)
                  ChipRow(children: [
                    filterChip(context, l.incAllHosts, _host == null, () => setState(() => _host = null)),
                    for (final h in f.hosts) filterChip(context, h.name, _host == h.id, () => setState(() => _host = h.id), dot: t.hostColor(hexColor(h.color))),
                  ]),
                if (families.length > 1)
                  ChipRow(children: [
                    filterChip(context, l.incAllKinds, _family == null, () => setState(() => _family = null)),
                    for (final k in families) filterChip(context, incidentFamilyName(l, k), _family == k, () => setState(() => _family = k)),
                  ]),
                for (final MapEntry(key: hostId, value: err) in f.errors.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: TCard(
                      child: Row(children: [
                        Icon(LucideIcons.circleAlert, color: t.danger),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('${l.incHostFailed(f.hosts.firstWhere((h) => h.id == hostId).name)}\n${agentErrorText(l, err)}',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                      ]),
                    ),
                  ),
                if (shown.isEmpty && f.errors.length < f.hosts.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TCard(
                      child: Text(inStatus.isNotEmpty
                          ? l.incEmptyFiltered
                          : switch (_status) {
                              'open' => l.incEmptyOpen,
                              'acknowledged' => l.incEmptyAck,
                              _ => l.incEmptyResolved,
                            }),
                    ),
                  ),
                for (final g in groups) GroupedSection(title: day(g.day), children: [for (final i in g.items) IncidentRow(incident: i, showHost: f.hosts.length > 1)]),
              ];
            },
          );
        },
      ),
    );
  }
}

/// Open / Acknowledged / Resolved with counts.
class _StatusTabs extends StatelessWidget {
  const _StatusTabs({required this.feed, required this.selected, required this.onSelect});
  final IncidentsFeed feed;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.separator)),
      child: Row(children: [
        for (final s in incidentStatuses)
          Expanded(
            child: Semantics(
              button: true,
              selected: s == selected,
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => onSelect(s),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                  decoration: BoxDecoration(
                    color: s == selected ? (t.isDark ? t.tabActive : const Color(0xFF111114)) : null,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '${incidentStatusName(l, s)} ${feed.count(s)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: s == selected ? (t.isDark ? Colors.black : Colors.white) : t.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Home screen: "Open incidents" card (count + the latest one). Hidden unless an agent has the feature.
class HomeIncidentsCard extends ConsumerWidget {
  const HomeIncidentsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final f = ref.watch(incidentsFeedProvider).value;
    final open = f == null ? const <IncidentSummary>[] : filterIncidents(f.incidents, status: 'open');
    final latest = open.isEmpty ? null : ([...open]..sort((a, b) => b.lastSignalAt.compareTo(a.lastSignalAt))).first;
    final String title;
    final String? subtitle;
    if (f == null) {
      title = l.commonLoading;
      subtitle = null;
    } else if (open.isEmpty) {
      title = f.errors.isNotEmpty && f.errors.length == f.hosts.length ? l.homeNotConnected : l.homeIncidentsNone;
      subtitle = null;
    } else {
      title = l.homeIncidentsCount(open.length);
      subtitle = [incidentTitle(l, latest!.kind, latest.target), if (f.hosts.length > 1) latest.host.name].join(' · ');
    }
    return GroupedSection(title: l.homeIncidentsTitle, children: [
      GroupedRow(
        title: title,
        subtitle: subtitle,
        icon: open.isEmpty ? LucideIcons.shieldCheck : LucideIcons.siren,
        iconBackground: open.isEmpty ? t.success : t.danger,
        onTap: () => context.push('/incidents'),
      ),
    ]);
  }
}
