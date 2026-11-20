// The sheet behind "Send to Claude" (PLAN.md §16 F4): asks the monitoring agent for the brief, shows what Claude would
// get (items with their mode, the fix target of every machine), lets the user pick the permission mode and add a note,
// then starts the security session on the PC agent and opens the chat.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider, claudeSessionsProvider;
import '../system/agent_providers.dart';
import 'security_data.dart' show securityCall;
import 'security_fix.dart';
import 'security_section_widgets.dart' show SecNote;
import 'security_texts.dart' show securityRoleName, securitySourceName;
import 'security_widgets.dart';

/// "Send to Claude" for [items] of the monitoring agent [agentId]. Without a Claude host: the usual hint. true = a session
/// was started.
Future<bool> sendToClaude(BuildContext context, WidgetRef ref, {required String agentId, required List<FixItem> items}) async {
  final l = AppLocalizations.of(context);
  if (ref.read(claudeHostProvider) == null) {
    toast(context, l.dozzleNoClaudeHost);
    return false;
  }
  final started = await showModalBottomSheet<bool>(
    useRootNavigator: true, // above the bottom tab bar
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: FixSendSheet(agentId: agentId, items: items),
    ),
  );
  return started == true;
}

class FixSendSheet extends ConsumerStatefulWidget {
  const FixSendSheet({super.key, required this.agentId, required this.items});

  /// The monitoring agent (where the brief comes from and the audit runs again).
  final String agentId;
  final List<FixItem> items;
  @override
  ConsumerState<FixSendSheet> createState() => _FixSendSheetState();
}

class _FixSendSheetState extends ConsumerState<FixSendSheet> {
  final _note = TextEditingController();
  FixBrief? _brief;
  Object? _briefError;
  bool _loading = true;
  String _mode = 'default';
  bool _busy = false;
  String? _error;

  String get _claudeHostId => ref.read(claudeHostProvider)!.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _briefError = null;
    });
    try {
      final b = await fetchFixBrief(ref, widget.agentId, widget.items, fixLanguage(context));
      if (!mounted) return;
      setState(() {
        _brief = b;
        _mode = fixDefaultMode(investigate: b.investigate);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _briefError = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _setTarget(FixBriefHost h) async {
    final hostId = _claudeHostId;
    await context.push('/claude/security-targets?host=${Uri.encodeQueryComponent(hostId)}&add=${Uri.encodeQueryComponent(h.id)}&name=${Uri.encodeQueryComponent(h.name)}');
    if (mounted) ref.invalidate(fixTargetsProvider(hostId));
  }

  Future<void> _start(FixBrief brief) async {
    final l = AppLocalizations.of(context);
    if (_mode == 'bypassPermissions') {
      final ok = await confirmDialog(context, message: l.fixBypassConfirm, confirmLabel: l.fixBypassConfirmGo, destructive: true);
      if (!ok || !mounted) return;
    }
    final router = GoRouter.of(context);
    final c = ref.read(profileProvider).claude;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The agent checks every target's SSH destination (`ssh -G`, up to ~10 s each) before the session opens.
      final res = await securityCall(ref, _claudeHostId, 'POST', '/v1/claude/sessions', body: fixSessionBody(brief: brief, agentHostId: widget.agentId, mode: _mode, note: _note.text, effort: c.effort, model: c.model), timeout: const Duration(minutes: 3)) as Map;
      if (!mounted) return;
      ref.invalidate(claudeSessionsProvider);
      Navigator.pop(context, true);
      router.push('/claude/session/${res['id']}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = agentErrorText(l, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final brief = _brief;
    final targets = ref.watch(fixTargetsProvider(_claudeHostId));
    final hasTarget = brief != null && targets.hasValue && brief.hosts.any((h) => targets.value!.of(h.id) != null);
    final ready = brief != null && brief.hasItems && hasTarget && !_busy;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(header: true, child: Text(l.fixSendTitle, style: tt.titleLarge)),
          const SizedBox(height: 4),
          Text(l.fixSendIntro, style: tt.bodySmall),
          const SizedBox(height: 12),
          if (_loading)
            Padding(padding: const EdgeInsets.all(24), child: Center(child: Semantics(label: l.fixBriefLoading, child: const CircularProgressIndicator())))
          else if (_briefError != null)
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(agentErrorText(l, _briefError!)),
                const SizedBox(height: 8),
                TextButton(onPressed: _load, child: Text(l.commonRetry)),
              ]),
            )
          else if (brief != null) ...[
            _ItemsCard(items: widget.items, brief: brief),
            if (brief.truncated) ...[const SizedBox(height: 10), SecNote(l.fixBriefTruncated, warn: true)],
            const SizedBox(height: 10),
            _HostsCard(brief: brief, targets: targets, onSet: _setTarget, onRetry: () => ref.invalidate(fixTargetsProvider(_claudeHostId))),
            const SizedBox(height: 10),
            _ModeCard(investigate: brief.investigate, mode: _mode, onChanged: (m) => setState(() => _mode = m)),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(labelText: l.fixNoteLabel, hintText: l.fixNoteHint),
            ),
            _Preview(brief: brief),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: context.tokens.danger))),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: ready ? () => _start(brief) : null,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.arrowUp),
              label: Text(l.fixStart),
            ),
          ],
        ]),
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  const _ItemsCard({required this.items, required this.brief});
  final List<FixItem> items;
  final FixBrief brief;

  IconData _icon(String type) => switch (type) {
        'change' => LucideIcons.gitCompareArrows,
        'vuln' => LucideIcons.bug,
        'secret' => LucideIcons.keyRound,
        'exposure' => LucideIcons.globe,
        _ => LucideIcons.shieldAlert,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(header: true, child: Text(l.fixItemsTitle(items.length), style: tt.titleMedium)),
        const SizedBox(height: 6),
        for (var i = 0; i < items.length; i++)
          Builder(builder: (_) {
            final r = i < brief.items.length ? brief.items[i] : null;
            final label = items[i].label;
            final status = r == null ? null : (r.ok ? (r.mode == 'investigate' ? l.fixModeInvestigate : l.fixModeFix) : fixErrorText(l, r.error!));
            return Semantics(
              container: true,
              label: '$label, $status',
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_icon(items[i].type), size: 16, color: r != null && !r.ok ? t.danger : t.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: tt.bodyMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
                      if (r != null && !r.ok) Text(status!, style: tt.bodySmall?.copyWith(color: t.danger)),
                    ]),
                  ),
                  if (r != null && r.ok) ...[
                    const SizedBox(width: 8),
                    SecChip(status!, r.mode == 'investigate' ? t.warning : t.success),
                  ],
                ]),
              ),
            );
          }),
      ]),
    );
  }
}

class _HostsCard extends StatelessWidget {
  const _HostsCard({required this.brief, required this.targets, required this.onSet, required this.onRetry});
  final FixBrief brief;
  final AsyncValue<FixTargets> targets;
  final ValueChanged<FixBriefHost> onSet;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final err = targets.error;
    final off = err is AgentError && err.code == 'agent.claude.securityFixDisabled';
    if (off) return SecNote(l.fixErrDisabled, warn: true);
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(header: true, child: Text(l.fixHostsTitle, style: tt.titleMedium)),
        const SizedBox(height: 6),
        if (brief.hosts.isEmpty) Text(l.fixHostsNone, style: tt.bodyMedium),
        if (err != null)
          Row(children: [
            Expanded(child: Text(agentErrorText(l, err), style: tt.bodyMedium?.copyWith(color: t.danger))),
            TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
          ])
        else if (targets.isLoading)
          const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
        else
          for (final h in brief.hosts)
            Builder(builder: (_) {
              final tg = targets.value!.of(h.id);
              final where = tg == null ? null : (tg.destination ?? l.fixTargetThisPc);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.name, style: tt.titleSmall),
                      Text('${securityRoleName(l, h.role)} · ${securitySourceName(l, h.source)}${h.root == false ? ' · ${l.fixHostNoRoot}' : ''}', style: tt.bodySmall),
                      if (where != null) Text(where, style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  if (tg != null)
                    SecChip(l.fixTargetSet, t.success, icon: LucideIcons.check)
                  else
                    OutlinedButton(onPressed: () => onSet(h), child: Text(l.fixTargetSetNow)),
                ]),
              );
            }),
        if (err == null && !targets.isLoading && brief.hosts.isNotEmpty && !brief.hosts.any((h) => targets.value!.of(h.id) != null))
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.fixTargetsNoneHint, style: tt.bodySmall?.copyWith(color: t.warning))),
      ]),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.investigate, required this.mode, required this.onChanged});
  final bool investigate;
  final String mode;
  final ValueChanged<String> onChanged;

  String _name(AppLocalizations l, String m) => switch (m) {
        'plan' => l.claudeModePlan,
        'default' => l.claudeModeDefaultShort,
        'acceptEdits' => l.claudeModeAcceptShort,
        _ => l.claudeModeBypassShort,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final allowed = fixAllowedModes(investigate: investigate);
    final bypass = mode == 'bypassPermissions';
    return TCard(
      borderColor: bypass ? t.danger : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(header: true, child: Text(l.fixModeTitle, style: tt.titleMedium)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in allowed)
            ChoiceChip(
              label: Text(_name(l, m)),
              selected: m == mode,
              onSelected: (_) => onChanged(m),
              showCheckmark: false,
              selectedColor: m == 'bypassPermissions' ? t.danger : (t.isDark ? t.tabActive : const Color(0xFF111114)),
              labelStyle: TextStyle(color: m == mode ? (m == 'bypassPermissions' || !t.isDark ? Colors.white : Colors.black) : (m == 'bypassPermissions' ? t.danger : t.text), fontWeight: FontWeight.w600),
            ),
        ]),
        if (investigate) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.fixModeInvestigateNote, style: tt.bodySmall?.copyWith(color: t.warning))),
        if (!investigate) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.fixModeRootNote, style: tt.bodySmall)),
        if (bypass)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.triangleAlert, size: 16, color: t.danger),
              const SizedBox(width: 8),
              Expanded(child: Text(l.fixBypassWarning, style: tt.bodySmall?.copyWith(color: t.danger, fontWeight: FontWeight.w600))),
            ]),
          ),
      ]),
    );
  }
}

/// The brief's text, collapsed: plain monospace, selectable, never interpreted.
class _Preview extends StatelessWidget {
  const _Preview({required this.brief});
  final FixBrief brief;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(l.fixPreview(brief.bytes), style: Theme.of(context).textTheme.labelLarge),
          children: [
            Text(l.fixPreviewHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(10)),
              child: SingleChildScrollView(child: SelectableText(brief.text, style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: t.text))),
            ),
          ],
        ),
      ),
    );
  }
}
