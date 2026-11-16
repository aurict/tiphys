// Transfer list: pause → resume where it left off, connection error/stall → resume, cancel → partial file
// deleted, folder archive → downloaded and the remote temp archive deleted. (SFTP side on a real server in
// ssh_test.dart.)
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/ssh/remote_files.dart';
import 'package:tiphys/features/files/transfers.dart';

/// In-memory byte arrays instead of a remote server; each chunk is 1000 bytes, 5 ms between chunks.
/// Each `connect` is a separate connection; `dispose` drops only that connection (an ongoing read errors).
class FakeRemote {
  final remote = <String, List<int>>{};
  final discarded = <String>[];
  final readOffsets = <int>[];
  int failAfter = -1; // the connection drops after this many chunks
  int stallAfter = -1; // no data after this many chunks (connection open but stalled)
  int connections = 0;
  int disposed = 0;

  RemoteFiles connect() {
    connections++;
    return _Conn(this);
  }
}

class _Conn implements RemoteFiles {
  _Conn(this.s);
  final FakeRemote s;
  bool _dead = false;

  @override
  void dispose() {
    if (!_dead) s.disposed++;
    _dead = true;
  }

  @override
  Future<bool> download(String path, File local, {required void Function(int, int) onProgress, required bool Function() stop}) async {
    final data = s.remote[path]!;
    var start = local.existsSync() ? local.lengthSync() : 0;
    s.readOffsets.add(start);
    onProgress(start, data.length);
    var chunks = 0;
    while (start < data.length) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (_dead) throw const SocketException('bağlantı kapatıldı');
      if (s.stallAfter >= 0 && chunks >= s.stallAfter) {
        while (!_dead) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        s.stallAfter = -1;
        throw const SocketException('bağlantı kapatıldı');
      }
      if (s.failAfter >= 0 && chunks >= s.failAfter) {
        s.failAfter = -1;
        throw const SocketException('bağlantı koptu');
      }
      chunks++;
      final end = (start + 1000).clamp(0, data.length);
      local.writeAsBytesSync(data.sublist(start, end), mode: FileMode.append);
      start = end;
      onProgress(start, data.length);
      if (stop()) return false;
    }
    return true;
  }

  @override
  Future<String> archive(String path, String base) async {
    s.remote['$base.zip'] = List.filled(2500, 1);
    return '$base.zip';
  }

  @override
  Future<void> discardArchive(String base) async => s.discarded.add(base);

  @override
  String resolve(String path) => path;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const host = Host(id: 'atlas', name: 'atlas', address: 'atlas');

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ok(), isTrue);
}

void main() {
  late Directory dir;
  late FakeRemote remote;
  late ProviderContainer c;
  late Transfers n;

  Transfers fresh() {
    c = ProviderContainer();
    return c.read(transfersProvider.notifier)
      ..downloadsDir = (() async => dir)
      ..openFiles = ((_) async => remote.connect());
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tiphys-transfers');
    remote = FakeRemote()
      ..remote['/srv/veri.bin'] = List.generate(10500, (i) => i & 0xff)
      ..remote['/srv/b/veri.bin'] = List.filled(3000, 7);
    n = fresh();
  });
  tearDown(() {
    c.dispose();
    dir.deleteSync(recursive: true);
  });

  RemoteEntry entry([String path = '/srv/veri.bin', int size = 10500]) =>
      RemoteEntry(name: 'veri.bin', path: path, isDir: false, isLink: false, size: size, modified: DateTime(2026, 11, 14));

  test('duraklat → devam: kaldığı bayttan sürer; her çalışma kendi bağlantısını açıp kapatır', () async {
    final t = n.download(host, entry());
    await until(() => t.done >= 3000);
    n.pause(t);
    expect(t.state, TransferState.paused); // hemen
    await until(() => remote.disposed == 1); // pausing closed the connection
    final pausedAt = File(Directory('${dir.path}/.partial').listSync().single.path).lengthSync();
    n.resume(t);
    await until(() => t.state == TransferState.done);
    expect(remote.readOffsets, [0, pausedAt]);
    expect(pausedAt, greaterThanOrEqualTo(3000));
    expect(t.local!.readAsBytesSync(), remote.remote['/srv/veri.bin']);
    expect(Directory('${dir.path}/.partial').listSync(), isEmpty); // partial file moved to the target
    expect(remote.connections, 2);
  });

  test('bağlantı koparsa "kesildi" olur; devam edince parçadan sürer', () async {
    remote.failAfter = 4;
    final t = n.download(host, entry());
    await until(() => t.state == TransferState.failed);
    expect(t.done, 4000);
    n.resume(t);
    await until(() => t.state == TransferState.done);
    expect(remote.readOffsets, [0, 4000]);
    expect(t.local!.readAsBytesSync(), remote.remote['/srv/veri.bin']);
  });

  test('takılan bağlantı: veri gelmezse bekçi bağlantıyı kapatır, "kesildi" olur, devam edilebilir', () async {
    n.stallAfter = const Duration(milliseconds: 90);
    remote.stallAfter = 3;
    final t = n.download(host, entry());
    await until(() => t.state == TransferState.failed);
    expect(t.error, isA<TransferStalled>());
    expect(t.done, 3000);
    n.resume(t);
    await until(() => t.state == TransferState.done);
    expect(t.local!.readAsBytesSync(), remote.remote['/srv/veri.bin']);
  });

  test('takılan bağlantıda duraklatma hemen işler (bağlantı kapatılır)', () async {
    remote.stallAfter = 2;
    final t = n.download(host, entry());
    await until(() => t.done == 2000);
    await Future<void>.delayed(const Duration(milliseconds: 30)); // stalled
    n.pause(t);
    await until(() => remote.disposed >= 1);
    await Future<void>.delayed(const Duration(milliseconds: 30)); // the run ends with an error
    expect(t.state, TransferState.paused);
    expect(t.error, isNull);
  });

  test('aynı dosya ikinci kez istenirse yeni aktarım açılmaz, mevcut olan sürer', () async {
    final first = n.download(host, entry());
    await until(() => first.done >= 2000);
    n.pause(first);
    final again = n.download(host, entry());
    expect(again, same(first));
    expect(c.read(transfersProvider), hasLength(1));
    await until(() => first.state == TransferState.done);
    expect(first.local!.readAsBytesSync(), remote.remote['/srv/veri.bin']);
  });

  test('uygulama yeniden açılınca aynı dosya yarım parçadan devam eder', () async {
    final first = n.download(host, entry());
    await until(() => first.done >= 2000);
    n.pause(first);
    await until(() => remote.disposed == 1);
    final pausedAt = File(Directory('${dir.path}/.partial').listSync().single.path).lengthSync();
    c.dispose();
    n = fresh(); // list is in memory: reopening
    final second = n.download(host, entry());
    await until(() => second.state == TransferState.done);
    expect(remote.readOffsets.last, pausedAt);
    expect(second.local!.readAsBytesSync(), remote.remote['/srv/veri.bin']);
  });

  test('farklı klasörlerdeki aynı adlı dosyalar birbirinin üzerine inmez', () async {
    final a = n.download(host, entry());
    final b = n.download(host, entry('/srv/b/veri.bin', 3000));
    await until(() => a.state == TransferState.done && b.state == TransferState.done);
    expect(a.local!.path, isNot(b.local!.path));
    expect(a.local!.lengthSync(), 10500);
    expect(b.local!.lengthSync(), 3000);
    await n.clearFinished();
    expect(a.local!.existsSync() || b.local!.existsSync(), isFalse);
  });

  test('iptal: listeden çıkar, yarım parça silinir', () async {
    final t = n.download(host, entry());
    await until(() => t.done >= 2000);
    n.pause(t);
    await until(() => remote.disposed == 1);
    expect(Directory('${dir.path}/.partial').listSync(), hasLength(1));
    await n.cancel(t);
    expect(c.read(transfersProvider), isEmpty);
    expect(Directory('${dir.path}/.partial').listSync(), isEmpty);
  });

  test('klasör: uzakta arşivlenir, arşiv indirilir, geçici arşiv temizlenir', () async {
    final t = n.downloadFolder(host, const RemoteEntry(name: 'proje', path: '/srv/proje', isDir: true, isLink: false, size: 0, modified: null));
    await until(() => t.state == TransferState.done);
    expect(t.name, 'proje.zip');
    expect(t.local!.lengthSync(), 2500);
    expect(remote.discarded.single, matches(RegExp(r'^/tmp/tiphys-\d+-proje$')));
  });

  test('yarım parça anahtarı: dosya değişince (boyut/tarih) farklı parça', () {
    final a = partialKey('h', '/x', 10, DateTime(2026));
    expect(partialKey('h', '/x', 10, DateTime(2026)), a);
    expect(partialKey('h', '/x', 11, DateTime(2026)), isNot(a));
    expect(partialKey('h', '/x', 10, DateTime(2027)), isNot(a));
  });

  // The share sheet can't open in tests (no plugin); that must not fail the transfer.
  test('paylaşım hatası aktarımı bozmaz', () async {
    final t = n.download(host, entry());
    await until(() => t.state == TransferState.done);
    expect(t.error, isNull);
  });
}
