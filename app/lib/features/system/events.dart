// System › Events: event feed (/v1/events) of all agent hosts on a single timeline. The event text comes from the
// same function as the notification text (noticeText); tapping goes to the screen the notification's link opens.
// The "Recent events" card on the home screen also uses the provider here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/push/push_service.dart';
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'agent_providers.dart';

class HostEvent {
  HostEvent(this.host, Map j)
      : id = '${j['id']}',
        key = '${j['key']}',
        params = Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
        link = j['link'] as String?,
        fromPhone = j['source'] == 'app',
        at = DateTime.parse('${j['at']}').toLocal();
  final Host host;
  final String id;
  final String key;
  final Map<String, dynamic> params;
  final String? link;
  final bool fromPhone;
  final DateTime at;
}

class EventsFeed {
  const EventsFeed({required this.events, required this.errors, required this.hosts});
  final List<HostEvent> events;

  /// Hosts whose events couldn't be fetched (hostId → error). Events of other hosts are still shown.
  final Map<String, Object> errors;
  final List<Host> hosts;
}

/// The newest [limit] events from all agent hosts in parallel. One host's error doesn't break the others.
final eventsFeedProvider = FutureProvider.autoDispose.family<EventsFeed, int>((ref, limit) async {
  autoRefresh(ref, const Duration(seconds: 60));
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final results = await Future.wait(hosts.map((h) async {
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/events', query: {'limit': '$limit'})).timeout(const Duration(seconds: 15));
      return (h, [for (final e in (j['events'] as List).cast<Map>()) HostEvent(h, e)], null);
    } catch (e) {
      return (h, const <HostEvent>[], e);
    }
  }));
  final events = [for (final r in results) ...r.$2]..sort((a, b) => b.at.compareTo(a.at));
  return EventsFeed(
    events: events.take(limit).toList(),
    errors: {for (final r in results) if (r.$3 != null) r.$1.id: r.$3!},
    hosts: hosts,
  );
});

/// Type for the filter: grouped by the first segment of the key.
String eventType(String key) => switch (key.split('.').first) {
      'claude' => 'claude',
      'docker' || 'compose' => 'docker',
      'backup' => 'backup',
      'grafana' => 'grafana',
      'command' => 'command',
      'host' || 'disk' || 'service' || 'agent' || 'push' || 'control' || 'ui' || 'gamemode' || 'security' || 'blackbox' => 'system',
      _ => 'other',
    };

const eventTypes = ['system', 'docker', 'backup', 'claude', 'grafana', 'command', 'other'];

String eventTypeName(AppLocalizations l, String type) => switch (type) {
      'system' => l.eventsTypeSystem,
      'docker' => 'Docker',
      'backup' => l.eventsTypeBackup,
      'claude' => 'Claude',
      'grafana' => 'Grafana',
      'command' => l.eventsTypeCommand,
      _ => l.eventsTypeOther,
    };

/// Event icon and color: bad news red, recovery green, others the type's color.
(IconData, Color) eventVisual(TiphysTokens t, String key) {
  const bad = {
    'host.offline', 'disk.full', 'service.failed', 'grafana.alert', 'agent.restarted', 'command.failed', 'claude.error', 'docker.died', 'docker.oom', //
    'backup.failed', 'backup.stale', 'security.unreachable', 'compose.failed', 'claude.scheduleFailed', 'config.restartFailed', 'db.restoreTest.failed',
    'security.trap', 'security.secretFound', 'blackbox.broken', 'security.lockdown',
  };
  const good = {'host.online', 'disk.ok', 'service.recovered', 'grafana.resolved', 'command.done', 'backup.ok', 'compose.updated', 'db.restoreTest.ok', 'security.reachable', 'security.accepted'};
  final icon = key.startsWith('claude.schedule') ? LucideIcons.alarmClock : switch (key.split('.').first) {
    'claude' => LucideIcons.asterisk,
    'host' => LucideIcons.server,
    'disk' => LucideIcons.hardDrive,
    'service' => LucideIcons.cog,
    'grafana' => LucideIcons.chartLine,
    'command' => LucideIcons.terminal,
    'docker' => LucideIcons.box,
    'compose' => LucideIcons.layers,
    'backup' => LucideIcons.archive,
    'agent' => LucideIcons.rotateCcw,
    'push' => LucideIcons.bell,
    'git' => LucideIcons.gitCommitHorizontal,
    'control' => LucideIcons.mousePointer2,
    'ui' => LucideIcons.layoutList,
    'gamemode' => LucideIcons.gamepad2,
    'security' || 'blackbox' => LucideIcons.shieldAlert,
    _ => LucideIcons.dot,
  };
  final color = bad.contains(key)
      ? t.danger
      : good.contains(key)
          ? t.success
          : key == 'claude.waiting' || key == 'docker.restarted' || key == 'claude.scheduleSkipped' || key == 'control.started'
              ? t.warning
              : key.startsWith('claude.')
                  ? const Color(0xFF5E5CE6)
                  : const Color(0xFF6C6C70);
  return (icon, color);
}

/// Event title and body; for an unknown key (e.g. a newer agent) a generic title from its type.
(String, String) eventText(AppLocalizations l, HostEvent e) =>
    noticeText(l, e.key, e.params) ?? (l.eventsUnknownTitle(eventTypeName(l, eventType(e.key))), e.params.values.join(' · '));

void openEvent(BuildContext context, HostEvent e) {
  final route = routeForLink(e.link);
  if (route == null) return;
  // Bottom tabs (tab shell) open with go, other screens with push; same target as opening from the notification.
  if (route.startsWith('/incidents/')) {
    context.push('$route?host=${e.host.id}');
    return;
  }
  if (route.startsWith('/security/')) {
    context.push('$route?host=${e.host.id}');
    return;
  }
  if (const {'/system', '/terminal', '/claude', '/files', '/'}.contains(route)) {
    context.go(route);
  } else {
    context.push(route);
  }
}

class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key});
  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> {
  String? _host; // null = all
  String? _type;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final feed = ref.watch(eventsFeedProvider(200));
    final now = ref.watch(clockProvider)();
    String day(DateTime d) {
      final today = DateTime(now.year, now.month, now.day);
      final dd = DateTime(d.year, d.month, d.day);
      if (dd == today) return l.eventsToday;
      if (dd == today.subtract(const Duration(days: 1))) return l.eventsYesterday;
      return DateFormat('d MMMM EEEE', locale).format(d);
    }

    return SettingsPage(
      title: l.eventsTitle,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(eventsFeedProvider(200)))],
      children: feed.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (f) {
          if (f.hosts.isEmpty) return [TCard(child: Text(l.eventsNoAgents))];
          final shown = f.events.where((e) => (_host == null || e.host.id == _host) && (_type == null || eventType(e.key) == _type)).toList();
          final types = eventTypes.where((ty) => f.events.any((e) => eventType(e.key) == ty)).toList();
          final groups = <String, List<HostEvent>>{};
          for (final e in shown) {
            groups.putIfAbsent(day(e.at), () => []).add(e);
          }
          return [
            if (f.hosts.length > 1)
              ChipRow(children: [
                filterChip(context, l.eventsAllHosts, _host == null, () => setState(() => _host = null)),
                for (final h in f.hosts)
                  filterChip(context, h.name, _host == h.id, () => setState(() => _host = h.id), dot: t.hostColor(hexColor(h.color))),
              ]),
            if (types.length > 1)
              ChipRow(children: [
                filterChip(context, l.eventsAllTypes, _type == null, () => setState(() => _type = null)),
                for (final ty in types) filterChip(context, eventTypeName(l, ty), _type == ty, () => setState(() => _type = ty)),
              ]),
            for (final MapEntry(key: hostId, value: err) in f.errors.entries)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TCard(
                  child: Row(children: [
                    Icon(LucideIcons.circleAlert, color: t.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${l.eventsHostFailed(f.hosts.firstWhere((h) => h.id == hostId).name)}\n${agentErrorText(l, err)}',
                          style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  ]),
                ),
              ),
            if (shown.isEmpty && f.errors.length < f.hosts.length)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TCard(child: Text(f.events.isEmpty ? l.eventsEmpty : l.eventsEmptyFiltered)),
              ),
            for (final g in groups.entries)
              GroupedSection(title: g.key, children: [for (final e in g.value) EventRow(event: e, showHost: f.hosts.length > 1)]),
          ];
        },
      ),
    );
  }
}

/// Horizontally scrolling filter chips (also used by the compose screen).
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [for (final c in children) Padding(padding: const EdgeInsets.only(right: 8), child: c)]),
        ),
      );
}

/// Same look as the host picker in the System tab.
Widget filterChip(BuildContext context, String label, bool selected, VoidCallback onTap, {Color? dot}) {
  final t = context.tokens;
  return ChoiceChip(
    selected: selected,
    showCheckmark: false,
    avatar: dot == null ? null : StatusDot(color: dot, size: 8, square: true),
    label: Text(label),
    onSelected: (_) => onTap(),
    selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
    labelStyle: TextStyle(color: selected ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
    backgroundColor: t.chipBackground,
    side: BorderSide(color: t.separator),
    shape: const StadiumBorder(),
  );
}

class EventRow extends StatelessWidget {
  const EventRow({super.key, required this.event, this.showHost = true});
  final HostEvent event;
  final bool showHost;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final (title, body) = eventText(l, event);
    final (icon, color) = eventVisual(t, event.key);
    final canOpen = routeForLink(event.link) != null;
    final meta = [
      DateFormat.Hm(Localizations.localeOf(context).toLanguageTag()).format(event.at),
      if (showHost) event.host.name,
      if (event.fromPhone) l.eventsFromPhone,
    ].join(' · ');
    // The notification body often starts with the host name ("atlas · last backup…"); don't repeat it if the host
    // is already at the start of the line.
    final agentHost = '${event.params['host'] ?? ''}';
    final parts = body.split('\n').first.trim().split(' · ');
    if (showHost && !event.fromPhone && agentHost.isNotEmpty && parts.first == agentHost) parts.removeAt(0);
    final firstLine = parts.join(' · ');
    return GroupedRow(
      title: title,
      subtitle: firstLine.isEmpty ? meta : '$meta · $firstLine',
      icon: icon,
      iconBackground: color,
      showChevron: canOpen,
      onTap: canOpen ? () => openEvent(context, event) : null,
    );
  }
}

/// Home screen: "Recent events" card (last 3 events).
class HomeEventsCard extends ConsumerWidget {
  const HomeEventsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final feed = ref.watch(eventsFeedProvider(10));
    final f = feed.value;
    final status = feed.isLoading && f == null
        ? l.commonLoading
        : f == null || (f.events.isEmpty && f.errors.isNotEmpty)
            ? l.homeNotConnected
            : f.events.isEmpty
                ? l.eventsEmpty
                : null;
    return GroupedSection(title: l.homeCardsEvents, children: [
      if (status != null)
        GroupedRow(title: status, icon: LucideIcons.history, iconBackground: const Color(0xFF6C6C70), showChevron: false)
      else
        for (final e in f!.events.take(3)) EventRow(event: e, showHost: f.hosts.length > 1),
      GroupedRow(
        title: l.homeEventsAll,
        icon: LucideIcons.listFilter,
        iconBackground: t.accent,
        onTap: () => context.push('/system/events'),
      ),
    ]);
  }
}
