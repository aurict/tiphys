// Texts of the sleep mode that depend on agent codes and keys (PLAN.md §21 contract): errors, phases, the room
// layout, the sound layers, the critical notification kinds, alarm days and the events.
import '../../../l10n/gen/app_localizations.dart';
import '../../system/agent_providers.dart';
import 'sleep_data.dart';

String sleepErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
  'agent.sleep.noGroup' => switch (params['reason']) {
    'notMember' => l.slErrNotMember,
    'noLeaderSource' => l.slErrNoLeaderSource('${params['leader'] ?? ''}'),
    _ => l.slErrNoGroup,
  },
  'agent.sleep.memberDown' => params['host'] is String ? l.slErrMemberDownHost('${params['host']}') : l.slErrMemberDown,
  'agent.sleep.ddcUnavailable' => params['reason'] == 'missing' ? l.slErrDdcMissing : l.slErrDdcUnavailable,
  'agent.sleep.badAlarm' => l.slErrBadAlarm,
  'agent.sleep.running' => l.slErrRunning,
  'agent.sleep.notRunning' => l.slErrNotRunning,
  'agent.sleep.notRinging' => l.slErrNotRinging,
  _ => '${l.commonError} ($code)',
};

/// A failed group action: each host and its error.
String sleepPartialText(AppLocalizations l, SleepGroup? g, SleepPartialError e) =>
    [for (final x in e.failed.entries) '${g?.byHost(x.key)?.host.name ?? x.key}: ${agentErrorText(l, x.value)}'].join('\n');

/// Any error of a sleep action.
String sleepActionError(AppLocalizations l, SleepGroup? g, Object e) => e is SleepPartialError ? sleepPartialText(l, g, e) : agentErrorText(l, e);

String sleepPhaseName(AppLocalizations l, String? phase) => switch (phase) {
  'settle' => l.slPhaseSettle,
  'fade' => l.slPhaseFade,
  'night' => l.slPhaseNight,
  'sunrise' => l.slPhaseSunrise,
  'ring' => l.slPhaseRing,
  'snoozed' => l.slPhaseSnoozed,
  'morning' => l.slPhaseMorning,
  _ => l.gmOff,
};

String sleepSideName(AppLocalizations l, String side) => switch (side) {
  'right' => l.slSideRight,
  'foot' => l.slSideFoot,
  'head' => l.slSideHead,
  _ => l.slSideLeft,
};

String sleepDistanceName(AppLocalizations l, String d) => switch (d) {
  'near' => l.slDistanceNear,
  'far' => l.slDistanceFar,
  _ => l.slDistanceMid,
};

String sleepLayerName(AppLocalizations l, String k) => switch (k) {
  'hum' => l.slLayerHum,
  'crackle' => l.slLayerCrackle,
  'logs' => l.slLayerLogs,
  'wind' => l.slLayerWind,
  _ => l.slLayerRain,
};

String sleepCriticalName(AppLocalizations l, String k) => switch (k) {
  'hostDown' => l.slCriticalHostDown,
  'securityTrap' => l.slCriticalSecurity,
  'incident' => l.slCriticalIncident,
  _ => l.slCriticalDisk,
};

String sleepSoundName(AppLocalizations l, String s) => switch (s) {
  'chime' => l.slSoundChime,
  'velour' => l.slSoundVelour,
  _ => l.slSoundBirds,
};

/// The short weekday names, Sunday first (the agent's 0..6).
List<String> sleepDayNames(AppLocalizations l) => [l.slDaySun, l.slDayMon, l.slDayTue, l.slDayWed, l.slDayThu, l.slDayFri, l.slDaySat];

/// "07:30 · Hafta içi"
String sleepDaysText(AppLocalizations l, Object days) => switch (days) {
  'weekdays' => l.slDaysWeekdays,
  'daily' => l.slDaysDaily,
  List<int> d when d.isNotEmpty => [for (final i in [1, 2, 3, 4, 5, 6, 0]) if (d.contains(i)) sleepDayNames(l)[i]].join(' '),
  _ => l.slDaysOnce,
};

/// The card's and hero's line: "alarm 07:30 · 2 makine" (no alarm: "alarm yok").
String sleepAlarmLine(AppLocalizations l, SleepGroup g) {
  final s = g.settings;
  final n = g.running ? g.runningMachines.length : g.members.length;
  return [s.hasAlarm && s.alarmEnabled ? l.slAlarmAt(s.alarmTime) : l.slNoAlarm, l.slMachines(n)].join(' · ');
}

/// `sleep.*` events and pushes for the event list (no content: the agent logs only that it happened).
(String, String)? sleepEventText(AppLocalizations l, String key, Map<String, dynamic> p) => switch (key) {
  'sleep.started' => (l.slEventStarted, '${p['device'] ?? ''}'),
  'sleep.stopped' => (l.slEventStopped, '${p['device'] ?? ''}'),
  'sleep.alarm' => (switch ('${p['state'] ?? 'ringing'}') {
    'snoozed' => l.slEventAlarmSnoozed,
    'dismissed' => l.slEventAlarmDismissed,
    'autoStopped' => l.slEventAlarmAutoStopped,
    _ => l.slEventAlarmRang,
  }, ''),
  _ => null,
};
