// Sleep mode screen (route /screen/sleep; PLAN.md §21 U2): a hero with the big moon, the group's state (phase, time
// left, alarm, each machine's dot) and "Uykuya geç" / "Uyan" (the alarm: Ertele / Kapat), then the sections: Sahne,
// Ses, Alarm, Makineler, Bildirimler, Hatırlatma and the setup. A separate screen rather than a fourth tab of /screen:
// the sleep mode belongs to the whole group (every display host at once), not to one display host like the three
// layout modes, and it has no layout or look settings. Group-wide changes go to every machine, per-machine changes only
// to that machine; each shows at once. Before the group is set up the wizard opens (sleep_wizard.dart).
import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/push/focus_notices.dart' show clockText;
import '../../../l10n/gen/app_localizations.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/forms.dart';
import '../../../widgets/surfaces.dart';
import '../../system/velour_data.dart' show velourPlaylistsProvider, velourErrorText;
import '../screen_widgets.dart';
import 'sleep_data.dart';
import 'sleep_machines.dart';
import 'sleep_morning.dart';
import 'sleep_sync.dart';
import 'sleep_texts.dart';
import 'sleep_widgets.dart';
import 'sleep_wizard.dart';

/// The last group start that failed somewhere (the hero shows it until retried, dismissed or the mode stops).
final sleepStartFailureProvider = NotifierProvider<SleepStartFailure, SleepStartResult?>(SleepStartFailure.new);

class SleepStartFailure extends Notifier<SleepStartResult?> {
  @override
  SleepStartResult? build() => null;
  void set(SleepStartResult? r) => state = r == null || r.ok ? null : r;
}

/// Sends a group-wide patch (every machine), with a toast on failure.
Future<void> saveSleepGroup(BuildContext context, WidgetRef ref, Map<String, Object?> patch) async {
  final l = AppLocalizations.of(context);
  try {
    await ref.read(sleepGroupProvider.notifier).saveGroup(patch);
  } catch (e) {
    if (context.mounted) toast(context, sleepActionError(l, ref.read(sleepGroupProvider).value, e));
  }
}

/// Sends a patch to one machine, with a toast on failure.
Future<void> saveSleepMachine(BuildContext context, WidgetRef ref, String hostId, Map<String, Object?> patch) async {
  final l = AppLocalizations.of(context);
  try {
    await ref.read(sleepGroupProvider.notifier).saveMachine(hostId, patch);
  } catch (e) {
    if (context.mounted) toast(context, sleepActionError(l, ref.read(sleepGroupProvider).value, e));
  }
}

/// Starts the group (leader first); a failure is kept for the hero. Returns whether everything started.
Future<bool> startSleepGroup(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  try {
    final r = await ref.read(sleepGroupProvider.notifier).start();
    ref.read(sleepStartFailureProvider.notifier).set(r);
    return r.ok;
  } catch (e) {
    if (context.mounted) toast(context, sleepActionError(l, ref.read(sleepGroupProvider).value, e));
    return false;
  }
}

class SleepScreen extends ConsumerStatefulWidget {
  const SleepScreen({super.key, this.morning});

  /// A morning summary (JSON) from its notification: shown on top, memory only.
  final String? morning;
  @override
  ConsumerState<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends ConsumerState<SleepScreen> {
  /// null: the wizard opens when the group isn't set up; true / false: opened / closed by the user.
  bool? _wizard;

  @override
  void initState() {
    super.initState();
    final m = SleepMorning.fromJson(widget.morning);
    if (m != null) Future.microtask(() => ref.read(sleepMorningShownProvider.notifier).show(m));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(sleepGroupProvider);
    final g = async.value;
    if (g == null) {
      return _page(l, [
        async.hasError ? ScreenErrorCard(error: async.error!, onRetry: () => ref.read(sleepGroupProvider.notifier).retry()) : const ScreenLoading(),
      ]);
    }
    if (g.machines.isEmpty) return _page(l, [ScreenNotice(icon: LucideIcons.monitor, title: l.smNoHostTitle, body: l.smNoHostBody)]);
    if (!g.anySupported) {
      return _page(l, [
        if (g.allUnsupported)
          ScreenNotice(icon: LucideIcons.circleArrowUp, title: l.smNeedsUpdateTitle, body: l.slNeedsUpdate)
        else
          ScreenErrorCard(error: g.machines.firstWhere((m) => m.error != null, orElse: () => g.machines.first).error ?? l.commonError, onRetry: () => ref.read(sleepGroupProvider.notifier).retry()),
      ]);
    }
    final morning = ref.watch(sleepMorningProvider).value;
    final wizard = _wizard ?? !g.configured;
    if (wizard) {
      return _page(l, [
        SleepWizard(
          group: g,
          onDone: () => setState(() => _wizard = false),
          onCancel: g.configured ? () => setState(() => _wizard = false) : null,
        ),
      ]);
    }
    return _page(l, [
      if (morning != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SleepMorningCard(summary: morning, onClose: () => ref.read(sleepMorningShownProvider.notifier).show(SleepMorning(at: DateTime(2000)))),
        ),
      SleepHero(group: g),
      _SceneSection(group: g),
      _SoundSection(group: g),
      _AlarmSection(group: g),
      SleepMachinesSection(group: g),
      _NotifySection(group: g),
      _ReminderSection(group: g),
      GroupedSection(
        title: l.slSectionSetup,
        children: [
          GroupedRow(
            title: l.slWizardOpen,
            subtitle: l.slWizardOpenHint,
            icon: LucideIcons.wandSparkles,
            iconBackground: const Color(0xFF5E5CE6),
            onTap: () => setState(() => _wizard = true),
          ),
        ],
      ),
    ]);
  }

  Widget _page(AppLocalizations l, List<Widget> body) => SettingsPage(
    title: l.smModeSleep,
    children: [
      LargeTitleHeader(title: l.slTitle),
      const SizedBox(height: 14),
      ...body,
    ],
  );
}

// ───────────────────────────── hero ─────────────────────────────

/// "Sönüyor · 18 dk", "Gece ışığı", "Alarm çalıyor", "Ertelendi · 07:39'a kadar".
String sleepPhaseLine(AppLocalizations l, SleepStatus s, DateTime now) {
  final name = sleepPhaseName(l, s.phase);
  if (s.isRinging) return l.slPhaseRing;
  if (s.phase == 'snoozed') {
    final until = s.local(s.snoozedUntil);
    return until == null ? name : l.slSnoozedUntil(_hm(until));
  }
  final end = s.phaseEndsLocal;
  if (end == null || !end.isAfter(now)) return name;
  final left = end.difference(now);
  return l.slPhaseLeft(name, left.inMinutes >= 1 ? l.durationMinutes((left.inSeconds / 60).ceil()) : clockText(left));
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class SleepHero extends ConsumerStatefulWidget {
  const SleepHero({super.key, required this.group});
  final SleepGroup group;
  @override
  ConsumerState<SleepHero> createState() => _SleepHeroState();
}

class _SleepHeroState extends ConsumerState<SleepHero> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, sleepActionError(l, ref.read(sleepGroupProvider).value, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry(SleepStartResult r) => _run(() async {
    final n = ref.read(sleepGroupProvider.notifier);
    final again = await n.start(only: r.failed.keys.toList(), session: n.lastSession);
    ref.read(sleepStartFailureProvider.notifier).set(again.ok ? null : SleepStartResult(again.failed, [...r.started, ...again.started]));
  });

  /// "Tek makineyle sür": what started keeps running; when nothing did, one machine starts alone (the leader, else a
  /// member that only waited for it).
  Future<void> _alone(SleepStartResult r) => _run(() async {
    ref.read(sleepStartFailureProvider.notifier).set(null);
    if (r.started.isEmpty) {
      final again = await ref.read(sleepGroupProvider.notifier).startAlone(r);
      ref.read(sleepStartFailureProvider.notifier).set(again);
    }
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final g = widget.group;
    final on = g.running;
    final src = g.phaseSource;
    final ringing = g.ringing;
    final failure = ref.watch(sleepStartFailureProvider);
    final n = ref.read(sleepGroupProvider.notifier);
    final shown = on ? {...g.runningMachines, ...g.members}.toList() : g.members;
    final warning = g.runningMachines.where((m) => m.status?.warning != null).firstOrNull;
    final sun = sleepSunColor(t);
    return TickBuilder(
      active: on && src?.phaseEndsAt != null,
      builder: (context) {
        final now = DateTime.now();
        return TCard(
          radius: TiphysTokens.radiusHero,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SleepMoon(size: 72, on: on, ringing: ringing),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            StatusDot(color: ringing ? sun : (on ? t.success : t.textSecondary)),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                on && src != null ? sleepPhaseLine(l, src, now) : l.gmOff,
                                style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(sleepAlarmLine(l, g), style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
              if (shown.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in shown) _MachineChip(machine: m, leader: g.leader == m, failed: failure?.failed.containsKey(m.host.id) == true, state: g.memberState(m)),
                  ],
                ),
              ],
              if (g.groupError != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.unplug, size: 17, color: t.warning),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        sleepErrorText(l, g.groupError!, {
                          if (g.machines.any((m) => g.memberState(m) == 'down')) 'host': g.machines.where((m) => g.memberState(m) == 'down').map((m) => m.host.name).join(', '),
                        }),
                        style: tt.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              if (warning != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.triangleAlert, size: 17, color: t.warning),
                    const SizedBox(width: 9),
                    Expanded(child: Text(l.slDdcWarning(warning.host.name), style: tt.bodySmall)),
                  ],
                ),
              ],
              if (failure != null) ...[const SizedBox(height: 14), _FailurePanel(group: g, result: failure, busy: _busy, onRetry: () => _retry(failure), onAlone: () => _alone(failure))],
              const SizedBox(height: 18),
              if (ringing)
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            side: BorderSide(color: t.isDark ? t.cardBorder : t.separator),
                          ),
                          onPressed: _busy ? null : () => _run(() => n.alarm('snooze')),
                          icon: const Icon(LucideIcons.alarmClock, size: 18),
                          label: Text(l.slSnoozeFor(g.settings.snoozeMin), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: sun,
                            foregroundColor: const Color(0xFF2A1405),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            textStyle: tt.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                          onPressed: _busy ? null : () => _run(() => n.alarm('dismiss')),
                          icon: const Icon(LucideIcons.alarmClockOff, size: 20),
                          label: Text(l.slDismiss),
                        ),
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: on ? sun : sleepColor(t),
                      foregroundColor: on ? const Color(0xFF2A1405) : const Color(0xFF15102B),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      textStyle: tt.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    onPressed: _busy || (!on && g.members.isEmpty)
                        ? null
                        : () => _run(() async {
                            if (on) {
                              ref.read(sleepStartFailureProvider.notifier).set(null);
                              await n.stop();
                            } else {
                              await startSleepGroup(context, ref);
                            }
                          }),
                    icon: _busy
                        ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: on ? const Color(0xFF2A1405) : const Color(0xFF15102B)))
                        : Icon(on ? LucideIcons.sun : LucideIcons.moon, size: 20),
                    label: Text(on ? l.slWake : l.slStart),
                  ),
                ),
              if (!on && g.members.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.slNoMembers, style: tt.bodySmall, textAlign: TextAlign.center)),
            ],
          ),
        );
      },
    );
  }
}

class _MachineChip extends StatelessWidget {
  const _MachineChip({required this.machine, required this.leader, required this.failed, this.state});
  final SleepMachine machine;

  /// The group's view of it (S3), when known.
  final String? state;
  final bool leader;
  final bool failed;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final m = machine;
    final (label, color) = failed
        ? (l.slMachineFailed, t.danger)
        : m.error != null || state == 'down'
        ? (l.gmStateDown, t.danger)
        : state == 'connecting'
        ? (l.gmStateConnecting, t.warning)
        : m.running
        ? (l.gmOn, t.success)
        : (l.gmOff, t.textSecondary);
    return Semantics(
      label: '${m.host.name}${leader ? ', ${l.slLeader}' : ''}: $label',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
          decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(999)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: color, size: 8),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(m.host.name, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (leader) ...[const SizedBox(width: 5), Icon(LucideIcons.crown, size: 13, color: t.textSecondary)],
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12.5, color: t.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.group, required this.result, required this.busy, required this.onRetry, required this.onAlone});
  final SleepGroup group;
  final SleepStartResult result;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onAlone;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(color: t.danger.withValues(alpha: t.isDark ? 0.14 : 0.08), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.circleAlert, size: 18, color: t.danger),
              const SizedBox(width: 9),
              Expanded(child: Text(result.started.isEmpty ? l.slStartFailedAll : l.slStartFailedSome, style: tt.titleMedium)),
            ],
          ),
          const SizedBox(height: 6),
          for (final e in result.failed.entries)
            Padding(
              padding: const EdgeInsets.only(left: 27, bottom: 2),
              child: Text('${group.byHost(e.key)?.host.name ?? e.key}: ${sleepActionError(l, group, e.value)}', style: tt.bodySmall),
            ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(onPressed: busy ? null : onAlone, child: Text(l.slStartAlone)),
              TextButton(onPressed: busy ? null : onRetry, child: Text(l.commonRetry)),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Sahne ─────────────────────────────

class _SceneSection extends ConsumerWidget {
  const _SceneSection({required this.group});
  final SleepGroup group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = group.settings;
    String min(int v) => l.durationMinutes(v);
    Future<void> times(Map<String, Object?> p) => saveSleepGroup(context, ref, {'times': p});
    return GroupedSection(
      title: l.slSectionScene,
      footer: l.slTimesHint,
      children: [
        GroupedRow(
          title: l.slSceneEmbers,
          subtitle: l.slSceneEmbersHint,
          icon: LucideIcons.flame,
          iconBackground: emberMid,
          showChevron: false,
          trailing: Icon(LucideIcons.check, size: 18, color: t.accent),
        ),
        StepperRow(title: l.slSettleMin, value: s.settleMin, min: 1, max: 30, step: 1, unit: min, icon: LucideIcons.sparkles, iconBackground: emberHot, onChanged: (v) => times({'settleMin': v})),
        StepperRow(title: l.slFadeMin, value: s.fadeMin, min: 10, max: 120, unit: min, icon: LucideIcons.sunset, iconBackground: const Color(0xFFFF6B35), onChanged: (v) => times({'fadeMin': v})),
      ],
    );
  }
}

// ───────────────────────────── Ses ─────────────────────────────

class _SoundSection extends ConsumerWidget {
  const _SoundSection({required this.group});
  final SleepGroup group;

  Future<void> _pickPlaylist(BuildContext context, WidgetRef ref, SleepMachine leader) async {
    final l = AppLocalizations.of(context);
    final current = group.settings.velourPlaylist;
    final choice = await showModalBottomSheet<(String?,)>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final lists = ref.watch(velourPlaylistsProvider(leader.host.id));
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(LucideIcons.circleSlash),
                    title: Text(l.slVelourNone),
                    trailing: current == null ? const Icon(LucideIcons.check) : null,
                    onTap: () => Navigator.pop(ctx, (null,)),
                  ),
                  ...lists.when(
                    loading: () => [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
                    error: (e, _) => [ListTile(leading: const Icon(LucideIcons.triangleAlert), title: Text(velourErrorText(l, e)))],
                    data: (items) => [
                      for (final (id, title) in items)
                        ListTile(
                          leading: const Icon(LucideIcons.listMusic),
                          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: current == id ? const Icon(LucideIcons.check) : null,
                          onTap: () => Navigator.pop(ctx, (id,)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (choice == null || choice.$1 == current || !context.mounted) return;
    await saveSleepGroup(context, ref, {
      'velour': {'playlistId': choice.$1},
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = group.settings;
    final leader = group.leader;
    String min(int v) => l.durationMinutes(v);
    Future<void> save(Map<String, Object?> p) => saveSleepGroup(context, ref, p);
    final icons = {
      'hum': (LucideIcons.audioWaveform, const Color(0xFF8E8E93)),
      'crackle': (LucideIcons.flame, emberMid),
      'logs': (LucideIcons.axe, const Color(0xFFA2845E)),
      'wind': (LucideIcons.wind, const Color(0xFF30B0C7)),
      'rain': (LucideIcons.cloudRain, const Color(0xFF0A84FF)),
    };
    final velourHere = leader?.velour == true;
    final playlist = s.velourPlaylist;
    final playlistName = playlist == null || leader == null
        ? null
        : ref.watch(velourPlaylistsProvider(leader.host.id)).value?.where((p) => p.$1 == playlist).firstOrNull?.$2 ?? playlist;
    return GroupedSection(
      title: l.slSectionSound,
      footer: l.slSoundHint,
      children: [
        for (final k in sleepLayers)
          SwitchRow(title: sleepLayerName(l, k), icon: icons[k]!.$1, iconBackground: icons[k]!.$2, value: s.layer(k), onChanged: (v) => save({'layers': {k: v}})),
        StepperRow(title: l.slSoundFadeMin, value: s.soundFadeMin, min: 10, max: 180, unit: min, icon: LucideIcons.volume1, iconBackground: const Color(0xFF5E5CE6), onChanged: (v) => save({'times': {'soundFadeMin': v}})),
        SegRow<String>(
          title: l.slNightSound,
          subtitle: l.slNightSoundHint,
          value: s.nightSound,
          options: [('hum', l.slNightSoundHum), ('off', l.slNightSoundOff)],
          onChanged: (v) => save({'times': {'nightSound': v}}),
        ),
        if (!s.hasVelour)
          const SleepNeedsUpdateRow()
        else ...[
          GroupedRow(
            title: l.slVelourList,
            subtitle: !velourHere ? l.slVelourMissing(leader?.host.name ?? '–') : (playlistName ?? l.slVelourNone),
            icon: LucideIcons.listMusic,
            iconBackground: const Color(0xFFFF375F),
            onTap: velourHere ? () => _pickPlaylist(context, ref, leader!) : null,
          ),
          if (playlist != null && velourHere) ...[
            SleepSliderRow(title: l.slVelourVolume, value: s.velourVolume, min: 0, max: 100, divisions: 20, onChangeEnd: (v) => save({'velour': {'volume': v}})),
            StepperRow(title: l.slVelourFadeMin, value: s.velourFadeMin, min: 10, max: 120, unit: min, icon: LucideIcons.music2, iconBackground: const Color(0xFFFF375F), onChanged: (v) => save({'velour': {'fadeMin': v}})),
          ],
        ],
      ],
    );
  }
}

// ───────────────────────────── Alarm ─────────────────────────────

class _AlarmSection extends ConsumerWidget {
  const _AlarmSection({required this.group});
  final SleepGroup group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = group.settings;
    if (!s.hasAlarm) return GroupedSection(title: l.slSectionAlarm, children: const [SleepNeedsUpdateRow()]);
    String min(int v) => l.durationMinutes(v);
    Future<void> save(Map<String, Object?> p) => saveSleepGroup(context, ref, {'alarm': p});
    final on = s.alarmEnabled;
    final days = s.alarmDays;
    // The time is the leader's clock time; in another time zone the phone's own is shown next to it.
    final zone = group.leaderZoneMin;
    return GroupedSection(
      title: l.slSectionAlarm,
      footer: l.slAlarmFooter,
      children: [
        SwitchRow(title: l.slAlarm, subtitle: on ? '${group.alarmHmLocal} · ${sleepDaysText(l, days)}' : null, icon: LucideIcons.alarmClock, iconBackground: sleepSunColor(t), value: on, onChanged: (v) => save({'enabled': v})),
        if (on) ...[
          SleepTimeRow(
            title: l.slAlarmTime,
            value: s.alarmTime,
            subtitle: zone != null && zone != 0 ? l.slAlarmLeaderClock(group.leader?.host.name ?? '–', shiftHm(s.alarmTime, -zone)) : null,
            icon: LucideIcons.clock,
            iconBackground: const Color(0xFF0A84FF),
            onChanged: (v) => save({'time': v}),
          ),
          _DaysRow(days: days, onChanged: (v) => save({'days': v})),
          StepperRow(title: l.slSunriseMin, value: s.sunriseMin, min: 10, max: 45, unit: min, icon: LucideIcons.sunrise, iconBackground: const Color(0xFFFF9F0A), onChanged: (v) => save({'sunriseMin': v})),
          SegRow<String>(
            title: l.slAlarmSound,
            subtitle: s.alarmSound == 'velour' ? l.slAlarmSoundVelourHint : null,
            value: s.alarmSound,
            options: [('birds', l.slSoundBirds), ('chime', l.slSoundChime), ('velour', l.slSoundVelour)],
            onChanged: (v) => save({'sound': v}),
          ),
          StepperRow(title: l.slRampMin, value: s.rampMin, min: 1, max: 10, step: 1, unit: min, icon: LucideIcons.volume2, iconBackground: const Color(0xFF34C759), onChanged: (v) => save({'rampMin': v})),
          StepperRow(title: l.slSnoozeMin, value: s.snoozeMin, min: 1, max: 30, step: 1, unit: min, icon: LucideIcons.alarmClockPlus, iconBackground: const Color(0xFF5E5CE6), onChanged: (v) => save({'snoozeMin': v})),
          StepperRow(title: l.slAutoStopMin, value: s.autoStopMin, min: 5, max: 60, unit: min, icon: LucideIcons.timerOff, iconBackground: const Color(0xFF8E8E93), onChanged: (v) => save({'autoStopMin': v})),
          SwitchRow(title: l.slMorningScreen, subtitle: l.slMorningScreenHint, icon: LucideIcons.sunMedium, iconBackground: const Color(0xFFFFCC00), value: s.morningScreen, onChanged: (v) => save({'morningScreen': v})),
          const _PhoneBackupRow(),
        ],
      ],
    );
  }
}

/// Alarm days: once / weekdays / every day, and the seven days under it (a tap there picks days one by one; the
/// agent's 0 = Sunday, shown Monday first).
class _DaysRow extends StatelessWidget {
  const _DaysRow({required this.days, required this.onChanged});
  final Object days;
  final ValueChanged<Object> onChanged;

  static const _week = [1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final names = sleepDayNames(l);
    final set = switch (days) {
      'weekdays' => _week,
      'daily' => const [0, 1, 2, 3, 4, 5, 6],
      List<int> d => d,
      _ => const <int>[],
    };
    void toggle(int i, bool on) {
      final next = ({...set}..removeWhere((x) => x == i));
      if (on) next.add(i);
      final sorted = next.toList()..sort();
      onChanged(switch (sorted.length) {
        0 => 'once',
        7 => 'daily',
        _ when listEquals(sorted, _week) => 'weekdays',
        _ => sorted,
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.slAlarmDays, style: tt.titleMedium),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final (v, label) in [('once', l.slDaysOnce), ('weekdays', l.slDaysWeekdays), ('daily', l.slDaysDaily)])
                  ButtonSegment(value: v, label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              selected: {if (days is String) days as String},
              onSelectionChanged: (v) {
                if (v.isNotEmpty) onChanged(v.first);
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final i in [1, 2, 3, 4, 5, 6, 0])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _DayChip(label: names[i], on: set.contains(i), onTap: () => toggle(i, !set.contains(i))),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final br = BorderRadius.circular(12);
    return Semantics(
      button: true,
      checked: on,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: on ? t.accent.withValues(alpha: t.isDark ? 0.22 : 0.12) : t.chipBackground,
          shape: RoundedRectangleBorder(borderRadius: br, side: BorderSide(color: on ? t.accent.withValues(alpha: 0.6) : Colors.transparent)),
          child: InkWell(
            borderRadius: br,
            onTap: onTap,
            child: SizedBox(
              height: 44,
              child: Center(
                child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? t.text : t.textSecondary)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The phone's backup alarm: Android with exact alarms allowed, else why not and how to allow them.
class _PhoneBackupRow extends ConsumerStatefulWidget {
  const _PhoneBackupRow();
  @override
  ConsumerState<_PhoneBackupRow> createState() => _PhoneBackupRowState();
}

class _PhoneBackupRowState extends ConsumerState<_PhoneBackupRow> with WidgetsBindingObserver {
  SleepPhoneAlarm? _phone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the system settings: read again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_read());
  }

  Future<void> _read() async {
    final p = await ref.read(sleepAlarmsProvider).phone();
    if (mounted) setState(() => _phone = p);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final p = _phone;
    if (p == null) return const SizedBox.shrink();
    final alarms = ref.read(sleepAlarmsProvider);
    final ok = p.supported && p.exact;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(!p.supported ? LucideIcons.smartphone : (ok ? LucideIcons.shieldCheck : LucideIcons.shieldAlert), size: 18, color: !p.supported ? t.textSecondary : (ok ? t.success : t.warning)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.slPhoneBackup, style: tt.titleSmall),
                Text(!p.supported ? l.slPhoneBackupInApp : (ok ? l.slPhoneBackupOk : l.slPhoneBackupNoExact), style: tt.bodySmall),
                if (p.supported)
                  Wrap(
                    spacing: 4,
                    children: [
                      if (!p.exact)
                        TextButton(
                          onPressed: () async {
                            await alarms.requestExact();
                            await _read();
                          },
                          child: Text(l.slAllowExact),
                        ),
                      TextButton(onPressed: alarms.requestFullScreen, child: Text(l.slAllowFullScreen)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Bildirimler ─────────────────────────────

class _NotifySection extends ConsumerWidget {
  const _NotifySection({required this.group});
  final SleepGroup group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = group.settings;
    if (!s.hasNotify) return GroupedSection(title: l.slSectionNotify, children: const [SleepNeedsUpdateRow()]);
    final critical = s.critical;
    final icons = {
      'hostDown': (LucideIcons.serverOff, const Color(0xFFFF3B30)),
      'securityTrap': (LucideIcons.shieldAlert, const Color(0xFFFF375F)),
      'incident': (LucideIcons.siren, const Color(0xFFFF9F0A)),
      'diskFull': (LucideIcons.hardDrive, const Color(0xFF8E8E93)),
    };
    return GroupedSection(
      title: l.slSectionNotify,
      footer: l.slNotifyHint,
      children: [
        for (final k in sleepCriticalKinds)
          SwitchRow(
            title: sleepCriticalName(l, k),
            icon: icons[k]!.$1,
            iconBackground: icons[k]!.$2,
            value: critical.contains(k),
            onChanged: (v) => saveSleepGroup(context, ref, {
              'notify': {
                'critical': [for (final x in sleepCriticalKinds) if (x == k ? v : critical.contains(x)) x],
              },
            }),
          ),
        SwitchRow(
          title: l.slMorningSummary,
          subtitle: l.slMorningSummaryHint,
          icon: LucideIcons.sunrise,
          iconBackground: const Color(0xFFFF9F0A),
          value: s.morningSummary,
          onChanged: (v) => saveSleepGroup(context, ref, {
            'notify': {'morningSummary': v},
          }),
        ),
      ],
    );
  }
}

// ───────────────────────────── Hatırlatma ─────────────────────────────

class _ReminderSection extends ConsumerWidget {
  const _ReminderSection({required this.group});
  final SleepGroup group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final s = group.settings;
    if (!s.hasReminder) return GroupedSection(title: l.slSectionReminder, children: const [SleepNeedsUpdateRow()]);
    Future<void> save(Map<String, Object?> p) => saveSleepGroup(context, ref, {'reminder': p});
    return GroupedSection(
      title: l.slSectionReminder,
      footer: l.slReminderHint,
      children: [
        SwitchRow(title: l.slReminder, icon: LucideIcons.bellRing, iconBackground: const Color(0xFF5E5CE6), value: s.reminderEnabled, onChanged: (v) => save({'enabled': v})),
        if (s.reminderEnabled) SleepTimeRow(title: l.slReminderTime, value: s.reminderTime, icon: LucideIcons.clock, iconBackground: const Color(0xFF0A84FF), onChanged: (v) => save({'time': v})),
      ],
    );
  }
}
