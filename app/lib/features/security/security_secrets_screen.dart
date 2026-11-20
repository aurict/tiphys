// Secrets in code and logs (PLAN.md §15 S-2): where the scanners found something (GitHub repositories, logs on Loki, local
// repositories). A finding is a location and a rule; no value is ever stored or shown. Findings can be dismissed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import 'security_data.dart' show securityCall;
import 'security_fix.dart';
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import 'security_widgets.dart';

const secretListCap = 100;

class SecuritySecretsScreen extends ConsumerStatefulWidget {
  const SecuritySecretsScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  ConsumerState<SecuritySecretsScreen> createState() => _SecuritySecretsScreenState();
}

class _SecuritySecretsScreenState extends ConsumerState<SecuritySecretsScreen> {
  /// Multi-select for "Send to Claude"; the blocks bind their agent and findings to it.
  late final _sel = FixSelection()..addListener(_onSel);

  String? get agentHint => widget.agentHint;

  void _onSel() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secSecretsTitle,
      bottomBar: fixBarFor(context, ref, _sel),
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      actions: [
        PopupMenuButton<String>(
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onSelected: (_) => context.push(securitySectionRoute('scanners', agentId: agentHint)),
          itemBuilder: (_) => [PopupMenuItem(value: 'scanners', child: Text(l.secScannersTitle))],
        ),
      ],
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _SecretsBlock(agent: a, selection: _sel))],
    );
  }
}

class _SecretsBlock extends ConsumerStatefulWidget {
  const _SecretsBlock({required this.agent, required this.selection});
  final Host agent;
  final FixSelection selection;
  @override
  ConsumerState<_SecretsBlock> createState() => _SecretsBlockState();
}

class _SecretsBlockState extends ConsumerState<_SecretsBlock> {
  bool _busy = false;
  bool _showDismissed = false;
  late final _key = (widget.agent.id, secSecretsPath);

  Future<void> _scan() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, widget.agent.id, 'POST', '$secSecretsPath/scan', body: <String, dynamic>{}), ok: l.secScanStarted);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_key));
  }

  Future<void> _dismiss(SecretFindingItem f, bool dismissed) async {
    final ok = await secAct(context, () => securityCall(ref, widget.agent.id, 'POST', '$secSecretsPath/${f.id}/dismiss', body: {'dismissed': dismissed}));
    if (ok) ref.invalidate(securityGetProvider(_key));
  }

  Future<void> _dismissGroup(SecretGroup g, bool dismissed) async {
    final l = AppLocalizations.of(context);
    final where = g.stream ?? g.dir ?? g.where;
    final sure = await confirmDialog(
      context,
      message: dismissed ? l.secSecretsGroupDismissConfirm(g.items.length, g.rule, where) : l.secSecretsGroupUndismissConfirm(g.items.length, g.rule, where),
      confirmLabel: dismissed ? l.secSecretsGroupDismiss : l.secSecretsGroupUndismiss,
    );
    if (!sure || !mounted) return;
    int? changed;
    final ok = await secAct(context, () async {
      final r = await securityCall(ref, widget.agent.id, 'POST', '$secSecretsPath/dismiss-group', body: {...g.body(), 'dismissed': dismissed});
      changed = (r['changed'] as num?)?.toInt();
    });
    if (!ok || !mounted) return;
    if (mounted) ref.invalidate(securityGetProvider(_key));
    if (changed != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.secSecretsGroupChanged(changed!))));
    }
  }

  /// A group of two or more findings is one collapsed card; a single finding stays a plain card.
  Widget _entries(List<SecretFindingItem> list) {
    final groups = groupSecretFindings(list);
    final shown = groups.take(secretListCap).toList();
    final hidden = groups.skip(secretListCap).fold<int>(0, (n, g) => n + g.items.length);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final g in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: g.items.length == 1
              ? _FindingCard(finding: g.items.first, onDismiss: (d) => _dismiss(g.items.first, d), selection: widget.selection, agentId: widget.agent.id)
              : _GroupCard(key: ValueKey(g.key), group: g, onGroup: (d) => _dismissGroup(g, d), onDismiss: _dismiss, selection: widget.selection, agentId: widget.agent.id),
        ),
      if (hidden > 0) Padding(padding: const EdgeInsets.all(8), child: Text(AppLocalizations.of(context).secMoreRows(hidden))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    return SecAsync<Map<String, dynamic>>(
      value: ref.watch(securityGetProvider(_key)),
      onRetry: () => ref.invalidate(securityGetProvider(_key)),
      data: (j) {
        final s = SecretsData(j);
        final open = s.open;
        final dismissed = s.dismissed;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SecNote(l.secSecretsInfo, icon: LucideIcons.keyRound),
          const SizedBox(height: 10),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(s.hasRun ? l.secSecretsLastRun(relativeTime(l, s.lastRunAt ?? now, now)) : l.secSecretsNeverRun, style: tt.titleSmall),
              if (s.hasRun)
                for (final src in const ['github', 'loki', 'local'])
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(s.sourceErrors[src] == null ? LucideIcons.circleCheck : LucideIcons.circleAlert, size: 16, color: s.sourceErrors[src] == null ? t.success : t.danger),
                      const SizedBox(width: 8),
                      Expanded(child: Text(s.sourceErrors[src] == null ? secretSourceName(l, src) : '${secretSourceName(l, src)}: ${secretRunErrorText(l, s.sourceErrors[src]!)}', style: tt.bodyMedium)),
                    ]),
                  ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy || s.running ? null : _scan,
                icon: _busy || s.running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.scanSearch, size: 16),
                label: Text(s.running ? l.secScanRunning : l.secScanNow),
              ),
            ]),
          ),
          SectionLabel(l.secSecretsFindings(open.length)),
          FixSelectRow(selection: widget.selection, agentId: widget.agent.id, all: [for (final f in open) secretFixItem(f)]),
          if (open.isEmpty) TCard(child: Text(s.hasRun ? l.secSecretsNone : l.secSecretsNeverRun)),
          _entries(open),
          if (dismissed.isNotEmpty) ...[
            const SizedBox(height: 4),
            GroupedSection(children: [SwitchRow(title: l.secSecretsShowDismissed(dismissed.length), value: _showDismissed, onChanged: (v) => setState(() => _showDismissed = v))]),
            if (_showDismissed) ...[
              const SizedBox(height: 10),
              _entries(dismissed),
            ],
          ],
          if (s.repos.isNotEmpty) ...[
            SectionLabel(l.secSecretsRepos(s.repos.length)),
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final r in s.repos.take(secretListCap))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(r.error == null ? LucideIcons.gitBranch : LucideIcons.circleAlert, size: 16, color: r.error == null ? t.textSecondary : t.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.repo, style: tt.bodyMedium?.copyWith(fontFamily: monoFamily, fontSize: 13)),
                          Text(
                            [
                              if (r.head.isNotEmpty) r.head.substring(0, r.head.length < 8 ? r.head.length : 8),
                              if (r.scannedAt != null) l.secVulnScannedAgo(relativeTime(l, r.scannedAt!, now)),
                              if (r.error != null) secretRepoErrorText(l, r.error!),
                            ].join(' · '),
                            style: tt.bodySmall?.copyWith(color: r.error == null ? null : t.danger),
                          ),
                        ]),
                      ),
                    ]),
                  ),
              ]),
            ),
            if (s.repos.length > secretListCap) Padding(padding: const EdgeInsets.all(8), child: Text(l.secMoreRows(s.repos.length - secretListCap))),
          ],
        ]);
      },
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({super.key, required this.group, required this.onGroup, required this.onDismiss, required this.selection, required this.agentId});
  final FixSelection selection;
  final String agentId;
  final SecretGroup group;
  final ValueChanged<bool> onGroup;
  final void Function(SecretFindingItem, bool) onDismiss;
  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final g = widget.group;
    final mono = tt.bodyMedium?.copyWith(fontFamily: monoFamily, fontSize: 13);
    final place = g.stream ?? g.dir;
    return Opacity(
      opacity: g.dismissed ? 0.65 : 1,
      child: TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Semantics(
              button: true,
              expanded: _open,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      SecChip(secretSourceName(l, g.source), t.accent),
                      SecChip(l.secSecretsGroupCount(g.items.length), t.warning),
                      if (g.dismissed) SecChip(l.secSecretsDismissedChip, t.textSecondary),
                    ]),
                    const SizedBox(height: 8),
                    Text(g.rule, style: tt.titleSmall),
                    const SizedBox(height: 2),
                    Text(g.where, style: mono),
                    if (place != null && place.isNotEmpty) Text(place, style: mono),
                  ]),
                ),
                Padding(padding: const EdgeInsets.only(top: 4), child: Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: t.textSecondary)),
              ]),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => widget.onGroup(!g.dismissed), child: Text(g.dismissed ? l.secSecretsGroupUndismiss : l.secSecretsGroupDismiss)),
          ),
          // While selecting, the findings are listed so they can be ticked.
          if (_open || widget.selection.selecting)
            for (final f in g.items.take(secretListCap))
              Padding(padding: const EdgeInsets.only(top: 8), child: _FindingCard(finding: f, onDismiss: (d) => widget.onDismiss(f, d), selection: widget.selection, agentId: widget.agentId)),
          if ((_open || widget.selection.selecting) && g.items.length > secretListCap) Padding(padding: const EdgeInsets.all(8), child: Text(l.secMoreRows(g.items.length - secretListCap))),
        ]),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding, required this.onDismiss, required this.selection, required this.agentId});
  final SecretFindingItem finding;
  final ValueChanged<bool> onDismiss;
  final FixSelection selection;
  final String agentId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final f = finding;
    final mono = tt.bodyMedium?.copyWith(fontFamily: monoFamily, fontSize: 13);
    return FixPick(
      selection: selection,
      agentId: agentId,
      item: secretFixItem(f),
      child: Opacity(
      opacity: f.dismissed ? 0.65 : 1,
      child: TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SecChip(secretSourceName(l, f.source), t.accent),
            if (f.dismissed) SecChip(l.secSecretsDismissedChip, t.textSecondary),
          ]),
          const SizedBox(height: 8),
          Text(f.rule, style: tt.titleSmall),
          const SizedBox(height: 2),
          Text(f.where, style: mono),
          if (f.location != null) Text(f.location!, style: mono),
          if (f.commit != null && f.commit!.isNotEmpty) Text(l.secSecretsCommit(f.commit!.substring(0, f.commit!.length < 8 ? f.commit!.length : 8)), style: tt.bodySmall),
          if (f.stream != null && f.stream!.isNotEmpty) Text(f.stream!, style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
          if (f.at != null) Text(securityWhen(context, f.at!), style: tt.bodySmall),
          if (f.firstSeenAt != null) Text(l.secSecretsFirstSeen(securityWhen(context, f.firstSeenAt!)), style: tt.bodySmall),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => onDismiss(!f.dismissed), child: Text(f.dismissed ? l.secSecretsUndismiss : l.secSecretsDismiss)),
          ),
        ]),
      ),
      ),
    );
  }
}

/// A secret finding as a "Send to Claude" item: rule and place only; the agent never has the value.
FixItem secretFixItem(SecretFindingItem f) => FixItem.secret(id: f.id, label: [f.rule, f.where, ?f.location].join(' · '));
