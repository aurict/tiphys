// Decoys (PLAN.md §15 S-3): fake service tokens, fake .env / SSH key files, decoy database users and SSH hosts that
// report reads of a decoy file. Any use raises a critical alarm (push + the owner's Telegram). A decoy token is shown
// once, in a FLAG_SECURE sheet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import '../telegram/telegram_data.dart' show recipientName, telegramRecipientsProvider;
import 'security_data.dart' show SecurityHostConfig, SecuritySettings, securityCall, securitySettingsProvider;
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import 'security_widgets.dart';
import '../system/agent_providers.dart';

class SecurityTrapsScreen extends ConsumerWidget {
  const SecurityTrapsScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secTrapsTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
        ref.invalidate(securitySettingsProvider);
      },
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _TrapsBlock(agent: a))],
    );
  }
}

class _TrapsBlock extends ConsumerStatefulWidget {
  const _TrapsBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_TrapsBlock> createState() => _TrapsBlockState();
}

class _TrapsBlockState extends ConsumerState<_TrapsBlock> {
  bool _busy = false;
  late final _key = (widget.agent.id, secTrapsPath);

  String get _id => widget.agent.id;

  Future<void> _run(Future<Object?> Function() body, {String? ok}) async {
    setState(() => _busy = true);
    await secAct(context, body, ok: ok);
    if (mounted) setState(() => _busy = false);
    ref.invalidate(securityGetProvider(_key));
  }

  Future<void> _test() async {
    final l = AppLocalizations.of(context);
    await _run(() => securityCall(ref, _id, 'POST', '$secTrapsPath/test', body: <String, dynamic>{}), ok: l.secTrapTestSent);
  }

  Future<void> _addToken() async {
    final l = AppLocalizations.of(context);
    final name = await secAskText(context, title: l.secTrapTokenAdd, label: l.secTrapTokenName, hint: 'backup-token', helper: l.secTrapTokenNameHint, validator: (v) => v.isEmpty || v.length > 80 ? l.secInvalid : null, action: l.secTrapCreate);
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    String? token;
    final ok = await secAct(context, () async {
      final j = await securityCall(ref, _id, 'POST', '$secTrapsPath/tokens', body: {'name': name});
      token = j is Map ? '${j['token']}' : null;
    });
    if (mounted) setState(() => _busy = false);
    ref.invalidate(securityGetProvider(_key));
    if (ok && token != null && mounted) {
      await showSecretOnce(context, title: l.secTrapTokenShownTitle(name), value: token!, hint: l.secTrapTokenPlantHint, warning: l.secTrapTokenOpensNothing);
    }
  }

  Future<void> _deleteToken(TrapToken tk) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.secTrapTokenDeleteConfirm(tk.name), confirmLabel: l.commonDelete, destructive: true)) return;
    await _run(() => securityCall(ref, _id, 'DELETE', '$secTrapsPath/tokens/${tk.id}'), ok: l.secDeleted);
  }

  Future<void> _addFile() async {
    final l = AppLocalizations.of(context);
    final r = await showDialog<(String, String)>(context: context, builder: (_) => const _FileDialog());
    if (r == null || !mounted) return;
    await _run(() => securityCall(ref, _id, 'POST', '$secTrapsPath/files', body: {'path': r.$1, 'kind': r.$2}), ok: l.secSaved);
  }

  Future<void> _deleteFile(TrapFile f) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.secTrapFileDeleteConfirm(f.path), confirmLabel: l.commonDelete, destructive: true)) return;
    await _run(() => securityCall(ref, _id, 'DELETE', '$secTrapsPath/files/${f.id}'), ok: l.secDeleted);
  }

  Future<void> _putUsers(List<String> users) async {
    final l = AppLocalizations.of(context);
    await _run(() => securityCall(ref, _id, 'PUT', '$secTrapsPath/db-users', body: {'users': users}), ok: l.secSaved);
  }

  Future<void> _addUser(TrapsData d) async {
    final l = AppLocalizations.of(context);
    final v = await secAskText(context, title: l.secTrapDbAdd, label: l.secTrapDbUser, hint: 'app_backup', mono: true, helper: l.secTrapDbUserHint, validator: (v) => validDbTrapUser(v) ? null : l.secInvalid);
    if (v == null || d.dbUsers.contains(v)) return;
    await _putUsers([...d.dbUsers, v]);
  }

  Future<void> _setHostTraps(SecurityHostConfig h, bool on) async {
    final l = AppLocalizations.of(context);
    await _run(() => securityCall(ref, _id, 'PATCH', '/v1/security/hosts/${Uri.encodeComponent(h.id)}', body: {'traps': on}), ok: l.secSaved);
    ref.invalidate(securitySettingsProvider(_id));
  }

  Future<void> _setRecipient(String? id) async {
    final l = AppLocalizations.of(context);
    await _run(() => securityCall(ref, _id, 'PUT', secAlertsPath, body: {'telegramRecipient': id}), ok: l.secSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final settings = ref.watch(securitySettingsProvider(_id));
    return SecAsync<Map<String, dynamic>>(
      value: ref.watch(securityGetProvider(_key)),
      onRetry: () => ref.invalidate(securityGetProvider(_key)),
      data: (j) {
        final d = TrapsData(j);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          SecNote(l.secTrapsInfo, icon: LucideIcons.bellRing),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _busy ? null : _test, icon: const Icon(LucideIcons.send, size: 16), label: Text(l.secTrapTest)),
          SectionLabel(l.secTrapTokens),
          if (d.tokens.isEmpty) TCard(child: Text(l.secTrapTokensEmpty)),
          if (d.tokens.isNotEmpty)
            GroupedSection(children: [
              for (final tk in d.tokens)
                GroupedRow(
                  title: tk.name,
                  subtitle: tk.createdAt == null ? null : l.secTrapCreatedAt(securityWhen(context, tk.createdAt!)),
                  icon: LucideIcons.keyRound,
                  showChevron: false,
                  trailing: IconButton(tooltip: l.secTrapDeleteTooltip(tk.name), icon: const Icon(LucideIcons.trash2, size: 18), onPressed: _busy ? null : () => _deleteToken(tk)),
                ),
            ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _busy ? null : _addToken, icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secTrapTokenAdd)),
          SectionLabel(l.secTrapFiles),
          if (d.files.isEmpty) TCard(child: Text(l.secTrapFilesEmpty)),
          for (final f in d.files) Padding(padding: const EdgeInsets.only(bottom: 10), child: _FileCard(file: f, onDelete: _busy ? null : () => _deleteFile(f))),
          OutlinedButton.icon(onPressed: _busy ? null : _addFile, icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secTrapFileAdd)),
          Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: Text(l.secTrapFileBackupWarn, style: tt.bodySmall?.copyWith(color: context.tokens.warning))),
          SectionLabel(l.secTrapDbUsers),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.secTrapDbHint, style: tt.bodySmall),
              const SizedBox(height: 8),
              SecChipList(items: d.dbUsers, addLabel: l.secTrapDbAdd, enabled: !_busy, removeLabel: (_) => l.secTrapDbRemove, onAdd: () => _addUser(d), onRemove: (u) => _putUsers([for (final x in d.dbUsers) if (x != u) x])),
            ]),
          ),
          SectionLabel(l.secTrapSshHosts),
          settings.when(
            skipLoadingOnRefresh: true,
            loading: () => const TCard(child: Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))),
            error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
            data: (s) => _sshHosts(context, s),
          ),
          SectionLabel(l.secTrapAlertsTitle),
          _AlertsCard(agent: widget.agent, busy: _busy, onPick: _setRecipient),
        ]);
      },
    );
  }

  Widget _sshHosts(BuildContext context, SecuritySettings s) {
    final l = AppLocalizations.of(context);
    final hosts = [for (final h in s.hosts) if (h.isSsh) h];
    if (hosts.isEmpty) return TCard(child: Text(l.secTrapSshNone));
    return GroupedSection(footer: l.secTrapSshHint, children: [
      for (final h in hosts) SwitchRow(title: h.name, subtitle: l.secTrapSshSwitch, value: h.traps, icon: LucideIcons.terminal, onChanged: _busy ? (_) {} : (v) => _setHostTraps(h, v)),
    ]);
  }
}

class _FileCard extends ConsumerWidget {
  const _FileCard({required this.file, required this.onDelete});
  final TrapFile file;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    final f = file;
    final hint = trapFileStatusHint(l, f.status);
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(f.path, style: tt.titleSmall?.copyWith(fontFamily: monoFamily, fontSize: 13))),
          IconButton(tooltip: l.secTrapDeleteTooltip(f.path), icon: const Icon(LucideIcons.trash2, size: 18), onPressed: onDelete),
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          SecChip(trapFileStatusName(l, f.status), trapFileStatusColor(t, f.status), filled: f.status == 'error'),
          SecChip(trapKindName(l, f.kind), t.textSecondary),
        ]),
        if (hint != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(hint, style: tt.bodySmall)),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(f.lastTriggeredAt == null ? l.secTrapNeverTriggered : l.secTrapTriggeredAgo(relativeTime(l, f.lastTriggeredAt!, now)), style: tt.bodySmall?.copyWith(color: f.lastTriggeredAt == null ? null : t.danger, fontWeight: f.lastTriggeredAt == null ? null : FontWeight.w700)),
        ),
      ]),
    );
  }
}

class _FileDialog extends StatefulWidget {
  const _FileDialog();
  @override
  State<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends State<_FileDialog> {
  final _form = GlobalKey<FormState>();
  final _path = TextEditingController();
  String _kind = 'env';

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secTrapFileAdd),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: 'env', label: Text(l.secTrapKindEnv)), ButtonSegment(value: 'sshkey', label: Text(l.secTrapKindSshKey))],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.single),
            ),
            const SizedBox(height: 12),
            TField(
              controller: _path,
              label: l.secTrapFilePath,
              mono: true,
              hint: _kind == 'env' ? '~/backup/.env.old' : '~/.ssh/id_backup',
              helper: l.secTrapFilePathHint,
              validator: (v) => v.trim().isEmpty || v.trim().length > 1024 ? l.secInvalid : null,
            ),
            const SizedBox(height: 10),
            Text(l.secTrapFileBackupWarn, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.tokens.warning)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: () {
            if (_form.currentState!.validate()) Navigator.pop(context, (_path.text.trim(), _kind));
          },
          child: Text(l.secTrapCreate),
        ),
      ],
    );
  }
}

/// Owner alerts to Telegram: the recipient picker is filled from the same agent's Telegram recipients.
class _AlertsCard extends ConsumerWidget {
  const _AlertsCard({required this.agent, required this.busy, required this.onPick});
  final Host agent;
  final bool busy;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final alerts = ref.watch(securityGetProvider((agent.id, secAlertsPath)));
    final recipients = ref.watch(telegramRecipientsProvider(agent.id));
    return SecAsync<Map<String, dynamic>>(
      value: alerts,
      onRetry: () => ref.invalidate(securityGetProvider((agent.id, secAlertsPath))),
      data: (j) {
        final current = alertRecipientOf(j);
        final list = [for (final r in recipients.value ?? const <Map<String, dynamic>>[]) if (r['status'] != 'stopped') r];
        final known = list.any((r) => '${r['id']}' == current);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(l.secTrapAlertsHint, style: tt.bodySmall)),
          if (recipients.hasError)
            TCard(child: Text(l.secTrapAlertsNoTelegram))
          else if (recipients.isLoading)
            const TCard(child: Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())))
          else
            ChoiceSection<String?>(
              options: [
                (null, l.secTrapAlertsOff),
                for (final r in list) ('${r['id']}', recipientName(r)),
                if (current != null && !known) (current, l.secTrapAlertsUnknown(current)),
              ],
              value: current,
              onChanged: busy ? (_) {} : onPick,
            ),
          if (list.isEmpty && !recipients.hasError && !recipients.isLoading) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(l.secTrapAlertsNoRecipients, style: tt.bodySmall)),
        ]);
      },
    );
  }
}
