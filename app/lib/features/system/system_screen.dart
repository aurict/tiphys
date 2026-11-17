// System tab: agent host selection, metrics, power, tools, quick actions, systemd services, Docker;
// monitoring links.
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
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import '../configfiles/configfiles_data.dart' show configHostsProvider;
import '../databases/db_data.dart' show dbHostsProvider;
import '../incidents/incidents_data.dart' show incidentHostsProvider;
import 'agent_providers.dart';
import 'agent_section.dart';
import 'tools.dart';
import 'wake.dart';

class SystemScreen extends ConsumerStatefulWidget {
  const SystemScreen({super.key});
  @override
  ConsumerState<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends ConsumerState<SystemScreen> {
  String? _hostId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    final hosts = p.hosts.where((h) => h.agent != null || h.wake != null).toList();
    final host = p.host(_hostId) ?? hosts.firstOrNull;
    final top = MediaQuery.paddingOf(context).top;

    return ListView(
      padding: EdgeInsets.fromLTRB(TiphysTokens.gutter, top + 18, TiphysTokens.gutter, FloatingTabBar.height + FloatingTabBar.bottomGap + 24),
      children: [
        LargeTitleHeader(title: l.tabSystem),
        const SizedBox(height: 12),
        if (hosts.isEmpty)
          TCard(child: Text(l.integrationNeedsAgentHost))
        else ...[
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final h in hosts)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: h.id == host?.id,
                    showCheckmark: false,
                    avatar: StatusDot(color: hexColor(h.color), size: 8, square: true),
                    label: Text(h.name),
                    onSelected: (_) => setState(() => _hostId = h.id),
                    selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
                    labelStyle: TextStyle(color: h.id == host?.id ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
                    backgroundColor: t.chipBackground,
                    side: BorderSide(color: t.separator),
                    shape: const StadiumBorder(),
                  ),
                ),
            ]),
          ),
          if (host != null) ...[
            if (host.agent != null) _Metrics(host: host),
            _Power(host: host),
            if (host.agent != null) AgentSection(host: host),
            ToolsSection(host: host),
            if (host.agent != null) ...[
              _Services(host: host),
              _Containers(host: host),
            ],
          ],
        ],
        GroupedSection(title: l.systemMonitoring, children: [
          if (ref.watch(incidentHostsProvider).value?.isNotEmpty == true)
            GroupedRow(title: l.incTitle, icon: LucideIcons.siren, iconBackground: t.danger, onTap: () => context.push('/incidents')),
          if (ref.watch(configHostsProvider).value?.isNotEmpty == true)
            GroupedRow(title: l.cfTitle, icon: LucideIcons.keyRound, iconBackground: const Color(0xFF8E6BD8), onTap: () => context.push('/configfiles')),
          if (ref.watch(dbHostsProvider).value?.isNotEmpty == true)
            GroupedRow(title: l.dbTitle, icon: LucideIcons.database, iconBackground: const Color(0xFF336791), onTap: () => context.push('/db')),
          GroupedRow(title: l.eventsTitle, icon: LucideIcons.history, iconBackground: const Color(0xFF5E5CE6), onTap: () => context.push('/system/events')),
          GroupedRow(title: l.backupsTitle, icon: LucideIcons.archive, iconBackground: const Color(0xFF0A84FF), onTap: () => context.push('/system/backups')),
          GroupedRow(title: l.composeTitle, icon: LucideIcons.layers, iconBackground: const Color(0xFF1D63ED), onTap: () => context.push('/system/compose')),
          GroupedRow(title: l.logSearchTitle, icon: LucideIcons.textSearch, iconBackground: const Color(0xFF30B0C7), onTap: () => context.push('/system/logs')),
          GroupedRow(title: l.systemSites, icon: LucideIcons.activity, iconBackground: t.success, onTap: () => context.push('/monitor/sites')),
          GroupedRow(title: 'Grafana', icon: LucideIcons.chartLine, iconBackground: const Color(0xFFE5795A), onTap: () => context.push('/monitor/grafana')),
          GroupedRow(title: 'Dozzle', icon: LucideIcons.scrollText, iconBackground: const Color(0xFF2F9E6A), onTap: () => context.push('/monitor/dozzle')),
          GroupedRow(title: 'Homepage', icon: LucideIcons.house, iconBackground: t.rowIconHomepage, onTap: () => context.push('/monitor/homepage')),
        ]),
      ],
    );
  }
}

class _Metrics extends ConsumerWidget {
  const _Metrics({required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final s = ref.watch(systemProvider(host.id));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TCard(
        child: s.when(
          skipLoadingOnRefresh: true,
          loading: () => const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => _ErrorRow(text: agentErrorText(l, e), onRetry: () => ref.invalidate(systemProvider(host.id))),
          data: (d) {
            final cpu = d['cpu'] as Map;
            final mem = d['memory'] as Map;
            final disks = (d['disks'] as List).cast<Map>();
            final gpus = (d['gpus'] as List).cast<Map>();
            final up = Duration(seconds: (d['uptimeSeconds'] as num).toInt());
            Widget bar(String label, double v, String value, Color c) => Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Semantics(
                    label: label,
                    value: value,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text(value, style: Theme.of(context).textTheme.bodySmall),
                      ]),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(value: v.clamp(0, 1), minHeight: 8, backgroundColor: t.ringTrack, color: v > 0.9 ? t.danger : c),
                      ),
                    ]),
                  ),
                );
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${d['hostname']}', style: Theme.of(context).textTheme.titleLarge)),
                Text(l.systemUptime(up.inDays, up.inHours % 24), style: Theme.of(context).textTheme.bodySmall),
              ]),
              Text('${d['os']} · ${d['kernel']}', style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              bar('CPU · ${cpu['cores']}', (cpu['loadPercent'] as num) / 100,
                  '%${(cpu['loadPercent'] as num).round()}${cpu['temperatureC'] == null ? '' : ' · ${(cpu['temperatureC'] as num).round()}°C'}', t.hostColor(hexColor(host.color))),
              bar('RAM', (mem['usedBytes'] as num) / (mem['totalBytes'] as num),
                  '${formatSize((mem['usedBytes'] as num).toInt(), locale)} / ${formatSize((mem['totalBytes'] as num).toInt(), locale)}', t.accent),
              for (final g in gpus)
                bar('GPU', ((g['utilizationPercent'] as num?) ?? 0) / 100,
                    '%${g['utilizationPercent'] ?? '–'} · ${g['temperatureC'] ?? '–'}°C · ${g['memoryUsedMiB'] ?? '–'}/${g['memoryTotalMiB'] ?? '–'} MiB', t.success),
              for (final dsk in disks.take(4))
                bar('${l.systemDisk} ${dsk['mount']}', (dsk['usedBytes'] as num) / (dsk['totalBytes'] as num),
                    '${formatSize((dsk['usedBytes'] as num).toInt(), locale)} / ${formatSize((dsk['totalBytes'] as num).toInt(), locale)}', t.warning),
            ]);
          },
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(LucideIcons.circleAlert, color: context.tokens.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
        TextButton(onPressed: onRetry, child: Text(AppLocalizations.of(context).commonRetry)),
      ]);
}

class _Power extends ConsumerWidget {
  const _Power({required this.host});
  final Host host;

  Future<void> _power(BuildContext context, WidgetRef ref, String action, String label) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.systemPowerConfirm(label, host.name), confirmLabel: label, destructive: true)) return;
    try {
      await agentCall(ref, host.id, 'POST', '/v1/power/$action', {'confirm': true});
      if (context.mounted) toast(context, l.systemPowerSent(label));
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return GroupedSection(title: l.systemPower, children: [
      if (host.wake != null)
        GroupedRow(
          title: l.systemWake,
          subtitle: host.wake!.mac,
          icon: LucideIcons.sunrise,
          iconBackground: t.success,
          onTap: () async {
            final msg = await wakeHost(ref, host, l);
            if (context.mounted) toast(context, msg);
          },
        ),
      if (host.agent != null) ...[
        GroupedRow(title: l.systemSuspend, icon: LucideIcons.moon, iconBackground: const Color(0xFF5E5CE6), onTap: () => _power(context, ref, 'suspend', l.systemSuspend)),
        GroupedRow(title: l.systemReboot, icon: LucideIcons.refreshCw, iconBackground: t.warning, onTap: () => _power(context, ref, 'reboot', l.systemReboot)),
        GroupedRow(title: l.systemPowerOff, icon: LucideIcons.power, iconBackground: t.danger, onTap: () => _power(context, ref, 'poweroff', l.systemPowerOff)),
      ],
    ]);
  }
}

class _Services extends ConsumerStatefulWidget {
  const _Services({required this.host});
  final Host host;
  @override
  ConsumerState<_Services> createState() => _ServicesState();
}

class _ServicesState extends ConsumerState<_Services> {
  String _scope = 'user';
  String _q = '';
  bool _expanded = false;

  Future<void> _action(String unit, String action) async {
    final l = AppLocalizations.of(context);
    try {
      await agentCall(ref, widget.host.id, 'POST', '/v1/services/$_scope/${Uri.encodeComponent(unit)}/$action');
      ref.invalidate(servicesProvider((widget.host.id, _scope)));
      if (mounted) toast(context, l.systemDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  Future<void> _logs(String unit) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (c) => _LogsPage(host: widget.host, title: unit, path: '/v1/services/$_scope/${Uri.encodeComponent(unit)}/logs')));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final units = ref.watch(servicesProvider((widget.host.id, _scope)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.systemServices),
      Row(children: [
        SegmentedButton<String>(
          segments: [ButtonSegment(value: 'user', label: Text(l.systemScopeUser)), ButtonSegment(value: 'system', label: Text(l.systemScopeSystem))],
          selected: {_scope},
          onSelectionChanged: (s) => setState(() => _scope = s.first),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            decoration: InputDecoration(hintText: l.homeSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v.toLowerCase()),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      units.when(
        loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => TCard(child: _ErrorRow(text: agentErrorText(l, e), onRetry: () => ref.invalidate(servicesProvider((widget.host.id, _scope))))),
        data: (list) {
          final filtered = list.where((u) => _q.isEmpty || '${u['unit']} ${u['description']}'.toLowerCase().contains(_q)).toList()
            ..sort((a, b) => (a['active'] == 'failed' ? 0 : 1).compareTo(b['active'] == 'failed' ? 0 : 1));
          final shown = _expanded || _q.isNotEmpty ? filtered : filtered.where((u) => u['active'] != 'inactive').take(12).toList();
          return Column(children: [
            GroupedSection(children: [
              for (final u in shown)
                GroupedRow(
                  title: (u['unit'] as String).replaceAll('.service', ''),
                  subtitle: '${u['active']} · ${u['sub']}',
                  icon: u['active'] == 'active' ? LucideIcons.circleCheck : (u['active'] == 'failed' ? LucideIcons.circleX : LucideIcons.circle),
                  iconBackground: u['active'] == 'active' ? t.success : (u['active'] == 'failed' ? t.danger : const Color(0xFF6C6C70)),
                  onTap: () => _logs(u['unit'] as String),
                  trailing: PopupMenuButton<String>(
                    tooltip: l.filesMore,
                    icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
                    onSelected: (a) => a == 'logs' ? _logs(u['unit'] as String) : _action(u['unit'] as String, a),
                    itemBuilder: (c) => [
                      PopupMenuItem(value: 'logs', child: Text(l.systemLogs)),
                      PopupMenuItem(value: 'restart', child: Text(l.systemRestart)),
                      PopupMenuItem(value: 'start', child: Text(l.systemStart)),
                      PopupMenuItem(value: 'stop', child: Text(l.systemStop)),
                    ],
                  ),
                ),
            ]),
            if (!_expanded && _q.isEmpty && filtered.length > shown.length)
              TextButton(onPressed: () => setState(() => _expanded = true), child: Text(l.systemShowAll(filtered.length))),
          ]);
        },
      ),
    ]);
  }
}

class _Containers extends ConsumerWidget {
  const _Containers({required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final list = ref.watch(containersProvider(host.id));
    Future<void> act(String id, String action) async {
      try {
        await agentCall(ref, host.id, 'POST', '/v1/docker/containers/$id/$action');
        ref.invalidate(containersProvider(host.id));
        if (context.mounted) toast(context, l.systemDone);
      } catch (e) {
        if (context.mounted) toast(context, agentErrorText(l, e));
      }
    }

    return list.when(
      skipLoadingOnRefresh: true,
      loading: () => const SizedBox.shrink(),
      error: (e, _) => (e is Exception && agentErrorText(l, e) == l.agentFeatureOff)
          ? const SizedBox.shrink()
          : GroupedSection(title: 'Docker', children: [GroupedRow(title: agentErrorText(l, e), showChevron: false)]),
      data: (cs) => cs.isEmpty
          ? const SizedBox.shrink()
          : GroupedSection(title: 'Docker', children: [
              for (final c in cs)
                GroupedRow(
                  title: '${c['name']}',
                  subtitle: [c['status'], if (c['cpuPercent'] != null) '%${(c['cpuPercent'] as num).toStringAsFixed(1)}', if (c['memory'] != null) '${c['memory']}'.split(' / ').first]
                      .join(' · '),
                  icon: LucideIcons.box,
                  iconBackground: c['state'] == 'running' ? t.success : (c['state'] == 'exited' ? const Color(0xFF6C6C70) : t.warning),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => _LogsPage(host: host, title: '${c['name']}', path: '/v1/docker/containers/${c['name']}/logs', docker: true))),
                  trailing: PopupMenuButton<String>(
                    tooltip: l.filesMore,
                    icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
                    onSelected: (a) => act('${c['name']}', a),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'restart', child: Text(l.systemRestart)),
                      PopupMenuItem(value: 'start', child: Text(l.systemStart)),
                      PopupMenuItem(value: 'stop', child: Text(l.systemStop)),
                    ],
                  ),
                ),
            ]),
    );
  }
}

class _LogsPage extends ConsumerStatefulWidget {
  const _LogsPage({required this.host, required this.title, required this.path, this.docker = false});
  final Host host;
  final String title;
  final String path;
  final bool docker;
  @override
  ConsumerState<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<_LogsPage> {
  List<(String, String, int)>? _lines; // (time, text, level)
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await agentCall(ref, widget.host.id, 'GET', widget.path) as Map;
      final fmt = DateFormat.Hms();
      setState(() {
        _error = null;
        _lines = widget.docker
            ? [for (final x in (j['lines'] as List).cast<Map>()) ('${x['time']}'.length > 19 ? '${x['time']}'.substring(11, 19) : '', '${x['message']}', x['stream'] == 'stderr' ? 3 : 6)]
            : [
                for (final x in (j['entries'] as List).cast<Map>())
                  (fmt.format(DateTime.fromMicrosecondsSinceEpoch((x['timeUs'] as num).toInt())), '${x['message']}', (x['priority'] as num).toInt())
              ];
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: _load)]),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(agentErrorText(l, _error!))))
          : _lines == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: _lines!.length,
                  itemBuilder: (c, i) {
                    final (time, text, prio) = _lines![_lines!.length - 1 - i];
                    final color = prio <= 3 ? t.danger : (prio == 4 ? t.warning : t.text);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: '$time  ', style: TextStyle(color: t.textSecondary)),
                          TextSpan(text: text, style: TextStyle(color: color)),
                        ]),
                        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.35),
                      ),
                    );
                  },
                ),
    );
  }
}
