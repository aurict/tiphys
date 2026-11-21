// Sleep mode side effects on the phone while the app is open (PLAN.md §21 U3): every group state the app reads keeps
// the run record and the phone's backup alarm (alarm + 3 min) in step, and the nightly reminder follows the group's
// `reminder` setting. The notification buttons do the same while the app is closed (core/push/sleep_notices.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/push/push_service.dart';
import '../../../core/push/sleep_notices.dart';
import '../../../state/providers.dart';
import '../../settings/push_section.dart' show pushServiceProvider;
import 'sleep_data.dart';

/// What the phone can do for the alarm (Android: exact alarms and full-screen notifications need the user's consent).
class SleepPhoneAlarm {
  const SleepPhoneAlarm({this.supported = false, this.exact = false});

  /// Android: a backup alarm and a full-screen alarm exist at all.
  final bool supported;

  /// Exact alarms are allowed (else the backup may ring late).
  final bool exact;
}

/// The notification surface (faked in tests).
abstract class SleepAlarms {
  /// Schedules the backup alarm at [at] (null: cancels it).
  Future<void> backup(DateTime? at, {int snoozeMin = 9});

  /// Removes the ringing alarm notification.
  Future<void> clearRinging();

  /// The nightly reminder at HH:MM (null: off).
  Future<void> reminder(String? hm);

  Future<SleepPhoneAlarm> phone();
  Future<void> requestExact();
  Future<void> requestFullScreen();
}

class _PushSleepAlarms implements SleepAlarms {
  _PushSleepAlarms(this.push);
  final PushService? push;
  @override
  Future<void> backup(DateTime? at, {int snoozeMin = 9}) async => push?.sleepBackup(at, snoozeMin: snoozeMin);
  @override
  Future<void> clearRinging() async => push?.notifications.cancel(id: sleepAlarmId);
  @override
  Future<void> reminder(String? hm) async => push?.sleepReminder(hm);
  @override
  Future<SleepPhoneAlarm> phone() async => push?.sleepPhoneAlarm() ?? const SleepPhoneAlarm();
  @override
  Future<void> requestExact() async => push?.requestExactAlarms();
  @override
  Future<void> requestFullScreen() async => push?.requestFullScreenIntent();
}

final sleepAlarmsProvider = Provider<SleepAlarms>((ref) => _PushSleepAlarms(ref.watch(pushServiceProvider)));

/// The run record (the push service's secure store); null where there are no notifications.
final sleepRunStoreProvider = Provider<SleepRunStore?>((ref) {
  final p = ref.watch(pushServiceProvider);
  return p == null ? null : SleepRunStore(p.vault);
});

final sleepSyncProvider = Provider<SleepSync>(SleepSync.new);

/// The ring the phone backs up (epoch times of the running group, the leader's first): the snooze end, the agent's
/// next ring (`alarm.next`), the plan's ring; an agent before S4 (none of them): the first time of the group's alarm
/// after the session started on the phone's clock (one that already passed in this session was answered: none). After
/// the alarm (morning): none.
DateTime? sleepRingAt(SleepGroup g, DateTime now) {
  final s = g.phaseSource;
  if (s == null || s.phase == 'morning') return null;
  final snoozed = s.local(s.snoozedUntil);
  if (snoozed != null) return snoozed;
  final next = s.local(s.alarmNext);
  if (next != null) return next;
  if (s.plan case final plan?) {
    final ring = plan['dismissedAt'] == null ? s.local(s.planRingAt) : null;
    return ring == null || ring.isBefore(now) ? null : ring;
  }
  final t0 = (s.session?['t0'] as num?)?.toInt();
  final ring = nextAlarm(g.settings, t0 == null ? now : DateTime.fromMillisecondsSinceEpoch(t0 - s.skewMs));
  return ring == null || ring.isBefore(now) ? null : ring;
}

class SleepSync {
  SleepSync(this.ref);
  final Ref ref;
  String? _key;
  String? _reminderKey;

  /// One change at a time, in the order the states arrived (two answers of one action mustn't overtake each other).
  Future<void> _chain = Future.value();
  Future<void> _queue(Future<void> Function() f) {
    final next = _chain.then((_) => f());
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> sync(SleepGroup g, {DateTime? now}) => _queue(() => _sync(g, now: now));

  Future<void> _sync(SleepGroup g, {DateTime? now}) async {
    final t = now ?? ref.read(clockProvider)();
    final alarms = ref.read(sleepAlarmsProvider);
    final s = g.settings;
    final rKey = s.hasReminder && g.configured ? (s.reminderEnabled ? s.reminderTime : 'off') : null;
    if (rKey != null && rKey != _reminderKey) {
      _reminderKey = rKey;
      await alarms.reminder(rKey == 'off' ? null : rKey);
    }

    final store = ref.read(sleepRunStoreProvider);
    if (!g.running) {
      if (_key == 'off') return;
      // First look after the app started: a record left from a night the phone didn't see end.
      final had = _key != null || (await store?.read()) != null;
      _key = 'off';
      if (had) await _ended();
      return;
    }
    // Ringing: the backup set for this ring stays until the alarm is answered (dismissed / snoozed).
    if (g.ringing) return;
    final l = g.leader;
    final hosts = [if (l != null && l.running) l.host.id, for (final m in g.runningMachines) if (m != l) m.host.id];
    final ring = sleepRingAt(g, t);
    final key = '${hosts.join(',')}|${ring?.millisecondsSinceEpoch}|${s.snoozeMin}';
    if (key == _key) return;
    _key = key;
    await store?.write(SleepRun(hosts: hosts, ringAt: ring, snoozeMin: s.snoozeMin));
    final backup = ring?.add(sleepBackupDelay);
    // A backup already due has rung (or rings now): it isn't moved or cancelled from here.
    if (backup == null) {
      await alarms.backup(null);
    } else if (backup.isAfter(t)) {
      await alarms.backup(backup, snoozeMin: s.snoozeMin);
    }
  }

  /// The mode stopped: the record, the backup and a ringing notification go.
  Future<void> ended() => _queue(_ended);

  Future<void> _ended() async {
    _key = 'off';
    final alarms = ref.read(sleepAlarmsProvider);
    await ref.read(sleepRunStoreProvider)?.delete();
    await alarms.backup(null);
    await alarms.clearRinging();
  }

  /// The alarm was dismissed from the app.
  Future<void> dismissed() => _queue(() async {
    final alarms = ref.read(sleepAlarmsProvider);
    await alarms.backup(null);
    await alarms.clearRinging();
    final store = ref.read(sleepRunStoreProvider);
    final run = await store?.read();
    if (run != null) await store!.write(run.withRing(null));
    _key = null;
  });

  /// Snoozed from the app: the backup moves to the snooze end + 3 min.
  Future<void> snoozed(int minutes, {DateTime? now}) => _queue(() async {
    final alarms = ref.read(sleepAlarmsProvider);
    final until = (now ?? ref.read(clockProvider)()).add(Duration(minutes: minutes));
    await alarms.clearRinging();
    await alarms.backup(until.add(sleepBackupDelay), snoozeMin: minutes);
    final store = ref.read(sleepRunStoreProvider);
    final run = await store?.read();
    if (run != null) await store!.write(run.withRing(until));
    _key = null;
  });
}
