// Ana ekran: "6 · Porselen × Bento" tasarımı.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/floating_tab_bar.dart';
import '../../widgets/painters.dart';
import '../../widgets/surfaces.dart';
import '../../core/util/open_url.dart';
import 'home_data.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profile = ref.watch(profileProvider);
    final data = ref.watch(homeDataProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final date = DateFormat('EEEE, d MMMM', locale).format(ref.watch(clockProvider)());
    final cards = profile.app.cards;

    final sections = <Widget>[
      for (final c in cards)
        switch (c) {
          'infra' => _InfraCard(profile: profile, data: data),
          'claude' || 'system' => const SizedBox.shrink(), // ikili satırda çizilir
          'grafana' || 'dozzle' => const SizedBox.shrink(),
          'quickAccess' => _QuickAccess(profile: profile, data: data),
          _ => const SizedBox.shrink(),
        },
    ];
    // Claude + PC durumu yan yana; Grafana + Dozzle yan yana (tasarımdaki gibi), sıralamadaki ilk konumlarında.
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

    return ListView(
      padding: EdgeInsets.fromLTRB(
        TiphysTokens.gutter,
        MediaQuery.paddingOf(context).top + 18,
        TiphysTokens.gutter,
        FloatingTabBar.height + FloatingTabBar.bottomGap + 24,
      ),
      children: [
        LargeTitleHeader(
          overline: date,
          title: l.appName,
          action: RoundIconButton(icon: LucideIcons.settings, tooltip: l.settingsTitle, onPressed: () => context.push('/settings')),
        ),
        for (final s in sections)
          if (s is! SizedBox) Padding(padding: const EdgeInsets.only(top: 12), child: s),
      ],
    );
  }

  Widget _tile(String id, Profile p, HomeData d) => switch (id) {
        'claude' => _ClaudeTile(data: d),
        'system' => _SystemTile(profile: p, data: d),
        'grafana' => _GrafanaTile(profile: p, data: d),
        'dozzle' => _DozzleTile(profile: p, data: d),
        _ => const SizedBox.shrink(),
      };
}

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
      height: 176,
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
      height: 120,
      color: t.claudeTile,
      borderColor: t.claudeTileBorder,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => context.go('/claude'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Icon(LucideIcons.asterisk, size: 16, color: t.claudeTileSubtext),
          const SizedBox(width: 6),
          Text('Claude', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileText)),
          const Spacer(),
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
      height: 120,
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
      height: 84,
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
      height: 84,
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
  const _QuickAccess({required this.profile, required this.data});
  final Profile profile;
  final HomeData data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hp = profile.integrations.homepage;
    return GroupedSection(title: l.homeQuickAccess, children: [
      GroupedRow(
        title: l.tabTerminal,
        icon: LucideIcons.terminal,
        iconBackground: t.rowIconTerminal,
        trailingText: data.terminalTabs > 0 ? l.homeTabsCount(data.terminalTabs) : null,
        onTap: () => context.go('/terminal'),
      ),
      GroupedRow(
        title: l.tabFiles,
        icon: LucideIcons.folder,
        iconBackground: t.rowIconFiles,
        trailingText: profile.files.bookmarks.firstOrNull?.path,
        onTap: () => context.go('/files'),
      ),
      if (hp != null)
        GroupedRow(
          title: 'Homepage',
          icon: LucideIcons.house,
          iconBackground: t.rowIconHomepage,
          trailingText: l.homeOpenInBrowser,
          external: true,
          onTap: () => openExternal(hp.browserUrl),
        ),
    ]);
  }
}
