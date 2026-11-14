// Grafana: dashboard listesi (favoriler önce) ve mobil düzende dashboard (tek sütun).
// Değişkenler, zaman aralığı, otomatik yenileme; stat / zaman serisi / tablo / log panelleri uygulamada çizilir.
import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/util/refresh.dart';
import '../../core/integrations/grafana_client.dart';
import '../../core/profile/model.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/markdown_lite.dart';
import '../../widgets/surfaces.dart';
import 'grafana_alerts_screen.dart';
import 'providers.dart';

const seriesPalette = [Color(0xFF8F88EE), Color(0xFF6CCB9F), Color(0xFFEE9C77), Color(0xFF64B5F6), Color(0xFFF06292), Color(0xFFFFD54F), Color(0xFF4DB6AC), Color(0xFFBA68C8)];

final grafanaListProvider = FutureProvider.autoDispose.family<List<GrafanaDashboardRef>, String>((ref, id) async {
  final g = ref.watch(profileProvider).integrations.grafana.firstWhere((x) => x.id == id);
  final c = await ref.read(grafanaFactoryProvider)(g);
  try {
    return await c.search();
  } finally {
    c.close();
  }
});

class GrafanaScreen extends ConsumerStatefulWidget {
  const GrafanaScreen({super.key});
  @override
  ConsumerState<GrafanaScreen> createState() => _GrafanaScreenState();
}

class _GrafanaScreenState extends ConsumerState<GrafanaScreen> {
  String? _id;
  bool _openedDefault = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final list = ref.watch(profileProvider.select((p) => p.integrations.grafana));
    final cfg = list.where((g) => g.id == _id).firstOrNull ?? list.firstOrNull;
    if (cfg != null && cfg.defaultDashboardUid != null && !_openedDefault) {
      _openedDefault = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDashboard(cfg, cfg.defaultDashboardUid!);
      });
    }
    return SettingsPage(title: cfg?.name ?? 'Grafana', children: [
      if (cfg == null)
        TCard(child: Text(l.integrationNotSet))
      else ...[
        if (list.length > 1)
          Wrap(spacing: 8, children: [for (final g in list) ChoiceChip(label: Text(g.name), selected: g.id == cfg.id, onSelected: (_) => setState(() => _id = g.id))]),
        GroupedSection(children: [
          GroupedRow(
            title: l.grafanaAlerts,
            icon: LucideIcons.bell,
            iconBackground: t.danger,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GrafanaAlertsScreen(config: cfg))),
          ),
          GroupedRow(
            title: l.grafanaExplore,
            subtitle: l.grafanaExploreHint,
            icon: LucideIcons.search,
            iconBackground: const Color(0xFF5E5CE6),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GrafanaExploreScreen(config: cfg))),
          ),
        ]),
        ref.watch(grafanaListProvider(cfg.id)).when(
              loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
              data: (ds) {
                final fav = cfg.favorites.toSet();
                final sorted = [...ds]..sort((a, b) => (fav.contains(a.uid) ? 0 : 1).compareTo(fav.contains(b.uid) ? 0 : 1));
                return GroupedSection(children: [
                  for (final d in sorted)
                    GroupedRow(
                      title: d.title,
                      subtitle: d.folder,
                      icon: fav.contains(d.uid) ? LucideIcons.star : LucideIcons.layoutDashboard,
                      iconBackground: fav.contains(d.uid) ? t.warning : const Color(0xFFE5795A),
                      onTap: () => _openDashboard(cfg, d.uid),
                    ),
                ]);
              },
            ),
      ],
    ]);
  }

  void _openDashboard(GrafanaConfig cfg, String uid) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GrafanaDashboardScreen(config: cfg, uid: uid)));
}

class GrafanaDashboardScreen extends ConsumerStatefulWidget {
  const GrafanaDashboardScreen({super.key, required this.config, required this.uid});
  final GrafanaConfig config;
  final String uid;
  @override
  ConsumerState<GrafanaDashboardScreen> createState() => _GrafanaDashboardState();
}

class _GrafanaDashboardState extends ConsumerState<GrafanaDashboardScreen> {
  GrafanaClient? _c;
  Map<String, dynamic>? _d;
  List<GrafanaVariable> _vars = [];
  List<GrafanaPanel> _panels = [];
  late String _range = widget.config.defaultRange;
  Object? _error;
  int _tick = 0; // paneller bu değer değişince yeniden sorgular
  VoidCallback? _cancelRefresh;
  final _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    _scheduleRefresh();
  }

  /// Panelleri aralıkla yeniler; uygulama arka plandayken bekler.
  void _scheduleRefresh() {
    if (widget.config.refreshSeconds <= 0) return;
    _cancelRefresh = whenVisibleAfter(Duration(seconds: widget.config.refreshSeconds), () {
      if (!mounted) return;
      setState(() => _tick++);
      _scheduleRefresh();
    });
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(grafanaFactoryProvider)(widget.config);
      final d = await c.dashboard(widget.uid);
      final vars = GrafanaClient.variables(d);
      for (final v in vars) {
        await c.loadOptions(v);
      }
      if (!mounted) return;
      setState(() {
        _c = c;
        _d = d;
        _vars = vars;
        _panels = GrafanaClient.panels(d);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _cancelRefresh?.call();
    _c?.close();
    super.dispose();
  }

  Future<void> _pickVar(GrafanaVariable v) async {
    final l = AppLocalizations.of(context);
    if (v.type == 'textbox') {
      final c = TextEditingController(text: v.current.firstOrNull ?? '');
      final r = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(v.label),
          content: TextField(controller: c, autofocus: true),
          actions: [TextButton(onPressed: () => Navigator.pop(d, c.text), child: Text(l.commonDone))],
        ),
      );
      if (r != null) {
        setState(() {
          v.current = [r];
          _tick++;
        });
      }
      return;
    }
    final picked = await showModalBottomSheet<List<String>>(
      useRootNavigator: true, // alt sekme barının üstünde açılsın; yoksa bar sayfanın altını örter
      context: context,
      builder: (c) => _VarSheet(variable: v),
    );
    if (picked != null && picked.isNotEmpty) {
      setState(() {
        v.current = picked;
        _tick++;
      });
    }
  }

  String _varText(AppLocalizations l, GrafanaVariable v) =>
      v.isAll ? l.grafanaAll : (v.current.isEmpty ? '–' : (v.current.length > 1 ? '${v.current.length}' : v.current.first));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final ranges = const ['now-15m', 'now-1h', 'now-6h', 'now-24h', 'now-7d'];
    final rows = <String?, List<GrafanaPanel>>{};
    for (final p in _panels) {
      rows.putIfAbsent(p.row, () => []).add(p);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: CustomScrollView(slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
            title: Text((_d?['title'] as String?) ?? 'Grafana'),
            actions: [
              IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: () => setState(() => _tick++)),
              IconButton(
                tooltip: l.homeOpenInBrowser,
                icon: const Icon(LucideIcons.externalLink),
                onPressed: () => openExternal('${widget.config.url}/d/${widget.uid}'),
              ),
            ],
          ),
          if (_error != null)
            SliverFillRemaining(child: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(integrationErrorText(l, _error!)))))
          else if (_d == null)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else ...[
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), children: [
                  for (final r in ranges)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(r.replaceFirst('now-', '')),
                        selected: _range == r,
                        onSelected: (_) => setState(() {
                          _range = r;
                          _tick++;
                        }),
                      ),
                    ),
                  for (final v in _vars.where((v) => v.type != 'constant' && v.type != 'interval'))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: const Icon(LucideIcons.chevronDown, size: 14),
                        label: Text('${v.label}: ${_varText(l, v)}'),
                        onPressed: () => _pickVar(v),
                      ),
                    ),
                ]),
              ),
            ),
            for (final entry in rows.entries) ...[
              if (entry.key != null)
                SliverToBoxAdapter(
                  child: InkWell(
                    onTap: () => setState(() => _collapsed.contains(entry.key) ? _collapsed.remove(entry.key) : _collapsed.add(entry.key!)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                      child: Row(children: [
                        Icon(_collapsed.contains(entry.key) ? LucideIcons.chevronRight : LucideIcons.chevronDown, size: 18, color: t.textSecondary),
                        const SizedBox(width: 6),
                        Text(entry.key!, style: Theme.of(context).textTheme.titleSmall),
                      ]),
                    ),
                  ),
                ),
              if (!_collapsed.contains(entry.key))
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  sliver: SliverList.list(children: _layout(entry.value)),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ]),
      ),
    );
  }

  /// Stat panelleri ikili ızgara, diğerleri tam genişlik.
  List<Widget> _layout(List<GrafanaPanel> panels) {
    final out = <Widget>[];
    final stats = <GrafanaPanel>[];
    void flush() {
      for (var i = 0; i < stats.length; i += 2) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(children: [
            Expanded(child: _panel(stats[i])),
            const SizedBox(width: 10),
            Expanded(child: i + 1 < stats.length ? _panel(stats[i + 1]) : const SizedBox.shrink()),
          ]),
        ));
      }
      stats.clear();
    }

    for (final p in panels) {
      if (p.type == 'stat' || p.type == 'gauge') {
        stats.add(p);
      } else {
        flush();
        out.add(Padding(padding: const EdgeInsets.only(top: 10), child: _panel(p)));
      }
    }
    flush();
    return out;
  }

  Widget _panel(GrafanaPanel p) => _PanelView(
        key: ValueKey('${p.id}-$_tick-$_range'),
        client: _c!,
        panel: p,
        vars: _vars,
        range: _range,
        dashboardUrl: '${widget.config.url}/d/${widget.uid}?viewPanel=${p.id}',
        prometheusUid: GrafanaClient.prometheusUid(_d!),
        onOpenDashboard: (uid) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GrafanaDashboardScreen(config: widget.config, uid: uid))),
      );
}

class _VarSheet extends StatefulWidget {
  const _VarSheet({required this.variable});
  final GrafanaVariable variable;
  @override
  State<_VarSheet> createState() => _VarSheetState();
}

class _VarSheetState extends State<_VarSheet> {
  late final Set<String> _sel = {...widget.variable.current};

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final v = widget.variable;
    final opts = [if (v.includeAll) r'$__all', ...v.options];
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(12), child: Text(v.label, style: Theme.of(context).textTheme.titleMedium)),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final o in opts)
              v.multi
                  ? CheckboxListTile(
                      value: _sel.contains(o),
                      title: Text(o == r'$__all' ? l.grafanaAll : o),
                      onChanged: (on) => setState(() {
                        if (o == r'$__all') {
                          _sel
                            ..clear()
                            ..add(o);
                        } else {
                          _sel.remove(r'$__all');
                          on == true ? _sel.add(o) : _sel.remove(o);
                        }
                      }),
                    )
                  : ListTile(
                      title: Text(o == r'$__all' ? l.grafanaAll : o),
                      trailing: _sel.contains(o) ? const Icon(LucideIcons.check) : null,
                      onTap: () => Navigator.pop(context, [o]),
                    ),
          ]),
        ),
        if (v.multi) Padding(padding: const EdgeInsets.all(12), child: FilledButton(onPressed: () => Navigator.pop(context, _sel.toList()), child: Text(l.commonDone))),
      ]),
    );
  }
}

/// Hızlı sorgu (Explore benzeri): veri kaynağı seç, PromQL/LogQL yaz, zaman aralığında çiz.
class GrafanaExploreScreen extends ConsumerStatefulWidget {
  const GrafanaExploreScreen({super.key, required this.config});
  final GrafanaConfig config;
  @override
  ConsumerState<GrafanaExploreScreen> createState() => _GrafanaExploreState();
}

class _GrafanaExploreState extends ConsumerState<GrafanaExploreScreen> {
  GrafanaClient? _c;
  List<({String uid, String type, String name})> _sources = const [];
  ({String uid, String type, String name})? _ds;
  final _expr = TextEditingController();
  String _range = 'now-1h';
  GrafanaPanel? _panel;
  int _run = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = await ref.read(grafanaFactoryProvider)(widget.config);
      final ds = (await c.datasources()).where((d) => d.type == 'prometheus' || d.type == 'loki').toList();
      if (!mounted) return c.close();
      setState(() {
        _c = c;
        _sources = ds;
        _ds = ds.firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _c?.close();
    _expr.dispose();
    super.dispose();
  }

  void _query() {
    final ds = _ds;
    if (ds == null || _expr.text.trim().isEmpty) return;
    final ref0 = {'type': ds.type, 'uid': ds.uid};
    setState(() {
      _panel = GrafanaPanel({
        'id': 0,
        'type': ds.type == 'loki' ? 'logs' : 'timeseries',
        'title': '',
        'datasource': ref0,
        'targets': [
          {'refId': 'A', 'expr': _expr.text.trim(), 'datasource': ref0},
        ],
      });
      _run++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    const ranges = ['now-15m', 'now-1h', 'now-6h', 'now-24h', 'now-7d'];
    return SettingsPage(
      title: l.grafanaExplore,
      children: [
        if (_error != null) TCard(child: Text(integrationErrorText(l, _error!))),
        if (_c == null && _error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (_c != null) ...[
          if (_sources.isEmpty)
            TCard(child: Text(l.grafanaNoDatasources))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in _sources)
                ChoiceChip(
                  label: Text(d.name),
                  avatar: Icon(d.type == 'loki' ? LucideIcons.scrollText : LucideIcons.chartLine, size: 16),
                  selected: d.uid == _ds?.uid,
                  onSelected: (_) => setState(() => _ds = d),
                ),
            ]),
          const SizedBox(height: 10),
          TField(
            controller: _expr,
            label: _ds?.type == 'loki' ? 'LogQL' : 'PromQL',
            hint: _ds?.type == 'loki' ? '{container="searxng"} |= "error"' : '100 - avg by (system) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100',
            mono: true,
            maxLines: 4,
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final r in ranges)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(r.replaceFirst('now-', '')),
                        selected: r == _range,
                        onSelected: (_) => setState(() {
                          _range = r;
                          if (_panel != null) _run++;
                        }),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(onPressed: _query, icon: const Icon(LucideIcons.play, size: 16), label: Text(l.grafanaRun)),
          ]),
          const SizedBox(height: 12),
          if (_panel != null)
            _PanelView(
              key: ValueKey(_run),
              client: _c!,
              panel: _panel!,
              vars: const [],
              range: _range,
              dashboardUrl: '${widget.config.url}/explore',
            )
          else
            Padding(padding: const EdgeInsets.all(8), child: Text(l.grafanaExploreEmpty, style: TextStyle(color: t.textSecondary))),
        ],
      ],
    );
  }
}

class _PanelView extends StatefulWidget {
  const _PanelView({
    super.key,
    required this.client,
    required this.panel,
    required this.vars,
    required this.range,
    required this.dashboardUrl,
    this.prometheusUid,
    this.onOpenDashboard,
  });
  final String? prometheusUid;
  final void Function(String uid)? onOpenDashboard;
  final GrafanaClient client;
  final GrafanaPanel panel;
  final List<GrafanaVariable> vars;
  final String range;
  final String dashboardUrl;
  @override
  State<_PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<_PanelView> {
  PanelData? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.panel.native) _query();
  }

  Future<void> _query() async {
    try {
      final d = await widget.client.query(
        widget.panel,
        widget.vars,
        from: widget.range,
        maxDataPoints: widget.panel.type == 'timeseries' ? 90 : 30,
        prometheusUid: widget.prometheusUid,
      );
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = widget.panel;
    Widget body;
    if (!p.native) {
      body = TextButton.icon(onPressed: () => openExternal(widget.dashboardUrl), icon: const Icon(LucideIcons.externalLink, size: 16), label: Text(l.grafanaOpenPanel(p.type)));
    } else if (_error != null) {
      body = Text(integrationErrorText(l, _error!), style: TextStyle(color: t.danger, fontSize: 12));
    } else if (_data == null) {
      body = SizedBox(height: p.type == 'stat' ? 40 : 140, child: const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
    } else {
      body = switch (p.type) {
        'stat' || 'gauge' => _stat(context, p, _data!),
        'timeseries' => _timeseries(context, p, _data!),
        'table' || 'bargauge' => _table(context, p, _data!),
        'logs' => _logs(context, _data!),
        'text' => MarkdownLite('${p.options['content'] ?? ''}', html: p.options['mode'] == 'html'),
        'alertlist' => _alerts(context, _data!),
        'dashlist' => _dashlist(context, _data!),
        _ => const SizedBox.shrink(),
      };
    }
    return TCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: p.type == 'timeseries' && _data != null
          ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _FullChart(panel: p, data: _data!)))
          : null,
      child: SizedBox(
        width: double.infinity,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (p.title.isNotEmpty) ...[
            Text(p.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
          ],
          body,
        ]),
      ),
    );
  }

  Widget _alerts(BuildContext context, PanelData d) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (d.alerts.isEmpty) {
      return Row(children: [
        Icon(LucideIcons.circleCheck, color: t.success, size: 18),
        const SizedBox(width: 8),
        Text(l.grafanaNoAlerts, style: Theme.of(context).textTheme.bodyMedium),
      ]);
    }
    Color c(String s) => switch (s) {
          'firing' || 'error' => t.danger,
          'pending' || 'nodata' => t.warning,
          _ => t.success,
        };
    return Column(children: [
      for (final a in d.alerts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 5), child: StatusDot(color: c(a.state), size: 9)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                if (a.summary != null) Text(a.summary!, style: Theme.of(context).textTheme.bodySmall),
                Text(
                  [
                    grafanaAlertState(l, a.state),
                    if (a.severity != null) a.severity!,
                    if (a.activeAt != null) DateFormat.MMMd(locale).add_Hm().format(a.activeAt!.toLocal()),
                  ].join(' · '),
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c(a.state)),
                ),
              ]),
            ),
          ]),
        ),
    ]);
  }

  Widget _dashlist(BuildContext context, PanelData d) {
    final t = context.tokens;
    if (d.dashboards.isEmpty) return Text(AppLocalizations.of(context).commonEmpty);
    return Column(children: [
      for (final ref in d.dashboards)
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onOpenDashboard == null ? null : () => widget.onOpenDashboard!(ref.uid),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(children: [
              Icon(LucideIcons.layoutDashboard, size: 16, color: t.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(ref.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
              Icon(LucideIcons.chevronRight, size: 16, color: t.textSecondary),
            ]),
          ),
        ),
    ]);
  }

  Widget _stat(BuildContext context, GrafanaPanel p, PanelData d) {
    final t = context.tokens;
    if (d.series.isEmpty) return Text('–', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: t.textSecondary));
    return Wrap(spacing: 12, runSpacing: 4, children: [
      for (final s in d.series.take(6))
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(formatValue(s.last, p.unit, decimals: p.decimals),
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Color(thresholdColor(p.thresholds, s.last)))),
          if (d.series.length > 1) Text(s.name, style: Theme.of(context).textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
    ]);
  }

  Widget _timeseries(BuildContext context, GrafanaPanel p, PanelData d) {
    final t = context.tokens;
    if (d.series.isEmpty) return SizedBox(height: 60, child: Center(child: Text(AppLocalizations.of(context).commonEmpty)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: 150, child: seriesChart(context, p, d.series, compact: true)),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 4, children: [
        for (var i = 0; i < d.series.length && i < 8; i++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            StatusDot(color: seriesPalette[i % seriesPalette.length], size: 7),
            const SizedBox(width: 4),
            Text('${d.series[i].name} ${formatValue(d.series[i].last, p.unit, decimals: p.decimals)}',
                style: TextStyle(fontSize: 11, color: t.textSecondary)),
          ]),
      ]),
    ]);
  }

  Widget _table(BuildContext context, GrafanaPanel p, PanelData d) {
    final t = context.tokens;
    final rows = [...d.series]..sort((a, b) => (b.last ?? -1e18).compareTo(a.last ?? -1e18));
    if (rows.isEmpty) return Text(AppLocalizations.of(context).commonEmpty);
    return Column(children: [
      for (final s in rows.take(20))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(s.name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
            Text(formatValue(s.last, p.unit, decimals: p.decimals), style: TextStyle(fontWeight: FontWeight.w700, color: Color(thresholdColor(p.thresholds, s.last)))),
          ]),
        ),
      if (rows.length > 20) Text('+${rows.length - 20}', style: TextStyle(color: t.textSecondary)),
    ]);
  }

  Widget _logs(BuildContext context, PanelData d) {
    final t = context.tokens;
    if (d.logs.isEmpty) return Text(AppLocalizations.of(context).commonEmpty);
    final fmt = DateFormat.Hms();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in d.logs.take(60))
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '${fmt.format(r.time)} ', style: TextStyle(color: t.textSecondary)),
              if (r.labels['container'] != null) TextSpan(text: '${r.labels['container']} ', style: TextStyle(color: t.accent)),
              TextSpan(text: r.line),
            ]),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, height: 1.35),
          ),
        ),
    ]);
  }
}

LineChart seriesChart(BuildContext context, GrafanaPanel p, List<Series> series, {bool compact = false}) {
  final t = context.tokens;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final all = [for (final s in series) ...s.values.whereType<double>()];
  final lo = p.min?.toDouble() ?? (all.isEmpty ? 0.0 : all.reduce((a, b) => a < b ? a : b).clamp(double.negativeInfinity, 0).toDouble());
  final hi = p.max?.toDouble() ?? (all.isEmpty ? 1.0 : all.reduce((a, b) => a > b ? a : b));
  final step = niceStep((hi - lo).abs(), compact ? 3 : 5);
  return LineChart(LineChartData(
    minY: lo,
    maxY: hi <= lo ? lo + 1 : (hi / step).ceil() * step,
    gridData: FlGridData(drawVerticalLine: false, horizontalInterval: step, getDrawingHorizontalLine: (_) => FlLine(color: t.separator, strokeWidth: 0.8)),
    borderData: FlBorderData(show: false),
    titlesData: FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: !compact,
          reservedSize: 22,
          getTitlesWidget: (v, m) => Text(DateFormat.Hm(locale).format(DateTime.fromMillisecondsSinceEpoch(v.toInt())), style: TextStyle(fontSize: 9, color: t.textSecondary)),
        ),
      ),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 48,
          interval: step,
          getTitlesWidget: (v, m) => Text(formatValue(v, p.unit, decimals: 0), style: TextStyle(fontSize: 9, color: t.textSecondary)),
        ),
      ),
    ),
    lineTouchData: LineTouchData(
      touchTooltipData: LineTouchTooltipData(
        fitInsideHorizontally: true,
        getTooltipItems: (spots) => [
          for (final s in spots)
            LineTooltipItem(
              '${series[s.barIndex].name}: ${formatValue(s.y, p.unit, decimals: p.decimals)}',
              TextStyle(color: seriesPalette[s.barIndex % seriesPalette.length], fontSize: 11, fontWeight: FontWeight.w600),
            ),
        ],
      ),
    ),
    lineBarsData: [
      for (var i = 0; i < series.length; i++)
        LineChartBarData(
          spots: [
            for (var j = 0; j < series[i].times.length; j++)
              if (series[i].values[j] != null) FlSpot(series[i].times[j].toDouble(), series[i].values[j]!),
          ],
          color: seriesPalette[i % seriesPalette.length],
          barWidth: 1.8,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: series.length == 1, color: seriesPalette[i % seriesPalette.length].withValues(alpha: 0.15)),
        ),
    ],
  ));
}

/// Panele dokununca tam ekran; yatay döndürmeye izin verilir.
class _FullChart extends StatefulWidget {
  const _FullChart({required this.panel, required this.data});
  final GrafanaPanel panel;
  final PanelData data;
  @override
  State<_FullChart> createState() => _FullChartState();
}

class _FullChartState extends State<_FullChart> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.panel.title)),
        body: Padding(padding: const EdgeInsets.fromLTRB(8, 16, 20, 16), child: seriesChart(context, widget.panel, widget.data.series)),
      );
}

String grafanaAlertState(AppLocalizations l, String s) => switch (s) {
      'firing' => l.grafanaFiring,
      'pending' => l.grafanaPending,
      'error' => l.commonError,
      'nodata' => l.grafanaNoData,
      _ => l.grafanaNormal,
    };
