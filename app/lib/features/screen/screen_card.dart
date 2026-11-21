// Home screen card "Ekran modu" (id screenMode; was gameMode): dark glass tile like the Claude one (W0 mock
// display/draft/app-card.html). Closed: "Kapalı" + the last mode; running: the mode, the display host and one live line
// (Work: Claude sessions and jobs, Focus: the countdown and the task, Game: the §19 line). The big button stops
// everything in one tap; closed it opens the mode chooser. Hidden while no host has the feature.
// While the sleep mode runs (§21) the card is the sleep group's: "Uyku · alarm 07:30 · 2 makine", the phase and a big
// Uyan (stop all); while the alarm rings, Kapat. For 12 h after a night the morning summary sits under it.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/push/focus_notices.dart' show clockText, focusPhaseName;
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'screen_data.dart';
import 'screen_sheet.dart';
import 'screen_texts.dart';
import 'screen_widgets.dart';
import 'sleep/sleep_data.dart';
import 'sleep/sleep_morning.dart';
import 'sleep/sleep_screen.dart' show sleepPhaseLine;
import 'sleep/sleep_texts.dart';
import 'sleep/sleep_widgets.dart' show sleepSunColor;

/// "1 sa 42 dk" since [from].
String elapsedText(AppLocalizations l, DateTime? from, DateTime now) {
  if (from == null) return '';
  final m = math.max(0, now.difference(from).inMinutes);
  return m < 60 ? l.durationMinutes(m) : l.smHoursMinutes(m ~/ 60, m % 60);
}

/// Where a mode's cards read from, in words: one remote source, this machine, or a custom mix.
String layoutSourceText(AppLocalizations l, Profile p, Host display, ScreenStatus s, String mode) {
  final src = s.settings.mode(mode).layout.commonSource;
  if (src == null) return l.smFromCustomLayout;
  if (src == selfSource) return l.smFromSelf;
  return l.smMirroring(sourceLabel(p, display, s, src));
}

/// Work's live line: "2 Claude oturumu · 1 iş" (an agent without the counts: just "on").
String workLine(AppLocalizations l, ScreenStatus s) {
  final c = s.claudeSessions, j = s.jobs;
  if (c == null && j == null) return l.gmOn;
  return [
    c == null || c == 0 ? l.smNoClaude : l.smClaudeSessions(c),
    if (j != null && j > 0) l.smJobs(j),
  ].join(' · ');
}

/// Game's line (§19): the route while driving, else the scene.
String gameLine(AppLocalizations l, ScreenStatus s) {
  final truck = s.truck;
  if (truck?.driving == true && truck?.from != null && truck?.to != null) return l.gmDriving(truck!.from!, truck.to!);
  if (truck?.driving == true && truck?.speedKmh != null) return l.gmDrivingSpeed('${truck!.speedKmh}');
  return l.gmSceneNow(gameSceneName(l, s.activeScene));
}

String gameSceneName(AppLocalizations l, String scene) => switch (scene) {
  'drive' => l.gmSceneDrive,
  'music' => l.gmSceneMusic,
  _ => l.gmSceneIdle,
};

String? songLine(ScreenStatus s) {
  final m = s.music;
  if (m == null || m.title.isEmpty) return null;
  return m.artist.isEmpty ? m.title : '${m.title} · ${m.artist}';
}

/// Focus's line: "14:32 kaldı" (or paused / ready).
String focusLine(AppLocalizations l, FocusState f, DateTime now) {
  if (f.idle) return l.smFocusReady;
  final left = clockText(f.remaining(now));
  return f.paused ? l.smFocusPausedLeft(left) : l.smFocusLeft(left);
}

class ScreenModeHomeCard extends ConsumerStatefulWidget {
  const ScreenModeHomeCard({super.key});
  @override
  ConsumerState<ScreenModeHomeCard> createState() => _ScreenModeHomeCardState();
}

class _ScreenModeHomeCardState extends ConsumerState<ScreenModeHomeCard> {
  bool _busy = false;

  Future<void> _stop(String hostId) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(screenProvider(hostId).notifier).stop();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sleep(Future<void> Function(SleepGroupNotifier n) f) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await f(ref.read(sleepGroupProvider.notifier));
    } catch (e) {
      if (mounted) toast(context, sleepActionError(l, ref.read(sleepGroupProvider).value, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(screenTargetProvider).value;
    if (target == null) return const SizedBox.shrink();
    final sleep = ref.watch(sleepGroupProvider).value;
    final morning = ref.watch(sleepMorningProvider).value;
    final card = sleep != null && sleep.running ? _sleepCard(sleep) : _screenCard(target);
    if (morning == null) return card;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [card, const SizedBox(height: 12), SleepMorningCard(summary: morning, compact: true)]);
  }

  Widget _sleepCard(SleepGroup g) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final src = g.phaseSource;
    final ringing = g.ringing;
    final textStyle = TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: t.claudeTileText);
    final subStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.claudeTileSubtext);
    final sun = sleepSunColor(t);
    return TCard(
      height: MediaQuery.textScalerOf(context).scale(112),
      color: t.claudeTile,
      borderColor: t.claudeTileBorder,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => context.push(ringing ? '/screen/sleep/alarm' : '/screen/sleep'),
      semanticLabel: l.smModeSleep,
      child: TickBuilder(
        active: src?.phaseEndsAt != null,
        builder: (context) {
          final now = DateTime.now();
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(ringing ? LucideIcons.alarmClock : screenModeIcon('sleep'), size: 16, color: ringing ? sun : t.claudeTileSubtext),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l.smModeSleep,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: ringing ? sun : t.success,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: (ringing ? sun : t.success).withValues(alpha: 0.6), blurRadius: 8)],
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ringing ? l.slAlarmTitle(g.settings.alarmTime) : (src == null ? l.gmOn : sleepPhaseLine(l, src, now)),
                          style: textStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(ringing ? l.slAlarmMachines(g.runningMachines.length) : sleepAlarmLine(l, g), style: subStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _BigButton(
                running: true,
                busy: _busy,
                round: false,
                progress: null,
                label: ringing ? l.slDismiss : l.slWake,
                icon: ringing ? LucideIcons.alarmClockOff : LucideIcons.sun,
                color: sun,
                iconColor: const Color(0xFF2A1405),
                onTap: () => _sleep((n) => ringing ? n.alarm('dismiss') : n.stop()),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _screenCard(ScreenTarget target) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = target.host;
    final status = target.ready ? ref.watch(screenProvider(host.id)).value : null;
    final route = '/screen?host=${Uri.encodeQueryComponent(host.id)}';
    final running = status?.running ?? false;
    final mode = running ? status!.mode : null;
    final focusTicking = mode == 'focus' && status!.focus.ticking;
    final profile = ref.watch(profileProvider);

    final kicker = running ? '${screenModeName(l, mode)} · ${host.name}' : l.smTitle;
    final textStyle = TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: t.claudeTileText);
    final subStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.claudeTileSubtext);

    Widget lines(DateTime now) {
      final String headline;
      String? round;
      String? sub;
      if (!target.ready) {
        headline = l.gmCardSetup;
      } else if (status == null) {
        headline = '–';
      } else if (!running) {
        headline = l.gmOff;
        sub = l.smLastUsed(screenModeName(l, status.settings.lastMode), host.name);
      } else if (mode == 'focus') {
        final f = status.focus;
        headline = focusLine(l, f, now);
        if (f.phase == 'focus') round = '${f.round}/${f.longEvery}';
        sub = f.phase == 'focus' ? (f.task?.isNotEmpty == true ? f.task : focusPhaseName(l, f.phase)) : focusPhaseName(l, f.phase);
      } else if (mode == 'game') {
        headline = gameLine(l, status);
        sub = songLine(status);
      } else {
        headline = workLine(l, status);
        sub = [layoutSourceText(l, profile, host, status, 'work'), elapsedText(l, status.startedAt, now)].where((x) => x.isNotEmpty).join(' · ');
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: headline,
              children: [
                if (round != null)
                  TextSpan(
                    text: ' · $round',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileSubtext),
                  ),
              ],
            ),
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null && sub.isNotEmpty) Text(sub, style: subStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      );
    }

    return TCard(
      height: MediaQuery.textScalerOf(context).scale(112),
      color: t.claudeTile,
      borderColor: t.claudeTileBorder,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => context.push(route),
      semanticLabel: l.smTitle,
      child: TickBuilder(
        active: focusTicking,
        builder: (context) {
          final now = DateTime.now();
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(screenModeIcon(mode), size: 16, color: t.claudeTileSubtext),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            kicker,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (running) ...[
                          const SizedBox(width: 7),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: t.success,
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: t.success.withValues(alpha: 0.6), blurRadius: 8)],
                            ),
                          ),
                        ],
                      ],
                    ),
                    lines(now),
                  ],
                ),
              ),
              if (target.ready && status != null) ...[
                const SizedBox(width: 12),
                _BigButton(
                  running: running,
                  busy: _busy,
                  round: mode == 'focus' && !status.focus.idle,
                  progress: mode == 'focus' ? status.focus.progress(now) : null,
                  label: running ? l.smStopAll : l.gmStart,
                  onTap: running ? () => _stop(host.id) : () => showScreenSheet(context, hostId: host.id),
                ),
              ] else if (!target.ready)
                Icon(LucideIcons.chevronRight, color: t.claudeTileSubtext),
            ],
          );
        },
      ),
    );
  }
}

/// 64×64: white Play when closed, red Stop when running (round with a progress ring while a Focus phase runs).
class _BigButton extends StatelessWidget {
  const _BigButton({required this.running, required this.busy, required this.round, required this.progress, required this.label, required this.onTap, this.icon, this.color, this.iconColor});
  final bool running;

  /// Another icon and colors (the sleep mode's Uyan / Kapat).
  final IconData? icon;
  final Color? color;
  final Color? iconColor;
  final bool busy;
  final bool round;
  final double? progress;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final radius = round ? BorderRadius.circular(32) : BorderRadius.circular(18);
    final button = Material(
      color: color ?? (running ? t.danger : Colors.white),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: busy
              ? Padding(padding: const EdgeInsets.all(22), child: CircularProgressIndicator(strokeWidth: 2.4, color: iconColor ?? (running ? Colors.white : null)))
              : Icon(icon ?? (running ? LucideIcons.square : LucideIcons.play), size: icon != null ? 26 : (running ? 24 : 26), color: iconColor ?? (running ? Colors.white : const Color(0xFF1E1B4B))),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (round && progress != null)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: CircularProgressIndicator(value: progress, strokeWidth: 2.5, strokeCap: StrokeCap.round, color: Colors.white.withValues(alpha: 0.9), backgroundColor: Colors.transparent),
                ),
              ),
            button,
          ],
        ),
      ),
    );
  }
}
