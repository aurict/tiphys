// SSH keys (Settings › Keys): import (file/paste), generate on the phone, copy/share the public key,
// add it to a host's authorized_keys file, delete.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../core/ssh/keys.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../terminal/sessions.dart';
import '../terminal/terminal_screen.dart';

class SshKeysSection extends ConsumerWidget {
  const SshKeysSection({super.key});

  Future<void> _save(WidgetRef ref, String label, ParsedKey k) async {
    final p = ref.read(profileProvider);
    var id = slugify('ssh-$label');
    if (id.isEmpty) id = 'ssh-key';
    final base = id;
    for (var i = 2; p.keys.any((x) => x.id == id); i++) {
      id = '$base-$i';
    }
    await ref.read(secretStoreProvider).write(id, k.unencryptedPem);
    await ref.read(profileProvider.notifier).update(
          (p) => p.copyWith(keys: [...p.keys, KeyInfo(id: id, label: label, type: k.type, publicKey: k.publicLine)]),
        );
    ref.invalidate(secretIdsProvider);
  }

  Future<void> _add(BuildContext context, WidgetRef ref, {required String mode}) async {
    final l = AppLocalizations.of(context);
    final label = TextEditingController(text: mode == 'generate' ? 'Tiphys (${DateTime.now().year})' : '');
    final pem = TextEditingController();
    final pass = TextEditingController();
    if (mode == 'file') {
      final f = await FilePicker.pickFile();
      if (f == null) return;
      pem.text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      label.text = f.name;
    }
    if (!context.mounted) return;
    final formKey = GlobalKey<FormState>();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(switch (mode) { 'generate' => l.keyGenerate, 'file' => l.keyImportFile, _ => l.keyPaste }),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TField(controller: label, label: l.keyLabel, validator: requiredV(l)),
                if (mode == 'paste') ...[
                  const SizedBox(height: 10),
                  TField(controller: pem, label: l.keyPrivate, mono: true, maxLines: 6, hint: '-----BEGIN OPENSSH PRIVATE KEY-----'),
                ],
                if (mode != 'generate') ...[
                  const SizedBox(height: 10),
                  TField(controller: pass, label: '${l.keyPassphrase} (${l.commonOptional})', obscure: true),
                ],
                if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: context.tokens.danger))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonCancel)),
            TextButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                try {
                  final k = mode == 'generate'
                      ? await generateEd25519(label.text.trim())
                      : parsePrivateKey(pem.text, passphrase: pass.text.isEmpty ? null : pass.text, comment: label.text.trim());
                  await _save(ref, label.text.trim(), k);
                  if (c.mounted) Navigator.pop(c);
                } on NeedsPassphrase {
                  setState(() => error = l.keyNeedsPassphrase);
                } on InvalidKey catch (e) {
                  setState(() => error = e.reason == 'passphrase' ? l.profilePassphraseWrong : l.keyInvalid);
                }
              },
              child: Text(mode == 'generate' ? l.keyGenerate : l.commonAdd),
            ),
          ],
        ),
      ),
    );
    for (final c in [label, pem, pass]) {
      c.dispose();
    }
  }

  Future<void> _details(BuildContext context, WidgetRef ref, KeyInfo k) async {
    final l = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(k.label, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            TCard(child: SelectableText(k.publicKey, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5))),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: k.publicKey));
                    toast(context, l.commonCopied);
                  },
                  icon: const Icon(LucideIcons.copy, size: 18),
                  label: Text(l.commonCopy),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => SharePlus.instance.share(ShareParams(text: k.publicKey)),
                  icon: const Icon(LucideIcons.share2, size: 18),
                  label: Text(l.commonShare),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(c);
                _install(context, ref, k);
              },
              icon: const Icon(LucideIcons.serverCog, size: 18),
              label: Text(l.keyInstallOnHost),
            ),
            TextButton(
              onPressed: () async {
                if (!await confirmDialog(c, message: l.keyDeleteConfirm(k.label), confirmLabel: l.commonDelete, destructive: true)) return;
                await ref.read(secretStoreProvider).delete(k.id);
                await ref.read(profileProvider.notifier).update((p) => p.copyWith(keys: p.keys.where((x) => x.id != k.id).toList()));
                ref.invalidate(secretIdsProvider);
                if (c.mounted) Navigator.pop(c);
              },
              style: TextButton.styleFrom(foregroundColor: context.tokens.danger),
              child: Text(l.commonDelete),
            ),
          ]),
        ),
      ),
    );
  }

  /// Adds the public key to a host (connecting with the current login method).
  Future<void> _install(BuildContext context, WidgetRef ref, KeyInfo k) async {
    final l = AppLocalizations.of(context);
    final hosts = ref.read(profileProvider).hosts.where((h) => h.ssh != null).toList();
    final host = await showDialog<Host>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(l.keyInstallOnHost),
        children: [for (final h in hosts) SimpleDialogOption(onPressed: () => Navigator.pop(c, h), child: Text('${h.name} (${h.ssh!.user}@${h.address})'))],
      ),
    );
    if (host == null || !context.mounted) return;
    toast(context, l.sshConnecting(host.name));
    try {
      final conn = await ref.read(sshOpenerProvider)(host);
      final r = await conn.exec(installKeyCommand(k.publicKey));
      conn.close();
      if (!context.mounted) return;
      toast(context, r.stdout.contains('TIPHYS_KEY_OK') ? l.keyInstalled(host.name) : '${l.commonError}: ${r.stderr.trim()}');
    } on SshFailure catch (f) {
      if (context.mounted) toast(context, sshFailureText(l, f));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final keys = ref.watch(profileProvider.select((p) => p.keys));
    final stored = ref.watch(secretIdsProvider).value ?? const <String>{};
    return GroupedSection(title: l.keysSshKeys, children: [
      for (final k in keys)
        GroupedRow(
          title: k.label,
          subtitle: '${k.type} · ${k.id}',
          icon: LucideIcons.keyRound,
          iconBackground: stored.contains(k.id) ? t.success : t.warning,
          trailingText: stored.contains(k.id) ? null : l.secretNeedsValue,
          onTap: () => _details(context, ref, k),
        ),
      GroupedRow(title: l.keyGenerate, icon: LucideIcons.sparkles, iconBackground: t.accent, onTap: () => _add(context, ref, mode: 'generate')),
      GroupedRow(title: l.keyImportFile, icon: LucideIcons.fileKey, iconBackground: const Color(0xFF6C6C70), onTap: () => _add(context, ref, mode: 'file')),
      GroupedRow(title: l.keyPaste, icon: LucideIcons.clipboardPaste, iconBackground: const Color(0xFF6C6C70), onTap: () => _add(context, ref, mode: 'paste')),
    ]);
  }
}
