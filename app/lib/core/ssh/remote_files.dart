// Uzak dosyalar: SFTP ile listeleme/okuma/yazma; kopyalama ve çöp kutusu SSH komutlarıyla.
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'connection.dart';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isLink,
    required this.size,
    required this.modified,
  });
  final String name;
  final String path;
  final bool isDir;
  final bool isLink;
  final int size;
  final DateTime? modified;
  bool get hidden => name.startsWith('.');
}

class RemoteFiles {
  RemoteFiles(this.conn, this._sftp, this.home);
  final SshConnection conn;
  final SftpClient _sftp;

  /// Ev dizininin mutlak yolu (~ genişletmek için).
  final String home;

  static Future<RemoteFiles> open(SshConnection conn) async {
    final sftp = await conn.sftp();
    final home = await sftp.absolute('.');
    return RemoteFiles(conn, sftp, home);
  }

  String resolve(String path) {
    if (path == '~' || path.isEmpty) return home;
    if (path.startsWith('~/')) return '$home/${path.substring(2)}';
    return path;
  }

  /// Ev dizini altındaki yolları "~/…" olarak gösterir.
  String pretty(String path) => path == home ? '~' : (path.startsWith('$home/') ? '~/${path.substring(home.length + 1)}' : path);

  static String join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  static String parent(String path) {
    if (path == '/' || !path.contains('/')) return '/';
    final p = path.substring(0, path.lastIndexOf('/'));
    return p.isEmpty ? '/' : p;
  }

  /// Klasör içeriği: önce klasörler, sonra dosyalar; ada göre (büyük/küçük harf duyarsız).
  Future<List<RemoteEntry>> list(String path, {bool showHidden = false}) async {
    final dir = resolve(path);
    final names = await _sftp.listdir(dir);
    final out = <RemoteEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      if (!showHidden && n.filename.startsWith('.')) continue;
      var isDir = n.attr.isDirectory;
      final isLink = n.attr.isSymbolicLink;
      if (isLink) {
        try {
          isDir = (await _sftp.stat(join(dir, n.filename))).isDirectory;
        } catch (_) {}
      }
      out.add(RemoteEntry(
        name: n.filename,
        path: join(dir, n.filename),
        isDir: isDir,
        isLink: isLink,
        size: n.attr.size ?? 0,
        modified: n.attr.modifyTime == null ? null : DateTime.fromMillisecondsSinceEpoch(n.attr.modifyTime! * 1000),
      ));
    }
    out.sort((a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<Uint8List> read(String path, {int? maxBytes}) async {
    final f = await _sftp.open(resolve(path));
    try {
      return await f.readBytes(length: maxBytes);
    } finally {
      await f.close();
    }
  }

  Future<void> write(String path, Uint8List data) async {
    final f = await _sftp.open(resolve(path), mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate);
    try {
      await f.writeBytes(data);
    } finally {
      await f.close();
    }
  }

  Future<void> mkdir(String path) => _sftp.mkdir(resolve(path));
  Future<void> rename(String from, String to) => _sftp.rename(resolve(from), resolve(to));

  Future<void> copy(String from, String to) => _run('cp -a -- ${shellQuote(resolve(from))} ${shellQuote(resolve(to))}');

  Future<void> deleteForever(String path) => _run('rm -rf -- ${shellQuote(resolve(path))}');

  /// Freedesktop çöp kutusuna taşır (~/.local/share/Trash); masaüstündeki çöp kutusundan geri alınabilir.
  Future<void> trash(String path) {
    final p = shellQuote(resolve(path));
    return _run('set -e; T="\$HOME/.local/share/Trash"; mkdir -p "\$T/files" "\$T/info"; '
        'src=$p; base=\$(basename -- "\$src"); name="\$base"; i=1; '
        'while [ -e "\$T/files/\$name" ] || [ -e "\$T/info/\$name.trashinfo" ]; do i=\$((i+1)); name="\$base.\$i"; done; '
        r'''printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$(realpath -- "$src")" "$(date +%Y-%m-%dT%H:%M:%S)" > "$T/info/$name.trashinfo"; '''
        'mv -- "\$src" "\$T/files/\$name"');
  }

  Future<void> _run(String cmd) async {
    final r = await conn.exec(cmd);
    if (r.code != 0) throw SshFailure('other', r.stderr.trim().isEmpty ? 'exit ${r.code}' : r.stderr.trim());
  }

  void close() => _sftp.close();
}
