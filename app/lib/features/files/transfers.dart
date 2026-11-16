// File transfers: progress, pause/resume, cancel; if the connection drops, resumes where it left off.
// Each transfer opens its own SSH connection: if one fails, the file browser and other transfers are unaffected,
// and pause/cancel close the connection, taking effect immediately even on a stuck (unresponsive) connection.
// Each downloaded file lands in its own folder (`downloads/<transfer>/<name>`); partial ones wait under
// `downloads/.partial/` and if the same file is downloaded again (same host, path, size, date) it resumes from
// the partial.
// For uploads the partial is a hidden `.name.size.tiphys-part` file in the remote target folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/remote_files.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../terminal/sessions.dart' show sshOpenerProvider;
import 'files_screen.dart' show formatSize;

enum TransferKind { download, upload }

enum TransferState { preparing, running, paused, failed, done }

/// Connection is open but no data flows (e.g. a half-open connection after switching Wi-Fi → mobile).
class TransferStalled implements Exception {
  const TransferStalled();
}

class Transfer extends ChangeNotifier {
  Transfer({
    required this.kind,
    required this.host,
    required this.name,
    required this.remote,
    this.folder = false,
    this.source,
    this.sourcePath,
    this.size = 0,
    this.modified,
  })  : listedSize = size,
        id = '${DateTime.now().microsecondsSinceEpoch}';
  final String id;
  final TransferKind kind;
  final Host host;
  String name;

  /// Download: remote file or folder. Upload: target folder.
  final String remote;

  /// Folder: archived remotely first, the archive is downloaded, then the remote archive is deleted.
  final bool folder;
  String? _archiveBase;
  String? _archive;

  /// Upload source: the local path if any (can resume even after the app is reopened), otherwise the picked file.
  final PlatformFile? source;
  final String? sourcePath;

  /// Size and modification time as seen in the list: the partial key comes from these (so the same partial is
  /// resumed even if the file grows while downloading).
  final int listedSize;
  final DateTime? modified;

  /// Completed local file for downloads.
  File? local;

  int size;
  int done = 0;
  TransferState state = TransferState.preparing;
  Object? error;

  bool _stop = false;
  bool _stalled = false;

  /// Increments on each start: a late result from an old (paused) run must not corrupt the new one's state.
  int _gen = 0;
  RemoteFiles? _files;
  Future<void>? _task;

  double? get progress => size > 0 ? (done / size).clamp(0.0, 1.0) : null;
  bool get active => state == TransferState.preparing || state == TransferState.running;

  void _set({TransferState? state, int? done, int? size, Object? error}) {
    if (state != null) this.state = state;
    if (done != null) this.done = done;
    if (size != null) this.size = size;
    this.error = error ?? (state == TransferState.failed ? this.error : null);
    notifyListeners();
  }
}

/// Name of the partial download: the same remote file (host + path + size + modification time) maps to the same
/// partial.
String partialKey(String hostId, String path, int size, DateTime? modified) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode('$hostId|$path|$size|${modified?.millisecondsSinceEpoch}')) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

class Transfers extends Notifier<List<Transfer>> {
  @override
  List<Transfer> build() => const [];

  /// Replaced in tests.
  Future<Directory> Function() downloadsDir = () async => Directory('${(await getApplicationDocumentsDirectory()).path}/downloads');
  late Future<RemoteFiles> Function(Host) openFiles = (h) async => RemoteFiles.open(await ref.read(sshOpenerProvider)(h));

  /// If no bytes are transferred for this long, the connection is considered stuck and closed; the transfer
  /// becomes "interrupted".
  Duration stallAfter = const Duration(seconds: 45);
  bool _cleaned = false;

  Transfer _add(Transfer t) {
    state = [t, ...state];
    _start(t);
    return t;
  }

  /// If an unfinished transfer of the same file exists, no new one is opened; that one is resumed (so two
  /// transfers don't write to the same partial).
  Transfer? _existing(bool Function(Transfer) same) {
    final t = state.where((t) => t.state != TransferState.done && same(t)).firstOrNull;
    if (t != null) resume(t);
    return t;
  }

  /// Download a file (the share menu opens when done).
  Transfer download(Host host, RemoteEntry e) =>
      _existing((t) => t.kind == TransferKind.download && !t.folder && t.host.id == host.id && t.remote == e.path) ??
      _add(Transfer(kind: TransferKind.download, host: host, name: e.name, remote: e.path, size: e.size, modified: e.modified));

  /// Archive and download a folder.
  Transfer downloadFolder(Host host, RemoteEntry e) =>
      _existing((t) => t.kind == TransferKind.download && t.folder && t.host.id == host.id && t.remote == e.path) ??
      _add(Transfer(kind: TransferKind.download, host: host, name: e.name, remote: e.path, folder: true));

  Transfer upload(Host host, String dir, PlatformFile f, int size) =>
      _existing((t) => t.kind == TransferKind.upload && t.host.id == host.id && t.remote == dir && t.name == f.name && t.size == size) ??
      _add(Transfer(kind: TransferKind.upload, host: host, name: f.name, remote: dir, source: f, sourcePath: f.path, size: size));

  /// Pause: the connection is closed (stops immediately even on a stuck connection); the partial is kept.
  void pause(Transfer t) {
    if (!t.active) return;
    t._stop = true;
    t._files?.dispose();
    t._set(state: TransferState.paused);
  }

  void resume(Transfer t) {
    if (t.active || t.state == TransferState.done) return;
    _start(t);
  }

  /// A new run doesn't start until the previous one has fully finished (closed the file): both must not write to
  /// the same partial.
  void _start(Transfer t) {
    final previous = t._task;
    final gen = ++t._gen;
    t._stop = false;
    t._stalled = false;
    t._set(state: t.folder && t._archive == null ? TransferState.preparing : TransferState.running);
    t._task = () async {
      await previous?.catchError((Object _) {});
      if (!t._stop && gen == t._gen) await _run(t, gen);
    }();
  }

  /// Cancel: removes from the list; deletes the partial, the remote partial upload and the temporary archive.
  Future<void> cancel(Transfer t) async {
    t._stop = true;
    state = [...state]..remove(t);
    t._files?.dispose();
    await t._task?.catchError((Object _) {});
    try {
      if (t.kind == TransferKind.download) {
        final part = await _partFile(t);
        if (await part.exists()) await part.delete();
      }
      if (t.kind == TransferKind.upload || t._archiveBase != null) {
        final f = await openFiles(t.host);
        try {
          if (t.kind == TransferKind.upload) await f.deleteForever(RemoteFiles.join(f.resolve(t.remote), RemoteFiles.uploadPartName(t.name, t.size)));
          if (t._archiveBase != null) await f.discardArchive(t._archiveBase!);
        } finally {
          f.dispose();
        }
      }
    } catch (_) {
      // Without a connection temporary files remain: partials are used by the next identical transfer or
      // cleaned up after 7 days; the server cleans the archive in /tmp.
    }
  }

  /// Removes finished ones from the list (downloaded files are deleted too: the copy is unneeded once shared).
  Future<void> clearFinished() async {
    final finished = state.where((t) => t.state == TransferState.done).toList();
    state = [for (final t in state) if (t.state != TransferState.done) t];
    for (final t in finished) {
      final dir = t.local?.parent;
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    }
  }

  Future<void> share(Transfer t) async {
    if (t.local != null) await SharePlus.instance.share(ShareParams(files: [XFile(t.local!.path)]));
  }

  Future<File> _partFile(Transfer t) async {
    final dir = await downloadsDir();
    final key = t.folder ? 'archive-${t.id}' : partialKey(t.host.id, t.remote, t.listedSize, t.modified);
    return File('${dir.path}/.partial/$key.part');
  }

  /// Cleans up, once, partials older than 7 days whose list was lost when the app was closed and reopened.
  Future<void> _cleanPartials(Directory partial) async {
    if (_cleaned) return;
    _cleaned = true;
    final old = DateTime.now().subtract(const Duration(days: 7));
    await for (final f in partial.list()) {
      if (f is File && (await f.lastModified()).isBefore(old)) await f.delete();
    }
  }

  Future<void> _run(Transfer t, int gen) async {
    RemoteFiles? files;
    Timer? watchdog;
    bool stopped() => t._stop || gen != t._gen;
    try {
      files = await openFiles(t.host);
      if (stopped()) return; // paused/cancelled while connecting
      t._files = files;
      // Stall watchdog: close the connection if no data flows (download/upload returns an error, can be resumed).
      var last = t.done;
      var idleSince = DateTime.now();
      watchdog = Timer.periodic(stallAfter ~/ 9, (_) {
        if (t.state != TransferState.running) return;
        if (t.done != last) {
          last = t.done;
          idleSince = DateTime.now();
        } else if (DateTime.now().difference(idleSince) >= stallAfter) {
          t._stalled = true;
          files?.dispose();
        }
      });
      if (t.kind == TransferKind.download) {
        if (t.folder && t._archive == null) {
          // If the previous attempt was interrupted while archiving, clean up its leftovers.
          if (t._archiveBase != null) await files.discardArchive(t._archiveBase!).catchError((Object _) {});
          t._archiveBase = RemoteFiles.archiveBase(files.resolve(t.remote), DateTime.now());
          t._archive = await files.archive(t.remote, t._archiveBase!);
          t.name = '${t.name}${t._archive!.endsWith('.zip') ? '.zip' : '.tar.gz'}';
          t._set(state: TransferState.running);
        }
        final part = await _partFile(t);
        await part.parent.create(recursive: true);
        await _cleanPartials(part.parent);
        final finished = await files.download(t._archive ?? t.remote, part, onProgress: (d, s) => t._set(done: d, size: s), stop: stopped);
        if (stopped()) return;
        if (!finished) throw const FileSystemException('incomplete'); // file shrank while downloading
        final out = File('${(await downloadsDir()).path}/${t.id}/${t.name}');
        await out.parent.create(recursive: true);
        t.local = await part.rename(out.path);
        if (t._archiveBase != null) {
          await files.discardArchive(t._archiveBase!).catchError((Object _) {});
          t._archiveBase = t._archive = null;
        }
        t._set(state: TransferState.done);
        // If the share menu can't open, the transfer is still done (the share button in the list remains).
        await share(t).catchError((Object _) {});
      } else {
        final src = t.sourcePath != null && File(t.sourcePath!).existsSync() ? File(t.sourcePath!) : null;
        Stream<List<int>> open(int skip) => src != null ? src.openRead(skip) : _skip(t.source!.readAsByteStream(), skip);
        final finished = await files.upload(t.remote, t.name, t.size, open, onProgress: (d, s) => t._set(done: d, size: s), stop: stopped);
        if (stopped()) return;
        if (!finished) throw const FileSystemException('incomplete'); // source shorter than expected
        t._set(state: TransferState.done);
      }
    } catch (e) {
      // If pause/cancel closed the connection, this isn't an error.
      if (!stopped() && state.contains(t)) t._set(state: TransferState.failed, error: t._stalled ? const TransferStalled() : e);
    } finally {
      watchdog?.cancel();
      files?.dispose();
      if (gen == t._gen) t._files = null;
    }
  }
}

/// Skips the first [skip] bytes of the stream (to resume an upload of a picked file that has no path).
Stream<List<int>> _skip(Stream<List<int>> s, int skip) async* {
  var left = skip;
  await for (final c in s) {
    if (left >= c.length) {
      left -= c.length;
      continue;
    }
    yield left > 0 ? c.sublist(left) : c;
    left = 0;
  }
}

final transfersProvider = NotifierProvider<Transfers, List<Transfer>>(Transfers.new);

/// Transfers page (opened from the button in the Files header).
class TransfersSheet extends ConsumerWidget {
  const TransfersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final list = ref.watch(transfersProvider);
    final n = ref.read(transfersProvider.notifier);
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
          child: Row(children: [
            Expanded(child: Text(l.transfersTitle, style: Theme.of(context).textTheme.titleLarge)),
            if (list.any((t) => t.state == TransferState.done)) TextButton(onPressed: n.clearFinished, child: Text(l.transfersClear)),
          ]),
        ),
        if (list.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text(l.transfersEmpty, textAlign: TextAlign.center))
        else
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [for (final t in list) _TransferTile(t)]),
          ),
      ]),
    );
  }
}

class _TransferTile extends ConsumerWidget {
  const _TransferTile(this.t);
  final Transfer t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final tk = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final n = ref.read(transfersProvider.notifier);
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) {
        final status = switch (t.state) {
          TransferState.preparing => l.transfersArchiving,
          TransferState.running || TransferState.paused =>
            '${formatSize(t.done, locale)} / ${t.size > 0 ? formatSize(t.size, locale) : '?'}${t.state == TransferState.paused ? ' · ${l.transfersPaused}' : ''}',
          TransferState.failed => l.transfersFailed,
          TransferState.done => t.kind == TransferKind.upload ? l.transfersUploaded : l.transfersDownloaded,
        };
        return ListTile(
          leading: Icon(
            t.kind == TransferKind.upload ? LucideIcons.upload : (t.folder ? LucideIcons.fileArchive : LucideIcons.download),
            color: t.state == TransferState.failed ? tk.danger : (t.state == TransferState.done ? tk.success : tk.accent),
          ),
          title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (t.state != TransferState.done)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LinearProgressIndicator(
                  value: t.state == TransferState.preparing ? null : t.progress,
                  semanticsLabel: t.name,
                  semanticsValue: t.progress == null ? null : '${(t.progress! * 100).round()}%',
                ),
              ),
            Text('${t.host.name} · $status', style: TextStyle(color: t.state == TransferState.failed ? tk.danger : null)),
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (t.state == TransferState.running)
              IconButton(tooltip: l.transfersPause, icon: const Icon(LucideIcons.pause), onPressed: () => n.pause(t)),
            if (t.state == TransferState.paused || t.state == TransferState.failed)
              IconButton(tooltip: l.transfersResume, icon: const Icon(LucideIcons.play), onPressed: () => n.resume(t)),
            if (t.state == TransferState.done && t.local != null)
              IconButton(tooltip: l.filesDownload, icon: const Icon(LucideIcons.share2), onPressed: () => n.share(t)),
            if (t.state != TransferState.done)
              IconButton(tooltip: l.commonCancel, icon: const Icon(LucideIcons.x), onPressed: () => n.cancel(t)),
          ]),
        );
      },
    );
  }
}
