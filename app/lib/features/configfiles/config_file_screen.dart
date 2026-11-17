// One config file (PLAN.md §13.3, C-1): its entries (secrets masked), staged edits, "Save" → masked preview → confirm,
// revealing secret values (app lock every time, FLAG_SECURE while shown, masked again after 30 s, sensitive clipboard),
// backups and the rotation settings of a key. Secret values are never stored, logged or kept after leaving the screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import '../incidents/incidents_data.dart' show incidentHostsFor;
import '../lock/lock_gate.dart';
import '../../state/providers.dart' show profileProvider;
import '../system/agent_providers.dart';
import '../vault/vault_state.dart' show secureWindowProvider, sensitiveClipboardProvider, vaultAuthProvider;
import 'config_preview_sheet.dart';
import 'config_reveal.dart';
import 'configfiles_data.dart';
import 'configfiles_texts.dart';

/// Is an app lock (PIN / fingerprint) set up? Without one a value can't be revealed (same rule as the vault). A
/// separate provider so tests can answer without locking the whole app.
final revealLockAvailableProvider = FutureProvider<bool>((ref) => ref.watch(lockRequiredProvider.future));

/// Names that look like secrets (the agent's name pattern): new values of such keys are typed hidden.
final _secretName = RegExp(r'PASS|PWD|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|DSN', caseSensitive: false);
bool looksSecretName(String key) => _secretName.hasMatch(key);

/// Route target: [hostHint] is a host id, or the agent's host name when it comes from a notification.
class ConfigFileRoute extends ConsumerWidget {
  const ConfigFileRoute({super.key, required this.hostHint, required this.fileId, this.focusKey});
  final String hostHint;
  final String fileId;

  /// A key to scroll to and highlight (from the rotation list).
  final String? focusKey;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider);
    final id = p.host(hostHint) != null ? hostHint : (incidentHostsFor(p, hostHint).hosts.firstOrNull?.id ?? hostHint);
    return ConfigFileScreen(hostId: id, fileId: fileId, focusKey: focusKey);
  }
}

class ConfigFileScreen extends ConsumerStatefulWidget {
  const ConfigFileScreen({super.key, required this.hostId, required this.fileId, this.focusKey});
  final String hostId;
  final String fileId;
  final String? focusKey;
  @override
  ConsumerState<ConfigFileScreen> createState() => _ConfigFileScreenState();
}

class _ConfigFileScreenState extends ConsumerState<ConfigFileScreen> {
  final _edits = ConfigEdits();
  late final RevealStore _reveal = RevealStore(onChanged: _revealChanged);
  late final AppLifecycleListener _life;
  late final Future<void> Function(bool) _secure;
  bool _secureOn = false;
  int _editing = 0;
  bool _busy = false;
  bool _selecting = false;
  final _selected = <String>{};

  /// The row of `widget.focusKey`: highlighted, and scrolled into view once after the first load.
  final _focusRow = GlobalKey();
  bool _focusScrolled = false;

  ConfigFileRef get _key => (widget.hostId, widget.fileId);

  @override
  void initState() {
    super.initState();
    _secure = ref.read(secureWindowProvider);
    // Revealed values don't survive the app going to the background.
    _life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _reveal.clear();
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _reveal.clear(notify: false);
    _edits.clear();
    if (_secureOn) unawaited(_secure(false));
    super.dispose();
  }

  void _revealChanged() {
    if (mounted) setState(() {});
    _syncSecure();
  }

  /// FLAG_SECURE while a value is shown or a value is being typed.
  void _syncSecure() {
    final want = !_reveal.isEmpty || _editing > 0;
    if (want != _secureOn) {
      _secureOn = want;
      unawaited(_secure(want));
    }
  }

  // --- reload / save ---------------------------------------------------------------------------------------------

  /// Reads the file again; staged edits whose key is gone are dropped.
  Future<void> _reload() async {
    final l = AppLocalizations.of(context);
    ref.invalidate(configFileProvider(_key));
    try {
      final d = await ref.read(configFileProvider(_key).future);
      final dropped = _edits.reconcile(d.entries);
      _reveal.clear();
      if (mounted) {
        setState(() {});
        toast(context, dropped > 0 ? l.cfReloadedDropped(dropped) : l.cfReloaded);
      }
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  Future<void> _save(ConfigFileDetail d) async {
    final l = AppLocalizations.of(context);
    final ops = _edits.toOps();
    if (ops.length > maxConfigOps) {
      toast(context, l.cfTooManyChanges(maxConfigOps));
      return;
    }
    final out = await showConfigPreviewSheet(
      context,
      file: d.file,
      restore: false,
      load: (restart) => agentCall(ref, d.host.id, 'POST', '/v1/config-files/${d.fileId}/preview', {'baseHash': d.hash, 'ops': ops, 'restart': restart ? 'affected' : 'none'}),
      execute: (p, restart) => configRequest(ref, d.host.id, 'PUT', '/v1/config-files/${d.fileId}', {'previewToken': p.token, 'confirm': true, 'restart': restart ? 'affected' : 'none'}, timeout: restart ? restartTimeout : null),
    );
    if (!mounted) return;
    if (out.saved) {
      _edits.clear();
      _reveal.clear();
      ref.invalidate(configFileProvider(_key));
      ref.invalidate(configFilesProvider(d.host.id));
      setState(() {});
      if (out.restoreBackupId != null) await _restoreBackup(d, out.restoreBackupId!);
    } else if (out.reload) {
      await _reload();
    }
  }

  /// "Restore the backup" after a failed recreate: the same masked preview and confirmation as any restore.
  Future<void> _restoreBackup(ConfigFileDetail d, String backupId) async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final path = '/v1/config-files/${d.fileId}/restore';
    final out = await showConfigPreviewSheet(
      context,
      file: d.file,
      restore: true,
      load: (restart) => agentCall(ref, d.host.id, 'POST', path, {'backupId': backupId, 'restart': restart ? 'affected' : 'none'}),
      execute: (p, restart) => configRequest(ref, d.host.id, 'POST', path, {'backupId': backupId, 'previewToken': p.token, 'confirm': true, 'restart': restart ? 'affected' : 'none'}, timeout: restart ? restartTimeout : null),
    );
    if (!mounted) return;
    if (out.saved || out.reload) await _reload();
  }

  // --- reveal ----------------------------------------------------------------------------------------------------

  /// The app lock (PIN / fingerprint), asked every time. Without a lock a value can't be revealed.
  Future<bool> _authenticate() async {
    final l = AppLocalizations.of(context);
    final required = await ref.read(revealLockAvailableProvider.future);
    if (!mounted) return false;
    if (!required) {
      toast(context, l.cfNeedsLock);
      return false;
    }
    return ref.read(vaultAuthProvider)(context);
  }

  Future<void> _revealKeys(ConfigFileDetail d, List<String> keys) async {
    final l = AppLocalizations.of(context);
    if (keys.isEmpty || keys.length > maxRevealKeys || _busy) return;
    if (!await _authenticate() || !mounted) return;
    setState(() => _busy = true);
    try {
      final j = await agentCall(ref, d.host.id, 'POST', '/v1/config-files/${d.fileId}/reveal', {'keys': keys});
      final values = <String, String>{
        for (final MapEntry(:key, :value) in ((j as Map)['values'] as Map? ?? const {}).entries) '$key': '$value',
      };
      if (!mounted) return;
      _reveal.reveal(values);
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      if (((j['missing'] as List?) ?? const []).isNotEmpty) toast(context, l.cfRevealMissing);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String key) async {
    final l = AppLocalizations.of(context);
    final v = _reveal.valueOf(key);
    if (v == null) return;
    await ref.read(sensitiveClipboardProvider).copy(v);
    if (mounted) toast(context, l.cfCopied);
  }

  // --- editing ---------------------------------------------------------------------------------------------------

  Future<_EditResult?> _dialog(_EditMode mode, ConfigFileDetail d, {EditRow? row}) async {
    _editing++;
    _syncSecure();
    try {
      return await showDialog<_EditResult>(
        context: context,
        builder: (_) => _EditDialog(mode: mode, entries: d.entries, edits: _edits, row: row),
      );
    } finally {
      _editing--;
      _syncSecure();
    }
  }

  Future<void> _add(ConfigFileDetail d) async {
    final r = await _dialog(_EditMode.add, d);
    if (r == null) return;
    setState(() => _edits.add(r.key, r.value));
  }

  Future<void> _edit(ConfigFileDetail d, EditRow row) async {
    final r = await _dialog(row.state == EditState.added ? _EditMode.addedValue : _EditMode.value, d, row: row);
    if (r == null) return;
    setState(() {
      if (row.state == EditState.added) {
        _edits.editAdded(row.key, row.key, r.value);
      } else {
        _edits.setValue(row.entry!.key, r.value, row.entry!);
      }
    });
  }

  Future<void> _rename(ConfigFileDetail d, EditRow row) async {
    final r = await _dialog(_EditMode.rename, d, row: row);
    if (r == null) return;
    setState(() {
      if (row.state == EditState.added) {
        _edits.editAdded(row.key, r.key, _edits.addedValue(row.key) ?? '');
      } else {
        _edits.rename(row.entry!.key, r.key);
      }
    });
  }

  Future<void> _meta(ConfigFileDetail d, ConfigEntry e) async {
    final l = AppLocalizations.of(context);
    final r = await showModalBottomSheet<_MetaResult>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MetaSheet(entry: e),
    );
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await agentCall(ref, d.host.id, 'PUT', '/v1/secrets/meta', {
        'updates': [
          {'fileId': d.fileId, 'key': e.key, if (r.markChanged) 'secret': r.mark, if (r.maxChanged) 'maxAgeDays': r.maxAgeDays},
        ],
      });
      _reveal.clear();
      ref.invalidate(configFileProvider(_key));
      ref.invalidate(configFilesProvider(d.host.id));
    } catch (err) {
      if (mounted) toast(context, agentErrorText(l, err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBackups(ConfigFileDetail d) async {
    final changed = await context.push<bool>('/configfiles/backups?host=${Uri.encodeQueryComponent(d.host.id)}&id=${Uri.encodeQueryComponent(d.fileId)}');
    if (changed == true && mounted) await _reload();
  }

  Future<void> _menu(ConfigFileDetail d, EditRow row) async {
    final l = AppLocalizations.of(context);
    final e = row.entry;
    final editable = !d.readOnly;
    final secret = e?.secret ?? false;
    final act = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Align(alignment: Alignment.centerLeft, child: Text(row.key, style: TextStyle(fontFamily: monoFamily, fontSize: 15, fontWeight: FontWeight.w700, color: c.tokens.text)))),
          if (row.state == EditState.deleted || (row.state != EditState.none && row.state != EditState.added))
            ListTile(leading: const Icon(LucideIcons.undo2), title: Text(l.cfUndo), onTap: () => Navigator.pop(c, 'undo')),
          if (row.state == EditState.added) ListTile(leading: const Icon(LucideIcons.undo2), title: Text(l.cfDiscardNew), onTap: () => Navigator.pop(c, 'discard')),
          if (secret && e != null && row.state != EditState.deleted)
            _reveal.isRevealed(e.key)
                ? ListTile(leading: const Icon(LucideIcons.eyeOff), title: Text(l.cfHide), onTap: () => Navigator.pop(c, 'hide'))
                : ListTile(leading: const Icon(LucideIcons.eye), title: Text(l.cfShow), onTap: () => Navigator.pop(c, 'show')),
          if (row.state != EditState.deleted) ...[
            ListTile(enabled: editable, leading: const Icon(LucideIcons.pencil), title: Text(l.cfEditValue), onTap: () => Navigator.pop(c, 'edit')),
            ListTile(enabled: editable, leading: const Icon(LucideIcons.textCursorInput), title: Text(l.cfRenameKey), onTap: () => Navigator.pop(c, 'rename')),
            if (row.state != EditState.added) ListTile(enabled: editable, leading: Icon(LucideIcons.trash2, color: c.tokens.danger), title: Text(l.cfDeleteKey, style: TextStyle(color: c.tokens.danger)), onTap: () => Navigator.pop(c, 'delete')),
          ],
          if (e != null && row.state == EditState.none) ListTile(leading: const Icon(LucideIcons.keyRound), title: Text(l.cfSecretSettings), onTap: () => Navigator.pop(c, 'meta')),
        ]),
      ),
    );
    if (act == null || !mounted) return;
    switch (act) {
      case 'undo':
        setState(() => _edits.undo(e!.key));
      case 'discard':
        setState(() => _edits.removeAdded(row.key));
      case 'show':
        await _revealKeys(d, [e!.key]);
      case 'hide':
        _reveal.hide(e!.key);
      case 'edit':
        await _edit(d, row);
      case 'rename':
        await _rename(d, row);
      case 'delete':
        setState(() => _edits.delete(e!.key));
      case 'meta':
        await _meta(d, e!);
    }
  }

  // --- build -----------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(configFileProvider(_key));
    final d = async.value;
    return SettingsPage(
      title: d == null ? l.cfTitle : d.file.split('/').last,
      onSave: d == null || _edits.isEmpty || d.readOnly ? null : () => _save(d),
      onRefresh: () async {
        ref.invalidate(configFileProvider(_key));
        await ref.read(configFileProvider(_key).future).then((_) {}, onError: (_) {});
      },
      actions: [
        if (d != null) IconButton(tooltip: l.cfBackups, icon: const Icon(LucideIcons.history), onPressed: () => _openBackups(d)),
      ],
      children: async.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          TCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(agentErrorText(l, e)),
            const SizedBox(height: 8),
            TextButton(onPressed: () => ref.invalidate(configFileProvider(_key)), child: Text(l.commonRetry)),
          ])),
        ],
        data: (det) => _body(context, d ?? det),
      ),
    );
  }

  List<Widget> _body(BuildContext context, ConfigFileDetail d) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final rows = _edits.rows(d.entries);
    final hasSecrets = d.entries.any((e) => e.secret && !e.duplicate);
    final focus = widget.focusKey;
    if (focus != null && !_focusScrolled && rows.any((r) => r.key == focus)) {
      _focusScrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _focusRow.currentContext;
        if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: Duration.zero, alignment: 0.3);
      });
    }
    return [
      TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.file, style: TextStyle(fontFamily: monoFamily, fontSize: 14, fontWeight: FontWeight.w700, color: t.text)),
          const SizedBox(height: 4),
          Text(
            [
              if (d.stack != null) d.stack!,
              formatSize(d.size, locale),
              if (d.mode.isNotEmpty) d.mode,
              if (d.modifiedAt != null) DateFormat('d MMM HH:mm', locale).format(d.modifiedAt!),
            ].join(' · '),
            style: tt.bodySmall,
          ),
          for (final w in d.warnings) _Banner(configWarningText(l, w, d.mode), t.warning),
          if (d.unterminatedQuote != null) _Banner(l.cfReadOnlyQuote(d.unterminatedQuote!.line), t.danger),
          for (final i in d.otherIssues) _Banner(configIssueText(l, i), t.warning),
        ]),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(onPressed: d.readOnly || _busy ? null : () => _add(d), icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.cfAddKey)),
        if (hasSecrets)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => setState(() {
              _selecting = !_selecting;
              _selected.clear();
            }),
            icon: Icon(_selecting ? LucideIcons.x : LucideIcons.listChecks, size: 16),
            label: Text(_selecting ? l.commonCancel : l.cfSelect),
          ),
      ]),
      if (_selecting)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TCard(
            child: Row(children: [
              Expanded(child: Text(l.cfSelectedCount(_selected.length, maxRevealKeys), style: tt.bodyMedium)),
              FilledButton.icon(
                onPressed: _selected.isEmpty || _busy ? null : () => _revealKeys(d, _selected.toList()),
                icon: const Icon(LucideIcons.eye, size: 16),
                label: Text(l.cfShowSelected),
              ),
            ]),
          ),
        ),
      if (!_reveal.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TCard(
            child: Row(children: [
              Icon(LucideIcons.timer, size: 18, color: t.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(l.cfRevealedNote(revealLifetime.inSeconds), style: tt.bodyMedium)),
              TextButton(onPressed: _reveal.clear, child: Text(l.cfHideAll)),
            ]),
          ),
        ),
      if (!_edits.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TCard(
            child: Row(children: [
              Icon(LucideIcons.pencilLine, size: 18, color: t.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(l.cfStagedNote(_edits.count), style: tt.bodyMedium)),
              TextButton(onPressed: () => setState(_edits.clear), child: Text(l.cfDiscardAll)),
            ]),
          ),
        ),
      const SizedBox(height: 10),
      if (rows.isEmpty)
        TCard(child: Text(l.cfNoEntries))
      else
        TCard(
          padding: EdgeInsets.zero,
          radius: TiphysTokens.radiusList,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: t.separator, height: 1),
              _EntryTile(
                key: focus != null && rows[i].key == focus && rows[i].entry?.duplicate != true ? _focusRow : null,
                highlighted: focus != null && rows[i].key == focus && rows[i].entry?.duplicate != true,
                row: rows[i],
                revealed: rows[i].entry != null ? _reveal.valueOf(rows[i].entry!.key) : null,
                selecting: _selecting,
                selected: rows[i].entry != null && _selected.contains(rows[i].entry!.key),
                canSelect: _selected.length < maxRevealKeys,
                onTap: () => _selecting && rows[i].entry != null && rows[i].entry!.secret && !rows[i].entry!.duplicate
                    ? setState(() => _selected.contains(rows[i].entry!.key) ? _selected.remove(rows[i].entry!.key) : _selected.add(rows[i].entry!.key))
                    : (rows[i].entry?.duplicate == true ? toast(context, l.cfDuplicateNote) : _menu(d, rows[i])),
                onShow: rows[i].entry == null ? null : () => _revealKeys(d, [rows[i].entry!.key]),
                onHide: rows[i].entry == null ? null : () => _reveal.hide(rows[i].entry!.key),
                onCopy: rows[i].entry == null ? null : () => _copy(rows[i].entry!.key),
              ),
            ],
          ]),
        ),
    ];
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(LucideIcons.triangleAlert, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ]),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

/// One key: secret icon, name, masked (or revealed) value, age chip and the per-key actions.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    this.highlighted = false,
    required this.row,
    required this.revealed,
    required this.selecting,
    required this.selected,
    required this.canSelect,
    required this.onTap,
    this.onShow,
    this.onHide,
    this.onCopy,
  });
  final EditRow row;

  /// The key the user came for (from the rotation list).
  final bool highlighted;
  final String? revealed;
  final bool selecting;
  final bool selected;
  final bool canSelect;
  final VoidCallback onTap;
  final VoidCallback? onShow, onHide, onCopy;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final e = row.entry;
    final secret = e?.secret ?? false;
    final deleted = row.state == EditState.deleted;
    final dup = e?.duplicate ?? false;
    final mono = TextStyle(fontFamily: monoFamily, fontSize: 12.5, height: 1.35, color: deleted || dup ? t.textSecondary : t.text);

    String valueText() {
      if (revealed != null) return revealed!;
      if (row.state == EditState.added) return maskedText(row.newLength ?? 0);
      if (row.state == EditState.changed) return secret ? maskedText(row.newLength ?? 0) : (row.newValue ?? '');
      if (secret) return e!.masked;
      if (e == null) return '';
      return e.inherited ? l.cfInherited : (e.value ?? '').isEmpty ? l.cfEmptyValue : e.value!;
    }

    final stateChip = switch (row.state) {
      EditState.added => _Pill(l.cfChangeAdded, t.success),
      EditState.changed => _Pill(l.cfChangeChanged, t.warning),
      EditState.renamed => _Pill(l.cfChangeRenamed, t.accent),
      EditState.deleted => _Pill(l.cfChangeRemoved, t.danger),
      EditState.none => null,
    };
    final age = e != null && secret && e.ageDays != null ? _Pill(e.due ? l.cfAgeDue(e.ageDays!) : l.cfAgeDays(e.ageDays!), e.due ? t.danger : t.textSecondary) : null;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? t.accent.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (selecting && secret && !dup)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Checkbox(value: selected, onChanged: selected || canSelect ? (_) => onTap() : null, visualDensity: VisualDensity.compact),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 10),
              child: Icon(row.state == EditState.added ? LucideIcons.plus : (secret ? LucideIcons.lock : LucideIcons.fileText), size: 18, color: secret ? t.accent : t.textSecondary),
            ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    row.key,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 13.5, fontWeight: FontWeight.w700, color: deleted || dup ? t.textSecondary : t.text, decoration: deleted ? TextDecoration.lineThrough : null),
                  ),
                ),
                ?stateChip,
                ?age,
                if (dup) _Pill(l.cfOverridden, t.textSecondary),
                if (e != null && e.mark == true) _Pill(l.cfMarkedSecret, t.accent),
              ]),
              if (row.state == EditState.renamed && e != null) Text('← ${e.key}', style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
              const SizedBox(height: 2),
              if (!deleted) Text(valueText(), maxLines: revealed != null ? 8 : 2, overflow: TextOverflow.ellipsis, style: mono),
            ]),
          ),
          if (!selecting && secret && !deleted && !dup && row.state != EditState.added)
            revealed == null
                ? IconButton(tooltip: l.cfShow, icon: const Icon(LucideIcons.eye, size: 20), onPressed: onShow, visualDensity: VisualDensity.compact)
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(tooltip: l.cfCopy, icon: const Icon(LucideIcons.copy, size: 19), onPressed: onCopy, visualDensity: VisualDensity.compact),
                    IconButton(tooltip: l.cfHide, icon: const Icon(LucideIcons.eyeOff, size: 20), onPressed: onHide, visualDensity: VisualDensity.compact),
                  ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Edit dialog

enum _EditMode { add, value, addedValue, rename }

class _EditResult {
  const _EditResult(this.key, this.value);
  final String key;
  final String value;
}

/// Add a key, change a value or rename a key. A secret's current value is never prefilled (the app doesn't have it).
class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.mode, required this.entries, required this.edits, this.row});
  final _EditMode mode;
  final List<ConfigEntry> entries;
  final ConfigEdits edits;
  final EditRow? row;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _key = TextEditingController(text: widget.mode == _EditMode.rename ? widget.row?.key : '');
  late final _value = TextEditingController(text: _initialValue());
  late bool _hidden = switch (widget.mode) {
    _EditMode.value => widget.row?.entry?.secret ?? false,
    _EditMode.addedValue => looksSecretName(widget.row?.key ?? ''),
    _ => false,
  };

  String _initialValue() {
    final r = widget.row;
    if (widget.mode == _EditMode.addedValue && r != null) return widget.edits.addedValue(r.key) ?? '';
    if (widget.mode != _EditMode.value || r == null || r.entry == null || r.entry!.secret) return '';
    return r.newValue ?? r.entry!.value ?? '';
  }

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  bool get _secretValue => widget.mode == _EditMode.value && (widget.row?.entry?.secret ?? false);

  String? _keyError(AppLocalizations l) {
    final k = _key.text.trim();
    if (k.isEmpty) return null;
    if (!validConfigKey(k)) return l.cfKeyInvalid;
    final except = widget.mode == _EditMode.rename ? (widget.row?.entry?.key ?? widget.row?.key) : null;
    if (widget.edits.nameTaken(k, widget.entries, except: except)) return l.cfKeyTaken;
    return null;
  }

  bool _valid(AppLocalizations l) {
    switch (widget.mode) {
      case _EditMode.rename:
        return _key.text.trim().isNotEmpty && _keyError(l) == null;
      case _EditMode.add:
        return _key.text.trim().isNotEmpty && _keyError(l) == null && _value.text.length <= 65536;
      case _EditMode.value || _EditMode.addedValue:
        // A secret can't be set to nothing by accident; a plain value may be empty.
        return (!_secretValue || _value.text.isNotEmpty) && _value.text.length <= 65536;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final title = switch (widget.mode) {
      _EditMode.add => l.cfAddKey,
      _EditMode.rename => l.cfRenameKey,
      _ => l.cfEditValue,
    };
    final showKey = widget.mode == _EditMode.add || widget.mode == _EditMode.rename;
    final showValue = widget.mode != _EditMode.rename;
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!showKey && widget.row != null) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(widget.row!.key, style: TextStyle(fontFamily: monoFamily, fontWeight: FontWeight.w700)))),
          if (showKey)
            TextField(
              controller: _key,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(fontFamily: monoFamily, fontSize: 14),
              decoration: InputDecoration(labelText: l.cfKeyName, errorText: _keyError(l)),
              onChanged: (v) => setState(() {
                if (widget.mode == _EditMode.add && !_value.text.isNotEmpty) _hidden = looksSecretName(v);
              }),
            ),
          if (showValue) ...[
            if (showKey) const SizedBox(height: 10),
            TextField(
              controller: _value,
              autofocus: !showKey,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: _hidden,
              maxLines: _hidden ? 1 : 4,
              minLines: 1,
              style: TextStyle(fontFamily: monoFamily, fontSize: 14),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _secretValue ? l.cfNewValue : l.cfValue,
                helperText: _secretValue ? l.cfSecretNotPrefilled : null,
                helperMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _hidden ? l.cfShow : l.cfHide,
                  icon: Icon(_hidden ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: _valid(l) ? () => Navigator.pop(context, _EditResult(_key.text.trim(), _value.text)) : null,
          child: Text(l.cfStage),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Secret settings (mark + rotation age)

class _MetaResult {
  const _MetaResult({required this.markChanged, this.mark, required this.maxChanged, this.maxAgeDays});
  final bool markChanged;
  final bool? mark;
  final bool maxChanged;
  final int? maxAgeDays;
}

/// Mark a key as secret / not secret (or back to automatic) and set after how many days it should be rotated.
class _MetaSheet extends StatefulWidget {
  const _MetaSheet({required this.entry});
  final ConfigEntry entry;
  @override
  State<_MetaSheet> createState() => _MetaSheetState();
}

class _MetaSheetState extends State<_MetaSheet> {
  late bool? _mark = widget.entry.mark;
  late final _days = TextEditingController(text: widget.entry.maxAgeDays?.toString() ?? '');

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  int? get _parsed => int.tryParse(_days.text.trim());
  bool get _daysValid => _days.text.trim().isEmpty || (_parsed != null && _parsed! >= 1 && _parsed! <= 3650);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final e = widget.entry;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(l.cfSecretSettings, style: tt.bodySmall),
            Text(e.key, style: tt.titleLarge?.copyWith(fontFamily: monoFamily, fontSize: 18)),
            const SizedBox(height: 14),
            Text(l.cfMarkTitle, style: tt.titleSmall),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 0, label: Text(l.cfMarkAuto)),
                  ButtonSegment(value: 1, label: Text(l.cfMarkSecret)),
                  ButtonSegment(value: 2, label: Text(l.cfMarkPlain)),
                ],
                selected: {_mark == null ? 0 : (_mark! ? 1 : 2)},
                onSelectionChanged: (s) => setState(() => _mark = switch (s.first) { 1 => true, 2 => false, _ => null }),
              ),
            ),
            const SizedBox(height: 16),
            Text(l.cfMaxAgeTitle, style: tt.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _days,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: l.cfMaxAgeDays, errorText: _daysValid ? null : l.cfMaxAgeInvalid, helperText: l.cfMaxAgeHelp, helperMaxLines: 3),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              ActionChip(label: Text(l.cfMaxAgeSuggest(suggestedMaxAgeDays)), onPressed: () => setState(() => _days.text = '$suggestedMaxAgeDays')),
              if (_days.text.isNotEmpty) ActionChip(label: Text(l.cfMaxAgeClear), onPressed: () => setState(_days.clear)),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
              const Spacer(),
              FilledButton(
                onPressed: !_daysValid
                    ? null
                    : () => Navigator.pop(
                          context,
                          _MetaResult(markChanged: _mark != e.mark, mark: _mark, maxChanged: _parsed != e.maxAgeDays, maxAgeDays: _parsed),
                        ),
                child: Text(l.commonSave),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
