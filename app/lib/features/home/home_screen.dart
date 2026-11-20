// Home screen: "6 · Porselen × Bento" design.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/push/push_service.dart' show routeForLink;
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/floating_tab_bar.dart';
import '../../widgets/painters.dart';
import '../../widgets/surfaces.dart';
import '../gamemode/gamemode_card.dart';
import '../incidents/incidents_data.dart' show incidentHostsProvider;
import '../incidents/incidents_screen.dart' show HomeIncidentsCard;
import '../security/security_home_card.dart' show SecurityHomeCard;
import '../security/security_screen.dart' show HomeSecurityCard;
import '../system/events.dart';
import '../system/media.dart';
import 'home_data.dart';
import 'shortcuts.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profile = ref.watch(profileProvider);
    final data = ref.watch(homeDataProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final date = DateFormat('EEEE, d MMMM', locale).format(ref.watch(clockProvider)());
    final layout = profile.app.layout;
    final shortcuts = visibleShortcuts(ref, l);

    final top = <Widget>[
      if (layout == HomeLayout.grid) ...[
        _StatusStrip(profile: profile, data: data),
        if (shortcuts.isNotEmpty) _ShortcutGrid(ids: shortcuts),
      ],
      if (layout == HomeLayout.focus) ...[
        _StatusHero(profile: profile, data: data),
        if (shortcuts.isNotEmpty)
          GroupedSection(title: l.homeShortcuts, children: [for (final id in shortcuts) ShortcutRow(id: id, data: data)]),
      ],
    ];
    // In the Shortcuts and Focus layouts shortcuts are on top; the Quick access card only in the Cards layout.
    final sections = _cardSections(
      layout == HomeLayout.cards ? profile.app.cards : profile.app.cards.where((c) => c != 'quickAccess').toList(),
      profile,
      data,
      shortcuts,
    );

    return ListView(
      padding: EdgeInsets.fromLTRB(
        TiphysTokens.gutter,
        MediaQuery.paddingOf(context).top + 18,
        TiphysTokens.gutter,
        // The bottom system bar (gesture/button navigation) pushes the floating bar up; content ends above it too.
        FloatingTabBar.height + FloatingTabBar.bottomGap + 24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        LargeTitleHeader(
          overline: date,
          title: l.appName,
          action: RoundIconButton(icon: LucideIcons.settings, tooltip: l.settingsTitle, onPressed: () => context.push('/settings')),
        ),
        if (ref.watch(incidentHostsProvider).value?.isNotEmpty == true) const Padding(padding: EdgeInsets.only(top: 12), child: HomeIncidentsCard()),
        // The small attention row would duplicate the Security card.
        if (!profile.app.cards.contains('security')) const HomeSecurityCard(),
        for (final s in [...top, ...sections])
          if (s is! SizedBox) Padding(padding: const EdgeInsets.only(top: 12), child: s),
      ],
    );
  }

  /// Enabled cards in profile order.
  List<Widget> _cardSections(List<String> cards, Profile profile, HomeData data, List<String> shortcuts) {
    final sections = <Widget>[
      for (final c in cards)
        switch (c) {
          'infra' => _InfraCard(profile: profile, data: data),
          'claude' || 'system' => const SizedBox.shrink(), // drawn in the paired row
          'grafana' || 'dozzle' => const SizedBox.shrink(),
          'quickAccess' => shortcuts.isEmpty ? const SizedBox.shrink() : _QuickAccess(ids: shortcuts, data: data),
          'events' => const HomeEventsCard(),
          'nowPlaying' => const NowPlayingCard(),
          'security' => const SecurityHomeCard(),
          'gameMode' => const GameModeHomeCard(),
          _ => const SizedBox.shrink(),
        },
    ];
    // Claude + PC status side by side; Grafana + Dozzle side by side (as in the design), at their first sort position.
    final pairs = <(String, String)>[('claude', 'system'), ('grafana', 'dozzle')];
    for (final (a, b) in pairs) {
      final ia = cards.indexOf(a), ib = cards.indexOf(b);
      if (ia < 0 && ib < 0) continue;
      final at = [ia, ib].where((i) => i >= 0).reduce((x, y) => x < y ? x : y);
      sections[at] = _Pair(
        left: ia >= 0 ? _tile(a, profile, data) : null,
        right: ib >= 0 ? _tile(b, profile, data) : null,
      );
    }
    return sections;
  }

  Widget _tile(String id, Profile p, HomeData d) => switch (id) {
        'claude' => _ClaudeTile(data: d),
        'system' => _SystemTile(profile: p, data: d),
        'grafana' => _GrafanaTile(profile: p, data: d),
        'dozzle' => _DozzleTile(profile: p, data: d),
        _ => const SizedBox.shrink(),
      };
}

/// Fixed-height boxes must not overflow at large text scales: height grows with the text (same at scale 1).
double _scaled(BuildContext context, double height) => MediaQuery.textScalerOf(context).scale(height);

class _Pair extends StatelessWidget {
  const _Pair({this.left, this.right});
  final Widget? left;
  final Widget? right;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: left ?? const SizedBox.shrink()),
        const SizedBox(width: 12),
        Expanded(child: right ?? const SizedBox.shrink()),
      ]);
}

class _InfraCard extends StatelessWidget {
  const _InfraCard({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final hosts = profile.hosts.take(3).toList();
    final online = profile.hosts.where((h) => data.hostStates[h.id] == HostState.online).length;
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: EdgeInsets.zero,
      height: _scaled(context, 176),
      semanticLabel: l.homeInfra,
      child: Stack(children: [
        Positioned(
          left: 20,
          top: 18,
          bottom: 18,
          right: 170,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.homeInfra, style: tt.titleSmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                hosts.isEmpty ? l.homeNoHosts : l.homeOnlineCount(online, profile.hosts.length),
                style: tt.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
            if (hosts.isEmpty)
              Text(l.homeAddHost, style: tt.bodySmall)
            else
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final h in hosts)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Row(children: [
                      StatusDot(color: t.hostColor(hexColor(h.color)), square: true),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(h.name,
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.isDark ? const Color(0xFFD1D1D6) : const Color(0xFF3A3A40)),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ),
              ]),
          ]),
        ),
        Positioned(
          right: 14,
          bottom: 0,
          child: ExcludeSemantics(
            child: IsoStack(
              slabs: [
                for (final h in hosts) StackSlab(color: hexColor(h.color), state: data.hostStates[h.id] ?? HostState.unknown),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _ClaudeTile extends StatelessWidget {
  const _ClaudeTile({required this.data});
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final count = data.claudeSessions;
    return TCard(
      height: _scaled(context, 120),
      color: t.claudeTile,
      borderColor: t.claudeTileBorder,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => context.go('/claude'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Icon(LucideIcons.asterisk, size: 16, color: t.claudeTileSubtext),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Claude',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileText), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Semantics(
            button: true,
            label: l.homeNewClaudeSession,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => context.go('/claude?new=1'),
                child: const SizedBox(width: 30, height: 30, child: Icon(LucideIcons.plus, size: 16, color: Color(0xFF1E1B4B))),
              ),
            ),
          ),
        ]),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(count == null ? '–' : '$count',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: t.claudeTileText)),
          Text(
            count == null
                ? l.homeNotConnected
                : data.claudeWaiting > 0
                    ? '${l.homeClaudeSessions(count)} · ${l.homeClaudeWaiting(data.claudeWaiting)}'
                    : l.homeClaudeSessions(count),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.claudeTileSubtext),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ]),
      ]),
    );
  }
}

String _pct(double? v, String locale) => v == null ? '–' : NumberFormat.percentPattern(locale).format(v);

class _SystemTile extends StatelessWidget {
  const _SystemTile({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final pc = profile.host(profile.claude.agentHostId) ?? profile.hosts.firstOrNull;
    final c1 = t.hostColor(hexColor(profile.hosts.elementAtOrNull(0)?.color ?? '#8F88EE'));
    final c2 = t.hostColor(hexColor(profile.hosts.elementAtOrNull(1)?.color ?? '#6CCB9F'));
    return TCard(
      height: _scaled(context, 120),
      onTap: () => context.go('/system'),
      child: Row(children: [
        RingGauge(outer: data.cpu, inner: data.ram, outerColor: c1, innerColor: c2, size: 62),
        const SizedBox(width: 9),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pc?.id ?? '–', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            _legend(context, c1, l.homeCpu(_pct(data.cpu, locale))),
            const SizedBox(height: 6),
            _legend(context, c2, l.homeRam(_pct(data.ram, locale))),
          ]),
        ),
      ]),
    );
  }

  Widget _legend(BuildContext context, Color c, String text) => Row(children: [
        StatusDot(color: c, size: 7),
        const SizedBox(width: 5),
        Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12), overflow: TextOverflow.ellipsis)),
      ]);
}

class _GrafanaTile extends StatelessWidget {
  const _GrafanaTile({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final name = profile.integrations.grafana.firstOrNull?.name ?? 'Grafana';
    return TCard(
      height: _scaled(context, 84),
      radius: 22,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => context.push('/monitor/grafana'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Expanded(child: Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
          Text(data.grafanaSpark == null ? l.homeNotConnected : l.homeLastHour, style: Theme.of(context).textTheme.labelSmall),
        ]),
        if (data.grafanaSpark != null)
          ExcludeSemantics(child: Sparkline(values: data.grafanaSpark!, color: t.isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4338CA)))
        else
          Container(height: 2, color: t.ringTrack),
      ]),
    );
  }
}

class _DozzleTile extends StatelessWidget {
  const _DozzleTile({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final lines = data.dozzleLines;
    return TCard(
      height: _scaled(context, 84),
      radius: 22,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: () => context.push('/monitor/dozzle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Dozzle', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          Text(lines == null ? l.homeNotConnected : l.homeLive,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: lines == null ? t.textSecondary : t.success)),
        ]),
        const SizedBox(height: 7),
        for (final line in (lines ?? const <LogLine>[]).take(2))
          Text.rich(
            TextSpan(children: [
              TextSpan(text: '● ', style: TextStyle(color: line.level == 'info' ? t.success : t.warning)),
              TextSpan(
                text: '${line.source}  ${switch (line.text) {
                  'running' => l.dozzleRunning,
                  'stopped' => l.dozzleStopped,
                  _ => line.text,
                }}',
              ),
            ]),
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: t.textSecondary, height: 1.35),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ]),
    );
  }
}

class _QuickAccess extends StatelessWidget {
  const _QuickAccess({required this.ids, required this.data});
  final List<String> ids;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GroupedSection(title: l.homeQuickAccess, children: [for (final id in ids) ShortcutRow(id: id, data: data)]);
  }
}

/// Shortcuts layout: single-line summary (infra · Claude · PC). Each section opens its own screen.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final total = profile.hosts.length;
    final online = profile.hosts.where((h) => data.hostStates[h.id] == HostState.online).length;
    final count = data.claudeSessions;
    final pc = profile.host(profile.claude.agentHostId) ?? profile.hosts.firstOrNull;
    Widget sep() => Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 12), color: t.separator);
    return TCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: _Stat(label: l.homeInfra, value: total == 0 ? '–' : '$online/$total', sub: total == 0 ? l.homeNoHosts : l.homeOnline),
          ),
          sep(),
          Expanded(
            child: _Stat(
              label: 'Claude',
              value: count == null ? '–' : '$count',
              sub: count == null
                  ? l.homeNotConnected
                  : data.claudeWaiting > 0
                      ? l.homeClaudeWaiting(data.claudeWaiting)
                      : l.homeClaudeSessions(count),
              subColor: count != null && data.claudeWaiting > 0 ? t.warning : null,
              onTap: () => context.go('/claude'),
            ),
          ),
          sep(),
          Expanded(
            child: _Stat(
              label: pc?.id ?? 'PC',
              prefix: 'CPU ',
              value: _pct(data.cpu, locale),
              sub: l.homeRam(_pct(data.ram, locale)),
              onTap: () => context.go('/system'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub, this.prefix, this.subColor, this.onTap});
  final String label;
  final String value;
  final String sub;
  final String? prefix;
  final Color? subColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final small = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.textSecondary);
    return Semantics(
      container: true,
      button: onTap != null,
      label: '$label, ${prefix ?? ''}$value, $sub',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.start, children: [
                Text(label, style: small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(children: [
                    if (prefix != null) TextSpan(text: prefix, style: small.copyWith(fontWeight: FontWeight.w700)),
                    TextSpan(text: value),
                  ]),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(sub, style: small.copyWith(color: subColor), maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shortcuts layout: tiles (content height). Two columns if width or text scale isn't enough for three.
class _ShortcutGrid extends StatelessWidget {
  const _ShortcutGrid({required this.ids});
  final List<String> ids;

  static const gap = 10.0;

  /// Minimum width of a three-column tile at text scale 1 (icon + two-line name + spacing).
  static const minTile = 96.0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.homeShortcuts),
      LayoutBuilder(builder: (context, box) {
        final cols = (box.maxWidth - 2 * gap) / 3 >= minTile * scale ? 3 : 2;
        final side = ((box.maxWidth - (cols - 1) * gap) / cols).floorToDouble();
        // Height follows content (12 + 34 icon + 10 + two-line name + 12 + slack): in two columns a square tile
        // left the middle empty and was needlessly tall. In three columns the tile stays nearly square.
        final height = math.min(side, (12 + 34 + 10 + 2 * 13.5 * 1.2 * scale + 12 + 4).ceilToDouble());
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final id in ids) SizedBox(width: side, height: height, child: ShortcutTile(id: id)),
        ]);
      }),
    ]);
  }
}

/// Focus layout: large status card (infra + Claude + PC + last event).
class _StatusHero extends ConsumerWidget {
  const _StatusHero({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final hosts = profile.hosts;
    final online = hosts.where((h) => data.hostStates[h.id] == HostState.online).length;
    final count = data.claudeSessions;
    final pc = profile.host(profile.claude.agentHostId) ?? hosts.firstOrNull;
    final c1 = t.hostColor(hexColor(hosts.elementAtOrNull(0)?.color ?? '#8F88EE'));
    final c2 = t.hostColor(hexColor(hosts.elementAtOrNull(1)?.color ?? '#6CCB9F'));
    // Events come from the agent: with no agent host there is no last-event row at all.
    final event = hosts.any((h) => h.agent != null) ? ref.watch(eventsFeedProvider(10)).value?.events.firstOrNull : null;
    final divider = Padding(padding: const EdgeInsets.only(left: 58), child: Divider(color: t.separator));

    final rows = <Widget>[
      GroupedRow(
        title: 'Claude',
        subtitle: count == null
            ? l.homeNotConnected
            : data.claudeWaiting > 0
                ? '$count ${l.homeClaudeSessions(count)} · ${l.homeClaudeWaiting(data.claudeWaiting)}'
                : count == 0
                    ? l.homeClaudeSessions(count)
                    : '$count ${l.homeClaudeSessions(count)}',
        icon: LucideIcons.asterisk,
        iconBackground: t.isDark ? const Color(0xFF5E5CE6) : t.claudeTile,
        onTap: () => context.go('/claude'),
      ),
      if (pc != null)
        GroupedRow(
          title: l.homeCardsSystem,
          subtitle: '${pc.name} · ${l.homeCpu(_pct(data.cpu, locale))} · ${l.homeRam(_pct(data.ram, locale))}',
          icon: LucideIcons.cpu,
          iconBackground: t.rowIconFiles,
          onTap: () => context.go('/system'),
        ),
      if (event != null) _eventRow(context, l, t, locale, event),
    ];

    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
          child: Row(children: [
            Expanded(
              child: Semantics(
                container: true,
                label: '${l.homeInfra}, ${hosts.isEmpty ? l.homeNoHosts : l.homeOnlineCount(online, hosts.length)}',
                child: ExcludeSemantics(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.homeStatus, style: tt.titleSmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                      hosts.isEmpty ? l.homeNoHosts : l.homeOnlineCount(online, hosts.length),
                      style: tt.headlineSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    if (hosts.isEmpty)
                      Text(l.homeAddHost, style: tt.bodySmall)
                    else
                      Wrap(spacing: 12, runSpacing: 6, children: [
                        for (final h in hosts.take(4))
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            StatusDot(
                              color: data.hostStates[h.id] == HostState.offline ? t.textSecondary : t.hostColor(hexColor(h.color)),
                              square: true,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(h.name,
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.isDark ? const Color(0xFFD1D1D6) : const Color(0xFF3A3A40)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                      ]),
                  ]),
                ),
              ),
            ),
            if (data.cpu != null) ...[
              const SizedBox(width: 12),
              ExcludeSemantics(child: RingGauge(outer: data.cpu, inner: data.ram, outerColor: c1, innerColor: c2, size: 64)),
            ],
          ]),
        ),
        Divider(color: t.separator),
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) divider, rows[i]],
      ]),
    );
  }

  Widget _eventRow(BuildContext context, AppLocalizations l, TiphysTokens t, String locale, HostEvent e) {
    final (title, _) = eventText(l, e);
    final (icon, color) = eventVisual(t, e.key);
    return GroupedRow(
      title: title,
      subtitle: '${DateFormat.Hm(locale).format(e.at)} · ${e.host.name}',
      icon: icon,
      iconBackground: color,
      onTap: () => routeForLink(e.link) != null ? openEvent(context, e) : context.push('/system/events'),
    );
  }
}
