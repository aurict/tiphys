// Grafana › Alerts: all alert rules (Grafana + Prometheus data sources), sorted by state.
// Firing ones on top; tapping a rule shows its summary, query and when it became active.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/integrations/grafana_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'grafana_screen.dart' show grafanaAlertState;
import 'providers.dart';

final grafanaRulesProvider = FutureProvider.autoDispose.family<List<GrafanaRule>, GrafanaConfig>((ref, g) async {
  final c = await ref.read(grafanaFactoryProvider)(g);
  try {
    final ds = await c.datasources().catchError((_) => <({String uid, String type, String name})>[]);
    return await c.rules([for (final d in ds) if (d.type == 'prometheus') d.uid]);
  } finally {
    c.close();
  }
});

class GrafanaAlertsScreen extends ConsumerStatefulWidget {
  const GrafanaAlertsScreen({super.key, required this.config});
  final GrafanaConfig config;
  @override
  ConsumerState<GrafanaAlertsScreen> createState() => _GrafanaAlertsScreenState();
}

class _GrafanaAlertsScreenState extends ConsumerState<GrafanaAlertsScreen> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final data = ref.watch(grafanaRulesProvider(widget.config));
    return SettingsPage(
      title: l.grafanaAlerts,
      actions: [IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(grafanaRulesProvider(widget.config)))],
      children: data.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(integrationErrorText(l, e)))],
        data: (rules) {
          final active = rules.where((r) => r.state != 'normal').toList();
          final shown = _all ? rules : active;
          return [
            TCard(
              child: Row(children: [
                Icon(active.isEmpty ? LucideIcons.circleCheck : LucideIcons.bellRing, color: active.isEmpty ? t.success : t.danger, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(active.isEmpty ? l.grafanaAllNormal(rules.length) : l.grafanaActiveAlerts(active.length, rules.length),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: [ButtonSegment(value: false, label: Text(l.grafanaActiveOnly)), ButtonSegment(value: true, label: Text(l.grafanaAllRules))],
              selected: {_all},
              onSelectionChanged: (v) => setState(() => _all = v.first),
            ),
            if (shown.isEmpty)
              Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.grafanaNoAlerts)))
            else
              GroupedSection(children: [for (final r in shown) _RuleRow(rule: r)]),
            Padding(padding: const EdgeInsets.all(8), child: Text(l.grafanaAlertsNote, style: Theme.of(context).textTheme.bodySmall)),
          ];
        },
      ),
    );
  }
}

Color ruleColor(TiphysTokens t, String s) => switch (s) {
      'firing' || 'error' => t.danger,
      'pending' || 'nodata' => t.warning,
      _ => t.success,
    };

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.rule});
  final GrafanaRule rule;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return GroupedRow(
      title: rule.name,
      subtitle: [
        grafanaAlertState(l, rule.state),
        if (rule.severity != null) rule.severity!,
        if (rule.activeAt != null) DateFormat.MMMd(locale).add_Hm().format(rule.activeAt!.toLocal()),
        rule.group,
      ].join(' · '),
      icon: rule.state == 'normal' ? LucideIcons.check : LucideIcons.bell,
      iconBackground: ruleColor(t, rule.state),
      onTap: () => showModalBottomSheet<void>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
        context: context,
        isScrollControlled: true,
        builder: (c) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                StatusDot(color: ruleColor(t, rule.state), size: 10),
                const SizedBox(width: 8),
                Expanded(child: Text(rule.name, style: Theme.of(context).textTheme.titleMedium)),
              ]),
              const SizedBox(height: 4),
              Text('${grafanaAlertState(l, rule.state)} · ${rule.source} / ${rule.group}', style: TextStyle(color: t.textSecondary, fontSize: 13)),
              if (rule.summary != null) ...[const SizedBox(height: 12), Text(rule.summary!)],
              if (rule.query != null) ...[
                const SizedBox(height: 12),
                TCard(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(rule.query!, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
