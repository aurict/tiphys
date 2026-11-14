// Siteler (Uptime Kuma): liste, detay (yanıt süresi grafiği, kesintiler), ekle/düzenle/duraklat/sil.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'maintenance_screen.dart';
import 'providers.dart';

Color siteColor(TiphysTokens t, String s) => switch (s) {
      'up' => t.success,
      'down' => t.danger,
      'maintenance' => const Color(0xFF64B5F6),
      'paused' => const Color(0xFF8E8E93),
      _ => t.warning,
    };

String siteStatusText(AppLocalizations l, String s) => switch (s) {
      'up' => l.siteUp,
      'down' => l.siteDown,
      'maintenance' => l.siteMaintenance,
      'paused' => l.sitePaused,
      _ => l.sitePending,
    };

String pct(num? v) => v == null ? '–' : '%${(v * 100).toStringAsFixed(v >= 0.9995 ? 0 : 2)}';

class SitesScreen extends ConsumerWidget {
  const SitesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final data = ref.watch(uptimeProvider);
    return SettingsPage(
      title: l.systemSites,
      actions: [
        IconButton(
          tooltip: l.maintenanceTitle,
          icon: const Icon(LucideIcons.wrench),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MaintenanceScreen())),
        ),
        IconButton(tooltip: l.siteAdd, icon: const Icon(LucideIcons.plus), onPressed: () => _edit(context, ref, null)),
      ],
      children: [
        data.when(
          skipLoadingOnRefresh: true,
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
          data: (d) {
            final ms = (d['monitors'] as List).cast<Map>();
            final down = ms.where((m) => m['status'] == 'down').length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TCard(
                child: Row(children: [
                  Icon(down == 0 ? LucideIcons.circleCheck : LucideIcons.circleAlert, color: down == 0 ? t.success : t.danger, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(down == 0 ? l.sitesAllUp(ms.length) : l.sitesSomeDown(down),
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ]),
              ),
              GroupedSection(children: [
                for (final m in ms)
                  GroupedRow(
                    title: '${m['name']}',
                    subtitle: [
                      siteStatusText(l, '${m['status']}'),
                      if (m['ping'] != null) '${m['ping']} ms',
                      '24 sa ${pct(m['uptime24h'] as num?)}',
                      if ((m['cert'] as Map?)?['daysRemaining'] != null) 'SSL ${(m['cert'] as Map)['daysRemaining']} ${l.daysShort}',
                    ].join(' · '),
                    icon: LucideIcons.globe,
                    iconBackground: siteColor(t, '${m['status']}'),
                    trailing: SizedBox(width: 64, height: 22, child: _Beats(beats: (m['recent'] as List).cast<num>())),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SiteDetailScreen(id: m['id'] as int))),
                  ),
              ]),
            ]);
          },
        ),
      ],
    );
  }
}

/// Son atışlar: küçük dikey çubuklar (yeşil açık, kırmızı kapalı).
class _Beats extends StatelessWidget {
  const _Beats({required this.beats});
  final List<num> beats;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final list = beats.length > 16 ? beats.sublist(beats.length - 16) : beats;
    return ExcludeSemantics(
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        for (final b in list)
          Container(
            width: 3,
            margin: const EdgeInsets.only(left: 1),
            decoration: BoxDecoration(
              color: b == 1 ? t.success : (b == 0 ? t.danger : t.warning),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ]),
    );
  }
}

Future<void> _edit(BuildContext context, WidgetRef ref, Map? current) async {
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SiteEditScreen(current: current)));
  if (changed == true) ref.invalidate(uptimeProvider);
}

final siteDetailProvider = FutureProvider.autoDispose.family<(Map<String, dynamic>, List<Map>), (int, int)>((ref, key) async {
  final (id, hours) = key;
  final u = ref.watch(profileProvider.select((p) => p.integrations.uptimeKuma))!;
  return withAgent(ref, u.viaHostId, (c) async {
    final d = await c.get('/v1/uptime/monitors/$id');
    final b = await c.get('/v1/uptime/monitors/$id/beats', query: {'hours': '$hours'});
    return (d, (b['beats'] as List).cast<Map>());
  });
});

class SiteDetailScreen extends ConsumerStatefulWidget {
  const SiteDetailScreen({super.key, required this.id});
  final int id;
  @override
  ConsumerState<SiteDetailScreen> createState() => _SiteDetailState();
}

class _SiteDetailState extends ConsumerState<SiteDetailScreen> {
  int _hours = 24;

  Future<void> _act(String method, String path, {bool pop = false}) async {
    final l = AppLocalizations.of(context);
    final u = ref.read(profileProvider).integrations.uptimeKuma!;
    try {
      await agentCall(ref, u.viaHostId, method, path);
      ref.invalidate(uptimeProvider);
      ref.invalidate(siteDetailProvider((widget.id, _hours)));
      if (!mounted) return;
      if (pop) Navigator.pop(context);
      toast(context, l.systemDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final data = ref.watch(siteDetailProvider((widget.id, _hours)));
    return data.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: Center(child: Text(integrationErrorText(l, e)))),
      data: (r) {
        final (d, beats) = r;
        final status = '${d['status']}';
        final pings = [
          for (final b in beats)
            if (b['ping'] != null) FlSpot(DateTime.parse('${b['time']}Z'.replaceFirst(' ', 'T')).millisecondsSinceEpoch.toDouble(), (b['ping'] as num).toDouble()),
        ];
        final incidents = (d['incidents'] as List).cast<Map>();
        return SettingsPage(
          title: '${d['name']}',
          actions: [
            PopupMenuButton<String>(
              tooltip: l.filesMore,
              onSelected: (v) async {
                switch (v) {
                  case 'edit':
                    await _edit(context, ref, d);
                    ref.invalidate(siteDetailProvider((widget.id, _hours)));
                  case 'pause':
                    await _act('POST', '/v1/uptime/monitors/${widget.id}/pause');
                  case 'resume':
                    await _act('POST', '/v1/uptime/monitors/${widget.id}/resume');
                  case 'delete':
                    if (await confirmDialog(context, message: l.siteDeleteConfirm('${d['name']}'), confirmLabel: l.commonDelete, destructive: true)) {
                      await _act('DELETE', '/v1/uptime/monitors/${widget.id}', pop: true);
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(l.commonEdit)),
                if (status == 'paused') PopupMenuItem(value: 'resume', child: Text(l.siteResume)) else PopupMenuItem(value: 'pause', child: Text(l.sitePause)),
                PopupMenuItem(value: 'delete', child: Text(l.commonDelete)),
              ],
            ),
          ],
          children: [
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  StatusDot(color: siteColor(t, status), size: 12),
                  const SizedBox(width: 8),
                  Text(siteStatusText(l, status), style: Theme.of(context).textTheme.titleLarge),
                ]),
                if (d['url'] != null) Text('${d['url']}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Row(children: [
                  _Stat(label: l.sitePing, value: d['ping'] == null ? '–' : '${d['ping']} ms'),
                  _Stat(label: '24 ${l.hoursShort}', value: pct(d['uptime24h'] as num?)),
                  _Stat(label: '30 ${l.daysShort}', value: pct(d['uptime30d'] as num?)),
                  _Stat(label: 'SSL', value: (d['cert'] as Map?)?['daysRemaining'] == null ? '–' : '${(d['cert'] as Map)['daysRemaining']} ${l.daysShort}'),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [ButtonSegment(value: 1, label: Text('1 sa')), ButtonSegment(value: 24, label: Text('24 sa')), ButtonSegment(value: 168, label: Text('7 g'))],
              selected: {_hours},
              onSelectionChanged: (s) => setState(() => _hours = s.first),
            ),
            const SizedBox(height: 10),
            TCard(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
              child: SizedBox(
                height: 180,
                child: pings.length < 2
                    ? Center(child: Text(l.commonEmpty))
                    : Semantics(
                        label: l.sitePingChart,
                        child: LineChart(LineChartData(
                          minY: 0,
                          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.separator, strokeWidth: 1)),
                          borderData: FlBorderData(show: false),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(),
                            rightTitles: const AxisTitles(),
                            bottomTitles: const AxisTitles(),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 40,
                                getTitlesWidget: (v, m) => Text('${v.round()}', style: TextStyle(fontSize: 10, color: t.textSecondary)),
                              ),
                            ),
                          ),
                          lineTouchData: LineTouchData(
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipItems: (spots) => [
                                for (final s in spots)
                                  LineTooltipItem(
                                    '${s.y.round()} ms\n${DateFormat.Hm(locale).format(DateTime.fromMillisecondsSinceEpoch(s.x.toInt()))}',
                                    const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: pings,
                              color: t.accent,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(show: true, color: t.accent.withValues(alpha: 0.15)),
                            ),
                          ],
                        )),
                      ),
              ),
            ),
            GroupedSection(title: l.siteIncidents, children: [
              if (incidents.isEmpty) GroupedRow(title: l.siteNoIncidents, showChevron: false),
              for (final i in incidents.take(30))
                GroupedRow(
                  title: siteStatusText(l, ['down', 'up', 'pending', 'maintenance'][(i['status'] as num).toInt().clamp(0, 3)]),
                  subtitle: '${DateFormat.yMMMd(locale).add_Hm().format(DateTime.parse('${i['time']}Z'.replaceFirst(' ', 'T')).toLocal())}'
                      '${'${i['msg']}'.isEmpty ? '' : ' · ${i['msg']}'}',
                  icon: i['status'] == 1 ? LucideIcons.circleCheck : LucideIcons.circleX,
                  iconBackground: i['status'] == 1 ? t.success : t.danger,
                ),
            ]),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
      );
}

class SiteEditScreen extends ConsumerStatefulWidget {
  const SiteEditScreen({super.key, this.current});
  final Map? current;
  @override
  ConsumerState<SiteEditScreen> createState() => _SiteEditState();
}

class _SiteEditState extends ConsumerState<SiteEditScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController(text: 'https://');
  final _keyword = TextEditingController();
  final _interval = TextEditingController();
  final _alert = TextEditingController();
  final _hpGroup = TextEditingController(text: 'Yayındaki siteler');
  String _type = 'http';
  bool _saving = false;
  bool _certExpiry = true;
  bool _addToHomepage = false;

  @override
  void initState() {
    super.initState();
    final def = ref.read(profileProvider).integrations.uptimeKuma;
    final c = widget.current;
    _interval.text = '${c?['interval'] ?? def?.intervalSeconds ?? 60}';
    final interval = int.parse(_interval.text);
    _alert.text = '${c == null ? (def?.alertAfterSeconds ?? 120) : ((c['maxretries'] as num? ?? 0) + 1) * interval}';
    if (c != null) {
      _name.text = '${c['name']}';
      _url.text = '${c['url'] ?? ''}';
      _type = const {'http', 'keyword', 'ping', 'port'}.contains(c['type']) ? '${c['type']}' : 'http';
      _certExpiry = c['expiryNotification'] == true || c['expiryNotification'] == 1;
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final u = ref.read(profileProvider).integrations.uptimeKuma!;
    final body = {
      'name': _name.text.trim(),
      'type': _type,
      if (_type == 'http' || _type == 'keyword') 'url': _url.text.trim(),
      if (_type == 'ping' || _type == 'port') 'hostname': Uri.tryParse(_url.text.trim())?.host.isNotEmpty == true ? Uri.parse(_url.text.trim()).host : _url.text.trim(),
      if (_type == 'keyword') 'keyword': _keyword.text,
      'interval': int.parse(_interval.text),
      'alertAfterSeconds': int.parse(_alert.text),
      if (_type == 'http' || _type == 'keyword') 'certExpiry': _certExpiry,
    };
    try {
      if (widget.current == null) {
        await agentCall(ref, u.viaHostId, 'POST', '/v1/uptime/monitors', body);
        final hp = ref.read(profileProvider).integrations.homepage;
        if (_addToHomepage && hp != null) {
          try {
            await agentCall(ref, hp.hostId, 'POST', '/v1/homepage/services', {
              'group': _hpGroup.text.trim(),
              'name': _name.text.trim(),
              'href': _url.text.trim(),
            });
            ref.invalidate(homepageProvider);
          } catch (e) {
            // Site eklendi; Homepage adımı başarısızsa ayrıca bildirilir.
            if (mounted) toast(context, '${l.siteHomepageFailed}: ${agentErrorText(l, e)}');
          }
        }
      } else {
        await agentCall(ref, u.viaHostId, 'PATCH', '/v1/uptime/monitors/${widget.current!['id']}', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, agentErrorText(l, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Form(
      key: _form,
      child: SettingsPage(
        title: widget.current == null ? l.siteAdd : l.commonEdit,
        onSave: _save,
        saving: _saving,
        children: [
          FieldCard(children: [
            TField(controller: _name, label: l.hostName, validator: requiredV(l)),
            TField(controller: _url, label: _type == 'ping' || _type == 'port' ? l.hostAddress : 'URL', keyboardType: TextInputType.url, validator: requiredV(l)),
            if (_type == 'keyword') TField(controller: _keyword, label: l.siteKeyword, validator: requiredV(l)),
          ]),
          ChoiceSection<String>(
            title: l.siteType,
            value: _type,
            options: [('http', 'HTTP(S)'), ('keyword', l.siteKeyword), ('ping', 'Ping')],
            onChanged: (v) => setState(() => _type = v),
          ),
          FieldCard(children: [
            TField(controller: _interval, label: l.uptimeInterval, keyboardType: TextInputType.number, validator: intV(20, 86400)),
            TField(controller: _alert, label: l.uptimeAlertAfter, keyboardType: TextInputType.number, validator: intV(0, 86400)),
          ]),
          GroupedSection(children: [
            if (_type == 'http' || _type == 'keyword')
              SwitchRow(title: l.siteCertExpiry, subtitle: l.siteCertExpiryHint, value: _certExpiry, onChanged: (v) => setState(() => _certExpiry = v)),
            if (widget.current == null && ref.watch(profileProvider).integrations.homepage != null)
              SwitchRow(title: l.siteAddToHomepage, value: _addToHomepage, onChanged: (v) => setState(() => _addToHomepage = v)),
          ]),
          if (_addToHomepage && widget.current == null) FieldCard(children: [TField(controller: _hpGroup, label: l.siteHomepageGroup, validator: requiredV(l))]),
          Padding(padding: const EdgeInsets.all(8), child: Text(l.siteNotifyNote, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
