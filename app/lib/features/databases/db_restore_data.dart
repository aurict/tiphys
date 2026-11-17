// Backup restore tests (PLAN.md §13.2, D-4): models of /v1/db/restore-tests, the list provider (which polls while a test
// is running), the results of one test and the pure validation/mapping used by the form. The agent restores the newest
// dump into a throwaway container; the app only starts runs and shows results.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/refresh.dart' show whenVisibleAfter;
import '../system/agent_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) Map<String, dynamic>.from(e),
      ]
    : const [];
int? _int(Object? v) => v is num ? v.toInt() : null;

/// While a test runs, the list is read again this often.
const restorePollInterval = Duration(seconds: 3);

/// The agent's image rule: an official postgres/mysql/mariadb image with an explicit tag (no `latest`, digest or
/// registry prefix).
final restoreImagePattern = RegExp(r'^(postgres|mysql|mariadb):(?!latest$)[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$');

const restoreOps = ['>', '>=', '=', '<=', '<'];
const restoreFormats = ['sql', 'gz', 'custom'];
const maxSanity = 20;

/// Does [image] satisfy the agent's rule for [engine]?
bool validRestoreImage(String engine, String image) => restoreImagePattern.hasMatch(image) && image.startsWith('$engine:');

/// Formats the agent can restore per engine (`custom` = pg_restore, PostgreSQL only).
List<String> restoreFormatsFor(String engine) => engine == 'postgres' ? restoreFormats : const ['sql', 'gz'];

class SanityCheck {
  const SanityCheck(this.sql, this.op, this.value);
  SanityCheck.fromJson(Map<String, dynamic> j) : sql = '${j['sql']}', op = '${_map(j['expect'])['op'] ?? '>'}', value = (_map(j['expect'])['value'] as num?) ?? 0;
  final String sql;
  final String op;
  final num value;

  Map<String, dynamic> toJson() => {
    'sql': sql,
    'expect': {'op': op, 'value': value},
  };
}

class RestoreFailure {
  RestoreFailure(Map<String, dynamic> j) : index = _int(j['index']) ?? 0, reason = '${j['reason']}', actual = j['actual'], expected = j['expected'] as String?;
  final int index;

  /// queryFailed | notNumeric | expectation
  final String reason;
  final Object? actual;
  final String? expected;
}

class RestoreResult {
  RestoreResult(Map<String, dynamic> j)
    : id = '${j['id']}',
      trigger = '${j['trigger'] ?? 'manual'}',
      startedAt = _timeOrNull(j['startedAt']),
      finishedAt = _timeOrNull(j['finishedAt']),
      ok = j['ok'] == true,
      reason = j['reason'] as String?,
      detail = j['detail'] as String?,
      image = j['image'] as String?,
      dumpFile = j['dumpFile'] as String?,
      dumpBytes = _int(j['dumpBytes']),
      rowsChecked = _int(j['rowsChecked']) ?? 0,
      failures = [for (final f in _maps(j['failures'])) RestoreFailure(f)],
      totalMs = _int(_map(j['durations'])['totalMs']);
  final String id;

  /// manual | schedule
  final String trigger;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final bool ok;

  /// null when ok: noDump, dumpOutsideRoots, insufficientDisk, imageVersionMismatch, dockerFailed, notReady,
  /// restoreFailed, dumpCorrupt, sanityFailed, timeout, shutdown.
  final String? reason;

  /// restoreFailed: the first error line of the client.
  final String? detail;
  final String? image;
  final String? dumpFile;
  final int? dumpBytes;
  final int rowsChecked;
  final List<RestoreFailure> failures;
  final int? totalMs;
}

class RestoreTest {
  RestoreTest(Map<String, dynamic> j)
    : id = '${j['id']}',
      name = '${j['name']}',
      connectionId = j['connectionId'] as String?,
      engine = '${j['engine']}',
      image = '${j['image']}',
      dumpGlob = '${j['dumpGlob']}',
      format = '${j['format']}',
      sanity = [for (final s in _maps(j['sanity'])) SanityCheck.fromJson(s)],
      schedule = j['schedule'] is Map ? _map(j['schedule']) : null,
      enabled = j['enabled'] != false,
      running = j['running'] == true,
      last = j['last'] is Map ? RestoreResult(_map(j['last'])) : null,
      nextRunAt = _timeOrNull(j['nextRunAt']);
  final String id;
  final String name;
  final String? connectionId;
  final String engine;
  final String image;
  final String dumpGlob;

  /// sql | custom | gz
  final String format;
  final List<SanityCheck> sanity;

  /// The agent's `when` (daily / weekly / interval) or null (manual only).
  final Map<String, dynamic>? schedule;
  final bool enabled;
  final bool running;
  final RestoreResult? last;
  final DateTime? nextRunAt;
}

class RestoreTests {
  RestoreTests(Map<String, dynamic> j) : tests = [for (final t in _maps(j['tests'])) RestoreTest(t)], runningId = _map(j['running'])['testId'] as String?;
  final List<RestoreTest> tests;

  /// The test running now (one at a time, agent-wide).
  final String? runningId;

  bool get anyRunning => runningId != null || tests.any((t) => t.running);
}

/// The list; while a test is running it is read again every [restorePollInterval] (the agent only reports "running" and
/// the result when done, so that is the whole progress).
final dbRestoreProvider = FutureProvider.autoDispose.family<RestoreTests, String>(retry: _noRetry, (ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/restore-tests')).timeout(const Duration(seconds: 20));
  final data = RestoreTests(j);
  if (data.anyRunning) {
    // No polling while the app is in the background: one refresh when it comes back.
    ref.onDispose(whenVisibleAfter(restorePollInterval, ref.invalidateSelf));
  }
  return data;
});

/// Family key: (host id, test id).
typedef RestoreRef = (String, String);

final dbRestoreResultsProvider = FutureProvider.autoDispose.family<List<RestoreResult>, RestoreRef>(retry: _noRetry, (ref, key) async {
  final (hostId, testId) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/restore-tests/$testId/results')).timeout(const Duration(seconds: 20));
  return [for (final r in _maps(j['results'])) RestoreResult(r)];
});

/// The body of a create/PATCH call. On edit a cleared connection is sent as `connectionId: null`.
Map<String, dynamic> restoreTestBody({
  String? id,
  required String name,
  String? connectionId,
  required String engine,
  required String image,
  required String dumpGlob,
  required String format,
  required List<SanityCheck> sanity,
  required Map<String, dynamic>? schedule,
  required bool enabled,
  required bool editing,
}) => {
  'id': ?id,
  'name': name,
  if (connectionId != null || editing) 'connectionId': connectionId,
  'engine': engine,
  'image': image,
  'dumpGlob': dumpGlob,
  'format': format,
  'sanity': [for (final s in sanity) s.toJson()],
  'schedule': schedule,
  'enabled': enabled,
};

bool isRestoreBusy(Object e) => e is AgentError && e.code == 'agent.db.restoreBusy';
