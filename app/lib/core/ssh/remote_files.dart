// Remote files: listing/reading/writing over SFTP; copying and trash via SSH commands.
import 'dart:io';
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

  /// Absolute path of the home directory (for expanding ~).
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

  /// Shows paths under the home directory as "~/…".
  String pretty(String path) => path == home ? '~' : (path.startsWith('$home/') ? '~/${path.substring(home.length + 1)}' : path);

  static String join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  static String parent(String path) {
    if (path == '/' || !path.contains('/')) return '/';
    final p = path.substring(0, path.lastIndexOf('/'));
    return p.isEmpty ? '/' : p;
  }

  /// Folder contents: folders first, then files; by name (case-insensitive).
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

  /// Downloads a remote file to a local file; if the local file exists, resumes from where it left off (its size).
  /// If [stop] returns true the download stops after that chunk (the local file stays for the next attempt).
  /// If the remote file is shorter than the local one (changed) it starts over. Returns true when done.
  Future<bool> download(String path, File local, {required void Function(int done, int total) onProgress, required bool Function() stop}) async {
    final f = await _sftp.open(resolve(path));
    try {
      final total = (await f.stat()).size ?? 0;
      var start = await local.exists() ? await local.length() : 0;
      if (start > total) {
        await local.writeAsBytes(const [], flush: true);
        start = 0;
      }
      onProgress(start, total);
      final sink = local.openWrite(mode: FileMode.append);
      var done = start;
      try {
        await for (final chunk in f.read(offset: start)) {
          sink.add(chunk);
          done += chunk.length;
          onProgress(done, total);
          if (stop()) return false;
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return done >= total;
    } finally {
      await f.close();
    }
  }

  /// Temporary name of the upload: hidden `.<name>.<size>.tiphys-part` in the target folder. Since the size is in
  /// the name, a different file with the same name isn't taken as a continuation of the partial upload.
  static String uploadPartName(String name, int size) => '.$name.$size.tiphys-part';

  /// Uploads local data to `dir/name`. Writes to a temporary part first; if a partial part exists,
  /// [source] is opened skipping that many bytes and the upload resumes. When done the part is moved over the target.
  /// Stops if [stop] returns true (the part stays). Returns true when done.
  Future<bool> upload(
    String dir,
    String name,
    int size,
    Stream<List<int>> Function(int skip) source, {
    required void Function(int done, int total) onProgress,
    required bool Function() stop,
  }) async {
    final target = join(resolve(dir), name);
    final part = join(resolve(dir), uploadPartName(name, size));
    var start = 0;
    try {
      start = (await _sftp.stat(part)).size ?? 0;
    } on SftpStatusError {
      start = 0; // no part: from scratch
    }
    final restart = start > size; // part larger than target: corrupt, start over
    final mode = SftpFileOpenMode.create | SftpFileOpenMode.write;
    final f = await _sftp.open(part, mode: restart ? mode | SftpFileOpenMode.truncate : mode);
    if (restart) start = 0;
    onProgress(start, size);
    var stopped = false;
    try {
      final writer = f.write(
        source(start).map((c) => c is Uint8List ? c : Uint8List.fromList(c)).takeWhile((_) => !(stopped = stop())),
        offset: start,
        onProgress: (n) => onProgress(start + n, size),
      );
      await writer.done;
    } finally {
      await f.close();
    }
    // If cancel/pause arrived while writing the last chunk, the file is not moved to the target.
    if (stopped || stop()) return false;
    if ((await _sftp.stat(part)).size != size) return false;
    // SFTP rename fails when the target exists; mv -f overwrites.
    await _run('mv -f -- ${shellQuote(part)} ${shellQuote(target)}');
    return true;
  }

  /// Remote temporary name of the archive (without extension). The timestamp helps find the process and file on cancel.
  static String archiveBase(String path, DateTime now) => '/tmp/tiphys-${now.millisecondsSinceEpoch}-${path.substring(path.lastIndexOf('/') + 1)}';

  /// Compresses the folder remotely as [base] (.zip if zip exists, else .tar.gz); returns the archive path.
  /// An unreadable file (zip 18) or a file changed while reading (tar 1) is a warning: the archive is still created.
  /// Runs at most 30 min on the server (so the job doesn't run forever if the connection drops).
  Future<String> archive(String path, String base) async {
    final p = resolve(path);
    final name = p.substring(p.lastIndexOf('/') + 1);
    final zip = shellQuote('$base.zip'), tgz = shellQuote('$base.tar.gz');
    final r = await conn.exec(
      'set -e; cd ${shellQuote(parent(p))}; '
      'if command -v zip >/dev/null 2>&1; then out=$zip; timeout 1800 zip -qry "\$out" -- ${shellQuote(name)} || [ \$? -eq 18 ]; '
      'else out=$tgz; timeout 1800 tar -czf "\$out" -- ${shellQuote(name)} || [ \$? -eq 1 ]; fi; '
      'test -s "\$out"; echo "\$out"',
      timeout: const Duration(minutes: 31),
    );
    if (r.code != 0) throw SshFailure('other', r.stderr.trim().isEmpty ? 'exit ${r.code}' : r.stderr.trim());
    return r.stdout.trim().split('\n').last;
  }

  /// Cleans up an abandoned archive: stops the running zip/tar, deletes temporary files.
  /// The pattern is `[/]tmp/...` and deletion is a separate command, so our own shell's command line doesn't match
  /// the pattern and get killed. pkill returns 1 if it finds nothing; that's not an error.
  Future<void> discardArchive(String base) async {
    final stamp = RegExp(r'^/tmp/tiphys-\d+-').stringMatch(base);
    if (stamp == null) return;
    await conn.exec("pkill -f -- '[/]${stamp.substring(1)}'");
    await _run('rm -f -- ${shellQuote('$base.zip')} ${shellQuote('$base.tar.gz')}');
  }

  Future<void> mkdir(String path) => _sftp.mkdir(resolve(path));
  Future<void> rename(String from, String to) => _sftp.rename(resolve(from), resolve(to));

  Future<void> copy(String from, String to) => _run('cp -a -- ${shellQuote(resolve(from))} ${shellQuote(resolve(to))}');

  Future<void> deleteForever(String path) => _run('rm -rf -- ${shellQuote(resolve(path))}');

  /// Moves to the freedesktop trash (~/.local/share/Trash); can be restored from the desktop trash.
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

  /// Closes the SSH connection along with SFTP (for transfers' own connections).
  void dispose() {
    _sftp.close();
    conn.close();
  }
}
