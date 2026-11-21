// Sleep mode, the machines (PLAN.md §21 U2 "Makineler"): one card per display host with its own settings, written to
// that machine only: join the group, its place in the room (side and distance), volume, brightness at the start, of
// the night light and of the morning (each with a live preview: dragging shows that level on that machine for 5 s),
// how it dims (backlight, DDC/CI or only the page; the DDC/CI warning), and the optional extras (quiet power profile,
// hold the system volume, lit LEDs off).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/forms.dart';
import '../../../widgets/surfaces.dart';
import '../../system/agent_providers.dart';
import '../screen_widgets.dart' show SegRow;
import 'sleep_data.dart';
import 'sleep_screen.dart' show saveSleepMachine;
import 'sleep_texts.dart';
import 'sleep_widgets.dart';

/// "Donanım: DDC/CI · %25" from a status or a preview answer.
String sleepDimmingText(AppLocalizations l, String? dimming, int? hardware) {
  final how = switch (dimming) {
    'backlight' => l.slDimBacklight,
    'ddc' => l.slDimDdc,
    'content' => l.slDimContent,
    _ => null,
  };
  if (how == null) return l.slDimUnknown;
  return hardware == null || dimming == 'content' ? how : '$how · %$hardware';
}

class SleepMachinesSection extends StatelessWidget {
  const SleepMachinesSection({super.key, required this.group});
  final SleepGroup group;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l.slSectionMachines),
        for (final (i, m) in group.machines.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 12), child: SleepMachineCard(group: group, machine: m)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(l.slMachinesHint, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class SleepMachineCard extends ConsumerStatefulWidget {
  const SleepMachineCard({super.key, required this.group, required this.machine});
  final SleepGroup group;
  final SleepMachine machine;
  @override
  ConsumerState<SleepMachineCard> createState() => _SleepMachineCardState();
}

class _SleepMachineCardState extends ConsumerState<SleepMachineCard> {
  /// The live preview: at most one request in flight and one every 700 ms while dragging; the last value wins.
  Timer? _throttle;
  int? _next;
  bool _sending = false;
  String? _previewDimming;
  int? _previewHardware;
  bool _previewFailed = false;

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  String get _hostId => widget.machine.host.id;

  void _preview(int v) {
    _next = v;
    if (_throttle != null || _sending) return;
    unawaited(_sendPreview());
    _throttle = Timer(const Duration(milliseconds: 700), () {
      _throttle = null;
      if (_next != null) _preview(_next!);
    });
  }

  Future<void> _sendPreview() async {
    final v = _next;
    if (v == null) return;
    _next = null;
    _sending = true;
    final l = AppLocalizations.of(context);
    try {
      final j = await ref.read(sleepGroupProvider.notifier).preview(_hostId, v);
      final p = j['preview'] is Map ? j['preview'] as Map : (j['brightness'] is Map ? j['brightness'] as Map : const {});
      if (mounted) {
        setState(() {
          _previewDimming = p['dimming'] as String?;
          _previewHardware = (p['hardware'] as num?)?.round() ?? v;
          _previewFailed = false;
        });
      }
    } catch (e) {
      // One toast per drag: the next drag tries again.
      if (mounted && !_previewFailed) {
        setState(() => _previewFailed = true);
        toast(context, sleepActionError(l, widget.group, e));
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _save(Map<String, Object?> p) => saveSleepMachine(context, ref, _hostId, p);

  Future<void> _join(bool v) async {
    final l = AppLocalizations.of(context);
    try {
      await ref.read(sleepGroupProvider.notifier).setJoin(_hostId, v);
    } catch (e) {
      if (mounted) toast(context, sleepActionError(l, widget.group, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final m = widget.machine;
    final g = widget.group;
    final leader = g.leader == m;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: sleepColor(t).withValues(alpha: t.isDark ? 0.16 : 0.13), borderRadius: BorderRadius.circular(12)),
            child: Icon(m.velour ? LucideIcons.monitorSpeaker : LucideIcons.monitor, size: 20, color: t.isDark ? sleepColor(t) : Color.lerp(sleepColor(t), Colors.black, 0.3)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(m.host.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (leader) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(999)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.crown, size: 12, color: t.textSecondary),
                            const SizedBox(width: 4),
                            Text(l.slLeader, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  m.unsupported
                      ? l.smNeedsUpdateTitle
                      : m.error != null
                      ? agentErrorText(l, m.error!)
                      : m.running
                      ? sleepPhaseName(l, m.status!.phase)
                      : (m.joined ? l.slInGroup : l.slNotInGroup),
                  style: tt.bodySmall?.copyWith(color: m.error != null ? t.danger : t.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          StatusDot(color: m.error != null ? t.danger : (m.running ? t.success : t.textSecondary)),
        ],
      ),
    );
    final divider = Padding(padding: const EdgeInsets.only(left: 16), child: Divider(color: t.separator, height: 1));
    if (!m.ok) {
      return TCard(
        padding: EdgeInsets.zero,
        radius: TiphysTokens.radiusList,
        child: Column(children: [header, if (m.unsupported) ...[divider, SleepNeedsUpdateRow(host: m.host.name)]]),
      );
    }
    final s = m.status!.settings;
    final st = m.status!;
    final dimming = _previewDimming ?? st.dimming;
    final hardware = _previewDimming != null ? _previewHardware : st.hardware;
    final rows = <Widget>[
      SwitchRow(title: l.slJoin, subtitle: l.slJoinHint, icon: LucideIcons.link, iconBackground: sleepColor(t), value: s.join, onChanged: _join),
      if (s.join) ...[
        SegRow<String>(title: l.slSide, value: s.side, options: [for (final x in sleepSides) (x, sleepSideName(l, x))], onChanged: (v) => _save({'side': v})),
        SegRow<String>(title: l.slDistance, value: s.distance, options: [for (final x in sleepDistances) (x, sleepDistanceName(l, x))], onChanged: (v) => _save({'distance': v})),
        SleepSliderRow(title: l.slVolume, value: s.volume, min: 0, max: 100, divisions: 20, onChangeEnd: (v) => _save({'volume': v})),
        SleepSliderRow(
          title: l.slBrightnessStart,
          value: s.brightnessStart,
          min: 1,
          max: 100,
          divisions: 99,
          onChanged: _preview,
          onChangeEnd: (v) {
            _preview(v);
            _save({'brightness': {'start': v}});
          },
        ),
        SleepSliderRow(
          title: l.slBrightnessNight,
          subtitle: l.slBrightnessNightHint,
          value: s.brightnessNight,
          min: 0,
          max: 30,
          onChanged: _preview,
          onChangeEnd: (v) {
            _preview(v);
            _save({'brightness': {'night': v}});
          },
        ),
        SleepSliderRow(
          title: l.slBrightnessMorning,
          value: s.brightnessMorning,
          min: 10,
          max: 100,
          divisions: 90,
          onChanged: _preview,
          onChangeEnd: (v) {
            _preview(v);
            _save({'brightness': {'morning': v}});
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(st.warning != null ? LucideIcons.triangleAlert : LucideIcons.sunDim, size: 18, color: st.warning != null ? t.warning : t.textSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.slDimming, style: tt.titleSmall),
                    Text(sleepDimmingText(l, dimming, hardware), style: tt.bodySmall),
                    if (st.warning != null) Text(sleepErrorText(l, st.warning!), style: tt.bodySmall?.copyWith(color: t.warning)),
                    Text(l.slPreviewHint, style: tt.bodySmall?.copyWith(color: t.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        SwitchRow(title: l.slQuietPower, subtitle: l.slQuietPowerHint, icon: LucideIcons.leaf, iconBackground: const Color(0xFF34C759), value: s.quietPower, onChanged: (v) => _save({'quietPower': v})),
        SwitchRow(
          title: l.slHoldVolume,
          subtitle: l.slHoldVolumeHint,
          icon: LucideIcons.volume2,
          iconBackground: const Color(0xFF0A84FF),
          value: s.holdVolume != null,
          onChanged: (v) => _save({'holdVolume': v ? 40 : null}),
        ),
        if (s.holdVolume != null) SleepSliderRow(title: l.slHoldVolumeLevel, value: s.holdVolume!, min: 0, max: 100, divisions: 20, onChangeEnd: (v) => _save({'holdVolume': v})),
        SwitchRow(title: l.slLeds, subtitle: l.slLedsHint, icon: LucideIcons.lightbulbOff, iconBackground: const Color(0xFF8E8E93), value: s.leds, onChanged: (v) => _save({'leds': v})),
      ],
    ];
    return TCard(
      padding: EdgeInsets.zero,
      radius: TiphysTokens.radiusList,
      child: Column(
        children: [
          header,
          for (final r in rows) ...[divider, r],
          if (s.join && !leader && g.members.length > 1) ...[
            divider,
            GroupedRow(
              title: l.slMakeLeader,
              subtitle: l.slMakeLeaderHint,
              icon: LucideIcons.crown,
              iconBackground: const Color(0xFFFF9F0A),
              showChevron: false,
              onTap: () => _makeLeader(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _makeLeader(BuildContext context) async {
    final l = AppLocalizations.of(context);
    try {
      await ref.read(sleepGroupProvider.notifier).writeGroup(leader: widget.machine.agentId);
    } catch (e) {
      if (context.mounted) toast(context, sleepActionError(l, widget.group, e));
    }
  }
}
