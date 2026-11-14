// Siteler › Bakım pencereleri (Uptime Kuma): bu sürede seçili sitelerin kesintisi bildirilmez.
// Yeni pencere şimdi başlar; süre hazır seçeneklerden seçilir.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/integrations/http_json.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'providers.dart';

final maintenanceProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final u = ref.watch(profileProvider.select((p) => p.integrations.uptimeKuma));
  if (u == null) throw const IntegrationError('notConfigured');
  final j = await withAgent(ref, u.viaHostId, (c) => c.get('/v1/uptime/maintenance'));
  return (j['maintenances'] as List).cast<Map<String, dynamic>>();
});

class MaintenanceScreen extends ConsumerWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fmt = DateFormat('d MMM HH:mm', Localizations.localeOf(context).toLanguageTag());
    final sites = {for (final m in ((ref.watch(uptimeProvider).value?['monitors'] as List?) ?? const []).cast<Map>()) m['id']: '${m['name']}'};
    Future<void> remove(Map<String, dynamic> m) async {
      if (!await confirmDialog(context, message: l.maintenanceDeleteConfirm('${m['title']}'), confirmLabel: l.commonDelete, destructive: true)) return;
      try {
        await agentCall(ref, ref.read(profileProvider).integrations.uptimeKuma!.viaHostId, 'DELETE', '/v1/uptime/maintenance/${m['id']}');
        ref.invalidate(maintenanceProvider);
        ref.invalidate(uptimeProvider);
      } catch (e) {
        if (context.mounted) toast(context, agentErrorText(l, e));
      }
    }

    String when(Map m) {
      DateTime? p(Object? v) => v == null ? null : DateTime.tryParse('$v'.contains('T') ? '$v' : '${'$v'.replaceFirst(' ', 'T')}Z')?.toLocal();
      final s = p(m['start']), e = p(m['end']);
      if (s == null || e == null) return '';
      return '${fmt.format(s)} – ${fmt.format(e)}';
    }

    return SettingsPage(
      title: l.maintenanceTitle,
      actions: [
        IconButton(
          tooltip: l.maintenanceAdd,
          icon: const Icon(LucideIcons.plus),
          onPressed: () async {
            final added = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const _MaintenanceAdd()));
            if (added == true) {
              ref.invalidate(maintenanceProvider);
              ref.invalidate(uptimeProvider);
            }
          },
        ),
      ],
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text(l.maintenanceExplain, style: TextStyle(color: t.textSecondary, fontSize: 13))),
        ref.watch(maintenanceProvider).when(
              loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
              data: (list) => list.isEmpty
                  ? TCard(child: Text(l.maintenanceEmpty))
                  : GroupedSection(children: [
                      for (final m in list)
                        GroupedRow(
                          title: '${m['title']}',
                          subtitle: [
                            maintenanceStatusText(l, '${m['status']}'),
                            if (when(m).isNotEmpty) when(m),
                            (m['monitorIds'] as List).map((id) => sites[id] ?? '#$id').join(', '),
                          ].join(' · '),
                          icon: LucideIcons.wrench,
                          iconBackground: m['status'] == 'under-maintenance' ? t.warning : (m['status'] == 'scheduled' ? const Color(0xFF0A84FF) : const Color(0xFF8E8E93)),
                          showChevron: false,
                          trailing: IconButton(tooltip: l.commonDelete, icon: Icon(LucideIcons.trash2, size: 18, color: t.danger), onPressed: () => remove(m)),
                        ),
                    ]),
            ),
      ],
    );
  }
}

String maintenanceStatusText(AppLocalizations l, String s) => switch (s) {
      'under-maintenance' => l.maintenanceActive,
      'scheduled' => l.maintenanceScheduled,
      'ended' => l.maintenanceEnded,
      _ => l.maintenanceInactive,
    };

class _MaintenanceAdd extends ConsumerStatefulWidget {
  const _MaintenanceAdd();
  @override
  ConsumerState<_MaintenanceAdd> createState() => _MaintenanceAddState();
}

class _MaintenanceAddState extends ConsumerState<_MaintenanceAdd> {
  final _title = TextEditingController();
  final _selected = <int>{};
  int _minutes = 60;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (_title.text.trim().isEmpty || _selected.isEmpty) {
      toast(context, l.maintenanceNeedsSites);
      return;
    }
    setState(() => _saving = true);
    final start = DateTime.now().toUtc();
    try {
      await agentCall(ref, ref.read(profileProvider).integrations.uptimeKuma!.viaHostId, 'POST', '/v1/uptime/maintenance', {
        'title': _title.text.trim(),
        'monitorIds': _selected.toList(),
        'start': start.toIso8601String(),
        'end': start.add(Duration(minutes: _minutes)).toIso8601String(),
      });
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
    final monitors = ((ref.watch(uptimeProvider).value?['monitors'] as List?) ?? const []).cast<Map>();
    return SettingsPage(
      title: l.maintenanceAdd,
      onSave: _save,
      saving: _saving,
      children: [
        FieldCard(children: [TField(controller: _title, label: l.maintenanceName)]),
        ChoiceSection<int>(
          title: l.maintenanceDuration,
          value: _minutes,
          options: [(30, l.durationMinutes(30)), (60, l.durationHours(1)), (120, l.durationHours(2)), (240, l.durationHours(4)), (720, l.durationHours(12))],
          onChanged: (v) => setState(() => _minutes = v),
        ),
        GroupedSection(title: l.systemSites, children: [
          for (final m in monitors)
            SwitchRow(
              title: '${m['name']}',
              value: _selected.contains(m['id']),
              onChanged: (v) => setState(() => v ? _selected.add(m['id'] as int) : _selected.remove(m['id'])),
            ),
        ]),
      ],
    );
  }
}
