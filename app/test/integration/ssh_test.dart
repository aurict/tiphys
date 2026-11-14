// Gerçek sunuculara karşı SSH/SFTP testleri (PC'den çalışır, Tailscale gerekir).
// Çalıştırma: flutter test test/integration --tags real
// Anahtar: TIPHYS_TEST_KEY (varsayılan real-test.json sshKey), kullanıcı real-test.json sshUser.
@Tags(['real'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/secrets/secret_store.dart';
import 'package:tiphys/core/ssh/connection.dart';
import 'package:tiphys/core/ssh/keys.dart';
import 'package:tiphys/core/ssh/remote_files.dart';

import 'real_env.dart';

final keyPath = Platform.environment['TIPHYS_TEST_KEY'] ?? real.sshKey;

Host server(String id, String address) => Host(
      id: id,
      name: id,
      address: address,
      ssh: SshConfig(user: real.sshUser, auth: const SshKeyAuth('secret:test-key'), tmuxSession: 'tiphys-test'),
    );

final home = Platform.environment['HOME']!;

void main() {
  late MemorySecretStore secrets;
  setUpAll(() {
    secrets = MemorySecretStore({'test-key': File(keyPath).readAsStringSync()});
  });

  for (final (id, addr) in [(real.server, real.host(real.server)), (real.server2, real.host(real.server2))]) {
    group(id, () {
      late SshConnection conn;
      setUpAll(() async => conn = await SshConnection.open(server(id, addr), secrets, knownHosts: MemoryKnownHosts()));
      tearDownAll(() => conn.close());

      test('komut çalıştırma', () async {
        final r = await conn.exec('echo tiphys-\$((40+2)); hostname');
        expect(r.code, 0);
        expect(r.stdout, contains('tiphys-42'));
        expect(r.stdout.trim().split('\n').last, id);
      });

      test('tmux kabuğu: yazılanı geri okur, oturum kopunca yaşar', () async {
        final shell = await conn.shell(cols: 80, rows: 24, startDir: '/tmp');
        final buf = StringBuffer();
        final sub = shell.stdout.listen((d) => buf.write(utf8.decode(d, allowMalformed: true)));
        await Future<void>.delayed(const Duration(seconds: 2));
        shell.write(Uint8List.fromList(utf8.encode('echo "MARK-\$(pwd)"\r')));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!buf.toString().contains('MARK-/tmp') && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(buf.toString(), contains('MARK-/tmp'));
        await sub.cancel();
        shell.close();
        final ls = await conn.exec('tmux ls');
        expect(ls.stdout, contains('tiphys-test'));
        await conn.exec('tmux kill-session -t tiphys-test');
      });

      test('SFTP: yaz, oku, listele, kopyala, yeniden adlandır, çöp kutusu', () async {
        final files = await RemoteFiles.open(conn);
        final dir = '~/tiphys-test-${DateTime.now().millisecondsSinceEpoch}';
        await files.mkdir(dir);
        final data = Uint8List.fromList(utf8.encode('merhaba dünya ğüşıöç\n'));
        await files.write('$dir/a.txt', data);
        expect(utf8.decode(await files.read('$dir/a.txt')), 'merhaba dünya ğüşıöç\n');
        await files.copy('$dir/a.txt', '$dir/b.txt');
        await files.rename('$dir/b.txt', "$dir/c d'e.txt");
        await files.mkdir('$dir/alt');
        final list = await files.list(dir);
        expect(list.map((e) => e.name), ['alt', 'a.txt', "c d'e.txt"]);
        expect(list.first.isDir, isTrue);
        expect(list[1].size, data.length);
        await files.trash("$dir/c d'e.txt");
        final trashed = await conn.exec('ls ~/.local/share/Trash/files/ | grep -c "c d.e.txt"; grep -l "tiphys-test" ~/.local/share/Trash/info/*.trashinfo | wc -l');
        expect(trashed.stdout.trim().split('\n').first, isNot('0'));
        expect(files.pretty(files.resolve(dir)), dir);
        await files.deleteForever(dir);
        await conn.exec(r'rm -f ~/.local/share/Trash/files/c\ d*e.txt*; grep -l tiphys-test ~/.local/share/Trash/info/*.trashinfo | xargs -r rm -f');
        files.close();
      });
    });
  }

  test('telefonda üretilen anahtar: sunucuya eklenir, onunla bağlanılır, sonra kaldırılır', () async {
    final key = await generateEd25519('tiphys-test-${DateTime.now().millisecondsSinceEpoch}');
    expect(key.publicLine, startsWith('ssh-ed25519 AAAA'));
    // Üretilen PEM tekrar okunabilmeli.
    expect(parsePrivateKey(key.unencryptedPem).publicLine.split(' ').take(2), key.publicLine.split(' ').take(2));

    final admin = await SshConnection.open(server(real.server, real.host(real.server)), secrets);
    final r = await admin.exec(installKeyCommand(key.publicLine));
    expect(r.stdout, contains('TIPHYS_KEY_OK'));
    // İkinci kez eklemek satırı çoğaltmaz.
    await admin.exec(installKeyCommand(key.publicLine));
    final count = await admin.exec('grep -cF ${shellQuote(key.publicLine)} ~/.ssh/authorized_keys');
    expect(count.stdout.trim(), '1');
    try {
      final store = MemorySecretStore({'test-key': key.unencryptedPem});
      final c2 = await SshConnection.open(server(real.server, real.host(real.server)), store);
      expect((await c2.exec('echo ok')).stdout.trim(), 'ok');
      c2.close();
    } finally {
      final comment = key.publicLine.split(' ').last;
      await admin.exec("sed -i '/$comment\$/d' ~/.ssh/authorized_keys");
      final left = await admin.exec('grep -c $comment ~/.ssh/authorized_keys || true');
      expect(left.stdout.trim(), '0');
      admin.close();
    }
  });

  test('bilinen sunucu anahtarı değişirse bağlantı reddedilir', () async {
    final known = MemoryKnownHosts();
    final h = server(real.server, real.host(real.server));
    (await SshConnection.open(h, secrets, knownHosts: known)).close();
    known.m[known.m.keys.single] = 'ssh-ed25519 00:11:22';
    await expectLater(
      SshConnection.open(h, secrets, knownHosts: known),
      throwsA(isA<SshFailure>().having((f) => f.code, 'code', anyOf('hostKeyChanged', 'other'))),
    );
  });

  test('yanlış anahtar → auth hatası', () async {
    final key = await generateEd25519('kimsenin-degil');
    final store = MemorySecretStore({'test-key': key.unencryptedPem});
    await expectLater(
      SshConnection.open(server(real.server, real.host(real.server)), store),
      throwsA(isA<SshFailure>().having((f) => f.code, 'code', 'auth')),
    );
  });

  test('erişilemeyen host → unreachable/timeout', () async {
    await expectLater(
      SshConnection.open(server('yok', '100.64.0.250'), secrets, timeout: const Duration(seconds: 3)),
      throwsA(isA<SshFailure>().having((f) => f.code, 'code', anyOf('unreachable', 'timeout'))),
    );
  });

  test('PC (yerel): tmux yokken giriş kabuğuna düşer', () async {
    final key = await generateEd25519('tiphys-test-local-${DateTime.now().millisecondsSinceEpoch}');
    final ak = File('$home/.ssh/authorized_keys');
    final before = ak.readAsStringSync();
    ak.writeAsStringSync('${before.endsWith('\n') || before.isEmpty ? before : '$before\n'}${key.publicLine}\n');
    try {
      final h = Host(
        id: real.pc,
        name: real.pc,
        address: real.host(real.pc),
        ssh: SshConfig(user: Platform.environment['USER']!, auth: const SshKeyAuth('secret:k')),
      );
      final conn = await SshConnection.open(h, MemorySecretStore({'k': key.unencryptedPem}));
      final shell = await conn.shell(cols: 80, rows: 24, startDir: '~/Desktop');
      final buf = StringBuffer();
      final sub = shell.stdout.listen((d) => buf.write(utf8.decode(d, allowMalformed: true)));
      await Future<void>.delayed(const Duration(seconds: 2));
      shell.write(Uint8List.fromList(utf8.encode('echo "LOCAL-\$(pwd)"\r')));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!buf.toString().contains('LOCAL-$home/Desktop') && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(buf.toString(), contains('LOCAL-$home/Desktop'));
      await sub.cancel();
      shell.close();
      conn.close();
    } finally {
      ak.writeAsStringSync(before);
      expect(ak.readAsStringSync(), before);
    }
  });
}
