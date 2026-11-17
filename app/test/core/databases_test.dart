// Database console (PLAN.md §13.2): result paging and truncation, column kinds → chart mapping, the CSV stream to a file,
// the write flow state machine (preview → confirm → commit; countChanged, expiry, rate limit), restore test models and
// notification texts/routing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/databases/db_data.dart';
import 'package:tiphys/features/databases/db_restore_data.dart';
import 'package:tiphys/features/databases/db_texts.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

import '../helpers/harness.dart' show exampleProfile;

DbResult result(List<Map<String, dynamic>> cols, List<List<Object?>> rows, {bool truncated = false, int cellsTruncated = 0}) => DbResult({
      'columns': cols,
      'rows': rows,
      'truncated': truncated,
      'cellsTruncated': cellsTruncated,
      'limit': 500,
      'elapsedMs': 5,
    });

void main() {
  group('result', () {
    test('paging: 120 rows → 3 pages of 50/50/20; pages are clamped', () {
      final r = result([{'name': 'n', 'type': 'int4'}], [for (var i = 0; i < 120; i++) [i]], truncated: true);
      expect(r.pageCount(), 3);
      expect(r.page(0).length, 50);
      expect(r.page(2).length, 20);
      expect(r.page(2).first.first, 100);
      expect(r.page(9).first.first, 100, reason: 'clamped to the last page');
      expect(r.page(-1).first.first, 0);
      expect(r.truncated, isTrue);
      expect(result([], []).pageCount(), 1);
    });

    test('truncation info and cell values survive parsing', () {
      final r = result([{'name': 'a', 'type': 'text'}], [['x…'], [null]], truncated: true, cellsTruncated: 2);
      expect(r.truncated, isTrue);
      expect(r.cellsTruncated, 2);
      expect(r.rows[1][0], isNull);
      expect(cellText(null), '');
    });

    test('kinds: given > type name > values', () {
      expect(columnKind('int4', const []), 'number');
      expect(columnKind('numeric(10,2)', const []), 'number');
      expect(columnKind('timestamptz', const []), 'datetime');
      expect(columnKind('boolean', const []), 'boolean');
      expect(columnKind('interval', const []), 'text', reason: 'starts with "int" but is not a number');
      expect(columnKind('varchar', ['1', '2']), 'text');
      expect(columnKind(null, ['1', 2.5, '3']), 'number');
      expect(columnKind(null, ['2026-11-01', '2026-11-02 10:00:00']), 'datetime');
      expect(columnKind('oid:1234', [true, false]), 'boolean');
      expect(columnKind('text', ['1'], given: 'number'), 'number');
      expect(columnKind(null, const []), 'text');
    });
  });

  group('chart mapping', () {
    final r = result(
      [
        {'name': 'day', 'type': 'date'},
        {'name': 'total', 'type': 'numeric'},
        {'name': 'orders', 'type': 'int8'},
        {'name': 'note', 'type': 'text'},
      ],
      [
        ['2026-11-01', '10.5', 3, 'a'],
        ['2026-11-02', 20, '4', 'b'],
        ['2026-11-03', null, 'x', 'c'],
      ],
    );

    test('y candidates are the numeric columns only; x takes any', () {
      expect([for (final c in chartYCandidates(r.columns)) c.name], ['total', 'orders']);
      expect(chartXCandidates(r.columns).length, 4);
    });

    test('suggestions: x = first non-numeric, y = numeric others; stat = first numeric', () {
      final line = suggestChart('line', r.columns);
      expect(line.x, 'day');
      expect(line.y, ['total', 'orders']);
      expect(suggestChart('stat', r.columns).y, ['total']);
      expect(suggestChart('table', r.columns).type, 'table');
    });

    test('bar/line: labels from x, numbers parsed from strings, bad cells null', () {
      final d = ChartData.build(r, const DbChartConfig.of('bar', x: 'day', y: ['total', 'orders']));
      expect(d.ok, isTrue);
      expect(d.labels, ['2026-11-01', '2026-11-02', '2026-11-03']);
      expect(d.series[0].values, [10.5, 20, null]);
      expect(d.series[1].values, [3, 4, null]);
    });

    test('stat: the named (else first numeric) column of the first row', () {
      expect(ChartData.build(r, const DbChartConfig.of('stat', y: ['orders'])).stat, '3');
      final d = ChartData.build(r, const DbChartConfig.of('stat'));
      expect((d.stat, d.statLabel), ('10.5', 'total'));
    });

    test('problems: no rows, missing columns, no numeric column', () {
      expect(ChartData.build(result([{'name': 'a', 'type': 'int4'}], []), const DbChartConfig.of('bar', x: 'a', y: ['a'])).problem, ChartProblem.noRows);
      expect(ChartData.build(r, const DbChartConfig.of('line', x: 'gone', y: ['total'])).problem, ChartProblem.missingColumns);
      expect(ChartData.build(r, const DbChartConfig.of('line', x: 'day', y: ['gone'])).problem, ChartProblem.missingColumns);
      final text = result([{'name': 'a', 'type': 'text'}], [['x']]);
      expect(ChartData.build(text, const DbChartConfig.of('stat')).problem, ChartProblem.noNumeric);
      expect(ChartData.build(r, const DbChartConfig.table()).type, 'table');
    });

    test('at most 40 points are drawn', () {
      final big = result([{'name': 'i', 'type': 'int4'}], [for (var i = 0; i < 100; i++) [i]]);
      expect(ChartData.build(big, const DbChartConfig.of('line', x: 'i', y: ['i'])).labels.length, ChartData.maxPoints);
    });

    test('chart config json: stat has no x; table has nothing', () {
      expect(const DbChartConfig.of('bar', x: 'a', y: ['b']).toJson(), {'type': 'bar', 'x': 'a', 'y': ['b']});
      expect(const DbChartConfig.of('stat', y: ['b']).toJson(), {'type': 'stat', 'y': ['b']});
      expect(const DbChartConfig.table().toJson(), {'type': 'table'});
      expect(DbSavedQuery({'id': 'q-1', 'connectionId': 'c', 'name': 'n', 'sql': 's', 'chart': {'type': 'weird'}}).chart.type, 'table');
    });
  });

  group('csv export', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tiphys-csv'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('row counter: header excluded, quoted newlines and a missing final newline', () {
      final c = CsvRowCounter()..add(utf8.encode('\u{FEFF}a,b\r\n1,"x\ny"\r\n2,3'));
      expect(c.rows, 2);
      final empty = CsvRowCounter()..add(utf8.encode('a,b\r\n'));
      expect(empty.rows, 0);
    });

    test('streams chunks into the file and counts rows without trailers', () async {
      final out = await exportCsvToFile(
        dir: dir,
        name: 'x.csv',
        fetch: (onData) async {
          onData(utf8.encode('id\r\n1\r\n'));
          onData(utf8.encode('2\r\n'));
          return {};
        },
      );
      expect(out.rows, 2);
      expect(out.truncated, isFalse);
      expect(out.file.readAsStringSync(), 'id\r\n1\r\n2\r\n');
      expect(out.bytes, 10);
    });

    test('trailer headers win; exactly 100000 rows counts as possibly truncated', () async {
      final a = await exportCsvToFile(dir: dir, name: 'a.csv', fetch: (d) async => {'x-tiphys-rows': '42', 'x-tiphys-truncated': 'true'});
      expect((a.rows, a.truncated), (42, true));
      final b = await exportCsvToFile(dir: dir, name: 'b.csv', fetch: (d) async => {'x-tiphys-rows': '$dbCsvMaxRows'});
      expect(b.truncated, isTrue);
    });

    test('a failure removes the partial file and rethrows', () async {
      await expectLater(
        exportCsvToFile(
          dir: dir,
          name: 'f.csv',
          fetch: (onData) async {
            onData(utf8.encode('id\r\n1\r\n'));
            throw const AgentError('net.unreachable');
          },
        ),
        throwsA(isA<AgentError>()),
      );
      expect(File('${dir.path}/f.csv').existsSync(), isFalse);
    });

    test('file names are safe', () {
      expect(csvFileName('shop db/1', DateTime(2026, 11, 14, 9, 5)), 'shop_db_1-20261114-0905.csv');
    });
  });

  group('write flow', () {
    var now = DateTime(2026, 11, 14, 14, 5);
    final calls = <String>[];
    Object? commitError;
    Map<String, dynamic> preview({int count = 3, String kind = 'dml', int ttl = 118}) => {
          'kind': kind,
          'statement': kind == 'ddl' ? 'create table' : 'update',
          'count': kind == 'ddl' ? null : count,
          'sample': {'columns': [{'name': 'id'}], 'rows': [[1], [2]]},
          'credential': 'write',
          'warnings': ['readCredentialUsed'],
          'previewToken': 'tok-${calls.length}',
          'expiresAt': now.add(Duration(seconds: ttl)).toUtc().toIso8601String(),
        };
    var count = 3;
    WriteFlow flow() => WriteFlow(
          previewFn: (sql) async {
            calls.add('preview:$sql');
            return preview(count: count);
          },
          commitFn: (token) async {
            calls.add('commit:$token');
            if (commitError != null) throw commitError!;
            return {'committed': true, 'count': count};
          },
          clock: () => now,
        );

    setUp(() {
      now = DateTime(2026, 11, 14, 14, 5);
      calls.clear();
      commitError = null;
      count = 3;
    });

    test('preview → ready → commit → done', () async {
      final f = flow();
      expect(f.stage, WriteStage.idle);
      await f.run('UPDATE t SET a = 1');
      expect(f.stage, WriteStage.ready);
      expect(f.preview!.count, 3);
      expect(f.preview!.sampleRows.length, 2);
      expect(f.preview!.warnings, ['readCredentialUsed']);
      expect(f.canCommit, isTrue);
      await f.confirm();
      expect(f.stage, WriteStage.done);
      expect(f.committed, 3);
      expect(calls, ['preview:UPDATE t SET a = 1', 'commit:tok-1']);
      await f.confirm();
      expect(calls.length, 2, reason: 'a second confirm does nothing');
    });

    test('a preview error ends in failed; run again recovers', () async {
      final f = WriteFlow(previewFn: (s) async => throw const AgentError('agent.db.ddlNotPreviewable', {'keyword': 'create'}, 400), commitFn: (t) async => {}, clock: () => now);
      await f.run('CREATE TABLE x (a int)');
      expect(f.stage, WriteStage.failed);
      expect((f.error as AgentError).code, 'agent.db.ddlNotPreviewable');
      expect(f.canCommit, isFalse);
    });

    test('zero rows cannot be committed; DDL (count null) can', () async {
      count = 0;
      final f = flow();
      await f.run('UPDATE t SET a = 1');
      expect(f.stage, WriteStage.ready);
      expect(f.canCommit, isFalse);
      final ddl = WriteFlow(previewFn: (s) async => preview(kind: 'ddl'), commitFn: (t) async => {'committed': true, 'count': null}, clock: () => now);
      await ddl.run('CREATE TABLE x (a int)');
      expect(ddl.preview!.isDdl, isTrue);
      expect(ddl.canCommit, isTrue);
      await ddl.confirm();
      expect((ddl.stage, ddl.committed), (WriteStage.done, null));
    });

    test('countChanged: nothing applied, expected/actual kept, re-preview gives a new token', () async {
      final f = flow();
      await f.run('DELETE FROM t');
      commitError = const AgentError('agent.db.countChanged', {'expected': 3, 'actual': 4}, 409);
      await f.confirm();
      expect(f.stage, WriteStage.countChanged);
      expect((f.expected, f.actual), (3, 4));
      expect(f.canCommit, isFalse);
      commitError = null;
      count = 4;
      await f.rePreview();
      expect(f.stage, WriteStage.ready);
      expect(f.preview!.count, 4);
      expect(f.expected, isNull);
      await f.confirm();
      expect(f.stage, WriteStage.done);
      expect(calls, ['preview:DELETE FROM t', 'commit:tok-1', 'preview:DELETE FROM t', 'commit:tok-3']);
    });

    test('expiry: the countdown runs out → expired, and no token is sent', () async {
      final f = flow();
      await f.run('UPDATE t SET a = 1');
      expect(f.preview!.remaining(now), const Duration(seconds: 118));
      now = now.add(const Duration(seconds: 117));
      f.tick();
      expect(f.stage, WriteStage.ready);
      now = now.add(const Duration(seconds: 2));
      f.tick();
      expect(f.stage, WriteStage.expired);
      expect(f.canCommit, isFalse);
      await f.confirm();
      expect(calls, ['preview:UPDATE t SET a = 1'], reason: 'no commit sent');
      await f.rePreview();
      expect(f.stage, WriteStage.ready);
    });

    test('confirm after the deadline (no tick yet) becomes expired without a call', () async {
      final f = flow();
      await f.run('UPDATE t SET a = 1');
      now = now.add(const Duration(seconds: 130));
      await f.confirm();
      expect(f.stage, WriteStage.expired);
      expect(calls.length, 1);
    });

    test('agent.preview.invalid → expired; rate limit keeps ready (token not spent); other errors → failed', () async {
      final f = flow();
      await f.run('UPDATE t SET a = 1');
      commitError = const AgentError('agent.db.writeRateLimited', {'perTenMinutes': 10}, 429);
      await f.confirm();
      expect(f.stage, WriteStage.ready);
      expect(f.canCommit, isTrue);
      expect((f.error as AgentError).code, 'agent.db.writeRateLimited');
      commitError = const AgentError('agent.preview.invalid', {}, 409);
      await f.confirm();
      expect(f.stage, WriteStage.expired);
      await f.rePreview();
      commitError = const AgentError('agent.db.timeout', {}, 504);
      await f.confirm();
      expect(f.stage, WriteStage.failed);
    });

    test('a preview deadline from a skewed clock falls back to the nominal lifetime', () {
      final p = WritePreview({'previewToken': 't', 'expiresAt': now.subtract(const Duration(hours: 2)).toUtc().toIso8601String()}, now);
      expect(p.expired(now), isFalse);
      expect(p.remaining(now) > Duration.zero, isTrue);
    });
  });

  group('models', () {
    test('connection: credentials without passwords, superuser, labels', () {
      final host = exampleProfile().hosts.first;
      final c = DbConnection(host, {
        'id': 'a',
        'name': 'A',
        'engine': 'postgres',
        'target': {'container': 'argo-db', 'port': 5432},
        'database': 'shop',
        'readCredential': {'mode': 'fromContainerEnv'},
        'writeCredential': {'mode': 'password', 'user': 'rw', 'hasPassword': true},
        'warnings': ['superuserCredential'],
      });
      expect(c.superuser, isTrue);
      expect(c.readCredential!.fromEnv, isTrue);
      expect(c.writeCredential!.hasPassword, isTrue);
      expect(c.targetLabel, 'argo-db:5432');
      expect(c.canWrite, isTrue);
      final s = DbConnection(host, {'id': 's', 'name': 'S', 'engine': 'sqlite', 'target': {'path': '/srv/a.sqlite'}});
      expect((s.targetLabel, s.canWrite, s.readCredential), ('/srv/a.sqlite', false, null));
    });

    test('role sql: statements end with a semicolon; runVia decides the helper', () {
      final r = RoleSql({'role': 'r', 'statements': ['CREATE USER a', 'GRANT SELECT ON *.* TO a;'], 'runVia': 'client'});
      expect(r.text, 'CREATE USER a;\nGRANT SELECT ON *.* TO a;');
      expect(r.viaWriteMode, isFalse);
    });
  });

  group('restore tests', () {
    test('image rule matches the agent: explicit tag, official image of the engine', () {
      expect(validRestoreImage('postgres', 'postgres:16'), isTrue);
      expect(validRestoreImage('postgres', 'postgres:16-alpine'), isTrue);
      expect(validRestoreImage('postgres', 'postgres:latest'), isFalse);
      expect(validRestoreImage('postgres', 'postgres'), isFalse);
      expect(validRestoreImage('postgres', 'mysql:8'), isFalse);
      expect(validRestoreImage('mariadb', 'docker.io/mariadb:11'), isFalse);
      expect(validRestoreImage('postgres', 'postgres:16@sha256:abc'), isFalse);
      expect(restoreFormatsFor('mysql'), isNot(contains('custom')));
      expect(restoreFormatsFor('postgres'), contains('custom'));
    });

    test('list parsing: running, last result, failures, next run', () {
      final d = RestoreTests({
        'running': {'testId': 't1', 'runId': 'r'},
        'tests': [
          {
            'id': 't1', 'name': 'N', 'engine': 'postgres', 'image': 'postgres:16', 'dumpGlob': '~/b/*.gz', 'format': 'gz',
            'sanity': [{'sql': 'SELECT 1', 'expect': {'op': '>', 'value': 0}}],
            'schedule': {'kind': 'daily', 'time': '03:30'}, 'enabled': true, 'running': true,
            'last': {'id': 'r-1', 'ok': false, 'reason': 'sanityFailed', 'failures': [{'index': 0, 'reason': 'expectation', 'actual': 0, 'expected': '> 0'}], 'durations': {'totalMs': 5000}},
            'nextRunAt': '2026-11-15T03:30:00Z',
          },
        ],
      });
      expect(d.anyRunning, isTrue);
      final t = d.tests.single;
      expect((t.running, t.last!.ok, t.last!.reason), (true, false, 'sanityFailed'));
      expect(t.last!.failures.single.expected, '> 0');
      expect(t.sanity.single.op, '>');
      expect(t.nextRunAt, isNotNull);
      expect(RestoreTests({'tests': []}).anyRunning, isFalse);
    });

    test('request body: id only on create; connection null clears on edit; sanity expectations', () {
      Map<String, dynamic> body({required bool editing, String? conn}) => restoreTestBody(
            id: editing ? null : 'nightly',
            name: 'Nightly',
            connectionId: conn,
            engine: 'postgres',
            image: 'postgres:16',
            dumpGlob: '~/b/*.gz',
            format: 'gz',
            sanity: const [SanityCheck('SELECT count(*) FROM t', '>=', 10)],
            schedule: null,
            enabled: true,
            editing: editing,
          );
      final create = body(editing: false);
      expect(create['id'], 'nightly');
      expect(create.containsKey('connectionId'), isFalse);
      expect(create['sanity'], [{'sql': 'SELECT count(*) FROM t', 'expect': {'op': '>=', 'value': 10}}]);
      expect(create['schedule'], isNull);
      final edit = body(editing: true);
      expect(edit.containsKey('id'), isFalse);
      expect(edit.containsKey('connectionId'), isTrue);
      expect(edit['connectionId'], isNull);
      expect(body(editing: true, conn: 'shop')['connectionId'], 'shop');
    });
  });

  group('texts and routing', () {
    late AppLocalizations tr, en;
    setUpAll(() {
      tr = lookupAppLocalizations(const Locale('tr'));
      en = lookupAppLocalizations(const Locale('en'));
    });

    test('agent.db.* errors have specific texts in both languages (no fallback)', () {
      const codes = [
        'agent.db.statementNotAllowed', 'agent.db.multipleStatements', 'agent.db.readOnly', 'agent.db.timeout', 'agent.db.countChanged', 'agent.db.ddlNotPreviewable',
        'agent.db.sqliteUnavailable', 'agent.db.connectionNotFound', 'agent.db.passwordRequired', 'agent.db.containerNotFound', 'agent.db.credentialUnavailable', 'agent.db.unreachable',
        'agent.db.authFailed', 'agent.db.queryFailed', 'agent.db.writeUnsupported', 'agent.db.nonTransactionalTables', 'agent.db.writeRateLimited', 'agent.db.exportRateLimited',
        'agent.db.rateLimited', 'agent.db.busy', 'agent.db.restoreBusy', 'agent.db.restoreTestExists', 'agent.db.restoreEngineMismatch', 'agent.db.sanityNotAllowed', 'agent.db.dumpOutsideRoots',
        'agent.db.restoreTestNotFound', 'agent.db.tableNotFound', 'agent.db.fileNotFound', 'agent.db.queryNotFound', 'agent.db.tooManyQueries', 'agent.db.failed', 'agent.db.permissionDenied',
        'agent.db.emptyStatement', 'agent.db.databaseNotFound', 'agent.db.networkNotFound', 'agent.db.containerNotRunning', 'agent.db.containerNoAddress', 'agent.db.connectionExists',
      ];
      for (final c in codes) {
        for (final l in [tr, en]) {
          final text = agentErrorText(l, AgentError(c, const {'keyword': 'copy', 'expected': 3, 'actual': 4, 'message': 'boom', 'tables': ['a.b (MyISAM)'], 'index': 1}));
          expect(text, isNot(contains('(agent.db')), reason: c);
          expect(text, isNot(startsWith(l.commonError)), reason: c);
        }
      }
      expect(agentErrorText(tr, const AgentError('agent.db.statementNotAllowed', {'keyword': 'copy'})), contains('copy'));
      expect(agentErrorText(en, const AgentError('agent.db.countChanged', {'expected': 3, 'actual': 4})), allOf(contains('3'), contains('4')));
      expect(agentErrorText(en, const AgentError('agent.db.sanityNotAllowed', {'index': 0, 'keyword': 'drop'})), contains('1'));
      expect(agentErrorText(en, const AgentError('agent.db.somethingNew')), contains('agent.db.somethingNew'));
    });

    test('restore reasons: every agent reason has a text; detail is appended', () {
      for (final r in ['noDump', 'dumpOutsideRoots', 'insufficientDisk', 'imageVersionMismatch', 'dockerFailed', 'notReady', 'restoreFailed', 'dumpCorrupt', 'sanityFailed', 'timeout', 'shutdown']) {
        expect(restoreReasonText(en, r), isNot(r));
        expect(restoreReasonText(tr, r), isNot(r));
      }
      expect(restoreReasonText(en, 'restoreFailed', 'ERROR 1064'), endsWith('(ERROR 1064)'));
      expect(restoreNotificationReason(en, 'restoreFailed: ERROR 1064'), endsWith('(ERROR 1064)'));
      expect(restoreNotificationReason(en, 'noDump'), restoreReasonText(en, 'noDump'));
    });

    test('notification texts (TR/EN)', () {
      final ok = noticeText(tr, 'db.restoreTest.ok', {'host': 'argo', 'name': 'Shop nightly'})!;
      expect(ok.$1, contains('argo'));
      expect(ok.$2, 'Shop nightly');
      final bad = noticeText(en, 'db.restoreTest.failed', {'host': 'argo', 'name': 'Shop nightly', 'reason': 'restoreFailed: ERROR 1064'})!;
      expect(bad.$1, contains('failed'));
      expect(bad.$2, allOf(contains('Shop nightly'), contains('ERROR 1064')));
    });

    test('notification payload opens the restore tests with the test highlighted', () {
      final payload = restorePayload('db.restoreTest.failed', {'host': 'argo', 'name': 'Shop nightly'})!;
      expect(routeForPayload(payload), '/db/restore?host=argo&test=Shop+nightly');
      expect(restorePayload('docker.died', {'host': 'argo', 'name': 'x'}), isNull);
      expect(routeForPayload('tiphys://db/restore'), '/db/restore');
    });
  });

  group('§13 review fixes', () {
    test('commit without an answer → unknown: no second commit, no re-preview', () async {
      final now = DateTime(2026, 11, 14, 14, 5);
      final calls = <String>[];
      final f = WriteFlow(
        previewFn: (sql) async {
          calls.add('preview');
          return {'kind': 'dml', 'statement': 'update', 'count': 2, 'previewToken': 'tok', 'expiresAt': now.add(const Duration(minutes: 2)).toUtc().toIso8601String()};
        },
        commitFn: (token) async {
          calls.add('commit');
          throw const AgentError('net.timeout');
        },
        clock: () => now,
      );
      await f.run('UPDATE t SET a = 1');
      await f.confirm();
      expect(f.stage, WriteStage.unknown);
      expect(f.canCommit, isFalse);
      await f.confirm();
      await f.rePreview();
      expect(calls, ['preview', 'commit'], reason: 'nothing is sent again');
      expect(f.stage, WriteStage.unknown);
    });

    test('which errors leave the outcome unknown', () {
      expect(outcomeUnknown(const AgentError('net.timeout')), isTrue);
      expect(outcomeUnknown(const AgentError('net.unreachable')), isTrue);
      expect(outcomeUnknown(const SocketException('reset')), isTrue);
      expect(outcomeUnknown(const AgentError('agent.db.timeout', {}, 504)), isFalse, reason: 'the agent answered: rolled back');
      expect(outcomeUnknown(const AgentError('net.tls')), isFalse);
    });

    test('PostgreSQL read guard state of a connection', () {
      final host = exampleProfile().host('argo')!;
      DbConnection c(Map<String, dynamic> extra) => DbConnection(host, {'id': 'x', 'name': 'x', 'engine': 'postgres', 'target': {'container': 'c'}, 'warnings': ['superuserCredential'], ...extra});
      expect(c({}).superuserReadsBlocked, isTrue);
      expect(c({'readRole': 'tiphys_ro'}).superuserReadsBlocked, isFalse);
      expect(c({'readRole': 'tiphys_ro'}).readRole, 'tiphys_ro');
      expect(c({'allowSuperuserReads': true}).superuserReadsBlocked, isFalse);
      expect(c({'warnings': <String>[]}).superuserReadsBlocked, isFalse);
      expect(c({'engine': 'mysql'}).superuserReadsBlocked, isFalse);
      final tr = lookupAppLocalizations(const Locale('tr'));
      expect(dbErrorText(tr, 'agent.db.superuserReadsDisabled'), contains('okuma sorguları kapalı'));
      expect(dbErrorText(tr, 'agent.db.superuserReadsDisabled', {'readRole': true}), contains('Okuma rolünün kendisi süper kullanıcı'));
    });
  });
}
