// Sleep group setup (PLAN.md §21 U5): pick the machines, the leader (default: the one with Velour: the sleep list and
// the alarm song play there), where each stands in the room, then a DDC test (the monitor dims for 5 s through
// POST /v1/sleep/preview and comes back). Nothing is written before "Bitir": then each machine gets its `join`, side
// and distance, and every machine the same `group`.
//
// TODO(PLAN §21 S6/S7): the sound test (each machine plays a short click in turn, the user confirms left/right) needs
// an agent route that doesn't exist yet; the step is left out of the wizard until it does.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/forms.dart';
import '../../../widgets/surfaces.dart';
import '../screen_widgets.dart' show SegRow;
import 'sleep_data.dart';
import 'sleep_machines.dart' show sleepDimmingText;
import 'sleep_texts.dart';
import 'sleep_widgets.dart';

class SleepWizard extends ConsumerStatefulWidget {
  const SleepWizard({super.key, required this.group, required this.onDone, this.onCancel});
  final SleepGroup group;
  final VoidCallback onDone;
  final VoidCallback? onCancel;
  @override
  ConsumerState<SleepWizard> createState() => _SleepWizardState();
}

class _SleepWizardState extends ConsumerState<SleepWizard> {
  int _step = 0;
  bool _busy = false;
  late final Map<String, bool> _join = {
    for (final m in widget.group.supported) m.host.id: widget.group.configured ? m.joined : true,
  };
  late String _leader = (widget.group.leader ?? widget.group.supported.first).host.id;
  late final Map<String, (String, String)> _layout = {
    for (final m in widget.group.supported) m.host.id: (m.status!.settings.side, m.status!.settings.distance),
  };

  /// host → DDC test result (text, ok).
  final _ddc = <String, (String, bool)>{};
  String? _testing;

  static const _steps = 4;

  List<SleepMachine> get _chosen => [for (final m in widget.group.supported) if (_join[m.host.id] == true) m];

  Future<void> _test(SleepMachine m) async {
    final l = AppLocalizations.of(context);
    setState(() => _testing = m.host.id);
    try {
      final j = await ref.read(sleepGroupProvider.notifier).preview(m.host.id, 10);
      final p = j['preview'] is Map ? j['preview'] as Map : (j['brightness'] is Map ? j['brightness'] as Map : const {});
      final dim = p['dimming'] as String?;
      final warn = j['warning'] as String?;
      setState(() => _ddc[m.host.id] = (warn != null ? sleepErrorText(l, warn) : l.slWizardDdcOk(sleepDimmingText(l, dim, null)), warn == null && dim != 'content'));
    } catch (e) {
      if (mounted) setState(() => _ddc[m.host.id] = (sleepActionError(l, widget.group, e), false));
    } finally {
      if (mounted) setState(() => _testing = null);
    }
  }

  Future<void> _finish() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(sleepGroupProvider.notifier).setup(join: _join, leaderHost: _leader, layout: _layout);
      widget.onDone();
    } catch (e) {
      if (mounted) toast(context, sleepActionError(l, widget.group, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final g = widget.group;
    final chosen = _chosen;
    if (!chosen.any((m) => m.host.id == _leader) && chosen.isNotEmpty) _leader = (chosen.where((m) => m.velour).firstOrNull ?? chosen.first).host.id;
    final (title, body) = switch (_step) {
      0 => (l.slWizardMachines, l.slWizardMachinesHint),
      1 => (l.slWizardLeader, l.slWizardLeaderHint),
      2 => (l.slWizardLayout, l.slWizardLayoutHint),
      _ => (l.slWizardDdc, l.slWizardDdcHint),
    };
    Widget radio(bool on) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: on ? t.accent : (t.isDark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC)), width: on ? 7 : 2),
      ),
    );
    final content = switch (_step) {
      0 => [
        for (final m in g.supported)
          CheckboxListTile(
            value: _join[m.host.id] == true,
            onChanged: (v) => setState(() => _join[m.host.id] = v == true),
            title: Text(m.host.name, style: tt.titleMedium),
            subtitle: m.velour ? Text(l.slWizardHasVelour, style: tt.bodySmall) : null,
            secondary: Icon(m.velour ? LucideIcons.monitorSpeaker : LucideIcons.monitor, color: t.textSecondary),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        for (final m in g.machines.where((m) => m.unsupported)) SleepNeedsUpdateRow(host: m.host.name),
      ],
      1 => [
        for (final m in chosen)
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: _leader == m.host.id,
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _leader = m.host.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                child: Row(
                  children: [
                    Icon(m.velour ? LucideIcons.monitorSpeaker : LucideIcons.monitor, color: t.textSecondary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.host.name, style: tt.titleMedium),
                          if (m.velour) Text(l.slWizardHasVelour, style: tt.bodySmall),
                        ],
                      ),
                    ),
                    radio(_leader == m.host.id),
                  ],
                ),
              ),
            ),
          ),
      ],
      2 => [
        for (final m in chosen) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(m.host.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          SegRow<String>(
            title: l.slSide,
            value: _layout[m.host.id]!.$1,
            options: [for (final x in sleepSides) (x, sleepSideName(l, x))],
            onChanged: (v) => setState(() => _layout[m.host.id] = (v, _layout[m.host.id]!.$2)),
          ),
          SegRow<String>(
            title: l.slDistance,
            value: _layout[m.host.id]!.$2,
            options: [for (final x in sleepDistances) (x, sleepDistanceName(l, x))],
            onChanged: (v) => setState(() => _layout[m.host.id] = (_layout[m.host.id]!.$1, v)),
          ),
        ],
      ],
      _ => [
        for (final m in chosen)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Icon(
                    _ddc[m.host.id] == null ? LucideIcons.sunDim : (_ddc[m.host.id]!.$2 ? LucideIcons.circleCheck : LucideIcons.triangleAlert),
                    size: 18,
                    color: _ddc[m.host.id] == null ? t.textSecondary : (_ddc[m.host.id]!.$2 ? t.success : t.warning),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.host.name, style: tt.titleMedium),
                        Text(_ddc[m.host.id]?.$1 ?? l.slWizardDdcIdle, style: tt.bodySmall),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _testing != null ? null : () => _test(m),
                  child: _testing == m.host.id ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.slWizardDdcTest),
                ),
              ],
            ),
          ),
      ],
    };
    final last = _step == _steps - 1;
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SleepMoon(size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.slWizardStep(_step + 1, _steps), style: tt.bodySmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w700)),
                    Semantics(header: true, child: Text(title, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: (_step + 1) / _steps, minHeight: 4, color: sleepColor(t), backgroundColor: t.ringTrack),
          ),
          const SizedBox(height: 12),
          Text(body, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
          const SizedBox(height: 8),
          ...content,
          const SizedBox(height: 14),
          Row(
            children: [
              if (_step > 0)
                TextButton.icon(onPressed: _busy ? null : () => setState(() => _step--), icon: const Icon(LucideIcons.chevronLeft, size: 18), label: Text(l.slBack))
              else if (widget.onCancel != null)
                TextButton(onPressed: _busy ? null : widget.onCancel, child: Text(l.commonCancel)),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: _busy || chosen.isEmpty ? null : (last ? _finish : () => setState(() => _step++)),
                iconAlignment: last ? IconAlignment.start : IconAlignment.end,
                icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(last ? LucideIcons.check : LucideIcons.chevronRight, size: 18),
                label: Text(last ? l.gmSetupFinish : l.commonContinue),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
