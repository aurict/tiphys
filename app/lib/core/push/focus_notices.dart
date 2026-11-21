// Focus mode on the phone (PLAN.md §20 U4/U5): the ongoing "Focus" notification with the time left and a Pause button
// (Android), and the quiet filter: while a Focus round runs on a display host whose `quietPhone` is on, only critical
// Tiphys notifications are shown; the rest are counted and, when the mode stops, one summary notification says how many
// waited (their content stays in the agents' event logs, nothing of it is kept here).
//
// The phone learns the state from the agent's answers while the app is open (screen/screen_focus.dart) and from the
// `screen.focus.phase` push while it isn't (its `data`: `quiet`, `endsAt`, `agent`; `cause: "stop"` when the mode ends).
// The only thing stored is one small record in the secure key-value store: the display host, the round's end and the
// count of held notifications.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';

import '../../features/security/security_more_texts.dart' show securityUrgentKeys;
import '../../l10n/gen/app_localizations.dart';
import '../agent/agent_client.dart';
import '../security/app_lock.dart';

const focusQuietKey = 'app:focusQuiet';

/// Id of the ongoing Focus notification (one Focus timer is followed at a time) and of the summary.
const focusOngoingId = 9101;
const focusSummaryId = 9102;

/// Buttons of the ongoing notification.
const actionFocusPause = 'screen-focus-pause';
const actionFocusResume = 'screen-focus-resume';

/// Shown even while a Focus round runs: a server down, Claude (or agy) waiting for the user, a job that failed, and the
/// security alarms.
const focusCriticalKeys = {
  // A server or a service down.
  'host.offline', 'uptime.down', 'service.failed', 'disk.full', 'docker.died', 'docker.oom', 'docker.unhealthy', 'docker.restartLoop', //
  // Waiting for the user.
  'claude.waiting', 'agy.waiting', 'claude.sudo', 'claude.pcExpiring', 'claude.pcEnded', //
  // A job that failed.
  'command.failed', 'claude.error', 'agy.error', 'claude.scheduleFailed', 'backup.failed', 'compose.failed', 'db.restoreTest.failed', 'incident.actionFailed',
};

bool focusCritical(String key, Map<String, dynamic> params) =>
    focusCriticalKeys.contains(key) || securityUrgentKeys.contains(key) || (key == 'security.change' && params['severity'] == 'critical');

/// The stored state: which display host, until when a round runs (null: between rounds, the mode still on), how many
/// notifications were held, and when it was last updated.
@immutable
class QuietRecord {
  const QuietRecord({required this.host, this.until, this.held = 0, required this.at});
  final String host;
  final DateTime? until;
  final int held;
  final DateTime at;

  Map<String, Object?> toJson() => {'host': host, 'until': until?.millisecondsSinceEpoch, 'held': held, 'at': at.millisecondsSinceEpoch};
  static QuietRecord? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      final until = j['until'] as num?;
      return QuietRecord(
        host: '${j['host']}',
        until: until == null ? null : DateTime.fromMillisecondsSinceEpoch(until.round()),
        held: (j['held'] as num?)?.round() ?? 0,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).round()),
      );
    } catch (_) {
      return null;
    }
  }

  /// A round runs now.
  bool activeAt(DateTime now) => until != null && now.isBefore(until!);
}

/// The filter itself: true = this notification waits (it isn't shown, it is counted).
bool quietHolds(QuietRecord? r, String key, Map<String, dynamic> params, DateTime now) => r != null && r.activeAt(now) && !focusCritical(key, params);

/// A record nobody ended (the mode stopped while the phone heard nothing) is ended after this long without an update.
const quietStaleAfter = Duration(hours: 6);

/// A paused round keeps the quiet this long (the phone hears of a resume only while the app is open).
const quietPausedFor = Duration(hours: 2);

/// Grace after a round's planned end (the next phase's push may come a little late).
const quietGrace = Duration(minutes: 2);

class FocusQuiet {
  FocusQuiet(this.vault);
  final KeyValueVault vault;

  Future<QuietRecord?> read() async => QuietRecord.fromJson(await vault.read(focusQuietKey));

  Future<void> _write(QuietRecord r) => vault.write(focusQuietKey, jsonEncode(r.toJson()));

  /// A round runs on [host] until [until] (the held count carries on).
  Future<void> enter(String host, DateTime until, DateTime now) async {
    final r = await read();
    await _write(QuietRecord(host: host, until: until, held: r?.host == host ? r!.held : (r?.held ?? 0), at: now));
  }

  /// Between rounds (a break, a reset) on [host]: notifications show again, the held ones still wait for the summary.
  Future<void> rest(String host, DateTime now) async {
    final r = await read();
    if (r == null || r.host != host) return;
    await _write(QuietRecord(host: host, held: r.held, at: now));
  }

  /// The mode stopped: the record goes; returns how many notifications waited.
  Future<int> end() async {
    final r = await read();
    if (r == null) return 0;
    await vault.delete(focusQuietKey);
    return r.held;
  }

  /// Decides one notification; a held one is counted.
  Future<bool> hold(String key, Map<String, dynamic> params, DateTime now) async {
    final r = await read();
    if (!quietHolds(r, key, params, now)) return false;
    await _write(QuietRecord(host: r!.host, until: r.until, held: r.held + 1, at: r.at));
    return true;
  }

  /// Ends a forgotten record (see [quietStaleAfter]); returns the held count to summarize, 0 otherwise.
  Future<int> endIfStale(DateTime now) async {
    final r = await read();
    if (r == null) return 0;
    final last = r.until != null && r.until!.isAfter(r.at) ? r.until! : r.at;
    return now.difference(last) > quietStaleAfter ? end() : 0;
  }
}

/// What the ongoing notification shows.
@immutable
class FocusOngoing {
  const FocusOngoing({required this.hostId, required this.hostName, required this.phase, required this.round, required this.longEvery, this.endsAt, this.left});
  final String hostId;
  final String hostName;

  /// focus | short | long
  final String phase;
  final int round;
  final int longEvery;

  /// Ticking: the phase's end on the phone's clock. Paused: [left].
  final DateTime? endsAt;
  final Duration? left;
  bool get paused => endsAt == null;
}

String focusPhaseName(AppLocalizations l, String phase) => switch (phase) {
  'focus' => l.smPhaseFocus,
  'short' => l.smPhaseShort,
  'long' => l.smPhaseLong,
  _ => l.smPhaseIdle,
};

/// "14:32" / "1:02:05" (a countdown: started seconds count, so 14:31.4 left shows 14:32).
String clockText(Duration d) {
  final s = (d.inMilliseconds / 1000).ceil();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// Not dismissible, silent, counting down to the phase's end (also while the app is closed); Pause (or Resume).
AndroidNotificationDetails focusOngoingDetails(AppLocalizations l, FocusOngoing o) => AndroidNotificationDetails(
  'tiphys-focus',
  'Tiphys · Odak',
  importance: Importance.low,
  priority: Priority.low,
  ongoing: true,
  autoCancel: false,
  onlyAlertOnce: true,
  silent: true,
  showWhen: !o.paused,
  when: o.endsAt?.millisecondsSinceEpoch,
  usesChronometer: !o.paused,
  chronometerCountDown: !o.paused,
  category: AndroidNotificationCategory.progress,
  color: const Color(0xFF4338CA),
  actions: [
    o.paused
        ? AndroidNotificationAction(actionFocusResume, l.smFocusResume, cancelNotification: false)
        : AndroidNotificationAction(actionFocusPause, l.smFocusPause, cancelNotification: false),
  ],
);

(String, String) focusOngoingText(AppLocalizations l, FocusOngoing o) => (
  o.phase == 'focus' ? l.smOngoingRound(focusPhaseName(l, o.phase), o.round, o.longEvery) : focusPhaseName(l, o.phase),
  o.paused ? l.smOngoingPaused(clockText(o.left ?? Duration.zero), o.hostName) : l.smOngoingEnds(DateFormat.Hm().format(o.endsAt!), o.hostName),
);

/// Shows/updates the ongoing notification (Android only; elsewhere the app shows the timer in-app). Tapping it opens the
/// screen mode screen of that host.
Future<void> showFocusOngoing(FlutterLocalNotificationsPlugin n, AppLocalizations l, FocusOngoing o) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final (title, body) = focusOngoingText(l, o);
  await n.show(
    id: focusOngoingId,
    title: title,
    body: body,
    payload: jsonEncode({'link': 'tiphys://screen', 'host': o.hostId}),
    notificationDetails: NotificationDetails(android: focusOngoingDetails(l, o)),
  );
}

/// The summary when the mode stopped: how many notifications waited; they are in the event list.
Future<void> showFocusSummary(FlutterLocalNotificationsPlugin n, AppLocalizations l, int held) => n.show(
  id: focusSummaryId,
  title: l.smQuietSummaryTitle(held),
  body: l.smQuietSummaryBody,
  payload: 'tiphys://system/events',
  notificationDetails: const NotificationDetails(android: AndroidNotificationDetails('tiphys', 'Tiphys')),
);

/// Pause / Resume from the notification, with the display host's device token. Returns the new `focus` (null on failure).
Future<Map?> focusActionFromNotification(AgentClient c, String action) async {
  try {
    final j = await c.post('/v1/screen/focus', {'action': action == actionFocusPause ? 'pause' : 'resume'}) as Map;
    return j['focus'] as Map?;
  } catch (_) {
    return null;
  } finally {
    c.close();
  }
}

/// The ongoing notification after a Pause/Resume answer, or from a phase push: null = nothing to show (idle).
FocusOngoing? focusOngoingFrom(Map? focus, {required String hostId, required String hostName, DateTime? now}) {
  if (focus == null) return null;
  final phase = '${focus['phase'] ?? 'idle'}';
  if (phase == 'idle') return null;
  final endsAt = (focus['endsAt'] as num?)?.round();
  final agentNow = (focus['now'] as num?)?.round();
  final left = (focus['pausedLeft'] as num?)?.round();
  final phoneNow = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return FocusOngoing(
    hostId: hostId,
    hostName: hostName,
    phase: phase,
    round: (focus['round'] as num?)?.round() ?? 0,
    longEvery: (focus['longEvery'] as num?)?.round() ?? 4,
    endsAt: endsAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endsAt - (agentNow == null ? 0 : agentNow - phoneNow)),
    left: left == null ? null : Duration(milliseconds: left),
  );
}
