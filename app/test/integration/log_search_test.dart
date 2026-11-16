// Log search on real servers — READ ONLY (journalctl, docker ps, docker logs). Searches for a word common in the
// last 15 minutes; the script must run without errors on both hosts and the results must parse.
// Run: flutter test test/integration/log_search_test.dart --tags real
@Tags(['real'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/core/ssh/connection.dart';
import 'package:tiphys/core/ssh/log_search.dart';

import 'real_env.dart';

void main() {
  late MemorySecretStore secrets;
  setUpAll(() => secrets = MemorySecretStore({'test-key': File(real.sshKey).readAsStringSync()}));

  for (final id in [real.server, real.server2]) {
    test('$id: son 15 dk, sık geçen sözcük; regex özel karakterli desen hata vermez', () async {
      final h = Host(id: id, name: id, address: real.host(id), ssh: SshConfig(user: real.sshUser, auth: const SshKeyAuth('secret:test-key')));
      final conn = await SshConnection.open(h, secrets, knownHosts: MemoryKnownHosts());
      try {
        const q = LogQuery(pattern: 'a', since: Duration(minutes: 15), journalLimit: 50, dockerLimit: 5);
        final sw = Stopwatch()..start();
        final r = await searchHostLogs(conn, id, q);
        expect(r.journalErrors, isEmpty, reason: r.journalErrors.join('\n'));
        expect(r.dockerError, isNull);
        expect(r.dockerMissing, isFalse);
        expect(r.userOnly, isFalse); // the user is in the adm group on the servers
        expect(r.hits, isNotEmpty);
        expect(r.hits.every((x) => x.time != null && x.source.isNotEmpty), isTrue);
        expect(r.hits.where((x) => x.kind == 'journal').length, lessThanOrEqualTo(100));
        final sources = {for (final x in r.hits) '${x.kind}:${x.source}'};
        // ignore: avoid_print
        print('$id: ${r.hits.length} eşleşme, ${sw.elapsedMilliseconds} ms, ${sources.length} kaynak (journal ${r.hits.where((x) => x.kind == 'journal').length}, docker ${r.hits.where((x) => x.kind == 'docker').length})');

        // Escaping: regex/shell special characters must not cause errors (no match expected).
        final odd = await searchHostLogs(conn, id, const LogQuery(pattern: r"z(q[*.$'`\ ?|{", since: Duration(minutes: 15)));
        expect(odd.journalErrors, isEmpty, reason: odd.journalErrors.join('\n'));
        expect(odd.hits, isEmpty);
      } finally {
        conn.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
