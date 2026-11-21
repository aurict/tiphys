// Sleep mode on the phone (PLAN.md §21 U3/U4): the alarm notification (Android: full screen, alarm category, insistent
// alarm sound, Ertele / Kapat buttons that work on the lock screen), the phone's own backup alarm (a local exact alarm
// at the alarm + 3 min, cancelled when the alarm is dismissed: it rings even if the machines rebooted at night), the
// optional nightly reminder, and the morning summary notification. iOS and desktop: in-app only.
//
// The only thing stored is a small run record in the secure key-value store: the hosts of the running group and the
// alarm time, so the notification buttons (a background isolate) know whom to tell and the backup can be moved.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/gen/app_localizations.dart';
import '../agent/agent_client.dart';
import '../profile/model.dart';
import '../secrets/secret_store.dart';
import '../security/app_lock.dart';

const sleepRunKey = 'app:sleepRun';

/// Notification ids: the ringing alarm, the backup alarm, the nightly reminder, the morning summary.
const sleepAlarmId = 9103;
const sleepBackupId = 9104;
const sleepReminderId = 9105;
const sleepMorningId = 9106;

/// Buttons of the alarm notification.
const actionSleepSnooze = 'sleep-snooze';
const actionSleepDismiss = 'sleep-dismiss';

/// The backup rings this long after the alarm (PLAN.md §21 A4).
const sleepBackupDelay = Duration(minutes: 3);

/// Android's FLAG_INSISTENT: the sound repeats until the notification is answered.
const _flagInsistent = 4;

/// The running group as the phone last saw it.
@immutable
class SleepRun {
  const SleepRun({required this.hosts, this.ringAt, this.snoozeMin = 9});

  /// The app's host ids of the machines that sleep.
  final List<String> hosts;

  /// The next ring (null: no alarm).
  final DateTime? ringAt;
  final int snoozeMin;

  Map<String, Object?> toJson() => {'hosts': hosts, 'ringAt': ringAt?.millisecondsSinceEpoch, 'snoozeMin': snoozeMin};
  static SleepRun? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      final at = (j['ringAt'] as num?)?.toInt();
      return SleepRun(
        hosts: [for (final h in (j['hosts'] as List? ?? const [])) '$h'],
        ringAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
        snoozeMin: (j['snoozeMin'] as num?)?.toInt() ?? 9,
      );
    } catch (_) {
      return null;
    }
  }

  SleepRun withRing(DateTime? at) => SleepRun(hosts: hosts, ringAt: at, snoozeMin: snoozeMin);
}

class SleepRunStore {
  SleepRunStore(this.vault);
  final KeyValueVault vault;
  Future<SleepRun?> read() async => SleepRun.fromJson(await vault.read(sleepRunKey));
  Future<void> write(SleepRun r) => vault.write(sleepRunKey, jsonEncode(r.toJson()));
  Future<void> delete() => vault.delete(sleepRunKey);
}

/// Payload of the alarm notifications: opens the alarm screen (with the ring time).
String sleepAlarmPayload(DateTime? at) => jsonEncode({'link': 'tiphys://sleep/alarm', if (at != null) 'at': at.millisecondsSinceEpoch});

/// The alarm route from a notification link (`tiphys://sleep/alarm` + `at`).
String sleepAlarmRoute(Object? at) => at is num ? '/screen/sleep/alarm?at=${at.toInt()}' : '/screen/sleep/alarm';

bool isSleepAlarmRoute(String route) => route.startsWith('/screen/sleep/alarm');

/// Full screen on the lock screen, alarm category and sound (insistent), never auto-cancelled; Ertele / Kapat.
AndroidNotificationDetails sleepAlarmDetails(AppLocalizations l, {int snoozeMin = 9}) => AndroidNotificationDetails(
  'tiphys-alarm',
  'Tiphys · alarm',
  channelDescription: l.slAlarmChannel,
  importance: Importance.max,
  priority: Priority.max,
  category: AndroidNotificationCategory.alarm,
  fullScreenIntent: true,
  audioAttributesUsage: AudioAttributesUsage.alarm,
  sound: const UriAndroidNotificationSound('content://settings/system/alarm_alert'),
  additionalFlags: Int32List.fromList([_flagInsistent]),
  ongoing: true,
  autoCancel: false,
  visibility: NotificationVisibility.public,
  color: const Color(0xFFF2A65A),
  actions: [
    AndroidNotificationAction(actionSleepSnooze, l.slSnoozeFor(snoozeMin), cancelNotification: true),
    AndroidNotificationAction(actionSleepDismiss, l.slDismiss, cancelNotification: true),
  ],
);

/// "Alarm · 07:30" / "2 makine aydınlanıyor"; the backup says the machines didn't answer.
(String, String) sleepAlarmText(AppLocalizations l, DateTime at, {bool backup = false}) =>
    (l.slAlarmTitle(DateFormat.Hm().format(at)), backup ? l.slBackupBody : l.slAlarmBody);

/// The alarm is ringing on the machines (push `sleep.alarm`): Android full screen; elsewhere a plain notification.
Future<void> showSleepAlarm(FlutterLocalNotificationsPlugin n, AppLocalizations l, DateTime at, {int snoozeMin = 9}) async {
  final (title, body) = sleepAlarmText(l, at);
  await n.show(
    id: sleepAlarmId,
    title: title,
    body: body,
    payload: sleepAlarmPayload(at),
    notificationDetails: NotificationDetails(
      android: sleepAlarmDetails(l, snoozeMin: snoozeMin),
      iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
      linux: const LinuxNotificationDetails(urgency: LinuxNotificationUrgency.critical),
    ),
  );
}

/// The phone's backup alarm at [at] (Android only; an exact alarm when allowed, else the closest Android allows).
/// Returns whether it is exact.
Future<bool> scheduleSleepBackup(FlutterLocalNotificationsPlugin n, AppLocalizations l, DateTime at, {int snoozeMin = 9}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  final android = n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  final exact = await android?.canScheduleExactNotifications() ?? false;
  final (title, body) = sleepAlarmText(l, at.subtract(sleepBackupDelay), backup: true);
  await n.zonedSchedule(
    id: sleepBackupId,
    title: title,
    body: body,
    payload: sleepAlarmPayload(at.subtract(sleepBackupDelay)),
    scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
    notificationDetails: NotificationDetails(android: sleepAlarmDetails(l, snoozeMin: snoozeMin)),
    androidScheduleMode: exact ? AndroidScheduleMode.alarmClock : AndroidScheduleMode.inexactAllowWhileIdle,
  );
  return exact;
}

/// The nightly "Uyku modunu başlatayım mı?" at [hm] every day (null: off). Not exact: a reminder may be a little late.
/// Repeats at the same UTC time (one hour off across a daylight saving change until the app next opens).
Future<void> scheduleSleepReminder(FlutterLocalNotificationsPlugin n, AppLocalizations l, String? hm, {DateTime? now}) async {
  await n.cancel(id: sleepReminderId);
  if (hm == null || defaultTargetPlatform != TargetPlatform.android) return;
  final t = now ?? DateTime.now();
  final p = hm.split(':');
  var at = DateTime(t.year, t.month, t.day, int.parse(p[0]), int.parse(p[1]));
  if (!at.isAfter(t)) at = at.add(const Duration(days: 1));
  await n.zonedSchedule(
    id: sleepReminderId,
    title: l.slReminderTitle,
    body: l.slReminderBody,
    payload: 'tiphys://sleep',
    scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
    notificationDetails: NotificationDetails(android: AndroidNotificationDetails('tiphys', 'Tiphys', channelDescription: l.slReminderChannel)),
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

/// The morning summary notification; tapping it opens the summary card ([payload] carries it).
Future<void> showSleepMorning(FlutterLocalNotificationsPlugin n, String title, String body, String payload) => n.show(
  id: sleepMorningId,
  title: title,
  body: body,
  payload: payload,
  notificationDetails: NotificationDetails(
    android: AndroidNotificationDetails('tiphys', 'Tiphys', styleInformation: body.length > 60 ? BigTextStyleInformation(body) : null, color: const Color(0xFFF2A65A)),
  ),
);

/// Ertele / Kapat sent to every machine of the run (all agent hosts when the phone has no record: e.g. the mode was
/// started on a machine). True when at least one machine took it.
Future<bool> sleepAlarmToAgents(String action, {required Profile profile, required SecretStore secrets, SleepRun? run, AgentClient Function(String url, String token)? clientFor}) async {
  final hosts = run != null && run.hosts.isNotEmpty ? [for (final id in run.hosts) ?profile.host(id)] : profile.hosts.where((h) => h.agent != null).toList();
  var ok = false;
  await Future.wait([
    for (final h in hosts.where((h) => h.agent != null))
      () async {
        final token = await secrets.read(secretIdOf(h.agent!.tokenRef));
        if (token == null) return;
        final c = (clientFor ?? (u, t) => AgentClient(baseUrl: u, token: t))(h.agent!.url, token);
        try {
          await c.post('/v1/sleep/alarm', {'action': action == actionSleepSnooze ? 'snooze' : 'dismiss'});
          ok = true;
        } catch (_) {
          // Not sleeping there, unreachable, or an agent without the alarm: the others still get it.
        } finally {
          c.close();
        }
      }(),
  ]);
  return ok;
}

/// Ertele / Kapat from the notification (also while the app is closed): the phone's own alarm follows at once (dismiss:
/// the backup goes; snooze: it moves to the snooze end + 3 min), then the machines are told.
Future<void> handleSleepAlarmAction(
  String action,
  FlutterLocalNotificationsPlugin n, {
  required Profile profile,
  required SecretStore secrets,
  required KeyValueVault vault,
  required AppLocalizations l,
  DateTime? now,
  AgentClient Function(String url, String token)? clientFor,
}) async {
  final store = SleepRunStore(vault);
  final run = await store.read();
  await n.cancel(id: sleepAlarmId);
  if (action == actionSleepDismiss) {
    await n.cancel(id: sleepBackupId);
    if (run != null) await store.write(run.withRing(null));
  } else {
    final until = (now ?? DateTime.now()).add(Duration(minutes: run?.snoozeMin ?? 9));
    await scheduleSleepBackup(n, l, until.add(sleepBackupDelay), snoozeMin: run?.snoozeMin ?? 9);
    if (run != null) await store.write(run.withRing(until));
  }
  await sleepAlarmToAgents(action, profile: profile, secrets: secrets, run: run, clientFor: clientFor);
}
