// Profile file: export (without secrets / encrypted), import (preview + merge/replace), reset.
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/profile/codec.dart';
import '../../core/profile/merge.dart';
import '../../core/profile/model.dart';
import '../../core/profile/repository.dart';
import '../../core/secrets/secret_box.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../lock/lock_gate.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;

  Future<String?> _askPassphrase({required bool confirm}) async {
    final l = AppLocalizations.of(context);
    final a = TextEditingController(), b = TextEditingController();
    final key = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.profilePassphrase),
        content: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TField(controller: a, label: l.profilePassphrase, obscure: true, autofocus: true,
                validator: (v) => confirm && v.length < 10 ? l.profilePassphraseShort : null),
            if (confirm) ...[
              const SizedBox(height: 12),
              TField(controller: b, label: l.profilePassphraseRepeat, obscure: true, validator: (v) => v == a.text ? null : l.profilePassphraseMismatch),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
          TextButton(onPressed: () => key.currentState!.validate() ? Navigator.pop(c, true) : null, child: Text(l.commonContinue)),
        ],
      ),
    );
    final v = ok == true ? a.text : null;
    a.dispose();
    b.dispose();
    return v;
  }

  Future<void> _share(String text) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final f = File('${dir.path}/tiphys-$stamp.tiphys.json');
    await f.writeAsString(text, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')]));
  }

  Future<void> _export({required bool encrypted}) async {
    final l = AppLocalizations.of(context);
    final repo = ref.read(repositoryProvider);
    final p = ref.read(profileProvider);
    String text;
    if (encrypted) {
      final pass = await _askPassphrase(confirm: true);
      if (pass == null) return;
      setState(() => _busy = true);
      text = await repo.exportEncrypted(p, pass);
    } else {
      text = repo.exportPlain(p);
    }
    setState(() => _busy = false);
    await _share(text);
    if (mounted) toast(context, l.profileExported);
  }

  String _errorText(AppLocalizations l, Object e) => switch (e) {
        NotJson() => l.profileErrorJson,
        NotAProfile() => l.profileErrorFormat,
        NewerSchema(:final version) => l.profileErrorNewer(version),
        InvalidProfile(:final issues) => l.profileErrorInvalid(issues.take(5).join('\n')),
        WrongPassphrase() => l.profilePassphraseWrong,
        _ => l.commonError,
      };

  Future<void> _import() async {
    final l = AppLocalizations.of(context);
    final picked = await FilePicker.pickFile();
    if (picked == null) return;
    final text = utf8.decode(await picked.readAsBytes(), allowMalformed: true);
    final repo = ref.read(repositoryProvider);
    try {
      const mode = ImportMode.merge;
      String? pass;
      // Ask for the password if there's an encrypted section.
      if (repo.codec.decode(text).encryptedSecrets != null) {
        pass = await _askPassphrase(confirm: false);
        if (pass == null) return;
      }
      setState(() => _busy = true);
      var prepared = await repo.prepare(ref.read(profileProvider), text, mode, passphrase: pass);
      setState(() => _busy = false);
      if (!mounted) return;
      final result = await showModalBottomSheet<ImportMode>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
        context: context,
        isScrollControlled: true,
        builder: (c) => _PreviewSheet(
          load: (m) => repo.prepare(ref.read(profileProvider), text, m, passphrase: pass),
          initial: prepared,
        ),
      );
      if (result == null) return;
      if (result != mode) prepared = await repo.prepare(ref.read(profileProvider), text, result, passphrase: pass);
      final applied = await repo.apply(prepared);
      ref.read(profileProvider.notifier).replace(applied);
      ref.invalidate(secretIdsProvider);
      if (mounted) toast(context, l.profileImported);
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(l.commonError),
            content: SingleChildScrollView(child: Text(_errorText(l, e))),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonClose))],
          ),
        );
      }
    }
  }

  Future<void> _reset() async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.profileResetConfirm, confirmLabel: l.profileReset, destructive: true)) return;
    await ref.read(repositoryProvider).reset();
    await ref.read(appLockProvider).clearPin();
    ref.read(profileProvider.notifier).replace(Profile.empty);
    ref.invalidate(secretIdsProvider);
    ref.invalidate(lockRequiredProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return SettingsPage(title: l.settingsProfile, children: [
      if (_busy) const LinearProgressIndicator(),
      GroupedSection(title: l.profileExport, children: [
        GroupedRow(title: l.profileExportPlain, subtitle: l.profileExportPlainHint, icon: LucideIcons.share2, iconBackground: t.accent, onTap: _busy ? null : () => _export(encrypted: false)),
        GroupedRow(title: l.profileExportEncrypted, subtitle: l.profileExportEncryptedHint, icon: LucideIcons.lock, iconBackground: t.success, onTap: _busy ? null : () => _export(encrypted: true)),
      ]),
      GroupedSection(title: l.profileImport, children: [
        GroupedRow(title: l.profileImport, subtitle: l.profileImportHint, icon: LucideIcons.download, iconBackground: const Color(0xFF5E5CE6), onTap: _busy ? null : _import),
      ]),
      const SizedBox(height: 18),
      GroupedSection(children: [GroupedRow(title: l.profileReset, destructive: true, showChevron: false, onTap: _reset)]),
    ]);
  }
}

class _PreviewSheet extends StatefulWidget {
  const _PreviewSheet({required this.load, required this.initial});
  final Future<PreparedImport> Function(ImportMode) load;
  final PreparedImport initial;
  @override
  State<_PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<_PreviewSheet> {
  late PreparedImport _p = widget.initial;
  ImportMode _mode = ImportMode.merge;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final groups = {
      ChangeKind.added: (l.profilePreviewAdded, t.success, LucideIcons.plus),
      ChangeKind.changed: (l.profilePreviewChanged, t.warning, LucideIcons.pencil),
      ChangeKind.removed: (l.profilePreviewRemoved, t.danger, LucideIcons.minus),
    };
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(18, 0, 18, 24), children: [
        Text(l.profilePreviewTitle, style: tt.titleLarge),
        const SizedBox(height: 12),
        SegmentedButton<ImportMode>(
          segments: [
            ButtonSegment(value: ImportMode.merge, label: Text(l.profileModeMerge)),
            ButtonSegment(value: ImportMode.replace, label: Text(l.profileModeReplace)),
          ],
          selected: {_mode},
          onSelectionChanged: (s) async {
            final m = s.first;
            final p = await widget.load(m);
            if (mounted) {
              setState(() {
                _mode = m;
                _p = p;
              });
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_mode == ImportMode.merge ? l.profileModeMergeHint : l.profileModeReplaceHint, style: tt.bodySmall),
        ),
        if (_p.plan.changes.isEmpty)
          Padding(padding: const EdgeInsets.all(18), child: Text(l.profilePreviewUnchanged, textAlign: TextAlign.center)),
        for (final kind in ChangeKind.values)
          if (_p.plan.changes.any((ch) => ch.kind == kind))
            GroupedSection(title: groups[kind]!.$1, children: [
              for (final ch in _p.plan.changes.where((ch) => ch.kind == kind))
                GroupedRow(title: ch.id ?? ch.section, subtitle: ch.id == null ? null : ch.section, icon: groups[kind]!.$3, iconBackground: groups[kind]!.$2),
            ]),
        if (_p.missingSecrets.isNotEmpty)
          GroupedSection(title: l.profileMissingSecrets, children: [
            for (final id in _p.missingSecrets) GroupedRow(title: id, icon: LucideIcons.keyRound, iconBackground: t.warning),
          ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)), child: Text(l.commonCancel))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: () => Navigator.pop(context, _mode), child: Text(l.profileImport))),
        ]),
      ]),
    );
  }
}
