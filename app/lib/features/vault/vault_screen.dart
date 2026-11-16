// Settings › Security › Password vault: search, entry details (show/hide, copy), add/edit/delete,
// password generator, import from the Markdown password list on the PC (vault_import.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/vault/vault.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'vault_import.dart';
import 'vault_state.dart';

/// Copies the password to the sensitive clipboard (cleared after 30 s).
Future<void> copyVaultPassword(BuildContext context, WidgetRef ref, String password) async {
  final l = AppLocalizations.of(context);
  await ref.read(sensitiveClipboardProvider).copy(password);
  if (context.mounted) toast(context, l.vaultPasswordCopied(ref.read(sensitiveClipboardProvider).clearAfter.inSeconds));
}

String? _subtitle(VaultEntry e) {
  final s = [if (e.username.isNotEmpty) e.username, if (e.url.isNotEmpty) _urlHost(e.url), if (e.tags.isNotEmpty) e.tags.join(', ')].join(' · ');
  return s.isEmpty ? null : s;
}

String _urlHost(String url) => Uri.tryParse(url)?.host.isNotEmpty == true ? Uri.parse(url).host : url;

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});
  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return VaultScope(
      root: true,
      builder: (context, entries) {
        final shown = searchVault(entries, _q.text);
        return SettingsPage(
          title: l.vaultTitle,
          actions: [
            IconButton(tooltip: l.vaultImport, icon: const Icon(LucideIcons.fileDown), onPressed: () => _open(const VaultImportPage())),
            IconButton(tooltip: l.vaultAdd, icon: const Icon(LucideIcons.plus), onPressed: () => _open(const VaultEditPage())),
            IconButton(tooltip: l.vaultLock, icon: const Icon(LucideIcons.lock), onPressed: () => ref.read(vaultProvider.notifier).lock()),
          ],
          children: [
            const SizedBox(height: 8),
            if (entries.isEmpty)
              TCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.vaultEmpty, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(l.vaultEmptyHint, style: TextStyle(color: t.textSecondary)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(onPressed: () => _open(const VaultEditPage()), icon: const Icon(LucideIcons.plus, size: 18), label: Text(l.vaultAdd)),
                    OutlinedButton.icon(onPressed: () => _open(const VaultImportPage()), icon: const Icon(LucideIcons.fileDown, size: 18), label: Text(l.vaultImport)),
                  ]),
                ]),
              )
            else ...[
              TextField(
                controller: _q,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: l.vaultSearchHint, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
              ),
              const SizedBox(height: 12),
              if (shown.isEmpty)
                TCard(child: Text(l.commonNothingFound))
              else
                GroupedSection(
                  footer: l.vaultFooter(entries.length, vaultIdleTimeout.inMinutes),
                  children: [
                    for (final e in shown)
                      GroupedRow(
                        title: e.title,
                        subtitle: _subtitle(e),
                        icon: LucideIcons.keyRound,
                        iconBackground: e.password.isEmpty ? const Color(0xFF8E8E93) : t.accent,
                        onTap: () => _open(VaultEntryPage(id: e.id)),
                      ),
                  ],
                ),
            ],
          ],
        );
      },
    );
  }
}

class VaultEntryPage extends ConsumerStatefulWidget {
  const VaultEntryPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<VaultEntryPage> createState() => _VaultEntryPageState();
}

class _VaultEntryPageState extends ConsumerState<VaultEntryPage> {
  bool _reveal = false;

  Future<void> _delete(VaultEntry e) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.vaultDeleteConfirm(e.title), confirmLabel: l.commonDelete, destructive: true)) return;
    try {
      await ref.read(vaultProvider.notifier).delete(e.id);
    } on VaultLockedError {
      if (mounted) toast(context, '${l.vaultLocked}. ${l.vaultLockedHint}');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return VaultScope(builder: (context, entries) {
      final e = entries.where((x) => x.id == widget.id).firstOrNull;
      if (e == null) return SettingsPage(title: l.vaultTitle, children: [TCard(child: Text(l.commonNothingFound))]);
      const mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14, fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')]);
      return SettingsPage(
        title: e.title,
        actions: [
          IconButton(
            tooltip: l.commonEdit,
            icon: const Icon(LucideIcons.pencil),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VaultEditPage(entry: e))),
          ),
          IconButton(tooltip: l.commonDelete, icon: Icon(LucideIcons.trash2, color: t.danger), onPressed: () => _delete(e)),
        ],
        children: [
          GroupedSection(children: [
            if (e.username.isNotEmpty)
              GroupedRow(
                title: e.username,
                subtitle: l.vaultUsername,
                icon: LucideIcons.user,
                iconBackground: const Color(0xFF5E5CE6),
                showChevron: false,
                trailing: IconButton(
                  tooltip: l.vaultCopyUsername,
                  icon: const Icon(LucideIcons.copy, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: e.username));
                    toast(context, l.commonCopied);
                  },
                ),
              ),
            if (e.password.isNotEmpty)
              GroupedRow(
                title: _reveal ? e.password : '•' * 12,
                subtitle: l.vaultPassword,
                icon: LucideIcons.keyRound,
                iconBackground: t.accent,
                showChevron: false,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: _reveal ? l.vaultHide : l.vaultReveal,
                    isSelected: _reveal,
                    icon: Icon(_reveal ? LucideIcons.eyeOff : LucideIcons.eye, size: 20),
                    onPressed: () => setState(() => _reveal = !_reveal),
                  ),
                  IconButton(tooltip: l.vaultCopyPassword, icon: const Icon(LucideIcons.copy, size: 20), onPressed: () => copyVaultPassword(context, ref, e.password)),
                ]),
              ),
            if (e.url.isNotEmpty)
              GroupedRow(
                title: e.url,
                subtitle: l.vaultUrl,
                icon: LucideIcons.globe,
                iconBackground: const Color(0xFF0A84FF),
                external: Uri.tryParse(e.url)?.hasScheme == true,
                onTap: Uri.tryParse(e.url)?.isScheme('http') == true || Uri.tryParse(e.url)?.isScheme('https') == true
                    ? () => launchUrl(Uri.parse(e.url), mode: LaunchMode.externalApplication)
                    : null,
              ),
            if (e.tags.isNotEmpty)
              GroupedRow(title: e.tags.join(', '), subtitle: l.vaultTags, icon: LucideIcons.tag, iconBackground: const Color(0xFFFF9F0A), showChevron: false),
          ]),
          if (e.notes.isNotEmpty) ...[
            SectionLabel(l.vaultNotes),
            TCard(child: SelectableText(e.notes, style: e.notes.contains('`') ? mono.copyWith(fontSize: 13) : null)),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(l.vaultUpdated(DateFormat('d MMM y HH:mm', locale).format(e.updatedAt.toLocal())), style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
          ),
        ],
      );
    });
  }
}

class VaultEditPage extends ConsumerStatefulWidget {
  const VaultEditPage({super.key, this.entry});

  /// null = new entry.
  final VaultEntry? entry;
  @override
  ConsumerState<VaultEditPage> createState() => _VaultEditPageState();
}

class _VaultEditPageState extends ConsumerState<VaultEditPage> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.entry?.title);
  late final _user = TextEditingController(text: widget.entry?.username);
  late final _pass = TextEditingController(text: widget.entry?.password);
  late final _url = TextEditingController(text: widget.entry?.url);
  late final _tags = TextEditingController(text: widget.entry?.tags.join(', '));
  late final _notes = TextEditingController(text: widget.entry?.notes);
  bool _reveal = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_title, _user, _pass, _url, _tags, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final now = ref.read(clockProvider)();
    final e = VaultEntry(
      id: widget.entry?.id ?? newVaultId(),
      title: _title.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      url: _url.text.trim(),
      notes: _notes.text.trim(),
      tags: {for (final s in _tags.text.split(',')) if (s.trim().isNotEmpty) s.trim()}.toList(),
      updatedAt: now.toUtc(),
    );
    try {
      await ref.read(vaultProvider.notifier).upsert(e);
    } on VaultLockedError {
      // Don't lose what was typed: the page stays open; the user unlocks and saves again.
      if (mounted) toast(context, '${AppLocalizations.of(context).vaultLocked}. ${AppLocalizations.of(context).vaultLockedHint}');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _generate() async {
    final p = await showPasswordGenerator(context);
    if (p != null) setState(() => _pass.text = p);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return VaultScope(
      builder: (context, _) => Form(
        key: _form,
        child: SettingsPage(
          title: widget.entry == null ? l.vaultAdd : l.commonEdit,
          onSave: _save,
          saving: _saving,
          children: [
            FieldCard(children: [
              TField(controller: _title, label: l.vaultEntryTitle, validator: requiredV(l)),
              TField(controller: _user, label: l.vaultUsername),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _pass,
                    obscureText: !_reveal,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14),
                    decoration: InputDecoration(labelText: l.vaultPassword),
                  ),
                ),
                IconButton(
                  tooltip: _reveal ? l.vaultHide : l.vaultReveal,
                  isSelected: _reveal,
                  icon: Icon(_reveal ? LucideIcons.eyeOff : LucideIcons.eye, size: 20),
                  onPressed: () => setState(() => _reveal = !_reveal),
                ),
                IconButton(tooltip: l.vaultGenerate, icon: const Icon(LucideIcons.wandSparkles, size: 20), onPressed: _generate),
              ]),
              TField(controller: _url, label: l.vaultUrl, keyboardType: TextInputType.url),
              TField(controller: _tags, label: l.vaultTags, helper: l.vaultTagsHint),
              TField(controller: _notes, label: l.vaultNotes, maxLines: 5),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Password generator sheet; returns the generated password via "Kullan".
Future<String?> showPasswordGenerator(BuildContext context) => showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (c) => const _GeneratorSheet(),
    );

class _GeneratorSheet extends StatefulWidget {
  const _GeneratorSheet();
  @override
  State<_GeneratorSheet> createState() => _GeneratorSheetState();
}

class _GeneratorSheetState extends State<_GeneratorSheet> {
  int _length = 20;
  bool _symbols = true;
  late String _value = generatePassword(length: _length, symbols: _symbols);

  void _again() => setState(() => _value = generatePassword(length: _length, symbols: _symbols));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.vaultGenerate, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TCard(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: SelectableText(_value, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 15, fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')]))),
              IconButton(tooltip: l.vaultRegenerate, icon: const Icon(LucideIcons.refreshCw, size: 20), onPressed: _again),
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text(l.vaultLength(_length)),
            Expanded(
              child: Slider(
                value: _length.toDouble(),
                min: 8,
                max: 64,
                divisions: 56,
                label: '$_length',
                semanticFormatterCallback: (v) => l.vaultLength(v.round()),
                onChanged: (v) {
                  _length = v.round();
                  _again();
                },
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.vaultSymbols),
            value: _symbols,
            onChanged: (v) {
              _symbols = v;
              _again();
            },
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context, _value), child: Text(l.vaultUse))),
        ]),
      ),
    );
  }
}
