// Dosyalar sekmesi: host seç → SFTP ile gez; önizleme, yükle/indir, yeniden adlandır, taşı, kopyala,
// çöp kutusuna taşı, yeni klasör; her klasörde "burada terminal" ve "burada Claude".
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../core/ssh/remote_files.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/floating_tab_bar.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../terminal/sessions.dart';
import '../terminal/terminal_screen.dart';
import 'editor_screen.dart';

/// Host başına açık SFTP oturumu (sekmeler arasında korunur).
class FileBrowsers extends Notifier<Map<String, RemoteFiles>> {
  final _open = <String, RemoteFiles>{};

  @override
  Map<String, RemoteFiles> build() {
    ref.onDispose(() {
      for (final f in _open.values) {
        f.close();
        f.conn.close();
      }
      _open.clear();
    });
    return {};
  }

  Future<RemoteFiles> get(Host host) async {
    final cur = state[host.id];
    if (cur != null && !cur.conn.client.isClosed) return cur;
    final conn = await ref.read(sshOpenerProvider)(host);
    final files = await RemoteFiles.open(conn);
    _open[host.id] = files;
    state = {...state, host.id: files};
    return files;
  }

  void drop(String hostId) {
    final f = _open.remove(hostId);
    f?.close();
    f?.conn.close();
    state = {...state}..remove(hostId);
  }
}

final fileBrowsersProvider = NotifierProvider<FileBrowsers, Map<String, RemoteFiles>>(FileBrowsers.new);

String formatSize(int bytes, String locale) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${NumberFormat(i == 0 ? '0' : '0.#', locale).format(v)} ${units[i]}';
}

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key, this.hostId, this.path});
  final String? hostId;
  final String? path;
  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  String? _hostId;
  String _path = '~';
  List<RemoteEntry>? _entries;

  /// Çok kalabalık klasörlerde (node_modules gibi) ilk açılış hızlı kalsın diye önce bu kadarı çizilir.
  static const _page = 200;
  int _limit = _page;
  Object? _error;
  bool _loading = false;
  RemoteFiles? _files;
  (String, bool)? _clipboard; // (yol, kes mi)

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    final bm = p.files.bookmarks.firstOrNull;
    _hostId = widget.hostId ?? bm?.hostId ?? p.hosts.where((h) => h.ssh != null).firstOrNull?.id;
    _path = widget.path ?? (bm != null && bm.hostId == _hostId ? bm.path : '~');
    if (_hostId != null) _load();
  }

  Future<void> _load([String? path]) async {
    final host = ref.read(profileProvider).host(_hostId);
    if (host == null) return;
    setState(() {
      _loading = true;
      _error = null;
      if (path != null) _path = path;
    });
    try {
      final files = await ref.read(fileBrowsersProvider.notifier).get(host);
      final list = await files.list(_path, showHidden: ref.read(profileProvider).files.showHidden);
      if (!mounted) return;
      setState(() {
        _files = files;
        _path = files.pretty(files.resolve(_path));
        _entries = list;
        _limit = _page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ref.read(fileBrowsersProvider.notifier).drop(host.id);
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _act(Future<void> Function(RemoteFiles f) body, {String? done}) async {
    final f = _files;
    if (f == null) return;
    try {
      await body(f);
      if (done != null && mounted) toast(context, done);
      await _load();
    } catch (e) {
      if (mounted) toast(context, '${AppLocalizations.of(context).commonError}: $e');
    }
  }

  Future<String?> _ask(String title, {String initial = ''}) async {
    final l = AppLocalizations.of(context);
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TField(controller: c, label: l.hostName, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(l.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(l.commonSave)),
        ],
      ),
    );
    c.dispose();
    return r == null || r.isEmpty || r.contains('/') ? null : r;
  }

  Future<void> _upload() async {
    final l = AppLocalizations.of(context);
    final picked = await FilePicker.pickFile();
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final name = picked.name;
    await _act((f) => f.write(RemoteFiles.join(f.resolve(_path), name), bytes), done: l.filesUploaded(name));
  }

  Future<void> _download(RemoteEntry e) async {
    await _act((f) async {
      final data = await f.read(e.path);
      final dir = await getTemporaryDirectory();
      final local = File('${dir.path}/${e.name}');
      await local.writeAsBytes(data, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(local.path)]));
    });
  }

  Future<void> _preview(RemoteEntry e) async {
    final l = AppLocalizations.of(context);
    final f = _files;
    if (f == null) return;
    final ext = e.name.contains('.') ? e.name.split('.').last.toLowerCase() : '';
    const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
    if (e.size > 2 * 1024 * 1024 && !images.contains(ext)) {
      await _download(e);
      return;
    }
    try {
      final data = await f.read(e.path, maxBytes: images.contains(ext) ? 20 * 1024 * 1024 : 2 * 1024 * 1024);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (c) => _PreviewPage(entry: e, data: data, isImage: images.contains(ext), onShare: () => _download(e)),
      ));
    } catch (err) {
      if (mounted) toast(context, '${l.commonError}: $err');
    }
  }

  Future<void> _edit(RemoteEntry e) async {
    final f = _files;
    if (f == null) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => TextEditorScreen(files: f, path: e.path, name: e.name)));
    if (saved == true) await _load();
  }

  void _entryMenu(RemoteEntry e) {
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      useRootNavigator: true, // alt sekme barının üstünde açılsın; yoksa bar sayfanın altını örter
      context: context,
      builder: (c) {
        Widget item(IconData icon, String label, VoidCallback onTap, {bool danger = false}) => ListTile(
              leading: Icon(icon, color: danger ? context.tokens.danger : null),
              title: Text(label, style: TextStyle(color: danger ? context.tokens.danger : null)),
              onTap: () {
                Navigator.pop(c);
                onTap();
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(e.name, style: Theme.of(context).textTheme.titleMedium)),
            if (!e.isDir) item(LucideIcons.eye, l.filesPreview, () => _preview(e)),
            if (!e.isDir && e.size <= TextEditorScreen.maxBytes) item(LucideIcons.fileCode, l.filesEdit, () => _edit(e)),
            if (!e.isDir) item(LucideIcons.share2, l.filesDownload, () => _download(e)),
            if (e.isDir) item(LucideIcons.terminal, l.filesTerminalHere, () => _terminalHere(e.path)),
            item(LucideIcons.pencil, l.filesRename, () async {
              final n = await _ask(l.filesRename, initial: e.name);
              if (n != null) await _act((f) => f.rename(e.path, RemoteFiles.join(RemoteFiles.parent(e.path), n)));
            }),
            item(LucideIcons.copy, l.filesCopy, () => setState(() => _clipboard = (e.path, false))),
            item(LucideIcons.scissors, l.filesMove, () => setState(() => _clipboard = (e.path, true))),
            item(LucideIcons.trash2, l.filesTrash, () async {
              if (await confirmDialog(context, message: l.filesTrashConfirm(e.name), confirmLabel: l.filesTrash, destructive: true)) {
                await _act((f) => f.trash(e.path), done: l.filesTrashed);
              }
            }, danger: true),
          ]),
        );
      },
    );
  }

  void _terminalHere(String path) {
    final host = ref.read(profileProvider).host(_hostId);
    if (host == null) return;
    final s = ref.read(terminalSessionsProvider.notifier).open(host, startDir: _files?.pretty(path) ?? path);
    ref.read(activeTerminalProvider.notifier).select(s.id);
    context.go('/terminal');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    final hosts = p.hosts.where((h) => h.ssh != null).toList();
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = DateFormat.yMMMd(locale);
    final top = MediaQuery.paddingOf(context).top;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(TiphysTokens.gutter, top + 18, TiphysTokens.gutter, FloatingTabBar.height + FloatingTabBar.bottomGap + 24),
        children: [
          LargeTitleHeader(
            title: l.tabFiles,
            action: _hostId == null
                ? null
                : RoundIconButton(icon: LucideIcons.upload, tooltip: l.filesUpload, onPressed: _upload),
          ),
          const SizedBox(height: 12),
          if (hosts.isEmpty)
            TCard(child: Text(l.terminalNoSshHosts))
          else ...[
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final h in hosts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: h.id == _hostId,
                      showCheckmark: false,
                      avatar: StatusDot(color: hexColor(h.color), size: 8, square: true),
                      label: Text(h.name),
                      onSelected: (_) {
                        setState(() {
                          _hostId = h.id;
                          _entries = null;
                        });
                        _load('~');
                      },
                      selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
                      labelStyle: TextStyle(color: h.id == _hostId ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
                      backgroundColor: t.chipBackground,
                      side: BorderSide(color: t.separator),
                      shape: const StadiumBorder(),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            // Yol + üst klasör + yer imleri
            TCard(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              radius: 18,
              child: Row(children: [
                IconButton(
                  tooltip: l.filesUp,
                  icon: const Icon(LucideIcons.arrowUp, size: 20),
                  onPressed: _path == '/' ? null : () => _load(_files == null ? '~' : _files!.pretty(RemoteFiles.parent(_files!.resolve(_path)))),
                ),
                Expanded(
                  child: Text(_path, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13), overflow: TextOverflow.ellipsis),
                ),
                PopupMenuButton<String>(
                  tooltip: l.filesBookmarks,
                  icon: const Icon(LucideIcons.bookmark, size: 20),
                  onSelected: (v) => _load(v),
                  itemBuilder: (c) => [
                    const PopupMenuItem(value: '~', child: Text('~')),
                    for (final b in p.files.bookmarks.where((b) => b.hostId == _hostId)) PopupMenuItem(value: b.path, child: Text(b.path)),
                  ],
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _Action(icon: LucideIcons.terminal, label: l.tabTerminal, semantics: l.filesTerminalHere, onTap: _files == null ? null : () => _terminalHere(_files!.resolve(_path))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Action(
                  icon: LucideIcons.asterisk,
                  label: 'Claude',
                  semantics: l.filesClaudeHere,
                  onTap: () => context.go(Uri(path: '/claude', queryParameters: {'host': _hostId!, 'cwd': _path, 'new': '1'}).toString()),
                ),
              ),
              const SizedBox(width: 8),
              if (p.host(_hostId)?.agent != null) ...[
                _Action(
                  icon: LucideIcons.gitBranch,
                  label: '',
                  semantics: 'Git',
                  onTap: _files == null
                      ? null
                      : () => context.push(Uri(path: '/git', queryParameters: {'host': _hostId!, 'path': _files!.resolve(_path)}).toString()),
                ),
                const SizedBox(width: 8),
              ],
              _Action(
                icon: LucideIcons.folderPlus,
                label: '',
                semantics: l.filesNewFolder,
                onTap: _files == null
                    ? null
                    : () async {
                        final n = await _ask(l.filesNewFolder);
                        if (n != null) await _act((f) => f.mkdir(RemoteFiles.join(f.resolve(_path), n)));
                      },
              ),
            ]),
            if (_clipboard != null) ...[
              const SizedBox(height: 10),
              TCard(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(children: [
                  Icon(_clipboard!.$2 ? LucideIcons.scissors : LucideIcons.copy, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_clipboard!.$1.split('/').last, overflow: TextOverflow.ellipsis)),
                  TextButton(
                    onPressed: () async {
                      final (src, cut) = _clipboard!;
                      setState(() => _clipboard = null);
                      await _act((f) {
                        final dst = RemoteFiles.join(f.resolve(_path), src.split('/').last);
                        return cut ? f.rename(src, dst) : f.copy(src, dst);
                      });
                    },
                    child: Text(l.filesPasteHere),
                  ),
                  IconButton(tooltip: l.commonCancel, icon: const Icon(LucideIcons.x, size: 18), onPressed: () => setState(() => _clipboard = null)),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            if (_loading && _entries == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              TCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_error is SshFailure ? sshFailureText(l, _error as SshFailure) : '${l.commonError}: $_error'),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _load, child: Text(l.commonRetry)),
                ]),
              )
            else if (_entries != null && _entries!.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Text(l.filesEmptyFolder, textAlign: TextAlign.center))
            else if (_entries != null)
              GroupedSection(children: [
                for (final e in _entries!.take(_limit))
                  GroupedRow(
                    title: e.name,
                    subtitle: e.isDir
                        ? (e.modified == null ? null : day.format(e.modified!))
                        : '${formatSize(e.size, locale)}${e.modified == null ? '' : ' · ${day.format(e.modified!)}'}',
                    icon: e.isDir ? LucideIcons.folder : _iconFor(e.name),
                    iconBackground: e.isDir ? t.rowIconFiles : const Color(0xFF6C6C70),
                    onTap: () => e.isDir ? _load(_files!.pretty(e.path)) : _preview(e),
                    trailing: IconButton(
                      tooltip: l.filesMore,
                      icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
                      onPressed: () => _entryMenu(e),
                    ),
                  ),
                if (_entries!.length > _limit)
                  GroupedRow(
                    title: l.filesShowAll(_entries!.length - _limit),
                    icon: LucideIcons.listPlus,
                    iconBackground: t.rowIconFiles,
                    showChevron: false,
                    onTap: () => setState(() => _limit = _entries!.length),
                  ),
              ]),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' => LucideIcons.image,
      'mp4' || 'mkv' || 'mov' || 'webm' => LucideIcons.film,
      'mp3' || 'wav' || 'ogg' || 'flac' => LucideIcons.music,
      'pdf' => LucideIcons.fileText,
      'zip' || 'gz' || 'tar' || 'xz' || '7z' => LucideIcons.fileArchive,
      'json' || 'yaml' || 'yml' || 'toml' => LucideIcons.fileJson,
      'dart' || 'ts' || 'js' || 'py' || 'sh' || 'go' || 'rs' || 'c' || 'cpp' || 'kt' => LucideIcons.fileCode,
      _ => LucideIcons.file,
    };
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.semantics});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? semantics;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      onTap: onTap,
      semanticLabel: semantics ?? label,
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 18, color: onTap == null ? t.textSecondary : t.text),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        ],
      ]),
    );
  }
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({required this.entry, required this.data, required this.isImage, required this.onShare});
  final RemoteEntry entry;
  final Uint8List data;
  final bool isImage;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = isImage ? null : utf8.decode(data, allowMalformed: true);
    final binary = text != null && text.contains('\u0000');
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.name),
        actions: [IconButton(tooltip: l.filesDownload, icon: const Icon(LucideIcons.share2), onPressed: onShare)],
      ),
      body: isImage
          ? InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(data, semanticLabel: entry.name)))
          : binary
              ? Center(child: Text(l.filesBinary))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(text!, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.4)),
                  ),
                ),
    );
  }
}
