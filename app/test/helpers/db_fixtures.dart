// Sample data and the fake agent's /v1/db/* routes (agent/src/db/*): connections, discovery, schema, queries, saved
// queries with chart configs, CSV export, the write mode and restore tests. All names are examples (argo, atlas).
import 'dart:convert';

import 'package:tiphys/core/agent/agent_client.dart';

final _clock = DateTime(2026, 11, 14, 14, 5);
String _at(Duration ago) => _clock.subtract(ago).toUtc().toIso8601String();

class FakeDbState {
  FakeDbState() {
    connections = [
      {
        'id': 'shop-db',
        'name': 'Shop (PostgreSQL)',
        'engine': 'postgres',
        'target': {'container': 'argo-shop-db'},
        'database': 'shop',
        'readCredential': {'mode': 'password', 'user': 'app_ro', 'hasPassword': true},
        'writeCredential': {'mode': 'password', 'user': 'app_rw', 'hasPassword': true},
        'warnings': <String>[],
      },
      {
        'id': 'analytics',
        'name': 'Analytics (MariaDB)',
        'engine': 'mariadb',
        'target': {'container': 'argo-analytics'},
        'database': null,
        'readCredential': {'mode': 'fromContainerEnv'},
        'writeCredential': null,
        'warnings': ['superuserCredential'],
      },
      {
        'id': 'notes-lite',
        'name': 'Notes (SQLite)',
        'engine': 'sqlite',
        'target': {'path': '/srv/notes/notes.sqlite'},
        'database': null,
        'readCredential': null,
        'writeCredential': null,
        'warnings': <String>[],
      },
    ];
    queries = [
      _q('q-111111111111', 'Daily orders', 'SELECT day, total FROM daily_orders', {'type': 'bar', 'x': 'day', 'y': ['total']}),
      _q('q-222222222222', 'Monthly revenue', 'SELECT month, revenue FROM monthly', {'type': 'line', 'x': 'month', 'y': ['revenue']}),
      _q('q-333333333333', 'Customers', 'SELECT count(*) AS customers FROM customers', {'type': 'stat', 'y': ['customers']}),
    ];
    restoreTests = [
      {
        'id': 'shop-nightly',
        'name': 'Shop nightly',
        'connectionId': 'shop-db',
        'engine': 'postgres',
        'image': 'postgres:16',
        'dumpGlob': '~/backups/shop/*.sql.gz',
        'format': 'gz',
        'sanity': [
          {'sql': 'SELECT count(*) FROM orders', 'expect': {'op': '>', 'value': 0}},
        ],
        'schedule': {'kind': 'daily', 'time': '03:30'},
        'enabled': true,
      },
      {
        'id': 'analytics-weekly',
        'name': 'Analytics weekly',
        'engine': 'mariadb',
        'image': 'mariadb:11',
        'dumpGlob': '~/backups/analytics/*.sql',
        'format': 'sql',
        'sanity': <Map<String, dynamic>>[],
        'schedule': null,
        'enabled': true,
      },
    ];
    results = {
      'shop-nightly': [
        _r('r-aaaaaaaaaaaa', 'shop-nightly', true, null, const Duration(hours: 10), 'schedule'),
        _r('r-bbbbbbbbbbbb', 'shop-nightly', false, 'sanityFailed', const Duration(days: 1, hours: 10), 'schedule', failures: [
          {'index': 0, 'reason': 'expectation', 'actual': 0, 'expected': '> 0'},
        ]),
      ],
      'analytics-weekly': [
        _r('r-cccccccccccc', 'analytics-weekly', false, 'restoreFailed', const Duration(days: 2), 'manual', detail: 'ERROR 1064 (42000) at line 12'),
      ],
    };
  }

  static Map<String, dynamic> _q(String id, String name, String sql, Map<String, dynamic> chart) =>
      {'id': id, 'connectionId': 'shop-db', 'name': name, 'sql': sql, 'params': <Object?>[], 'chart': chart, 'createdAt': _at(const Duration(days: 3)), 'updatedAt': _at(const Duration(days: 3))};

  static Map<String, dynamic> _r(String id, String testId, bool ok, String? reason, Duration ago, String trigger, {List<Map<String, dynamic>> failures = const [], String? detail}) => {
        'id': id,
        'testId': testId,
        'trigger': trigger,
        'startedAt': _at(ago),
        'finishedAt': _at(ago - const Duration(minutes: 4)),
        'ok': ok,
        'reason': reason,
        'detail': detail,
        'image': 'postgres:16',
        'dumpFile': 'shop-20261113.sql.gz',
        'dumpBytes': 48 * 1024 * 1024,
        'rowsChecked': 1,
        'failures': failures,
        'durations': {'totalMs': 236000},
      };

  late List<Map<String, dynamic>> connections;
  late List<Map<String, dynamic>> queries;
  late List<Map<String, dynamic>> restoreTests;
  late Map<String, List<Map<String, dynamic>>> results;

  /// Agent's `engines.sqlite`.
  bool sqlite = true;

  /// Rows of every editor query and whether the agent says it cut them.
  int queryRows = 60;
  bool queryTruncated = true;

  /// Write mode knobs: rows the preview reports; the commit then answers countChanged (expected → actual) once.
  int writeCount = 3;
  int? commitActual;
  Duration previewTtl = const Duration(seconds: 118);
  int previews = 0;
  final writeCalls = <String>[];

  /// Restore tests: the number of list reads a started run keeps `running` for.
  int runningPolls = 2;
  String? runningId;
  int _polls = 0;
  int runs = 0;

  /// CSV export: body (UTF-8) and extra response headers.
  String csv = '\u{FEFF}id,total\r\n1,10.5\r\n2,"a,b"\r\n3,7\r\n';
  Map<String, String> csvHeaders = {};
  AgentError? exportError;
  final exports = <String>[];

  AgentError? queryError;

  /// Thrown by the next commits (e.g. net.timeout: the answer was lost).
  AgentError? commitError;
  bool empty = false;
}

List<Map<String, dynamic>> _containers() => [
      {
        'container': 'argo-shop-db', 'id': 'c1', 'engine': 'postgres', 'supported': true, 'image': 'postgres:16-alpine', 'version': '16-alpine', 'state': 'running', 'project': 'shop',
        'networks': [{'name': 'shop_default', 'ip': '172.20.0.2'}], 'ports': [{'port': 5432}], 'envNames': ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB'], 'containerEnvCredential': true, 'connections': ['shop-db'],
      },
      {
        'container': 'argo-analytics', 'id': 'c2', 'engine': 'mariadb', 'supported': true, 'image': 'mariadb:11', 'version': '11', 'state': 'running', 'project': 'analytics',
        'networks': [{'name': 'analytics_default', 'ip': '172.21.0.2'}, {'name': 'proxy', 'ip': '172.22.0.5'}], 'ports': [{'port': 3306}], 'envNames': ['MARIADB_ROOT_PASSWORD'], 'containerEnvCredential': true, 'connections': ['analytics'],
      },
      {
        'container': 'argo-blog-db', 'id': 'c3', 'engine': 'postgres', 'supported': true, 'image': 'postgres:15', 'version': '15', 'state': 'running', 'project': 'blog',
        'networks': [{'name': 'blog_default', 'ip': '172.23.0.2'}], 'ports': [{'port': 5432}], 'envNames': ['POSTGRES_PASSWORD'], 'containerEnvCredential': true, 'connections': <String>[],
      },
      {
        'container': 'argo-cache', 'id': 'c4', 'engine': 'redis', 'supported': false, 'image': 'redis:7', 'version': '7', 'state': 'running', 'project': 'shop',
        'networks': [{'name': 'shop_default', 'ip': '172.20.0.3'}], 'ports': [{'port': 6379}], 'envNames': <String>[], 'containerEnvCredential': false, 'connections': <String>[],
      },
    ];

Map<String, dynamic> _col(String name, String type, {bool pk = false, bool nullable = true}) => {'name': name, 'type': type, 'nullable': nullable, 'default': null, 'primaryKey': pk};

Map<String, dynamic> _schema(String engine) => {
      'conn': 'shop-db',
      'engine': engine,
      'schemas': [
        {
          'name': 'public',
          'tables': [
            {
              'name': 'orders', 'kind': 'table', 'estimatedRows': 12840,
              'columns': [_col('id', 'int4', pk: true, nullable: false), _col('customer_id', 'int4', nullable: false), _col('total', 'numeric'), _col('created_at', 'timestamptz')],
              'indexes': [
                {'name': 'orders_pkey', 'unique': true, 'primary': true, 'definition': '(id)'},
                {'name': 'orders_customer_idx', 'unique': false, 'primary': false, 'definition': '(customer_id)'},
              ],
            },
            {
              'name': 'customers', 'kind': 'table', 'estimatedRows': 912,
              'columns': [_col('id', 'int4', pk: true, nullable: false), _col('email', 'text', nullable: false)],
              'indexes': [{'name': 'customers_pkey', 'unique': true, 'primary': true, 'definition': '(id)'}],
            },
            {'name': 'order_totals', 'kind': 'view', 'estimatedRows': null, 'columns': [_col('day', 'date'), _col('total', 'numeric')], 'indexes': <Map<String, dynamic>>[]},
          ],
        },
        {
          'name': 'billing',
          'tables': [
            {'name': 'invoices', 'kind': 'table', 'estimatedRows': 4300, 'columns': [_col('id', 'int8', pk: true, nullable: false)], 'indexes': <Map<String, dynamic>>[]},
          ],
        },
      ],
      'truncated': false,
    };

Map<String, dynamic> _rows(FakeDbState st, {int? n}) {
  final count = n ?? st.queryRows;
  return {
    'conn': 'shop-db',
    'columns': [
      {'name': 'id', 'type': 'int4'},
      {'name': 'customer', 'type': 'text'},
      {'name': 'total', 'type': 'numeric'},
      {'name': 'created_at', 'type': 'timestamptz'},
    ],
    'rows': [
      for (var i = 1; i <= count; i++) [i, 'customer-$i@example.org', (i * 12.5).toStringAsFixed(2), '2026-11-${(1 + i % 28).toString().padLeft(2, '0')} 10:${(i % 60).toString().padLeft(2, '0')}:00+00'],
    ],
    'rowCount': count,
    'truncated': st.queryTruncated,
    'cellsTruncated': 0,
    'limit': count,
    'elapsedMs': 14,
  };
}

Map<String, dynamic> _runSaved(Map<String, dynamic> q) {
  final id = q['id'] as String;
  Map<String, dynamic> r(List<List<String>> cols, List<List<Object?>> rows) => {
        'conn': q['connectionId'],
        'columns': [for (final c in cols) {'name': c[0], 'type': c[1], 'kind': c[2]}],
        'rows': rows,
        'rowCount': rows.length,
        'truncated': false,
        'cellsTruncated': 0,
        'limit': 500,
        'elapsedMs': 8,
        'query': {'id': id, 'name': q['name'], 'chart': q['chart']},
      };
  return switch ((q['chart'] as Map)['type']) {
    'line' => r([['month', 'text', 'text'], ['revenue', 'numeric', 'number']], [for (var i = 0; i < 8; i++) ['2026-0${i + 1}', '${(1000 + i * i * 120 - i * 40)}']]),
    'stat' => r([['customers', 'int8', 'number']], [['912']]),
    _ => r([['day', 'date', 'datetime'], ['total', 'numeric', 'number']], [for (var i = 0; i < 7; i++) ['2026-11-${8 + i}', '${[42, 58, 31, 77, 64, 25, 49][i]}']]),
  };
}

dynamic fakeDbRoute(String hostId, String method, String path, Object? body, FakeDbState st) {
  final empty = hostId != 'argo' || st.empty;
  final seg = path.substring('/v1/db/'.length).split('/');
  if (seg[0] == 'discover') return {'containers': empty ? <Object>[] : _containers()};
  if (seg[0] == 'connections') {
    if (seg.length == 1) {
      if (method == 'GET') return {'connections': empty ? <Object>[] : st.connections, 'engines': {'postgres': true, 'mysql': true, 'mariadb': true, 'sqlite': st.sqlite}};
      final b = Map<String, dynamic>.from(body as Map);
      final id = 'db-${st.connections.length + 1}0000000';
      st.connections.add({
        'id': id, 'name': b['name'], 'engine': b['engine'], 'target': b['target'], 'database': b['database'],
        'readCredential': _cred(b['readCredential']), 'writeCredential': _cred(b['writeCredential']),
        'warnings': (b['readCredential'] as Map?)?['fromContainerEnv'] == true ? ['superuserCredential'] : <String>[],
      });
      return st.connections.last;
    }
    final id = seg[1];
    final c = st.connections.where((x) => x['id'] == id).firstOrNull;
    if (c == null) throw AgentError('agent.db.connectionNotFound', {'id': id}, 404);
    if (seg.length == 2) {
      if (method == 'GET') return c;
      if (method == 'DELETE') {
        st.connections.remove(c);
        return {'ok': true};
      }
      final b = Map<String, dynamic>.from(body as Map);
      if (b.containsKey('target') && '${b['target']}' != '${c['target']}' && (b['readCredential'] as Map?)?['password'] == null && (c['readCredential'] as Map?)?['hasPassword'] == true) {
        throw const AgentError('agent.db.passwordRequired', {}, 400);
      }
      for (final k in ['name', 'target', 'database', 'readRole', 'allowSuperuserReads']) {
        if (b.containsKey(k)) c[k] = b[k];
      }
      if (b['readCredential'] != null) c['readCredential'] = _cred(b['readCredential'], c['readCredential']);
      if (b.containsKey('writeCredential')) c['writeCredential'] = _cred(b['writeCredential'], c['writeCredential']);
      return c;
    }
    final op = seg.skip(2).join('/');
    final engine = c['engine'];
    if (op == 'test') {
      return {'ok': true, 'engine': engine, 'serverVersion': engine == 'postgres' ? 'PostgreSQL 16.4' : '11.5.2-MariaDB', 'user': 'app_ro', 'database': c['database'], 'superuser': (c['warnings'] as List).isNotEmpty, 'readOnlyDefault': true, 'latencyMs': 12, 'warnings': c['warnings']};
    }
    if (op == 'schema') return _schema(engine as String);
    if (op.startsWith('tables/')) {
      final r = _rows(st, n: 5);
      return {...r, 'schema': seg[3], 'table': seg[4], 'truncated': false};
    }
    if (op == 'query') {
      if (st.queryError != null) throw st.queryError!;
      return _rows(st);
    }
    if (op == 'export') {
      st.exports.add((body as Map)['sql'] as String);
      if (st.exportError != null) throw st.exportError!;
      return null;
    }
    if (op == 'write/preview') {
      if (engine == 'sqlite') throw const AgentError('agent.db.writeUnsupported', {}, 400);
      st.writeCalls.add('preview:${(body as Map)['sql']}');
      st.previews++;
      final sql = '${body['sql']}'.toLowerCase();
      if (engine == 'mariadb' && sql.startsWith('create')) throw const AgentError('agent.db.ddlNotPreviewable', {'keyword': 'create'}, 400);
      final ddl = sql.startsWith('create') || sql.startsWith('drop') || sql.startsWith('alter');
      return {
        'conn': id, 'kind': ddl ? 'ddl' : 'dml', 'statement': ddl ? sql.split(' ').take(2).join(' ') : sql.split(' ').first, 'count': ddl ? null : st.writeCount,
        if (!ddl) 'sample': {'columns': [{'name': 'id'}, {'name': 'status'}], 'rows': [for (var i = 1; i <= st.writeCount.clamp(0, 20); i++) [i, 'pending'] ], 'cellsTruncated': 0},
        'credential': (c['writeCredential'] != null) ? 'write' : 'read',
        'warnings': [if (c['writeCredential'] == null) 'readCredentialUsed', if ((c['warnings'] as List).isNotEmpty) 'superuserCredential'],
        'previewToken': 'tok-${st.previews}', 'expiresAt': _clock.add(st.previewTtl).toUtc().toIso8601String(), 'elapsedMs': 9,
      };
    }
    if (op == 'write/commit') {
      st.writeCalls.add('commit:${(body as Map)['previewToken']}');
      if (st.commitError != null) throw st.commitError!;
      final actual = st.commitActual;
      if (actual != null) {
        st.commitActual = null;
        throw AgentError('agent.db.countChanged', {'expected': st.writeCount, 'actual': actual}, 409);
      }
      return {'conn': id, 'committed': true, 'count': st.writeCount, 'elapsedMs': 11};
    }
    if (op == 'readonly-role-sql') {
      final pg = engine == 'postgres';
      return {
        'conn': id, 'engine': engine, 'role': 'tiphys_ro', 'password': 'EXAMPLE-NOT-A-REAL-PASSWORD', 'runVia': pg ? 'writeMode' : 'client', 'requires': pg ? 'PostgreSQL 14+' : 'mysql client',
        'statements': pg
            ? ['CREATE ROLE "tiphys_ro" LOGIN PASSWORD \'EXAMPLE-NOT-A-REAL-PASSWORD\' NOSUPERUSER CONNECTION LIMIT 5 IN ROLE pg_read_all_data']
            : ['CREATE USER \'tiphys_ro\'@\'%\' IDENTIFIED BY \'EXAMPLE-NOT-A-REAL-PASSWORD\'', 'GRANT SELECT, SHOW VIEW ON *.* TO \'tiphys_ro\'@\'%\''],
      };
    }
  }
  if (seg[0] == 'queries') {
    if (seg.length == 1) {
      if (method == 'GET') return {'queries': st.queries};
      final b = Map<String, dynamic>.from(body as Map);
      st.queries.add({'id': 'q-${st.queries.length + 1}00000000000'.substring(0, 14), 'connectionId': b['connectionId'], 'name': b['name'], 'sql': b['sql'], 'params': <Object?>[], 'chart': b['chart'] ?? {'type': 'table'}, 'createdAt': _at(Duration.zero), 'updatedAt': _at(Duration.zero)});
      return st.queries.last;
    }
    final q = st.queries.where((x) => x['id'] == seg[1]).firstOrNull;
    if (q == null) throw AgentError('agent.db.queryNotFound', {'id': seg[1]}, 404);
    if (seg.length == 3 && seg[2] == 'run') return _runSaved(q);
    if (seg.length == 3 && seg[2] == 'export') {
      st.exports.add('saved:${q['id']}');
      return null;
    }
    if (method == 'DELETE') {
      st.queries.remove(q);
      return {'ok': true};
    }
    if (method == 'PATCH') {
      q.addAll(Map<String, dynamic>.from(body as Map));
      return q;
    }
    return q;
  }
  if (seg[0] == 'restore-tests') {
    if (seg.length == 1) {
      if (method == 'GET') {
        if (st.runningId != null && ++st._polls > st.runningPolls) {
          final id = st.runningId!;
          st.runningId = null;
          (st.results[id] ??= []).insert(0, FakeDbState._r('r-run${st.runs}00000000'.substring(0, 14), id, true, null, Duration.zero, 'manual'));
        }
        return {
          'running': empty || st.runningId == null ? null : {'testId': st.runningId, 'runId': 'r-x'},
          'tests': [
            if (!empty)
              for (final t in st.restoreTests)
                {
                  ...t,
                  'running': st.runningId == t['id'],
                  'last': st.results[t['id']]?.firstOrNull,
                  'nextRunAt': t['schedule'] != null && t['enabled'] == true ? _clock.add(const Duration(hours: 13, minutes: 25)).toUtc().toIso8601String() : null,
                },
          ],
        };
      }
      final b = Map<String, dynamic>.from(body as Map);
      if (st.restoreTests.any((t) => t['id'] == b['id'])) throw AgentError('agent.db.restoreTestExists', {'id': b['id']}, 409);
      st.restoreTests.add(b);
      return b;
    }
    final t = st.restoreTests.where((x) => x['id'] == seg[1]).firstOrNull;
    if (t == null) throw AgentError('agent.db.restoreTestNotFound', {'id': seg[1]}, 404);
    if (seg.length == 3 && seg[2] == 'run') {
      if (st.runningId != null) throw const AgentError('agent.db.restoreBusy', {}, 409);
      st.runningId = seg[1];
      st._polls = 0;
      st.runs++;
      return {'started': true, 'testId': seg[1], 'runId': 'r-x'};
    }
    if (seg.length == 3 && seg[2] == 'results') return {'testId': seg[1], 'results': st.results[seg[1]] ?? <Object>[]};
    if (method == 'DELETE') {
      st.restoreTests.remove(t);
      return {'ok': true};
    }
    if (method == 'PATCH') {
      t.addAll(Map<String, dynamic>.from(body as Map));
      return t;
    }
    return t;
  }
  throw AgentError('agent.route.notFound', {'path': path}, 404);
}

Map<String, dynamic>? _cred(Object? input, [Object? old]) {
  if (input is! Map) return null;
  if (input['fromContainerEnv'] == true) return {'mode': 'fromContainerEnv'};
  final had = old is Map && old['hasPassword'] == true;
  return {'mode': 'password', 'user': input['user'], 'hasPassword': input['password'] != null || had};
}

List<int> fakeCsvBytes(FakeDbState st) => utf8.encode(st.csv);
