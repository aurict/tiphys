// Preview → confirm sheet of a config save or restore (PLAN.md §13.3): the masked line diff (secret values are never
// shown, only their length), the services that use the changed keys, the one-time preview token's countdown and a
// destructive confirmation. Recreating the affected services comes in phase C-2: the option is shown disabled.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../incidents/incidents_data.dart' show formatArgv;
import '../system/agent_providers.dart';
import 'configfiles_data.dart';
import 'configfiles_texts.dart';

/// What the sheet ended with: [saved] (the file was written), [reload] (the file changed under us: read it again).
class ConfigSheetOutcome {
  const ConfigSheetOutcome({this.saved = false, this.reload = false, this.result, this.restoreBackupId});
  final bool saved;
  final bool reload;
  final ConfigSaveResult? result;

  /// The recreate failed and the user chose "Restore the backup": the backup that undoes the save.
  final String? restoreBackupId;
}

/// Opens the sheet. [load] asks the agent for the preview (POST …/preview or …/restore), [execute] sends the token
/// with `confirm: true` (PUT … or POST …/restore).
Future<ConfigSheetOutcome> showConfigPreviewSheet(
  BuildContext context, {
  required String file,
  required bool restore,
  required Future<dynamic> Function(bool restart) load,
  required Future<dynamic> Function(ConfigPreview preview, bool restart) execute,
}) async {
  // Once written, closing the sheet any way (barrier, back) still reports the save, so the screen reloads.
  ConfigSaveResult? saved;
  final r = await showModalBottomSheet<ConfigSheetOutcome>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    // No drag-to-dismiss: a drag would close the sheet while the write runs (PopScope only stops back and barrier).
    enableDrag: false,
    builder: (_) => ConfigPreviewSheet(file: file, restore: restore, load: load, execute: execute, onSaved: (res) => saved = res),
  );
  return r ?? (saved != null ? ConfigSheetOutcome(saved: true, result: saved) : const ConfigSheetOutcome());
}

class ConfigPreviewSheet extends ConsumerStatefulWidget {
  const ConfigPreviewSheet({super.key, required this.file, required this.restore, required this.load, required this.execute, this.onSaved});
  final String file;

  /// Called once the file was written.
  final ValueChanged<ConfigSaveResult>? onSaved;
  final bool restore;
  final Future<dynamic> Function(bool restart) load;
  final Future<dynamic> Function(ConfigPreview preview, bool restart) execute;

  @override
  ConsumerState<ConfigPreviewSheet> createState() => _ConfigPreviewSheetState();
}

class _ConfigPreviewSheetState extends ConsumerState<ConfigPreviewSheet> {
  ConfigPreview? _preview;
  Object? _error;
  bool _loading = true;
  bool _running = false;

  /// The confirmation dialog is open (a second tap must not open another).
  bool _confirming = false;
  ConfigSaveResult? _result;

  /// Recreate the affected services after writing (the preview token is bound to this choice, so changing it asks for a
  /// new preview). Disabled when no service is affected.
  bool _restart = false;
  Timer? _tick;
  late DateTime _now = ref.read(clockProvider)();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = ref.read(clockProvider)());
    });
    _load();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final j = await widget.load(_restart);
      if (!mounted) return;
      final received = ref.read(clockProvider)();
      setState(() {
        _preview = ConfigPreview(Map<String, dynamic>.from(j as Map), received);
        _now = received;
        _loading = false;
      });
    } catch (e) {
      // No service is affected: the option can't be used; show the plain preview instead.
      if (e is AgentError && e.code == 'agent.configfiles.nothingToRestart' && _restart && mounted) {
        _restart = false;
        return _load();
      }
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    final p = _preview;
    if (p == null || _running || _confirming) return;
    _confirming = true;
    final bool ok;
    try {
      ok = await confirmDialog(
        context,
        message: (widget.restore ? l.cfRestoreConfirm(widget.file) : l.cfSaveConfirm(widget.file)) + (p.restart == 'affected' ? '\n\n${l.cfRestartConfirm}' : ''),
        confirmLabel: widget.restore ? l.cfRestore : l.commonSave,
        destructive: true,
      );
    } finally {
      _confirming = false;
    }
    if (!ok || !mounted) return;
    // The confirmation may have taken a while: don't send a token that has surely expired.
    if (p.expired(ref.read(clockProvider)())) {
      setState(() => _now = ref.read(clockProvider)());
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final j = await widget.execute(p, p.restart == 'affected');
      final res = ConfigSaveResult(Map<String, dynamic>.from(j as Map));
      widget.onSaved?.call(res);
      if (mounted) setState(() => _result = res);
    } catch (e) {
      // The token is spent either way (or the file changed): a new preview is needed to try again.
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final p = _preview;
    final expired = p != null && p.expired(_now);
    final err = _error;
    final needsReload = err is AgentError && configNeedsReload(err.code);
    final canRun = p != null && !expired && !_running && _result == null && p.changes.isNotEmpty;
    return PopScope(
      canPop: !_running,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.restore ? l.cfPreviewRestoreTitle : l.cfPreviewTitle, style: tt.bodySmall),
            const SizedBox(height: 4),
            Text(widget.file, style: tt.titleLarge?.copyWith(fontFamily: monoFamily, fontSize: 18)),
            if (p != null && _result == null) ...[
              const SizedBox(height: 8),
              _Countdown(preview: p, now: _now),
            ],
            const SizedBox(height: 12),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (p != null) ...[
              if (p.changes.isEmpty) TCard(child: Text(l.cfPreviewNoChanges)),
              for (final c in p.changes) Padding(padding: const EdgeInsets.only(bottom: 8), child: ConfigChangeCard(change: c)),
              if (p.otherLinesChanged) _Note(l.cfPreviewOtherLines, t.warning),
              SectionLabel(l.cfAffectedTitle),
              TCard(
                radius: TiphysTokens.radiusList,
                child: p.affected.isEmpty
                    ? Text(l.cfAffectedNone, style: tt.bodyMedium)
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final a in p.affected)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Icon(LucideIcons.layers, size: 16, color: t.accent),
                              const SizedBox(width: 8),
                              Expanded(child: Text('${a.stack.isEmpty ? a.project : a.stack}: ${a.services.join(', ')}', style: tt.bodyMedium)),
                            ]),
                          ),
                      ]),
              ),
              const SizedBox(height: 8),
              TCard(
                radius: TiphysTokens.radiusList,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SwitchListTile(
                  value: _restart && p.restart == 'affected',
                  onChanged: p.affected.isEmpty || _running || _result != null ? null : (v) {
                    _restart = v;
                    _load();
                  },
                  title: Text(l.cfRestartAffected),
                  subtitle: Text(p.affected.isEmpty ? l.cfNothingToRestart : l.cfRestartHint),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              if (p.restart == 'affected' && p.restartPlan.isNotEmpty) ...[
                SectionLabel(l.cfRestartPlan),
                TCard(
                  radius: TiphysTokens.radiusList,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (var i = 0; i < p.restartPlan.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      Text('\$ ${formatArgv(p.restartPlan[i].argv)}', style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, height: 1.4, color: t.text)),
                    ],
                  ]),
                ),
              ],
            ],
            if (_running)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), Text(_preview?.restart == 'affected' ? l.cfRecreating : l.cfSaving)]),
              ),
            if (_result != null) _ResultView(result: _result!, restore: widget.restore),
            if (err != null) _Note(agentErrorText(l, err), t.danger),
            if (expired && _result == null && err == null) _Note(l.incPreviewExpired, t.danger),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(
                onPressed: _running ? null : () => Navigator.pop(context, _result != null ? ConfigSheetOutcome(saved: true, result: _result) : const ConfigSheetOutcome()),
                child: Text(_result != null ? l.commonClose : l.commonCancel),
              ),
              const Spacer(),
              if (_result?.restoreBackupId != null && _result?.recreate?.ok == false)
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, ConfigSheetOutcome(saved: true, result: _result, restoreBackupId: _result!.restoreBackupId)),
                  icon: const Icon(LucideIcons.rotateCcw, size: 16),
                  label: Text(l.cfRestoreBackup),
                )
              else if (_result == null && needsReload)
                FilledButton.icon(onPressed: () => Navigator.pop(context, const ConfigSheetOutcome(reload: true)), icon: const Icon(LucideIcons.refreshCw, size: 16), label: Text(l.cfReload))
              else if (_result == null && (err != null || expired))
                OutlinedButton.icon(onPressed: _running ? null : _load, icon: const Icon(LucideIcons.refreshCw, size: 16), label: Text(l.incPreviewRefresh))
              else if (_result == null)
                FilledButton(onPressed: canRun ? _confirm : null, child: Text(widget.restore ? l.cfRestore : l.commonSave)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// One changed key: its kind, the "-"/"+" lines (secrets masked) and for a secret the change of length.
class ConfigChangeCard extends StatelessWidget {
  const ConfigChangeCard({super.key, required this.change});
  final ConfigChange change;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final color = switch (change.kind) { 'added' => t.success, 'removed' => t.danger, 'renamed' => t.accent, _ => t.warning };
    final len = secretLengthChange(change);
    return TCard(
      radius: TiphysTokens.radiusList,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
            child: Text(changeKindName(l, change.kind), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          if (change.secret) ...[
            const SizedBox(width: 8),
            Icon(LucideIcons.lock, size: 14, color: t.textSecondary),
          ],
          if (len != null && change.kind == 'changed') ...[
            const SizedBox(width: 8),
            Flexible(child: Text(l.cfLengthChange(len.$1, len.$2), style: tt.bodySmall, overflow: TextOverflow.ellipsis)),
          ],
        ]),
        const SizedBox(height: 8),
        for (final line in changeDiff(change))
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: (line.added ? t.success : t.danger).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
            child: Text(
              '${line.added ? '+' : '-'} ${line.text}',
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, height: 1.35, color: t.text),
            ),
          ),
      ]),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.preview, required this.now});
  final ConfigPreview preview;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final left = preview.remaining(now);
    final low = left < const Duration(seconds: 20);
    final s = left.inSeconds;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(LucideIcons.timer, size: 15, color: low ? t.danger : t.textSecondary),
      const SizedBox(width: 4),
      Text(l.incPreviewExpiresIn('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'), style: TextStyle(fontSize: 12.5, color: low ? t.danger : t.textSecondary)),
    ]);
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(LucideIcons.circleAlert, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ]),
      );
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.restore});
  final ConfigSaveResult result;
  final bool restore;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final rc = result.recreate;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(LucideIcons.circleCheck, size: 18, color: t.success),
          const SizedBox(width: 8),
          Expanded(child: Text(restore ? l.cfRestored : l.cfSaved, style: tt.bodyMedium)),
        ]),
        if (result.backupId != null)
          Padding(padding: const EdgeInsets.only(top: 6, left: 26), child: Text(l.cfBackupMade(result.backupId!), style: tt.bodySmall)),
        for (final w in result.warnings) _Note(configWarningText(l, w, ''), t.warning),
        if (rc != null) ...[
          SectionLabel(l.cfRecreateTitle),
          if (!rc.ok) _Note(rc.stage == 'postCheck' ? l.cfRecreateFailedPostCheck : l.cfRecreateFailedCommand, t.danger),
          TCard(
            radius: TiphysTokens.radiusList,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final s in rc.services)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Icon(s.ok ? LucideIcons.circleCheck : LucideIcons.circleX, size: 17, color: s.ok ? t.success : t.danger),
                    const SizedBox(width: 8),
                    Expanded(child: Text(s.service, style: tt.bodyMedium)),
                    Text(s.state, style: tt.bodySmall),
                  ]),
                ),
              for (final s in rc.stacks)
                if (!s.ok && s.stderr != null && s.stderr!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(s.stderr!, maxLines: 12, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, height: 1.35, color: t.text)),
                  ),
              for (final s in rc.skipped)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.cfRecreateSkipped(s.services.join(', ')), style: tt.bodySmall)),
            ]),
          ),
        ],
      ]),
    );
  }
}
