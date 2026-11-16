// Compose stacks on real servers — READ ONLY (ps, config, image inspect, inspect). pull/up/restart/stop are never
// run here: these are production services; flows that change things are tested with the fake shell.
// Run: flutter test test/integration/compose_test.dart --tags real
@Tags(['real'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/core/ssh/compose.dart';
import 'package:tiphys/core/ssh/connection.dart';

import 'real_env.dart';

final real = RealEnv.load();

void main() {
  late MemorySecretStore secrets;
  setUpAll(() => secrets = MemorySecretStore({'test-key': File(real.sshKey).readAsStringSync()}));

  for (final id in [real.server, real.server2]) {
    group(id, () {
      late SshConnection conn;
      setUpAll(() async {
        final h = Host(id: id, name: id, address: real.host(id), ssh: SshConfig(user: real.sshUser, auth: const SshKeyAuth('secret:test-key')));
        conn = await SshConnection.open(h, secrets, knownHosts: MemoryKnownHosts());
      });
      tearDownAll(() => conn.close());

      test('akışlı komut: stdout + stderr parça parça, çıkış kodu', () async {
        final out = StringBuffer();
        final code = await conn.execStreaming('echo bir; sleep 0.2; echo iki >&2; exit 3', out.write, timeout: const Duration(seconds: 20));
        expect(code, 3);
        expect(out.toString(), allOf(contains('bir'), contains('iki')));
      });

      test('~/stack yığınları ve container durumları; tek yığının imaj kimlikleri', () async {
        final l = await listComposeStacks(conn, const ['~/stack']);
        expect(l.home, startsWith('/'));
        expect(l.stacks.length, greaterThanOrEqualTo(3), reason: l.stacks.map((s) => s.name).join(', '));
        final running = l.stacks.where((s) => s.state == 'running' || s.state == 'partial').toList();
        expect(running, isNotEmpty);
        for (final s in l.stacks) {
          expect(composeFileNames, contains(s.file));
          expect(s.dir, startsWith('${l.home}/stack/'));
          for (final c in s.containers) {
            expect(c.service, isNotEmpty);
            expect(c.state, isNotEmpty);
          }
        }
        // ignore: avoid_print
        print('$id: ${[for (final s in l.stacks) '${s.name}(${s.state} ${s.running}/${s.containers.length})'].join(' ')}');

        // Read-only snapshot: service → image, image ID, container image (no pull).
        final stack = running.first;
        final ops = ComposeOps(conn, stack);
        final services = await ops.serviceImages();
        expect(services, isNotEmpty);
        final snap = await ops.snapshot(services.values);
        expect(snap.imageIds.values, everyElement(startsWith('sha256:')));
        expect(snap.containerImages, isNotEmpty);
        // Nothing was pulled, so before/after are equal → no changes.
        final same = ComposeOps.compare(services, snap, snap);
        expect(same.pulled, isEmpty);
        final logs = await ops.logs(tail: 5);
        expect(logs, isNotEmpty);
      });
    });
  }
}
