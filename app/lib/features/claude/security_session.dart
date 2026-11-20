// Security fix sessions in the chat (PLAN.md §16 F4): readable tool names, the sudo password dialog (typed here, sent to
// the agent and forgotten), the session panel (pinned hosts, changed files, backups, rollback timers, "roll back",
// "forget sudo passwords") and the "re-run the audit" card at the end.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../security/security_data.dart' show securityCall, securityCheckTimeout, securityHostPath, securityRoute;
import '../security/security_widgets.dart';
import '../system/agent_providers.dart';
import '../vault/vault_state.dart' show secureWindowProvider;
import 'claude_controller.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Tool names

String secToolLabel(AppLocalizations l, String tool) => switch (tool) {
      'hosts' => l.fixToolHosts,
      'read_file' => l.fixToolRead,
      'run' => l.fixToolRun,
      'write_file' => l.fixToolWrite,
      'validate' => l.fixToolValidate,
      'safe_apply' => l.fixToolSafeApply,
      'confirm_apply' => l.fixToolConfirm,
      'rollback' => l.fixToolRollback,
      _ => tool,
    };

IconData secToolIcon(String tool) => switch (tool) {
      'hosts' => LucideIcons.server,
      'read_file' => LucideIcons.fileText,
      'run' => LucideIcons.terminal,
      'write_file' => LucideIcons.filePen,
      'validate' => LucideIcons.badgeCheck,
      'safe_apply' => LucideIcons.timer,
      'confirm_apply' => LucideIcons.check,
      'rollback' => LucideIcons.undo2,
      _ => LucideIcons.wrench,
    };

// ---------------------------------------------------------------------------------------------------------------------
// Header badge

/// "Security fix" / "Investigation" chip of a security session.
class SecuritySessionBadge extends StatelessWidget {
  const SecuritySessionBadge({super.key, required this.investigate});
  final bool investigate;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return SecChip(investigate ? l.fixBadgeInvestigate : l.fixBadgeFix, investigate ? t.warning : t.accent, icon: LucideIcons.shieldCheck);
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// sudo

/// Opens the password dialog for [event] (a `sudo` event) unless it is answered meanwhile.
Future<void> askSudo(BuildContext context, ClaudeSessionController c, ClaudeEvent event) {
  final id = event.get<String>('requestId');
  if (id == null) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SudoDialog(
      host: event.get<String>('host') ?? '?',
      attempt: event.get<int>('attempt') ?? 1,
      investigate: event.get<bool>('investigate') == true,
      source: c,
      stillPending: () => c.pendingSudo.any((e) => e.get<String>('requestId') == id),
      onPassword: (pw) => c.answerSudo(id, pw),
      onDeny: () => c.denySudo(id),
    ),
  );
}

/// The password prompt: obscured, no suggestions or autofill, FLAG_SECURE while it is open. The text lives only in the
/// field's controller; it is cleared as soon as it is sent and whenever the app goes to the background.
class SudoDialog extends ConsumerStatefulWidget {
  const SudoDialog({super.key, required this.host, required this.attempt, required this.onPassword, required this.onDeny, this.source, this.stillPending, this.investigate = false});
  final String host;

  /// The session investigates possible attack traces: the machine may be compromised, so the dialog warns.
  final bool investigate;

  /// 1 = first ask; 2–3 = the previous password was wrong.
  final int attempt;
  final Future<void> Function(String password) onPassword;
  final Future<void> Function() onDeny;

  /// Closes the dialog when [stillPending] turns false (answered elsewhere, timed out).
  final Listenable? source;
  final bool Function()? stillPending;
  @override
  ConsumerState<SudoDialog> createState() => _SudoDialogState();
}

class _SudoDialogState extends ConsumerState<SudoDialog> with WidgetsBindingObserver {
  final _pw = TextEditingController();
  late final Future<void> Function(bool) _secure;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _secure = ref.read(secureWindowProvider);
    WidgetsBinding.instance.addObserver(this);
    widget.source?.addListener(_onSource);
    _secure(true);
  }

  @override
  void dispose() {
    widget.source?.removeListener(_onSource);
    WidgetsBinding.instance.removeObserver(this);
    _pw.clear();
    _pw.dispose();
    _secure(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _pw.clear();
  }

  void _onSource() {
    if (mounted && widget.stillPending != null && !widget.stillPending!()) Navigator.of(context).maybePop();
  }

  Future<void> _send() async {
    final password = _pw.text;
    if (password.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // The text leaves the field before the request goes out; only the local variable holds it for the call.
    _pw.clear();
    try {
      await widget.onPassword(password);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = agentErrorText(AppLocalizations.of(context), e);
        });
      }
    }
  }

  Future<void> _deny() async {
    setState(() => _busy = true);
    try {
      await widget.onDeny();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = agentErrorText(AppLocalizations.of(context), e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(l.fixSudoTitle(widget.host)),
      scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.attempt > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Semantics(liveRegion: true, child: Text(l.fixSudoWrong(widget.attempt), style: tt.bodyMedium?.copyWith(color: t.danger, fontWeight: FontWeight.w700))),
          ),
        if (widget.investigate)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.triangleAlert, size: 16, color: t.danger),
              const SizedBox(width: 8),
              Expanded(child: Text(l.fixSudoInvestigateWarn, style: tt.bodySmall?.copyWith(color: t.danger, fontWeight: FontWeight.w600))),
            ]),
          ),
        Text(l.fixSudoBody, style: tt.bodySmall),
        const SizedBox(height: 12),
        TextField(
          controller: _pw,
          autofocus: true,
          obscureText: true,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          autofillHints: null,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.send,
          contextMenuBuilder: (context, state) => const SizedBox.shrink(),
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(labelText: l.fixSudoLabel),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: t.danger))),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : _deny, style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.fixSudoDeny)),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l.fixSudoLater)),
        FilledButton(onPressed: _busy ? null : _send, child: Text(l.fixSudoSend)),
      ],
    );
  }
}

/// A `sudo` event in the chat: "password needed" with the button that reopens the dialog, or what became of it.
class SudoCard extends StatelessWidget {
  const SudoCard({super.key, required this.event, required this.controller, required this.provided});
  final ClaudeEvent event;
  final ClaudeSessionController controller;

  /// null: still waiting.
  final bool? provided;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = event.get<String>('host') ?? '?';
    final waiting = provided == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        liveRegion: waiting,
        child: TCard(
          radius: 18,
          borderColor: waiting ? t.warning : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.keyRound, size: 18, color: waiting ? t.warning : t.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text(l.fixSudoCard(host), style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            if (waiting)
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => controller.denySudo(event.get<String>('requestId')!).catchError((Object e) {
                      if (context.mounted) toast(context, agentErrorText(l, e));
                    }),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48), foregroundColor: t.danger),
                    child: Text(l.fixSudoDeny),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: FilledButton(onPressed: () => askSudo(context, controller, event), child: Text(l.fixSudoEnter))),
              ])
            else
              Text(provided! ? l.fixSudoProvided : l.fixSudoNotProvided, style: TextStyle(color: provided! ? t.success : t.textSecondary, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Session panel

class SecPinnedHost {
  SecPinnedHost(Map<String, dynamic> j)
      : host = '${j['host']}',
        name = '${j['name']}',
        ssh = j['ssh'] as String?,
        port = (j['port'] as num?)?.toInt();
  final String host, name;
  final String? ssh;
  final int? port;
}

class SecBackup {
  SecBackup(Map<String, dynamic> j)
      : host = '${j['host']}',
        path = '${j['path']}',
        backup = '${j['backup']}',
        existed = j['existed'] != false,
        sudo = j['sudo'] == true,
        at = DateTime.tryParse('${j['at']}');
  final String host, path, backup;

  /// false: the file did not exist before (rolling back deletes it).
  final bool existed, sudo;
  final DateTime? at;
}

class SecRollbackTimer {
  SecRollbackTimer(Map<String, dynamic> j)
      : host = '${j['host']}',
        unit = '${j['unit']}',
        kind = '${j['kind']}',
        expiresAt = DateTime.tryParse('${j['expiresAt']}');
  final String host, unit, kind;
  final DateTime? expiresAt;
}

class SecuritySessionInfo {
  SecuritySessionInfo(Map<String, dynamic> j)
      : hosts = [for (final h in (j['hosts'] as List? ?? const [])) SecPinnedHost(Map<String, dynamic>.from(h as Map))],
        mode = '${j['mode'] ?? ''}',
        investigate = j['investigate'] == true,
        backups = [for (final b in (j['backups'] as List? ?? const [])) SecBackup(Map<String, dynamic>.from(b as Map))],
        changed = [for (final c in (j['changed'] as List? ?? const [])) ('${(c as Map)['host']}', '${c['path']}')],
        timers = [for (final x in (j['timers'] as List? ?? const [])) SecRollbackTimer(Map<String, dynamic>.from(x as Map))],
        sudoCached = [for (final h in (j['sudoCached'] as List? ?? const [])) '$h'];
  final List<SecPinnedHost> hosts;
  final String mode;
  final bool investigate;
  final List<SecBackup> backups;
  final List<(String, String)> changed;
  final List<SecRollbackTimer> timers;
  final List<String> sudoCached;

  bool touched(String host) => backups.any((b) => b.host == host) || changed.any((c) => c.$1 == host);
}

/// "m:ss" of a countdown.
String secCountdown(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The panel as a bottom sheet.
Future<void> showSecurityPanel(BuildContext context, ClaudeSessionController c) => showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 0, 18, 18), child: SecurityPanel(controller: c)),
    );

class SecurityPanel extends ConsumerStatefulWidget {
  const SecurityPanel({super.key, required this.controller});
  final ClaudeSessionController controller;
  @override
  ConsumerState<SecurityPanel> createState() => _SecurityPanelState();
}

class _SecurityPanelState extends ConsumerState<SecurityPanel> {
  SecuritySessionInfo? _info;
  Object? _error;
  bool _busy = false;
  Timer? _tick;
  int _seen = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_info?.timers.isNotEmpty ?? false)) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _tick?.cancel();
    super.dispose();
  }

  /// Reads the panel again when a security tool finished or a sudo request was settled (not on every text chunk).
  void _onController() {
    final n = widget.controller.events.where((e) => e.kind == 'tool_result' || e.kind == 'sudoResolved' || e.kind == 'permissionResolved').length;
    if (n != _seen) _load();
  }

  Future<void> _load() async {
    _seen = widget.controller.events.where((e) => e.kind == 'tool_result' || e.kind == 'sudoResolved' || e.kind == 'permissionResolved').length;
    try {
      final j = await widget.controller.securityInfo();
      if (mounted) {
        setState(() {
          _info = SecuritySessionInfo(j);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _rollback(SecPinnedHost h) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.fixRollbackConfirm(h.name), confirmLabel: l.fixRollback, destructive: true) || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.controller.securityRollback(h.host);
      if (!mounted) return;
      final restored = (r['restored'] as List? ?? const []).length;
      final failed = [for (final f in (r['failed'] as List? ?? const [])) '${(f as Map)['path']}: ${f['error']}'];
      final reloaded = [for (final u in (r['reloaded'] as List? ?? const [])) '$u'];
      if (failed.isEmpty) {
        toast(context, '${l.fixRollbackDone(restored)}${reloaded.isEmpty ? '' : ' · ${reloaded.join(', ')}'}');
      } else {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(l.fixRollbackPartial(restored, failed.length)),
            scrollable: true,
            content: SelectableText(failed.join('\n'), style: const TextStyle(fontFamily: monoFamily, fontSize: 12)),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonClose))],
          ),
        );
      }
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _load();
      }
    }
  }

  Future<void> _forget() async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.fixForgetConfirm, confirmLabel: l.fixForgetSudo) || !mounted) return;
    try {
      await widget.controller.forgetSudo();
      if (mounted) toast(context, l.fixForgetDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final info = _info;
    final now = ref.watch(clockProvider)();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Semantics(header: true, child: Text(l.fixPanelTitle, style: tt.titleLarge))),
        IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: _load),
      ]),
      if (info == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      if (info == null && _error != null)
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(agentErrorText(l, _error!)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: Text(l.commonRetry)),
          ]),
        ),
      if (info != null) ...[
        Wrap(spacing: 6, runSpacing: 6, children: [
          SecuritySessionBadge(investigate: info.investigate),
          SecChip(_modeName(l, info.mode), t.textSecondary),
        ]),
        const SizedBox(height: 12),
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(header: true, child: Text(l.fixPanelHosts, style: tt.titleMedium)),
            const SizedBox(height: 6),
            if (info.hosts.isEmpty) Text(l.fixPanelNoHosts, style: tt.bodyMedium),
            for (final h in info.hosts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.name, style: tt.titleSmall),
                      Text(h.ssh == null ? l.fixTargetThisPc : (h.port == null ? h.ssh! : '${h.ssh}:${h.port}'), style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
                      if (info.sudoCached.contains(h.host)) Padding(padding: const EdgeInsets.only(top: 4), child: SecChip(l.fixPanelSudoCached, t.warning, icon: LucideIcons.keyRound)),
                    ]),
                  ),
                  if (!info.investigate && info.touched(h.host))
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _rollback(h),
                      icon: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.undo2, size: 16),
                      label: Text(l.fixRollback),
                      style: OutlinedButton.styleFrom(foregroundColor: t.danger),
                    ),
                ]),
              ),
          ]),
        ),
        if (info.timers.isNotEmpty) ...[
          const SizedBox(height: 10),
          TCard(
            borderColor: t.warning,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(LucideIcons.timer, size: 18, color: t.warning),
                const SizedBox(width: 8),
                Expanded(child: Semantics(header: true, child: Text(l.fixPanelTimers, style: tt.titleMedium))),
              ]),
              const SizedBox(height: 4),
              Text(l.fixPanelTimersHint, style: tt.bodySmall),
              for (final x in info.timers)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(child: Text('${x.host} · ${x.kind}', style: tt.bodyMedium)),
                    Semantics(
                      label: x.expiresAt == null ? null : l.fixTimerLeftSemantics(secCountdown(x.expiresAt!.difference(now))),
                      excludeSemantics: x.expiresAt != null,
                      child: Text(x.expiresAt == null ? '—' : secCountdown(x.expiresAt!.difference(now)), style: tt.titleMedium?.copyWith(fontFamily: monoFamily, color: t.warning)),
                    ),
                  ]),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(header: true, child: Text(l.fixPanelChanged(info.changed.length), style: tt.titleMedium)),
            const SizedBox(height: 4),
            if (info.changed.isEmpty) Text(l.fixPanelNothing, style: tt.bodyMedium),
            for (final c in info.changed.take(50)) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${c.$1} · ${c.$2}', style: const TextStyle(fontFamily: monoFamily, fontSize: 12.5))),
            if (info.changed.length > 50) Text(l.secMore(info.changed.length - 50), style: tt.bodySmall),
          ]),
        ),
        const SizedBox(height: 10),
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(header: true, child: Text(l.fixPanelBackups(info.backups.length), style: tt.titleMedium)),
            const SizedBox(height: 4),
            if (info.backups.isEmpty) Text(l.fixPanelNothing, style: tt.bodyMedium),
            for (final b in info.backups.take(50))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${b.host} · ${b.path}', style: const TextStyle(fontFamily: monoFamily, fontSize: 12.5)),
                  Text(b.existed ? b.backup : l.fixBackupNew, style: tt.bodySmall?.copyWith(fontFamily: b.existed ? monoFamily : null, color: t.textSecondary)),
                  if (b.at != null) Text(securityWhen(context, b.at!.toLocal()), style: tt.bodySmall),
                ]),
              ),
            if (info.backups.length > 50) Text(l.secMore(info.backups.length - 50), style: tt.bodySmall),
          ]),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: _forget, icon: const Icon(LucideIcons.keyRound, size: 16), label: Text(l.fixForgetSudo)),
      ],
    ]);
  }

  String _modeName(AppLocalizations l, String m) => switch (m) {
        'plan' => l.claudeModePlan,
        'acceptEdits' => l.claudeModeAcceptShort,
        'bypassPermissions' => l.claudeModeBypassShort,
        _ => l.claudeModeDefaultShort,
      };
}

// ---------------------------------------------------------------------------------------------------------------------
// After the session

/// Under the session's result: run the audit again on the monitoring agent, then open the host to accept the baseline.
class SecurityAfterCard extends ConsumerStatefulWidget {
  const SecurityAfterCard({super.key, required this.summary});

  /// The session summary (`security.hosts`, `security.origin.agentHostId`).
  final Map<String, dynamic> summary;
  @override
  ConsumerState<SecurityAfterCard> createState() => _SecurityAfterCardState();
}

class _SecurityAfterCardState extends ConsumerState<SecurityAfterCard> {
  bool _busy = false;
  bool _done = false;
  final _errors = <String, String>{};

  Map<String, dynamic> get _sec => Map<String, dynamic>.from(widget.summary['security'] as Map? ?? const {});
  String? get _agentId => (_sec['origin'] as Map?)?['agentHostId'] as String?;
  List<(String, String)> get _hosts => [for (final h in (_sec['hosts'] as List? ?? const [])) ('${(h as Map)['host']}', '${h['name']}')];

  Future<void> _run() async {
    final l = AppLocalizations.of(context);
    final agent = _agentId;
    if (agent == null) return;
    setState(() {
      _busy = true;
      _errors.clear();
    });
    for (final (id, name) in _hosts) {
      try {
        await securityCall(ref, agent, 'POST', '${securityHostPath(id)}/check', body: {'full': false}, timeout: securityCheckTimeout(full: false));
      } catch (e) {
        _errors[id] = '$name: ${agentErrorText(l, e)}';
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final agent = _agentId;
    if (agent == null || _hosts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TCard(
        radius: 18,
        borderColor: t.accent,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(LucideIcons.scanSearch, size: 18, color: t.accent),
            const SizedBox(width: 8),
            Expanded(child: Semantics(header: true, child: Text(l.fixAuditTitle, style: const TextStyle(fontWeight: FontWeight.w700)))),
          ]),
          const SizedBox(height: 6),
          Text(_done && _errors.isEmpty ? l.fixAuditDone : l.fixAuditBody, style: tt.bodyMedium),
          for (final e in _errors.values) Padding(padding: const EdgeInsets.only(top: 4), child: Text(e, style: tt.bodySmall?.copyWith(color: t.danger))),
          const SizedBox(height: 10),
          if (!_done || _errors.isNotEmpty)
            FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.scanSearch, size: 16),
              label: Text(_busy ? l.fixAuditRunning : l.fixAuditRun),
            ),
          if (_done)
            for (final (id, name) in _hosts)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: FilledButton.tonalIcon(
                  onPressed: () => context.push(securityRoute(id, agentId: agent)),
                  icon: const Icon(LucideIcons.shieldCheck, size: 16),
                  label: Text(l.fixAuditOpen(name)),
                ),
              ),
        ]),
      ),
    );
  }
}
