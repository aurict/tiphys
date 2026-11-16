// Importing into the vault: the Markdown password list on the PC (default ~/SIFRELER.md) is read over SFTP, its tables
// parsed, and entries picked from a masked-password preview list are added (updated if title + user match).
// Deleting the file from the PC is then asked separately (default: don't delete). Contents are never written/logged.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../core/vault/markdown_import.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../files/files_screen.dart' show fileBrowsersProvider;
import '../system/log_search.dart' show logSearchErrorText;
import 'vault_state.dart';

/// Maximum size of the file to import.
const _maxBytes = 1 << 20;

/// Reading / deleting the remote file (tests supply a fake).
abstract interface class VaultFileAccess {
  Future<String> read(Host host, String path);

  /// Deletes the file (`shred -u` if available, else `rm`). Throws on failure.
  Future<void> delete(Host host, String path);
}

class _SftpFileAccess implements VaultFileAccess {
  _SftpFileAccess(this.ref);
  final Ref ref;

  @override
  Future<String> read(Host host, String path) async {
    final f = await ref.read(fileBrowsersProvider.notifier).get(host);
    final bytes = await f.read(path, maxBytes: _maxBytes);
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> delete(Host host, String path) async {
    final f = await ref.read(fileBrowsersProvider.notifier).get(host);
    final p = shellQuote(f.resolve(path));
    final r = await f.conn.exec('if command -v shred >/dev/null 2>&1; then shred -u -- $p; else rm -f -- $p; fi', timeout: const Duration(seconds: 30));
    if (r.code != 0) throw Exception(r.stderr.trim().isEmpty ? 'exit ${r.code}' : r.stderr.trim());
  }
}

final vaultFileAccessProvider = Provider<VaultFileAccess>((ref) => _SftpFileAccess(ref));

/// Default source host: the Claude host (PC) if it has SSH, else a wakeable host, else the first host with SSH.
Host? defaultImportHost(Profile p, Host? claudeHost) {
  final ssh = p.hosts.where((h) => h.ssh != null);
  return (claudeHost?.ssh != null ? claudeHost : null) ?? ssh.where((h) => h.wake != null).firstOrNull ?? ssh.firstOrNull;
}

class VaultImportPage extends ConsumerStatefulWidget {
  const VaultImportPage({super.key});
  @override
  ConsumerState<VaultImportPage> createState() => _VaultImportPageState();
}

class _VaultImportPageState extends ConsumerState<VaultImportPage> {
  final _path = TextEditingController(text: '~/SIFRELER.md');
  String? _hostId;
  bool _busy = false;
  Object? _error;
  List<ImportCandidate>? _items;
  Set<int> _picked = {};

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Host? _host() {
    final p = ref.read(profileProvider);
    return p.host(_hostId) ?? defaultImportHost(p, ref.read(claudeHostProvider));
  }

  Future<void> _read() async {
    final host = _host();
    if (host == null || _path.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _items = null;
    });
    try {
      final items = parsePasswordMarkdown(await ref.read(vaultFileAccessProvider).read(host, _path.text.trim()));
      setState(() {
        _items = items;
        // Rows without a password (e.g. only a command) are unselected by default.
        _picked = {for (var i = 0; i < items.length; i++) if (items[i].password.isNotEmpty) i};
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final l = AppLocalizations.of(context);
    final items = _items!;
    final picked = [for (var i = 0; i < items.length; i++) if (_picked.contains(i)) items[i]];
    final vault = ref.read(vaultProvider.notifier);
    final current = ref.read(vaultProvider).entries;
    if (current == null) {
      toast(context, '${l.vaultLocked}. ${l.vaultLockedHint}');
      return;
    }
    final r = mergeImported(current, picked, ref.read(clockProvider)());
    try {
      await vault.replaceAll(r.entries);
    } on VaultLockedError {
      if (mounted) toast(context, '${l.vaultLocked}. ${l.vaultLockedHint}');
      return;
    }
    if (!mounted) return;
    toast(context, l.vaultImported(r.added, r.updated));
    final host = _host()!;
    final path = _path.text.trim();
    // Separate, explicit confirmation; the default button is "Vazgeç" (file stays).
    final del = await confirmDialog(context, message: l.vaultDeleteSourceConfirm(path, host.name), confirmLabel: l.vaultDeleteSource, destructive: true);
    if (del) {
      try {
        await ref.read(vaultFileAccessProvider).delete(host, path);
        if (mounted) toast(context, l.vaultSourceDeleted);
      } catch (e) {
        if (mounted) toast(context, logSearchErrorText(l, e));
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hosts = ref.watch(profileProvider).hosts.where((h) => h.ssh != null).toList();
    final host = _host();
    return VaultScope(builder: (context, entries) {
      final existing = {for (final e in entries) VaultEntryKey(e.title, e.username)};
      final items = _items;
      return SettingsPage(
        title: l.vaultImport,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(l.vaultImportExplain, style: TextStyle(color: t.textSecondary, fontSize: 13)),
          ),
          if (hosts.isEmpty)
            TCard(child: Text(l.composeNoSshHosts))
          else ...[
            FieldCard(children: [
              DropdownButtonFormField<String>(
                initialValue: host?.id,
                decoration: InputDecoration(labelText: l.vaultImportHost),
                items: [for (final h in hosts) DropdownMenuItem(value: h.id, child: Text(h.name))],
                onChanged: (v) => setState(() {
                  _hostId = v;
                  _items = null;
                }),
              ),
              TField(controller: _path, label: l.vaultImportPath, mono: true),
            ]),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _read,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.fileSearch, size: 18),
              label: Text(l.vaultImportRead),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TCard(
                child: Row(children: [
                  Icon(LucideIcons.circleAlert, color: t.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text(logSearchErrorText(l, _error!))),
                ]),
              ),
            ),
          if (items != null && items.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.vaultImportNone))),
          if (items != null && items.isNotEmpty) ...[
            GroupedSection(
              title: l.vaultImportPreview(items.length),
              footer: l.vaultImportFooter,
              children: [
                GroupedRow(
                  title: _picked.length == items.length ? l.vaultSelectNone : l.vaultSelectAll,
                  showChevron: false,
                  onTap: () => setState(() => _picked = _picked.length == items.length ? {} : {for (var i = 0; i < items.length; i++) i}),
                ),
                for (var i = 0; i < items.length; i++)
                  CheckboxListTile(
                    value: _picked.contains(i),
                    onChanged: (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (items[i].username.isNotEmpty) items[i].username,
                        items[i].password.isEmpty ? l.vaultNoPassword : '•' * 8,
                        ...items[i].tags,
                        if (existing.contains(VaultEntryKey(items[i].title, items[i].username))) l.vaultWillUpdate,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            FilledButton.icon(
              onPressed: _picked.isEmpty ? null : _import,
              icon: const Icon(LucideIcons.download, size: 18),
              label: Text(l.vaultImportCount(_picked.length)),
            ),
          ],
        ],
      );
    });
  }
}

/// Matching key (title + user, case-insensitive).
class VaultEntryKey {
  VaultEntryKey(String title, String user)
      : title = title.trim().toLowerCase(),
        user = user.trim().toLowerCase();
  final String title;
  final String user;
  @override
  bool operator ==(Object other) => other is VaultEntryKey && other.title == title && other.user == user;
  @override
  int get hashCode => Object.hash(title, user);
}
