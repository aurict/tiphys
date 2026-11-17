// Database console (PLAN.md §13.2, D-1..D-3): models of the agent's /v1/db responses, the providers that read them and
// the pure logic behind the screens: result paging, column kinds and chart mapping, the CSV export to a temp file and
// the write flow (preview → confirm → commit) as a small state machine. Passwords never appear here: the agent only
// reports `hasPassword`, and the forms keep what the user types in memory until it is sent.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../state/providers.dart';
import '../incidents/incidents_data.dart' show previewDeadline;
import '../lock/lock_gate.dart' show lockRequiredProvider;
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
List<String> _strings(Object? v) => v is List ? [for (final e in v) '$e'] : const [];

/// Rows shown per page of a result table.
const dbPageSize = 50;

/// Rows of a table preview.
const dbPreviewRows = 100;

/// The agent's CSV cap: a file with exactly this many rows may have been cut.
const dbCsvMaxRows = 100000;

/// Default and largest row limit / timeout of the agent.
const dbDefaultLimit = 500, dbMaxLimit = 5000;
const dbDefaultTimeoutSec = 15, dbMaxTimeoutSec = 60;

// ---------------------------------------------------------------------------------------------------------------------
// Connections

/// `{mode: password, user, hasPassword}` or `{mode: fromContainerEnv}`; there is never a password.
class DbCredential {
  DbCredential(Map<String, dynamic> j) : fromEnv = j['mode'] == 'fromContainerEnv', user = j['user'] as String?, hasPassword = j['hasPassword'] == true;
  final bool fromEnv;
  final String? user;
  final bool hasPassword;
}

class DbConnection {
  DbConnection(this.host, Map<String, dynamic> j)
    : id = '${j['id']}',
      name = '${j['name']}',
      engine = '${j['engine']}',
      target = _map(j['target']),
      database = j['database'] as String?,
      readCredential = j['readCredential'] is Map ? DbCredential(_map(j['readCredential'])) : null,
      writeCredential = j['writeCredential'] is Map ? DbCredential(_map(j['writeCredential'])) : null,
      readRole = j['readRole'] as String?,
      allowSuperuserReads = j['allowSuperuserReads'] == true,
      warnings = _strings(j['warnings']);
  final Host host;
  final String id;
  final String name;

  /// postgres | mysql | mariadb | sqlite
  final String engine;

  /// `{container, network?, port?}`, `{host, port?}` or `{path}`.
  final Map<String, dynamic> target;
  final String? database;
  final DbCredential? readCredential;
  final DbCredential? writeCredential;

  /// PostgreSQL: reads run `SET LOCAL ROLE readRole` first (a non-superuser role, so the server enforces read-only).
  final String? readRole;

  /// PostgreSQL: reads by a superuser login without a [readRole] are allowed (the user accepted the risk). Otherwise
  /// the agent refuses them with agent.db.superuserReadsDisabled.
  final bool allowSuperuserReads;

  /// `superuserCredential`: the read credential is the container's superuser.
  final List<String> warnings;

  bool get isSqlite => engine == 'sqlite';
  bool get superuser => warnings.contains('superuserCredential');
  bool get canWrite => !isSqlite;
  bool get isPostgres => engine == 'postgres';

  /// PostgreSQL reads with a superuser login are refused now (known when the credential is the container's superuser).
  bool get superuserReadsBlocked => isPostgres && superuser && readRole == null && !allowSuperuserReads;

  /// "argo-db" / "db.example.org:5432" / "/srv/app.sqlite".
  String get targetLabel {
    final t = target;
    if (t['container'] != null) return '${t['container']}${t['port'] != null ? ':${t['port']}' : ''}';
    if (t['host'] != null) return '${t['host']}${t['port'] != null ? ':${t['port']}' : ''}';
    return '${t['path'] ?? ''}';
  }
}

class DbConnections {
  DbConnections(this.host, Map<String, dynamic> j) : connections = [for (final e in _maps(j['connections'])) DbConnection(host, e)], sqlite = _map(j['engines'])['sqlite'] != false;
  final Host host;
  final List<DbConnection> connections;

  /// `engines.sqlite`: false when this Node has no `node:sqlite`.
  final bool sqlite;

  DbConnection? byId(String id) => connections.where((c) => c.id == id).firstOrNull;
}

class DbNetwork {
  DbNetwork(Map<String, dynamic> j) : name = '${j['name']}', ip = j['ip'] as String?;
  final String name;
  final String? ip;
}

/// A running database container found by `GET /v1/db/discover`.
class DbContainer {
  DbContainer(Map<String, dynamic> j)
    : container = '${j['container']}',
      engine = '${j['engine']}',
      supported = j['supported'] == true,
      image = '${j['image'] ?? ''}',
      version = '${j['version'] ?? ''}',
      state = '${j['state'] ?? ''}',
      project = j['project'] as String?,
      networks = [for (final e in _maps(j['networks'])) DbNetwork(e)],
      ports = [
        for (final e in _maps(j['ports']))
          if (_int(e['port']) != null) _int(e['port'])!,
      ],
      envNames = _strings(j['envNames']),
      containerEnvCredential = j['containerEnvCredential'] == true,
      connections = _strings(j['connections']);
  final String container;
  final String engine;
  final bool supported;
  final String image;
  final String version;
  final String state;
  final String? project;
  final List<DbNetwork> networks;
  final List<int> ports;

  /// Names only, never values.
  final List<String> envNames;

  /// The environment holds a usable credential (`fromContainerEnv` works).
  final bool containerEnvCredential;

  /// Ids of connections that already target this container.
  final List<String> connections;
}

/// Agent hosts whose health response lists the `databases` feature.
final dbHostsProvider = FutureProvider.autoDispose<List<Host>>(retry: _noRetry, (ref) async {
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final checked = await Future.wait(
    hosts.map((h) async {
      try {
        final j = await ref.watch(healthProvider(h.id).future);
        return (j['features'] as Map?)?['databases'] == true ? h : null;
      } catch (_) {
        return null;
      }
    }),
  );
  return [...checked.nonNulls];
});

final dbConnectionsProvider = FutureProvider.autoDispose.family<DbConnections, String>(retry: _noRetry, (ref, hostId) async {
  final host = ref.watch(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/connections')).timeout(const Duration(seconds: 20));
  return DbConnections(host, j);
});

final dbDiscoverProvider = FutureProvider.autoDispose.family<List<DbContainer>, String>(retry: _noRetry, (ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/discover')).timeout(const Duration(seconds: 30));
  return [for (final e in _maps(j['containers'])) DbContainer(e)];
});

/// Family key: (host id, connection id).
typedef DbConnRef = (String, String);

// ---------------------------------------------------------------------------------------------------------------------
// Schema

class DbSchemaColumn {
  DbSchemaColumn(Map<String, dynamic> j) : name = '${j['name']}', type = '${j['type'] ?? ''}', nullable = j['nullable'] != false, defaultValue = j['default'] as String?, primaryKey = j['primaryKey'] == true;
  final String name;
  final String type;
  final bool nullable;
  final String? defaultValue;
  final bool primaryKey;
}

class DbSchemaIndex {
  DbSchemaIndex(Map<String, dynamic> j) : name = '${j['name']}', unique = j['unique'] == true, primary = j['primary'] == true, definition = '${j['definition'] ?? ''}';
  final String name;
  final bool unique;
  final bool primary;
  final String definition;
}

class DbTable {
  DbTable(this.schema, Map<String, dynamic> j)
    : name = '${j['name']}',
      kind = '${j['kind'] ?? 'table'}',
      estimatedRows = _int(j['estimatedRows']),
      columns = [for (final e in _maps(j['columns'])) DbSchemaColumn(e)],
      indexes = [for (final e in _maps(j['indexes'])) DbSchemaIndex(e)];
  final String schema;
  final String name;

  /// table | view | materializedView | foreignTable | partitionedTable
  final String kind;
  final int? estimatedRows;
  final List<DbSchemaColumn> columns;
  final List<DbSchemaIndex> indexes;
}

class DbSchema {
  DbSchema(this.name, List<Map<String, dynamic>> tables) : tables = [for (final t in tables) DbTable(name, t)];
  final String name;
  final List<DbTable> tables;
}

class DbSchemaInfo {
  DbSchemaInfo(Map<String, dynamic> j) : schemas = [for (final s in _maps(j['schemas'])) DbSchema('${s['name']}', _maps(s['tables']))], truncated = j['truncated'] == true;
  final List<DbSchema> schemas;
  final bool truncated;
}

final dbSchemaProvider = FutureProvider.autoDispose.family<DbSchemaInfo, DbConnRef>(retry: _noRetry, (ref, key) async {
  final (hostId, connId) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/connections/$connId/schema')).timeout(const Duration(seconds: 70));
  return DbSchemaInfo(j);
});

// ---------------------------------------------------------------------------------------------------------------------
// Results, column kinds and paging

/// number | datetime | boolean | text
typedef DbKind = String;

final _numberType = RegExp(r'^(u?(tiny|small|medium|big)?int(eger)?\d*|float\d*|double.*|decimal.*|numeric.*|real|money|serial\d*|bigserial|smallserial|number)(?![a-z])', caseSensitive: false);
final _datetimeType = RegExp(r'^(timestamp|timestamptz|datetime|date|time|timetz)', caseSensitive: false);

double? parseNumber(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

/// The kind of a column: the agent's own `kind` when given, else from the type name, else from the values (the editor's
/// results carry no kind; SQLite types are often declared loosely or missing).
DbKind columnKind(String? type, List<Object?> values, {String? given}) {
  if (given != null && const {'number', 'datetime', 'boolean', 'text'}.contains(given)) return given;
  final t = (type ?? '').trim();
  if (t.isNotEmpty && !t.startsWith('oid:')) {
    if (_numberType.hasMatch(t)) return 'number';
    if (_datetimeType.hasMatch(t)) return 'datetime';
    if (RegExp(r'^bool', caseSensitive: false).hasMatch(t)) return 'boolean';
    if (RegExp(r'(char|text|uuid|json|blob|bytea|enum|interval|inet)', caseSensitive: false).hasMatch(t)) return 'text';
  }
  final sample = values.where((v) => v != null).take(50).toList();
  if (sample.isEmpty) return 'text';
  if (sample.every((v) => v is bool)) return 'boolean';
  if (sample.every((v) => parseNumber(v) != null)) return 'number';
  if (sample.every((v) => v is String && RegExp(r'^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}.*)?$').hasMatch(v))) return 'datetime';
  return 'text';
}

class DbResultColumn {
  const DbResultColumn(this.name, this.type, this.kind);
  final String name;
  final String? type;
  final DbKind kind;
}

/// The agent's "rows result" (query, preview and saved query run).
class DbResult {
  DbResult(Map<String, dynamic> j)
    : columns = _columns(j),
      rows = [
        for (final r in (j['rows'] as List? ?? const []))
          if (r is List) List<Object?>.from(r),
      ],
      truncated = j['truncated'] == true,
      cellsTruncated = _int(j['cellsTruncated']) ?? 0,
      limit = _int(j['limit']),
      elapsedMs = _int(j['elapsedMs']),
      queryName = _map(j['query'])['name'] as String?,
      chart = _map(j['query'])['chart'] is Map ? DbChartConfig(_map(_map(j['query'])['chart'])) : null;

  static List<DbResultColumn> _columns(Map<String, dynamic> j) {
    final cols = _maps(j['columns']);
    final rows = [
      for (final r in (j['rows'] as List? ?? const []))
        if (r is List) r,
    ];
    return [
      for (var i = 0; i < cols.length; i++)
        DbResultColumn(
          '${cols[i]['name']}',
          cols[i]['type'] as String?,
          columnKind(cols[i]['type'] as String?, [
            for (final r in rows)
              if (i < r.length) r[i],
          ], given: cols[i]['kind'] as String?),
        ),
    ];
  }

  final List<DbResultColumn> columns;
  final List<List<Object?>> rows;

  /// More rows than the limit (or the 8 MB cap): what's here is the start.
  final bool truncated;

  /// Cells cut at 4 KB.
  final int cellsTruncated;
  final int? limit;
  final int? elapsedMs;

  /// Saved query runs: its name and chart config.
  final String? queryName;
  final DbChartConfig? chart;

  int get rowCount => rows.length;
  int pageCount([int size = dbPageSize]) => rows.isEmpty ? 1 : (rows.length + size - 1) ~/ size;

  /// Rows of page [i] (0-based; clamped).
  List<List<Object?>> page(int i, [int size = dbPageSize]) {
    final p = i.clamp(0, pageCount(size) - 1);
    return rows.sublist(p * size, ((p + 1) * size).clamp(0, rows.length));
  }

  int columnIndex(String? name) => name == null ? -1 : columns.indexWhere((c) => c.name == name);
}

/// A cell as text (null → empty marker handled by the widget).
String cellText(Object? v) => v == null ? '' : '$v';

// ---------------------------------------------------------------------------------------------------------------------
// Saved queries and chart mapping

const chartTypes = ['table', 'stat', 'line', 'bar'];

/// At most this many y columns (the agent's limit).
const maxChartY = 8;

class DbChartConfig {
  DbChartConfig(Map<String, dynamic> j) : type = chartTypes.contains(j['type']) ? '${j['type']}' : 'table', x = j['x'] as String?, y = _strings(j['y']);
  const DbChartConfig.table() : type = 'table', x = null, y = const [];
  const DbChartConfig.of(this.type, {this.x, this.y = const []});
  final String type;
  final String? x;
  final List<String> y;

  Map<String, dynamic> toJson() => {'type': type, if (type != 'table' && type != 'stat' && x != null) 'x': x, if (type != 'table' && y.isNotEmpty) 'y': y};
}

class DbSavedQuery {
  DbSavedQuery(Map<String, dynamic> j)
    : id = '${j['id']}',
      connectionId = '${j['connectionId']}',
      name = '${j['name']}',
      sql = '${j['sql'] ?? ''}',
      params = List<Object?>.from(j['params'] as List? ?? const []),
      chart = j['chart'] is Map ? DbChartConfig(_map(j['chart'])) : const DbChartConfig.table();
  final String id;
  final String connectionId;
  final String name;
  final String sql;
  final List<Object?> params;
  final DbChartConfig chart;
}

final dbQueriesProvider = FutureProvider.autoDispose.family<List<DbSavedQuery>, DbConnRef>(retry: _noRetry, (ref, key) async {
  final (hostId, connId) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/db/queries', query: {'connectionId': connId})).timeout(const Duration(seconds: 20));
  return [for (final e in _maps(j['queries'])) DbSavedQuery(e)];
});

/// Candidate columns for the chart pickers, from the kinds of a result: the x axis takes any column, the y series only
/// numeric ones.
List<DbResultColumn> chartXCandidates(List<DbResultColumn> cols) => cols;
List<DbResultColumn> chartYCandidates(List<DbResultColumn> cols) => [
  for (final c in cols)
    if (c.kind == 'number') c,
];

/// A sensible starting config for a type once the columns are known: x = the first non-numeric column (else the first),
/// y = the numeric columns other than x.
DbChartConfig suggestChart(String type, List<DbResultColumn> cols) {
  if (type == 'table') return const DbChartConfig.table();
  final ys = chartYCandidates(cols);
  if (type == 'stat') return DbChartConfig.of('stat', y: ys.isEmpty ? const [] : [ys.first.name]);
  final x = cols.where((c) => c.kind != 'number').firstOrNull ?? cols.firstOrNull;
  return DbChartConfig.of(
    type,
    x: x?.name,
    y: [
      for (final c in ys)
        if (c.name != x?.name) c.name,
    ].take(maxChartY).toList(),
  );
}

/// Why a result can't be drawn with its config (null: it can).
enum ChartProblem { noRows, missingColumns, noNumeric }

class ChartSeries {
  const ChartSeries(this.name, this.values);
  final String name;

  /// One value per label; null where the cell isn't a number.
  final List<double?> values;
}

/// A result mapped onto a chart config: labels from the x column (as text), one series per y column; for `stat` the
/// first numeric cell of the first row.
class ChartData {
  const ChartData._(this.type, {this.labels = const [], this.series = const [], this.stat, this.statLabel, this.problem});
  final String type;
  final List<String> labels;
  final List<ChartSeries> series;
  final String? stat;
  final String? statLabel;
  final ChartProblem? problem;

  bool get ok => problem == null;

  /// Bars/points drawn at most (a bar chart of thousands of rows is unreadable; the table has the rest).
  static const maxPoints = 40;

  static ChartData build(DbResult r, DbChartConfig c) {
    if (c.type == 'table') return const ChartData._('table');
    if (r.rows.isEmpty) return ChartData._(c.type, problem: ChartProblem.noRows);
    if (c.type == 'stat') {
      final named = [for (final n in c.y) r.columnIndex(n)].where((i) => i >= 0).toList();
      final idx = named.isNotEmpty ? named.first : r.columns.indexWhere((x) => x.kind == 'number');
      if (idx < 0) return ChartData._('stat', problem: c.y.isEmpty ? ChartProblem.noNumeric : ChartProblem.missingColumns);
      final cell = r.rows.first[idx];
      return ChartData._('stat', stat: cellText(cell), statLabel: r.columns[idx].name);
    }
    final xi = r.columnIndex(c.x);
    final yis = [for (final n in c.y) r.columnIndex(n)];
    if (xi < 0 || c.y.isEmpty || yis.any((i) => i < 0)) {
      return ChartData._(c.type, problem: (c.y.isEmpty && xi >= 0 && chartYCandidates(r.columns).isEmpty) ? ChartProblem.noNumeric : ChartProblem.missingColumns);
    }
    final rows = r.rows.take(maxPoints).toList();
    return ChartData._(
      c.type,
      labels: [for (final row in rows) cellText(row[xi])],
      series: [
        for (var k = 0; k < yis.length; k++) ChartSeries(c.y[k], [for (final row in rows) parseNumber(row[yis[k]])]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// API calls

/// One database call (for buttons and sheets). The agent's own timeout is passed on as the client timeout plus slack.
class DbApi {
  DbApi(this._ref, this.hostId);
  final WidgetRef _ref;
  final String hostId;

  Future<dynamic> call(String method, String path, {Object? body, int timeoutSec = 15}) async {
    final host = _ref.read(profileProvider).host(hostId);
    if (host == null) throw const AgentError('agent.notConfigured');
    final c = await _ref.read(agentClientFactoryProvider)(host);
    try {
      return await c.request(
        method,
        path,
        body: body,
        timeout: Duration(seconds: timeoutSec + 10),
      );
    } finally {
      c.close();
    }
  }

  /// Read-only SQL; the agent clamps limit/timeout itself.
  Future<DbResult> query(String connId, String sql, {int? limit, int? timeoutSec}) async {
    final j = await call('POST', '/v1/db/connections/$connId/query', body: {'sql': sql, 'limit': ?limit, 'timeoutMs': ?(timeoutSec == null ? null : timeoutSec * 1000)}, timeoutSec: timeoutSec ?? dbDefaultTimeoutSec);
    return DbResult(_map(j));
  }

  Future<DbResult> preview(String connId, DbTable t) async {
    final path = '/v1/db/connections/$connId/tables/${Uri.encodeComponent(t.schema)}/${Uri.encodeComponent(t.name)}/preview?limit=$dbPreviewRows';
    return DbResult(_map(await call('GET', path)));
  }

  Future<DbResult> runSaved(String queryId) async => DbResult(_map(await call('POST', '/v1/db/queries/$queryId/run', body: const {}, timeoutSec: dbDefaultTimeoutSec)));

  Future<Map<String, dynamic>> test(String connId) async => _map(await call('POST', '/v1/db/connections/$connId/test', timeoutSec: 20));
}

// ---------------------------------------------------------------------------------------------------------------------
// CSV export

/// Counts the data rows of a CSV stream (header excluded; quoted newlines don't count) while it is written.
class CsvRowCounter {
  var _lines = 0;
  var _inQuote = false;
  var _pending = false;

  void add(List<int> bytes) {
    for (final b in bytes) {
      if (b == 0x22) {
        _inQuote = !_inQuote;
        _pending = true;
      } else if (b == 0x0A && !_inQuote) {
        _lines++;
        _pending = false;
      } else if (b != 0x0D) {
        _pending = true;
      }
    }
  }

  int get rows => (_lines + (_pending ? 1 : 0) - 1).clamp(0, 1 << 31);
}

class DbExport {
  const DbExport({required this.file, required this.rows, required this.truncated, required this.bytes});
  final File file;
  final int rows;

  /// The agent said so, or the file hit the row cap exactly (a proxy may drop the trailers).
  final bool truncated;
  final int bytes;
}

/// Streams a CSV into a temp file. [fetch] gets the byte sink and returns the response headers (the agent's trailers
/// `x-tiphys-rows` / `x-tiphys-truncated` when a proxy forwards them as headers). The file is removed on failure.
Future<DbExport> exportCsvToFile({required Future<Map<String, String>> Function(void Function(List<int>) onData) fetch, required Directory dir, required String name}) async {
  await dir.create(recursive: true);
  final file = File('${dir.path}/$name');
  final sink = file.openWrite();
  final counter = CsvRowCounter();
  var bytes = 0;
  try {
    final headers = await fetch((b) {
      sink.add(b);
      counter.add(b);
      bytes += b.length;
    });
    await sink.close();
    final rows = int.tryParse(headers['x-tiphys-rows'] ?? '') ?? counter.rows;
    return DbExport(file: file, rows: rows, truncated: headers['x-tiphys-truncated'] == 'true' || rows >= dbCsvMaxRows, bytes: bytes);
  } catch (_) {
    try {
      await sink.close();
    } catch (_) {}
    if (file.existsSync()) file.deleteSync();
    rethrow;
  }
}

/// The app's temp (cache) directory (overridden in tests). CSV files are written to its `db-export/`; share_plus copies
/// what it shares into its `share_plus/`.
final dbCacheDirProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// Where CSV files are written.
final dbExportDirProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await ref.read(dbCacheDirProvider)()).path}/db-export'),
);

/// Removes every CSV copy left in [cache]: our `db-export/` files (an export killed half way) and share_plus's copies of
/// shared files (`share_plus/`, which share_plus itself never removes).
Future<void> clearCsvCopies(Directory cache) async {
  for (final name in const ['db-export', 'share_plus']) {
    final d = Directory('${cache.path}/$name');
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

/// [clearCsvCopies] of the cache directory; never throws (called at app start and when leaving the console).
final dbClearCsvCopiesProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    try {
      await clearCsvCopies(await ref.read(dbCacheDirProvider)());
    } catch (e) {
      debugPrint('db: clearing CSV copies failed: $e');
    }
  },
);

/// Hands a CSV file to the Android share sheet; true when the user shared it (overridden in tests).
final dbShareProvider = Provider<Future<bool> Function(File file)>(
  (ref) => (file) async {
    final r = await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'text/csv')]));
    return r.status == ShareResultStatus.success;
  },
);

/// Export (POST [path] with [body]) → temp file → share sheet → delete the file. Returns what was exported.
Future<DbExport> shareCsv(WidgetRef ref, String hostId, String path, Object body, {required String name}) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final dir = await ref.read(dbExportDirProvider)();
  final c = await ref.read(agentClientFactoryProvider)(host);
  final DbExport out;
  try {
    out = await exportCsvToFile(
      fetch: (onData) => c.download('POST', path, body: body, onData: onData),
      dir: dir,
      name: name,
    );
  } finally {
    c.close();
  }
  try {
    // Shared: the receiving app has it, so share_plus's copy can go too (else it goes when the console is left).
    if (await ref.read(dbShareProvider)(out.file)) await ref.read(dbClearCsvCopiesProvider)();
  } finally {
    if (out.file.existsSync()) out.file.deleteSync();
  }
  return out;
}

/// `<id>-<yyyyMMdd-HHmm>.csv` with characters a file name can take.
String csvFileName(String id, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '$safe-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}.csv';
}

// ---------------------------------------------------------------------------------------------------------------------
// Write mode

/// The write mode needs the app lock to be set up (like revealing a secret); overridden in tests.
final dbWriteLockAvailableProvider = FutureProvider<bool>((ref) => ref.watch(lockRequiredProvider.future));

/// Is the write mode on for a connection? Off when the screen is left or the app goes to the background; turning it on
/// asks for the app lock each time.
class DbWriteMode extends Notifier<bool> {
  DbWriteMode(this.key);
  final DbConnRef key;

  @override
  bool build() {
    final life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) state = false;
    });
    ref.onDispose(life.dispose);
    return false;
  }

  void set(bool on) => state = on;
}

final dbWriteModeProvider = NotifierProvider.autoDispose.family<DbWriteMode, bool, DbConnRef>(DbWriteMode.new);

class WritePreview {
  WritePreview(Map<String, dynamic> j, DateTime receivedAt)
    : kind = '${j['kind'] ?? 'dml'}',
      statement = '${j['statement'] ?? ''}',
      count = _int(j['count']),
      sampleColumns = [for (final c in _maps(_map(j['sample'])['columns'])) '${c['name']}'],
      sampleRows = [
        for (final r in (_map(j['sample'])['rows'] as List? ?? const []))
          if (r is List) List<Object?>.from(r),
      ],
      credential = '${j['credential'] ?? 'write'}',
      warnings = _strings(j['warnings']),
      token = '${j['previewToken']}',
      deadline = previewDeadline(_timeOrNull(j['expiresAt']), receivedAt);

  /// dml | ddl
  final String kind;

  /// "update", "create table", …
  final String statement;

  /// Rows the statement would change; null for DDL.
  final int? count;
  final List<String> sampleColumns;
  final List<List<Object?>> sampleRows;

  /// write | read: which credential ran it.
  final String credential;
  final List<String> warnings;
  final String token;

  /// When the token stops working, on this phone's clock.
  final DateTime deadline;

  bool get isDdl => kind == 'ddl';
  Duration remaining(DateTime now) => deadline.difference(now).isNegative ? Duration.zero : deadline.difference(now);
  bool expired(DateTime now) => !now.isBefore(deadline);
}

/// unknown: the commit was sent but no answer came back (client timeout, broken connection): it may have been applied.
enum WriteStage { idle, previewing, ready, committing, done, countChanged, expired, failed, unknown }

/// Errors after which a sent request may still have been carried out (the answer was lost, not the request refused).
bool outcomeUnknown(Object e) => e is! AgentError || const {'net.timeout', 'net.unreachable', 'net.badResponse', 'net.http'}.contains(e.code);

/// The write flow of the editor: [run] previews a statement (the agent runs it in a transaction it rolls back), the user
/// confirms, [confirm] commits with the one-time token. States: idle → previewing → ready → committing → done; a commit
/// answering `countChanged` (the data moved under us, nothing applied) or a lapsed token ends in countChanged / expired,
/// from where [run] again makes a fresh preview. A rate-limit answer keeps `ready` (the token isn't spent).
class WriteFlow extends ChangeNotifier {
  WriteFlow({required this.previewFn, required this.commitFn, required this.clock});

  /// POST …/write/preview → the response; POST …/write/commit with the token → the response.
  final Future<dynamic> Function(String sql) previewFn;
  final Future<dynamic> Function(String token) commitFn;
  final DateTime Function() clock;

  WriteStage stage = WriteStage.idle;
  String? sql;
  WritePreview? preview;
  Object? error;

  /// countChanged: what the preview said and what the statement affects now.
  int? expected, actual;

  /// done: rows the commit changed (null for DDL).
  int? committed;
  var _gen = 0;

  bool get busy => stage == WriteStage.previewing || stage == WriteStage.committing;

  /// A commit makes sense: a live token and, for DML, at least one row.
  bool get canCommit {
    final p = preview;
    return stage == WriteStage.ready && p != null && !p.expired(clock()) && (p.isDdl || (p.count ?? 0) > 0);
  }

  void _set(WriteStage s) {
    stage = s;
    notifyListeners();
  }

  /// Call on a timer: a ready preview whose token ran out becomes `expired`.
  void tick() {
    final p = preview;
    if (stage == WriteStage.ready && p != null && p.expired(clock())) _set(WriteStage.expired);
  }

  Future<void> run(String statement) async {
    if (busy) return;
    final gen = ++_gen;
    sql = statement;
    error = null;
    preview = null;
    expected = actual = committed = null;
    _set(WriteStage.previewing);
    try {
      final j = await previewFn(statement);
      if (gen != _gen) return;
      preview = WritePreview(_map(j), clock());
      _set(WriteStage.ready);
    } catch (e) {
      if (gen != _gen) return;
      error = e;
      _set(WriteStage.failed);
    }
  }

  /// Preview the same statement again (after countChanged, expiry or an error). Not after `unknown`: the statement
  /// may have been applied already, a second commit would apply it twice.
  Future<void> rePreview() async {
    if (stage == WriteStage.unknown) return;
    await run(sql ?? '');
  }

  Future<void> confirm() async {
    final p = preview;
    if (stage != WriteStage.ready || p == null) return;
    // Don't send a token that has surely lapsed.
    if (p.expired(clock())) return _set(WriteStage.expired);
    error = null;
    _set(WriteStage.committing);
    try {
      final j = _map(await commitFn(p.token));
      committed = _int(j['count']);
      _set(WriteStage.done);
    } on AgentError catch (e) {
      error = e;
      switch (e.code) {
        case 'agent.db.countChanged':
          expected = _int(e.params['expected']);
          actual = _int(e.params['actual']);
          _set(WriteStage.countChanged);
        case 'agent.preview.invalid':
          _set(WriteStage.expired);
        case 'agent.db.writeRateLimited':
          _set(WriteStage.ready);
        default:
          _set(outcomeUnknown(e) ? WriteStage.unknown : WriteStage.failed);
      }
    } catch (e) {
      error = e;
      _set(WriteStage.unknown);
    }
  }
}

/// `GET …/readonly-role-sql`: statements to create a read-only role (the password is fresh and shown once).
class RoleSql {
  RoleSql(Map<String, dynamic> j) : role = '${j['role']}', statements = _strings(j['statements']), runVia = '${j['runVia']}';
  final String role;
  final List<String> statements;

  /// writeMode (PostgreSQL: the write mode can run it) | client (MySQL/MariaDB: account statements can't be previewed).
  final String runVia;

  bool get viaWriteMode => runVia == 'writeMode';
  String get text => statements.map((s) => s.trimRight().endsWith(';') ? s : '$s;').join('\n');
}
