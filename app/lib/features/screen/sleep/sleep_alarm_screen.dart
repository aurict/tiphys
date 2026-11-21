// The alarm on the phone (route /screen/sleep/alarm; PLAN.md §21 U3): opened by the full-screen alarm notification
// (also on the lock screen) or from the app while the machines ring: the time, Ertele and a big Kapat. Both work
// without the machines: the phone's own alarm follows at once (dismiss: the backup goes; snooze: it moves), then every
// machine is told. With the app lock on, the lock gate shows this screen alone (no other screen of the app is reached
// from it); it only snoozes or dismisses, like the notification's buttons.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys_native/tiphys_native.dart';

import '../../../core/push/sleep_notices.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../../state/providers.dart';
import 'sleep_data.dart';
import 'sleep_sync.dart';

/// An alarm notification opened the app (the ring time, ms; 0 when unknown); null: none. The lock gate shows the alarm
/// screen alone while the app is locked; [handledAt] tells the routed screen it was answered there already.
@immutable
class SleepAlarmRequest {
  const SleepAlarmRequest({this.at, this.handledAt});
  final int? at;
  final DateTime? handledAt;
}

final sleepAlarmRequestProvider = NotifierProvider<SleepAlarmRequestNotifier, SleepAlarmRequest>(SleepAlarmRequestNotifier.new);

class SleepAlarmRequestNotifier extends Notifier<SleepAlarmRequest> {
  @override
  SleepAlarmRequest build() => const SleepAlarmRequest();

  /// From the notification's route (`/screen/sleep/alarm?at=…`).
  void open(String route) => state = SleepAlarmRequest(at: int.tryParse(Uri.parse(route).queryParameters['at'] ?? '') ?? 0);
  void handled() => state = SleepAlarmRequest(handledAt: DateTime.now());
}

class SleepAlarmScreen extends ConsumerStatefulWidget {
  const SleepAlarmScreen({super.key, this.at, this.standalone = false});

  /// The ring time (ms) from the notification; null: the group's, else now.
  final int? at;

  /// Shown by the lock gate (no navigator around it).
  final bool standalone;
  @override
  ConsumerState<SleepAlarmScreen> createState() => _SleepAlarmScreenState();
}

class _SleepAlarmScreenState extends ConsumerState<SleepAlarmScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_overLock(true));
    if (!widget.standalone) {
      // Already answered on the lock screen: nothing to do here.
      final h = ref.read(sleepAlarmRequestProvider).handledAt;
      if (h != null && DateTime.now().difference(h) < const Duration(minutes: 2)) WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }
  }

  @override
  void dispose() {
    unawaited(_overLock(false));
    super.dispose();
  }

  /// Android: shown over the lock screen (and the screen turned on) only while this screen is open.
  Future<void> _overLock(bool on) async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;
    try {
      await TiphysNative.setShowWhenLocked(on);
    } on MissingPluginException {
      // Tests and an engine without the plugin.
    } on PlatformException {
      // No activity (a background engine).
    }
  }

  void _leave() {
    if (!mounted) return;
    if (widget.standalone) {
      ref.read(sleepAlarmRequestProvider.notifier).handled();
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _act(String action) async {
    setState(() => _busy = true);
    final g = ref.read(sleepGroupProvider).value;
    try {
      if (g != null && g.running) {
        await ref.read(sleepGroupProvider.notifier).alarm(action);
      } else {
        // The machines aren't known here (or not running: the phone's backup rings): the phone's alarm, then the run's
        // machines as far as they answer.
        final sync = ref.read(sleepSyncProvider);
        final run = await ref.read(sleepRunStoreProvider)?.read();
        if (action == 'dismiss') {
          await sync.dismissed();
        } else {
          await sync.snoozed(run?.snoozeMin ?? 9);
        }
        await sleepAlarmToAgents(
          action == 'dismiss' ? actionSleepDismiss : actionSleepSnooze,
          profile: ref.read(profileProvider),
          secrets: ref.read(secretStoreProvider),
          run: run,
        );
      }
    } catch (_) {
      // A machine that didn't answer still rings until its own auto-stop; the phone's own alarm is already handled.
    } finally {
      if (mounted) setState(() => _busy = false);
      _leave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final g = ref.watch(sleepGroupProvider).value;
    final src = g?.phaseSource;
    final at = widget.at != null && widget.at! > 0
        ? DateTime.fromMillisecondsSinceEpoch(widget.at!)
        : (src?.local(src.alarmNext) ?? ref.read(clockProvider)());
    final snooze = g?.settings.snoozeMin ?? 9;
    final machines = g?.runningMachines.length ?? 0;
    const ink = Color(0xFF2A1405);
    const cream = Color(0xFFFFF4E4);
    final time = DateFormat.Hm().format(at);
    final date = DateFormat.MMMMEEEEd(Localizations.localeOf(context).toLanguageTag()).format(at);
    final body = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF120B24), Color(0xFF3A1730), Color(0xFFB4502A), Color(0xFFF2A65A)],
          stops: [0, 0.38, 0.78, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(LucideIcons.alarmClock, size: 18, color: cream),
                  const SizedBox(width: 8),
                  Text(l.slAlarm, style: const TextStyle(color: cream, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                ],
              ),
              const Spacer(flex: 2),
              Semantics(
                label: l.slAlarmTitle(time),
                child: ExcludeSemantics(
                  child: Text(
                    time,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 92, height: 1, fontWeight: FontWeight.w800, letterSpacing: -3, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(date, textAlign: TextAlign.center, style: TextStyle(color: cream.withValues(alpha: 0.85), fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                machines > 0 ? l.slAlarmMachines(machines) : l.slGoodMorning,
                textAlign: TextAlign.center,
                style: TextStyle(color: cream.withValues(alpha: 0.7), fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(flex: 3),
              SizedBox(
                height: 58,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cream,
                    side: BorderSide(color: cream.withValues(alpha: 0.55), width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : () => _act('snooze'),
                  icon: const Icon(LucideIcons.alarmClockPlus, size: 20),
                  label: Text(l.slSnoozeFor(snooze)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 76,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: cream,
                    foregroundColor: ink,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  onPressed: _busy ? null : () => _act('dismiss'),
                  icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: ink)) : const Icon(LucideIcons.alarmClockOff, size: 26),
                  label: Text(l.slDismiss),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return PopScope(
      canPop: !widget.standalone,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(backgroundColor: const Color(0xFF120B24), body: body),
      ),
    );
  }
}
