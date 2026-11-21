// Focus mode side effects on the phone while the app is open (PLAN.md §20 U4/U5): every screen status the app reads
// drives the ongoing Focus notification (Android) and the quiet record of core/push/focus_notices.dart. While the app
// is closed the `screen.focus.phase` push does the same (push_service.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push/focus_notices.dart';
import '../../core/push/push_service.dart';
import '../settings/push_section.dart' show pushServiceProvider;
import 'screen_data.dart';

/// The notification surface (faked in tests).
abstract class FocusNotifications {
  /// Shows/updates (or with null removes) the ongoing Focus notification.
  Future<void> ongoing(FocusOngoing? o);

  /// One summary of the notifications that waited during Focus.
  Future<void> summary(int held);
}

class _PushFocusNotifications implements FocusNotifications {
  _PushFocusNotifications(this.push);
  final PushService? push;
  @override
  Future<void> ongoing(FocusOngoing? o) async => push?.syncFocusOngoing(o);
  @override
  Future<void> summary(int held) async => push?.showFocusSummaryNow(held);
}

final focusNotificationsProvider = Provider<FocusNotifications>((ref) => _PushFocusNotifications(ref.watch(pushServiceProvider)));

/// The quiet record (the push service's secure store); null where there are no notifications.
final focusQuietProvider = Provider<FocusQuiet?>((ref) {
  final p = ref.watch(pushServiceProvider);
  return p == null ? null : FocusQuiet(p.vault);
});

final focusSyncProvider = Provider<FocusSync>(FocusSync.new);

class FocusSync {
  FocusSync(this.ref);
  final Ref ref;

  /// What was last applied, so a poll that changes nothing writes nothing.
  String? _ongoingKey;
  String? _ongoingHost;
  final _quietKey = <String, String>{};

  Future<void> sync(String hostId, String hostName, ScreenStatus s, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final active = !s.legacy && s.running && s.mode == 'focus';
    final f = s.focus;

    // Ongoing notification: one Focus timer at a time (the last host that showed one).
    final show = active && !f.idle;
    final key = show ? '$hostId|${f.phase}|${f.round}|${f.endsAt}|${f.pausedLeft}' : null;
    if (show || _ongoingHost == hostId) {
      if (key != _ongoingKey) {
        _ongoingKey = key;
        _ongoingHost = show ? hostId : null;
        await ref
            .read(focusNotificationsProvider)
            .ongoing(
              show
                  ? FocusOngoing(hostId: hostId, hostName: hostName, phase: f.phase, round: f.round, longEvery: f.longEvery, endsAt: f.paused ? null : f.endsAtLocal, left: f.paused ? f.remaining(t) : null)
                  : null,
            );
      }
    }

    // Quiet notifications: only while a round runs (paused counts) and the mode's `quietPhone` is on.
    final quiet = ref.read(focusQuietProvider);
    if (quiet == null) return;
    final round = active && f.phase == 'focus' && s.settings.mode('focus').quietPhone;
    final qKey = '$round|$active|${f.endsAt}|${f.paused}';
    if (_quietKey[hostId] == qKey) return;
    _quietKey[hostId] = qKey;
    if (round) {
      final until = f.paused ? t.add(quietPausedFor) : (f.endsAtLocal ?? t).add(quietGrace);
      await quiet.enter(hostId, until, t);
      return;
    }
    final rec = await quiet.read();
    if (rec == null || rec.host != hostId) return;
    // Between rounds, or stopped with a session summary on its way (W7: that one push carries the held count).
    if (active || (!s.running && s.summarySent)) {
      await quiet.rest(hostId, t);
    } else {
      final held = await quiet.end();
      if (held > 0) await ref.read(focusNotificationsProvider).summary(held);
    }
  }
}
