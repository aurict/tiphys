// Log search: PCRE escaping, the script carrying the pattern safely (local sh with fake journalctl/docker), output
// parsing, merging, highlighting and the "Claude'a sor" message. No network access.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/ssh/log_search.dart';
import 'package:tiphys/features/system/log_search.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

String _j(Map<String, Object?> m) => jsonEncode(m);

/// Entry in journalctl -o json format.
String journalLine({required String cursor, required int sec, required String msg, String? unit, String? userUnit, String? ident, int prio = 6}) => _j({
      '__CURSOR': cursor,
      '__REALTIME_TIMESTAMP': '${DateTime.utc(2026, 11, 14, 10, 0, sec).microsecondsSinceEpoch}',
      'MESSAGE': msg,
      'PRIORITY': '$prio',
      '_SYSTEMD_UNIT': ?unit,
      '_SYSTEMD_USER_UNIT': ?userUnit,
      'SYSLOG_IDENTIFIER': ?ident,
    });

void main() {
  group('pcreEscape', () {
    test('özel karakterler kaçışlanır, harf/rakam/boşluk/Türkçe dokunulmaz', () {
      expect(pcreEscape(r'a.b*c+d?e|f^g$h\i(j)k[l]m{n}o/p#q-r'), r'a\.b\*c\+d\?e\|f\^g\$h\\i\(j\)k\[l\]m\{n\}o\/p\#q\-r');
      expect(pcreEscape('Bağlantı reddedildi 502'), 'Bağlantı reddedildi 502');
      expect(pcreEscape(''), '');
    });

    test('kaçışlı desen yalnız metnin kendisiyle eşleşir (regex olarak yorumlanmaz)', () {
      for (final s in [r'error (code 5)', r'a.b', r'x*', r'[warn]', r'$HOME/\d+', r'c++ {1,2}', r'a|b', r'50%', 'çğış.?']) {
        final re = RegExp(pcreEscape(s));
        expect(re.hasMatch('önce $s sonra'), isTrue, reason: s);
        expect(re.firstMatch('önce $s sonra')![0], s, reason: s);
      }
      expect(RegExp(pcreEscape('a.b')).hasMatch('axb'), isFalse);
      expect(RegExp(pcreEscape('x*')).hasMatch('y'), isFalse);
      expect(RegExp(pcreEscape('a|b')).hasMatch('a'), isFalse);
    });

    test('desen tek satıra indirilir', () {
      expect(normalizeLogPattern('  a\nb\tc\r\n '), 'a b c');
      expect(normalizeLogPattern(' \n '), '');
    });
  });

  group('betik (yerel sh, sahte journalctl/docker)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('tiphys-logsearch');
      final bin = Directory('${dir.path}/bin')..createSync();
      void tool(String name, String body) {
        final f = File('${bin.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['+x', f.path]);
      }

      // Writes the arguments to a file line by line; on the -n 0 call (permission check) prints the hint.
      tool('journalctl', '''
for a in "\$@"; do printf '%s\\n' "\$a"; done >> "${dir.path}/journal-args"
echo '--' >> "${dir.path}/journal-args"
case " \$* " in *" -n 0 "*) echo 'Hint: You are currently not seeing messages from other users and the system.' >&2; exit 0;; esac
case " \$* " in *" --user "*) echo '{"__CURSOR":"u1","__REALTIME_TIMESTAMP":"1794650400000000","MESSAGE":"user hit","_SYSTEMD_USER_UNIT":"tiphys-agent.service"}';;
  *) echo '{"__CURSOR":"s1","__REALTIME_TIMESTAMP":"1794650401000000","MESSAGE":"sys hit","SYSLOG_IDENTIFIER":"sshd"}';; esac''');
      tool('docker', '''
if [ "\$1" = ps ]; then printf 'web\\ndb\\n'; exit 0; fi
printf '%s\\n' "\$@" >> "${dir.path}/docker-args"
echo '2026-11-14T10:00:02.123456789Z first line'
echo '2026-11-14T10:00:03.000000001Z it'"'"'s \$HOME; `id` a.b* matched'
echo '2026-11-14T10:00:04Z other'
''');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String> run(LogQuery q) async {
      final r = await Process.run('sh', ['-c', logSearchCommand(q)], environment: {'PATH': '${dir.path}/bin:/usr/bin:/bin'});
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return r.stdout as String;
    }

    test('kabuk/regex özel karakterli desen tek argüman olarak ve birebir ulaşır', () async {
      const pattern = r"it's $HOME; `id` a.b*";
      final out = await run(const LogQuery(pattern: pattern, since: Duration(minutes: 15)));
      final jargs = File('${dir.path}/journal-args').readAsStringSync().split('\n');
      // System and user call: the argument after -g is an escaped PCRE with the (?i) prefix.
      final gs = [for (var i = 0; i < jargs.length - 1; i++) if (jargs[i] == '-g') jargs[i + 1]];
      expect(gs, [r"(?i)it's \$HOME; `id` a\.b\*", r"(?i)it's \$HOME; `id` a\.b\*"]);
      expect(jargs, containsAll(['--since=-900s', '-o', 'json', '-n', '200', '--user']));
      final dargs = File('${dir.path}/docker-args').readAsStringSync();
      expect(dargs, contains('--since\n900s\n--timestamps\nweb\n'));
      expect(dargs, contains('\ndb\n'));

      final r = parseLogSearch('argo', out, const LogQuery(pattern: pattern, since: Duration(minutes: 15)));
      expect(r.userOnly, isTrue);
      expect(r.dockerError, isNull);
      // grep -F -i: only lines containing the pattern verbatim, from both containers.
      final docker = r.hits.where((h) => h.kind == 'docker').toList();
      expect(docker.map((h) => h.source), ['web', 'db']);
      expect(docker.first.message, r"it's $HOME; `id` a.b* matched");
      expect(docker.first.time, DateTime.utc(2026, 11, 14, 10, 0, 3).toLocal());
      expect(r.hits.where((h) => h.kind == 'journal').map((h) => h.source), ['sshd', 'tiphys-agent']);
    });

    test('büyük/küçük harf duyarsız (grep -i) ve çıktı sınırı (head -c)', () async {
      final out = await run(const LogQuery(pattern: 'FIRST', since: Duration(hours: 1)));
      final r = parseLogSearch('argo', out, const LogQuery(pattern: 'FIRST', since: Duration(hours: 1)));
      expect(r.hits.where((h) => h.kind == 'docker').map((h) => h.message), ['first line', 'first line']);
      expect(File('${dir.path}/docker-args').readAsStringSync(), contains('3600s'));

      const cut = LogQuery(pattern: 'first', since: Duration(hours: 1), maxBytes: 300);
      final small = await run(cut);
      expect(utf8.encode(small).length, 300);
      expect(parseLogSearch('argo', small, cut).truncated, isTrue);
      expect(parseLogSearch('argo', out, const LogQuery(pattern: 'FIRST', since: Duration(hours: 1))).truncated, isFalse);
    });
  });

  group('ayrıştırma', () {
    const q = LogQuery(pattern: 'timeout', since: Duration(minutes: 15));

    test('journal (sistem + kullanıcı, imleçle tekilleştirme, bayt dizili ileti), docker, notlar', () {
      final out = [
        '@@j system',
        journalLine(cursor: 'a', sec: 5, msg: 'upstream timeout', unit: 'nginx.service', prio: 3),
        journalLine(cursor: 'b', sec: 6, msg: 'Timeout in session', unit: 'session-3.scope', ident: 'sshd'),
        _j({'__CURSOR': 'c', '__REALTIME_TIMESTAMP': '${DateTime.utc(2026, 11, 14, 10, 0, 7).microsecondsSinceEpoch}', 'MESSAGE': utf8.encode('bayt timeout ç'), '_COMM': 'kernel'}),
        '{"__CURSOR":"kesik", "MESS',
        '@@j user',
        journalLine(cursor: 'b', sec: 6, msg: 'Timeout in session', unit: 'session-3.scope', ident: 'sshd'), // duplicate
        journalLine(cursor: 'd', sec: 8, msg: 'agent timeout', unit: 'user@1000.service', userUnit: 'tiphys-agent.service'),
        'Failed to add filter: Invalid argument',
        '@@useronly',
        '@@d web 2026-11-14T10:00:09.5Z GET /api timeout after 30s',
        '@@d web 2026-11-14T10:00:10Z 10:00 timeout', // also appears in the message
        '@@d db 2026-11-14T10:00:11Z nothing here', // had grep matched only in the timestamp: dropped
        '@@dockererr permission denied while trying to connect to the Docker daemon socket',
      ].join('\n');
      final r = parseLogSearch('argo', out, q);
      expect(r.userOnly, isTrue);
      expect(r.truncated, isFalse);
      expect(r.journalErrors, ['Failed to add filter: Invalid argument']);
      expect(r.dockerError, startsWith('permission denied'));
      expect([for (final h in r.hits) (h.kind, h.source, h.message)], [
        ('journal', 'nginx', 'upstream timeout'),
        ('journal', 'sshd', 'Timeout in session'),
        ('journal', 'kernel', 'bayt timeout ç'),
        ('journal', 'tiphys-agent', 'agent timeout'),
        ('docker', 'web', 'GET /api timeout after 30s'),
        ('docker', 'web', '10:00 timeout'),
      ]);
      expect(r.hits.first.priority, 3);
      expect(r.hits.first.time, DateTime.utc(2026, 11, 14, 10, 0, 5).toLocal());
      expect(r.hits[4].time, DateTime.utc(2026, 11, 14, 10, 0, 9, 500).toLocal());
    });

    test('docker yok', () {
      final r = parseLogSearch('orion', '@@j system\n@@j user\n@@nodocker\n', q);
      expect(r.dockerMissing, isTrue);
      expect(r.hits, isEmpty);
    });

    test('zaman damgası: nanosaniye, saat dilimi, bozuk', () {
      expect(parseLogTime('2026-11-14T10:00:00.123456789Z'), DateTime.utc(2026, 11, 14, 10, 0, 0, 123, 456));
      expect(parseLogTime('2026-11-14T13:00:00+03:00'), DateTime.utc(2026, 11, 14, 10));
      expect(parseLogTime('dün'), isNull);
    });

    test('birleştirme: yeniden eskiye, zamansızlar sonda, eşitlikte çıktı sırası korunur', () {
      LogHit h(String host, int? sec, String msg, int seq) =>
          LogHit(hostId: host, kind: 'docker', source: 's', time: sec == null ? null : DateTime(2026, 1, 1, 0, 0, sec), message: msg, seq: seq);
      final merged = mergeLogHits([
        LogSearchResult(hostId: 'a', hits: [h('a', 1, 'a1', 0), h('a', 3, 'a3-ilk', 1), h('a', 3, 'a3-son', 2), h('a', null, 'a?', 3)]),
        LogSearchResult(hostId: 'b', hits: [h('b', 2, 'b2', 0)]),
      ]);
      expect(merged.map((e) => e.message), ['a3-son', 'a3-ilk', 'b2', 'a1', 'a?']);
    });

    test('vurgu aralıkları: büyük/küçük harf duyarsız, regex değil', () {
      expect(logMatchRanges('Timeout ve TIMEOUT ve timeout', 'timeout'), [(0, 7), (11, 18), (22, 29)]);
      expect(logMatchRanges('a.b axb', 'a.b'), [(0, 3)]);
      expect(logMatchRanges('Hata: Şifre yanlış', 'şifre'), [(6, 11)]);
      expect(logMatchRanges('x', ''), isEmpty);
    });
  });

  test("Claude'a sor: hedef satır + aynı host/kaynaktaki önceki eşleşmeler (eskiden yeniye)", () {
    final l = AppLocalizationsTr();
    LogHit h(String host, String src, int sec, String msg) => LogHit(hostId: host, kind: 'journal', source: src, time: DateTime.utc(2026, 11, 14, 10, 0, sec), message: msg);
    final hits = [h('argo', 'nginx', 9, 'son'), h('argo', 'nginx', 8, 'hedef'), h('atlas', 'nginx', 7, 'başka host'), h('argo', 'sshd', 6, 'başka kaynak'), h('argo', 'nginx', 5, 'önce 2'), h('argo', 'nginx', 4, 'önce 1')];
    final p = logSearchClaudePrompt(l, pattern: 'hata', hostName: 'argo (PC)', newestFirst: hits, index: 1);
    expect(p, startsWith(l.logSearchClaudeIntro('argo (PC)', 'nginx', 'hata')));
    expect(p, contains('```\n2026-11-14T10:00:08.000Z hedef\n```'));
    expect(p, contains('${l.logSearchClaudeBefore}\n```\n2026-11-14T10:00:04.000Z önce 1\n2026-11-14T10:00:05.000Z önce 2\n```'));
    expect(p, isNot(contains('başka')));
    expect(p, isNot(contains('son')));
  });
}
