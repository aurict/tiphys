// Lost phone (PLAN.md §15 S-4): a recovery code (shown once, kept as a hash by the agent) lets any device in the tailnet
// lock everything without a paired token, and fans the lockdown out to the agents listed here. Creating a code asks for
// the app lock again; the lockdown screen sends the code to the monitoring server WITHOUT any token.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../configfiles/config_file_screen.dart' show revealLockAvailableProvider;
import '../vault/vault_state.dart' show secureWindowProvider, vaultAuthProvider;
import 'security_data.dart' show securityCall;
import 'security_more_data.dart';
import 'security_section_widgets.dart';
import 'security_widgets.dart';
import '../system/agent_providers.dart';

class SecurityRecoveryScreen extends ConsumerStatefulWidget {
  const SecurityRecoveryScreen({super.key, this.agentHint});
  final String? agentHint;
  @override
  ConsumerState<SecurityRecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<SecurityRecoveryScreen> {
  /// Requests in flight on this screen: while a recovery code is being created, leaving would lose it (it is shown once).
  final _inFlight = ValueNotifier<int>(0);

  @override
  void dispose() {
    _inFlight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: _inFlight,
      builder: (context, n, _) => PopScope(
        canPop: n == 0,
        child: SettingsPage(
          title: l.secRecTitle,
          backEnabled: n == 0,
          onRefresh: () async {
            ref.invalidate(securityAgentsProvider(widget.agentHint));
            ref.invalidate(securityGetProvider);
          },
          children: [SecurityAgentBlocks(hint: widget.agentHint, builder: (c, a) => _RecoveryBlock(agent: a, inFlight: _inFlight))],
        ),
      ),
    );
  }
}

class _RecoveryBlock extends ConsumerStatefulWidget {
  const _RecoveryBlock({required this.agent, required this.inFlight});
  final Host agent;
  final ValueNotifier<int> inFlight;
  @override
  ConsumerState<_RecoveryBlock> createState() => _RecoveryBlockState();
}

class _RecoveryBlockState extends ConsumerState<_RecoveryBlock> {
  bool _busy = false;
  late final _statusKey = (widget.agent.id, secRecoveryPath);
  late final _targetsKey = (widget.agent.id, secLockdownTargetsPath);

  String get _id => widget.agent.id;

  /// Marks the screen busy (back is blocked) for the duration of [body].
  Future<T> _guarded<T>(Future<T> Function() body) async {
    widget.inFlight.value++;
    try {
      return await body();
    } finally {
      widget.inFlight.value--;
    }
  }

  /// The app lock (PIN / fingerprint), asked every time; without a lock set up no code is created.
  Future<bool> _authenticate() async {
    final l = AppLocalizations.of(context);
    final available = await ref.read(revealLockAvailableProvider.future);
    if (!mounted) return false;
    if (!available) {
      toast(context, l.secRecNeedsLock);
      return false;
    }
    return ref.read(vaultAuthProvider)(context);
  }

  Future<void> _create(RecoveryStatus s) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: s.configured ? l.secRecReplaceConfirm : l.secRecCreateConfirm, confirmLabel: l.secRecCreate, destructive: s.configured)) return;
    if (!mounted || !await _authenticate() || !mounted) return;
    setState(() => _busy = true);
    String? code;
    final ok = await _guarded(() => secAct(context, () async {
          final j = await securityCall(ref, _id, 'POST', secRecoveryPath, body: {'confirm': true});
          code = j is Map ? '${j['code']}' : null;
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_statusKey));
    if (ok && code != null) {
      await showSecretOnce(context, title: l.secRecCodeTitle, value: code!, hint: l.secRecCodeHint, warning: l.secRecCodeWarn, copyable: false);
    }
  }

  Future<void> _addTarget() async {
    final l = AppLocalizations.of(context);
    final body = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _TargetDialog());
    if (body == null || !mounted) return;
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, _id, 'POST', secLockdownTargetsPath, body: body), ok: l.secSaved);
    if (!mounted) return;
    setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_targetsKey));
  }

  Future<void> _deleteTarget(LockdownTarget tg) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.secRecTargetDeleteConfirm(tg.name), confirmLabel: l.commonDelete, destructive: true)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, _id, 'DELETE', '$secLockdownTargetsPath/${tg.id}'), ok: l.secDeleted);
    if (!mounted) return;
    setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_targetsKey));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      SecNote(l.secRecInfo, icon: LucideIcons.smartphoneNfc),
      const SizedBox(height: 10),
      SecAsync<Map<String, dynamic>>(
        value: ref.watch(securityGetProvider(_statusKey)),
        onRetry: () => ref.invalidate(securityGetProvider(_statusKey)),
        data: (j) {
          final s = RecoveryStatus(j);
          return TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(s.configured ? LucideIcons.circleCheck : LucideIcons.circleAlert, size: 18, color: s.configured ? t.success : t.warning),
                const SizedBox(width: 10),
                Expanded(child: Text(s.configured ? l.secRecConfigured(s.createdAt == null ? '—' : securityWhen(context, s.createdAt!)) : l.secRecNotConfigured, style: tt.titleSmall)),
              ]),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: _busy ? null : () => _create(s), icon: const Icon(LucideIcons.keyRound, size: 16), label: Text(s.configured ? l.secRecReplace : l.secRecCreate)),
            ]),
          );
        },
      ),
      SectionLabel(l.secRecTargets),
      SecAsync<Map<String, dynamic>>(
        value: ref.watch(securityGetProvider(_targetsKey)),
        onRetry: () => ref.invalidate(securityGetProvider(_targetsKey)),
        data: (j) {
          final targets = [for (final e in (j['targets'] as List? ?? const [])) if (e is Map) LockdownTarget(Map<String, dynamic>.from(e))];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(l.secRecTargetsHint, style: tt.bodySmall)),
            if (targets.isEmpty) TCard(child: Text(l.secRecTargetsEmpty)),
            if (targets.isNotEmpty)
              GroupedSection(children: [
                for (final tg in targets)
                  GroupedRow(
                    title: tg.name,
                    subtitle: '${tg.url} · ${tg.hasToken ? l.secTokenSaved : l.secTokenMissing}',
                    icon: LucideIcons.server,
                    showChevron: false,
                    trailing: IconButton(tooltip: l.secRecTargetRemove(tg.name), icon: const Icon(LucideIcons.trash2, size: 18), onPressed: _busy ? null : () => _deleteTarget(tg)),
                  ),
              ]),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _busy || targets.length >= 20 ? null : _addTarget, icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secRecTargetAdd)),
          ]);
        },
      ),
      const SizedBox(height: 14),
      GroupedSection(footer: l.secLockdownRowHint, children: [
        GroupedRow(title: l.secLockdownTitle, icon: LucideIcons.lock, iconBackground: t.danger, onTap: () => context.push(securitySectionRoute('lockdown', agentId: widget.agent.id))),
      ]),
    ]);
  }
}

/// An agent that a lockdown fans out to: the token is a "lockdown" service token created on that agent; write-only.
class _TargetDialog extends StatefulWidget {
  const _TargetDialog();
  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    for (final c in [_id, _name, _url, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secRecTargetAdd),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TField(controller: _id, label: l.secFieldId, hint: 'orion', mono: true, validator: idV(l)),
            const SizedBox(height: 10),
            TField(controller: _name, label: l.secFieldName, validator: (v) => v.trim().isEmpty || v.trim().length > 80 ? l.secInvalid : null),
            const SizedBox(height: 10),
            TField(controller: _url, label: l.secFieldUrl, mono: true, keyboardType: TextInputType.url, hint: 'https://orion.example.org:6767', validator: (v) => v.trim().startsWith('https://') && Uri.tryParse(v.trim())?.host.isNotEmpty == true ? null : l.secInvalid),
            const SizedBox(height: 10),
            TField(controller: _token, label: l.secRecTargetToken, obscure: true, mono: true, helper: l.secRecTargetTokenHint, validator: (v) => validServiceToken(v.trim()) ? null : l.secInvalid),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: () {
            if (_form.currentState!.validate()) Navigator.pop(context, {'id': _id.text.trim(), 'name': _name.text.trim(), 'url': _url.text.trim(), 'token': _token.text.trim()});
          },
          child: Text(l.commonAdd),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Lock with the recovery code (no token, no app lock: the phone may be somebody else's)

class SecurityLockdownScreen extends ConsumerStatefulWidget {
  const SecurityLockdownScreen({super.key, this.agentHint});
  final String? agentHint;
  @override
  ConsumerState<SecurityLockdownScreen> createState() => _LockdownScreenState();
}

class _LockdownScreenState extends ConsumerState<SecurityLockdownScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _code = TextEditingController();
  bool _prefilled = false;
  bool _busy = false;
  bool _hideCode = false;
  List<LockdownResult>? _results;
  Object? _error;
  late final Future<void> Function(bool) _secure;

  @override
  void initState() {
    super.initState();
    // The recovery code is typed here: no screenshots or recents preview.
    _secure = ref.read(secureWindowProvider);
    _secure(true);
  }

  @override
  void dispose() {
    _secure(false);
    _url.dispose();
    _code.dispose();
    super.dispose();
  }

  /// The code only goes to an https address; http is refused with its own message.
  String? _urlError(AppLocalizations l, String v) {
    final u = Uri.tryParse(v.trim());
    if (u == null || u.host.isEmpty) return l.secInvalid;
    return u.scheme == 'https' ? null : (u.scheme == 'http' ? l.secLockdownHttpsOnly : l.secInvalid);
  }

  Future<void> _lock() async {
    final l = AppLocalizations.of(context);
    if (_busy || !_form.currentState!.validate() || _urlError(l, _url.text) != null) return;
    if (!await confirmDialog(context, message: l.secLockdownConfirm, confirmLabel: l.secLockdownDo, destructive: true) || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(lockdownCallProvider)(_url.text, formatRecoveryCode(_code.text));
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      // The code is not kept after the call, whatever the result.
      if (mounted) {
        _code.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final agents = ref.watch(securityAgentsProvider(widget.agentHint));
    if (!_prefilled && agents.hasValue) {
      _prefilled = true;
      _url.text = lockdownUrlFor(agents.value!) ?? '';
    }
    return SettingsPage(
      title: l.secLockdownTitle,
      children: [
        if (_results == null) ...[
          SecNote(l.secLockdownWarn, warn: true, title: l.secLockdownWarnTitle),
          const SizedBox(height: 10),
          TCard(
            child: Form(
              key: _form,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TField(
                  controller: _url,
                  label: l.secLockdownUrl,
                  mono: true,
                  keyboardType: TextInputType.url,
                  helper: l.secLockdownUrlHint,
                  enabled: !_busy,
                  validator: (v) => _urlError(l, v),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _code,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  obscureText: _hideCode,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')), LengthLimitingTextInputFormatter(29)],
                  style: const TextStyle(fontFamily: monoFamily, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: l.secLockdownCode,
                    hintText: 'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2',
                    helperText: l.secLockdownCodeHint,
                    helperMaxLines: 3,
                    suffixIcon: IconButton(
                      tooltip: _hideCode ? l.secLockdownCodeShow : l.secLockdownCodeHide,
                      icon: Icon(_hideCode ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
                      onPressed: () => setState(() => _hideCode = !_hideCode),
                    ),
                  ),
                  validator: (v) => recoveryCodeComplete(v ?? '') ? null : l.secLockdownCodeInvalid,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  onFieldSubmitted: (_) => _lock(),
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(agentErrorText(l, _error!), style: TextStyle(color: t.danger, fontWeight: FontWeight.w600))),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _busy ? null : _lock,
                  style: FilledButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white),
                  icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(LucideIcons.lock, size: 16),
                  label: Text(l.secLockdownDo),
                ),
              ]),
            ),
          ),
        ] else ...[
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(LucideIcons.lock, color: t.success),
                const SizedBox(width: 10),
                Expanded(child: Semantics(header: true, child: Text(l.secLockdownDone, style: tt.titleMedium))),
              ]),
              const SizedBox(height: 8),
              Text(l.secLockdownPairAgain, style: tt.bodyMedium),
            ]),
          ),
          SectionLabel(l.secLockdownResults),
          if (_results!.isEmpty) TCard(child: Text(l.secLockdownNoTargets)),
          if (_results!.isNotEmpty)
            GroupedSection(children: [
              for (final r in _results!)
                GroupedRow(
                  title: r.name,
                  subtitle: r.ok ? l.secLockdownTargetOk : (r.status == null ? l.secLockdownTargetUnreachable : l.secLockdownTargetFailed(r.status!)),
                  icon: r.ok ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                  iconBackground: r.ok ? t.success : t.danger,
                  showChevron: false,
                ),
            ]),
        ],
      ],
    );
  }
}
