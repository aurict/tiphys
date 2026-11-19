// One audited host (PLAN.md §15, S-1): score, check buttons, pending changes with "accept this state", findings by
// severity and the report sections as tabs. Everything the agent reports is shown as plain text.
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
import '../claude/claude_screen.dart' show relativeTime;
import '../incidents/host_picker.dart';
import '../system/agent_providers.dart';
import '../system/events.dart' show ChipRow, filterChip;
import 'security_data.dart';
import 'security_texts.dart';
import 'security_widgets.dart';

/// Rows shown per list; the rest is summarised ("… and N more").
const securityListCap = 100;

class SecurityHostScreen extends ConsumerStatefulWidget {
  const SecurityHostScreen({super.key, required this.hostId, this.agentHint});
  final String hostId;

  /// Agent id or name (from the app or a notification); null = look on every agent with the feature.
  final String? agentHint;

  @override
  ConsumerState<SecurityHostScreen> createState() => _SecurityHostScreenState();
}

class _SecurityHostScreenState extends ConsumerState<SecurityHostScreen> {
  String _tab = 'ports';
  bool _busy = false;

  SecurityRef get _key => (widget.hostId, widget.agentHint);

  void _refreshAll() {
    if (mounted) ref.invalidate(securityDetailProvider(_key));
    if (mounted) ref.invalidate(securityFeedProvider);
  }

  Future<void> _check(SecurityDetail d, {required bool full}) async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String message;
    try {
      await securityCall(ref, d.agent.id, 'POST', '${securityHostPath(d.summary.id)}/check', body: {'full': full}, timeout: securityCheckTimeout(full: full));
      message = l.secCheckDone;
    } catch (e) {
      message = agentErrorText(l, e);
    }
    // A failed check changes the host's last error too, so the detail is read again either way.
    if (mounted) {
      setState(() => _busy = false);
      _refreshAll();
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _accept(SecurityDetail d) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(context: context, builder: (_) => _AcceptDialog(count: d.changes.length));
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      // expected: the agent refuses (409 changesMoved) if the list changed after the user looked at it.
      final j = await securityCall(ref, d.agent.id, 'POST', '${securityHostPath(d.summary.id)}/baseline', body: {'confirm': true, 'expected': d.changes.length});
      final n = (j is Map ? (j['accepted'] as num?)?.toInt() : null) ?? d.changes.length;
      if (mounted) toast(context, l.secAccepted(n));
    } catch (e) {
      if (mounted) toast(context, e is AgentError && e.code == 'agent.security.changesMoved' ? l.secChangesMoved : agentErrorText(l, e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshAll();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(securityDetailProvider(_key));
    final d = async.value;
    return SettingsPage(
      title: d?.summary.name ?? l.secTitle,
      onRefresh: () async {
        ref.invalidate(securityDetailProvider(_key));
        await ref.read(securityDetailProvider(_key).future).then((_) {}, onError: (_) {});
      },
      actions: [
        IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(securityDetailProvider(_key))),
        if (d != null)
          PopupMenuButton<String>(
            tooltip: MaterialLocalizations.of(context).showMenuTooltip,
            onSelected: (v) => v == 'full' ? _check(d, full: true) : context.push('/security/settings'),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'full', enabled: !_busy, child: Text(l.secCheckFull)),
              PopupMenuItem(value: 'settings', child: Text(l.secMenuSettings)),
            ],
          ),
      ],
      children: async.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          if (e is AmbiguousHostError)
            HostPicker(hosts: e.hosts, onPick: (h) => context.replace(securityRoute(widget.hostId, agentId: h.id)))
          else
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e is AgentError && e.code == 'agent.security.hostNotFound' ? l.secHostNotFound(widget.hostId) : agentErrorText(l, e)),
                const SizedBox(height: 8),
                TextButton(onPressed: () => ref.invalidate(securityDetailProvider(_key)), child: Text(l.commonRetry)),
              ]),
            ),
        ],
        data: (det) => [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _body(context, det))],
      ),
    );
  }

  List<Widget> _body(BuildContext context, SecurityDetail d) {
    final l = AppLocalizations.of(context);
    final tabs = [
      ('ports', l.secTabPorts),
      ('ssh', l.secTabSsh),
      ('users', l.secTabUsers),
      ('jobs', l.secTabJobs),
      ('updates', l.secTabUpdates),
      ('containers', l.secTabContainers),
      ('system', l.secTabSystem),
    ];
    final r = d.report;
    return [
      _Header(detail: d, busy: _busy, onCheck: () => _check(d, full: false)),
      if (d.changes.isNotEmpty) ...[
        const SizedBox(height: 12),
        _ChangesCard(detail: d, busy: _busy, onAccept: () => _accept(d)),
      ],
      SectionLabel(l.secFindingsTitle),
      if (r == null)
        TCard(child: Text(l.secNoReport))
      else if (d.findings.isEmpty)
        TCard(child: Text(l.secNoFindings))
      else
        for (final s in securityFindingSeverities)
          if (d.findingsOf(s).isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: _FindingsGroup(severity: s, findings: d.findingsOf(s))),
      if (r != null) ...[
        const SizedBox(height: 2),
        _FirewallCard(report: r),
        ChipRow(children: [for (final (id, label) in tabs) filterChip(context, label, _tab == id, () => setState(() => _tab = id))]),
        const SizedBox(height: 10),
        switch (_tab) {
          'ports' => _PortsTab(detail: d, report: r),
          'ssh' => _SshTab(report: r),
          'users' => _UsersTab(report: r),
          'jobs' => _JobsTab(report: r),
          'updates' => _UpdatesTab(report: r),
          'containers' => _ContainersTab(report: r),
          _ => _SystemTab(report: r),
        },
      ],
    ];
  }
}

/// Confirmation with a guard against a second tap while the dialog closes.
class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.count});
  final int count;
  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secAcceptTitle),
      content: Text(l.secAcceptBody(widget.count)),
      actions: [
        TextButton(onPressed: _done ? null : () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        TextButton(
          onPressed: _done
              ? null
              : () {
                  setState(() => _done = true);
                  Navigator.pop(context, true);
                },
          child: Text(l.secAccept),
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.detail, required this.busy, required this.onCheck});
  final SecurityDetail detail;
  final bool busy;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = detail.summary;
    final now = ref.watch(clockProvider)();
    final running = busy || s.running;
    final err = s.lastError;
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ScoreBadge(score: s.score, size: 60),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, style: tt.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('${securityRoleName(l, s.role)} · ${securitySourceName(l, s.source)} · ${detail.agent.name}', style: tt.bodyMedium?.copyWith(color: t.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(s.lastOkAt == null ? l.secNeverChecked : l.secLastCheck('${securityWhen(context, s.lastOkAt!)} · ${relativeTime(l, s.lastOkAt!, now)}'), style: tt.bodySmall),
        if (s.lastFullAt != null) Text(l.secLastFull(securityWhen(context, s.lastFullAt!)), style: tt.bodySmall),
        if (detail.baselineAt != null) Text(l.secBaselineAt(securityWhen(context, detail.baselineAt!)), style: tt.bodySmall),
        if (s.showStale && s.lastOkAt != null) Padding(padding: const EdgeInsets.only(top: 6), child: SecChip(l.secStaleSince(relativeTime(l, s.lastOkAt!, now)), t.warning, icon: LucideIcons.clockAlert)),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(LucideIcons.circleAlert, size: 16, color: t.danger),
              const SizedBox(width: 6),
              Expanded(child: Text(securityErrorText(l, err.code), style: tt.bodyMedium?.copyWith(color: t.danger))),
            ]),
          ),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(
            onPressed: running ? null : onCheck,
            icon: running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.scanSearch, size: 16),
            label: Text(running ? l.secChecking : l.secCheckNow),
          ),
        ]),
      ]),
    );
  }
}

class _ChangesCard extends StatelessWidget {
  const _ChangesCard({required this.detail, required this.busy, required this.onAccept});
  final SecurityDetail detail;
  final bool busy;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final shown = detail.changes.take(securityListCap).toList();
    return TCard(
      borderColor: t.warning,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(LucideIcons.gitCompareArrows, size: 18, color: t.warning),
          const SizedBox(width: 8),
          Expanded(child: Text('${l.secChangesTitle} · ${detail.changes.length}', style: tt.titleMedium)),
        ]),
        const SizedBox(height: 4),
        Text(l.secChangesIntro, style: tt.bodySmall),
        const SizedBox(height: 8),
        for (final c in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SecChip(securityKindName(l, c.kind), c.kind == 'removed' ? t.textSecondary : t.warning),
                const SizedBox(width: 8),
                Expanded(child: Text(securityCategoryName(l, c.category), style: tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 2),
              Text(c.item, style: const TextStyle(fontFamily: monoFamily, fontSize: 12.5), maxLines: 3, overflow: TextOverflow.ellipsis),
              if (c.firstSeenAt != null) Text(l.secFirstSeen(securityWhen(context, c.firstSeenAt!)), style: tt.bodySmall),
            ]),
          ),
        if (detail.changes.length > shown.length) Text(l.secMore(detail.changes.length - shown.length), style: tt.bodySmall),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(onPressed: busy ? null : onAccept, icon: const Icon(LucideIcons.check, size: 16), label: Text(l.secAccept)),
      ]),
    );
  }
}

class _FindingsGroup extends StatelessWidget {
  const _FindingsGroup({required this.severity, required this.findings});
  final String severity;
  final List<SecFinding> findings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final c = securitySeverityColor(t, severity);
    return TCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: SecChip('${securitySeverityName(l, severity)} · ${findings.length}', c, filled: severity == 'critical')),
        for (final f in findings)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              container: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(securityRuleTitle(l, f.rule, f.params), style: tt.titleSmall),
                if (securityRuleWhy(l, f.rule, f.params) case final why?) Padding(padding: const EdgeInsets.only(top: 2), child: Text(why, style: tt.bodyMedium)),
                if (securityRuleFix(l, f.rule) case final fix?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${l.secFixLabel}: ', style: TextStyle(fontWeight: FontWeight.w700, color: t.textSecondary)),
                      TextSpan(text: fix),
                    ]), style: tt.bodySmall),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 6),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Tabs

/// A titled card of rows.
class _Block extends StatelessWidget {
  const _Block({required this.title, required this.children, this.note});
  final String? title;
  final List<Widget> children;

  /// Shown instead of the rows (section not available / empty).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) Semantics(header: true, child: Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title!, style: tt.titleMedium))),
          if (note != null) Text(note!, style: tt.bodyMedium?.copyWith(color: context.tokens.textSecondary)) else ...children,
        ]),
      ),
    );
  }
}

/// Rows capped at [securityListCap] with a "… and N more" line.
List<Widget> _capped(BuildContext context, List<Widget> rows) {
  final l = AppLocalizations.of(context);
  if (rows.length <= securityListCap) return rows;
  return [...rows.take(securityListCap), Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.secMore(rows.length - securityListCap), style: Theme.of(context).textTheme.bodySmall))];
}

/// "label ........ value"; both wrap when long.
class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.mono = false, this.color});
  final String label;
  final String value;
  final bool mono;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(flex: 4, child: Text(label, style: tt.bodyMedium?.copyWith(color: t.textSecondary))),
        const SizedBox(width: 12),
        Flexible(
          flex: 5,
          child: Text(value, textAlign: TextAlign.end, style: (mono ? const TextStyle(fontFamily: monoFamily, fontSize: 12.5) : tt.bodyMedium)?.copyWith(color: color)),
        ),
      ]),
    );
  }
}

/// One line of monospace text (a path, a fingerprint), ellipsized at the end.
class _Mono extends StatelessWidget {
  const _Mono(this.text, {this.lines = 2, this.color});
  final String text;
  final int lines;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(text, maxLines: lines, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: color)),
      );
}

class _FirewallCard extends StatelessWidget {
  const _FirewallCard({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fw = report.firewall;
    final text = fw == null ? l.secFwUnknown : (fw.defaultDeny ? l.secFwDenyYes : l.secFwDenyNo);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TCard(
        semanticLabel: '${l.secFwTitle}: $text',
        child: ExcludeSemantics(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(fw == null ? LucideIcons.shieldQuestionMark : (fw.defaultDeny ? LucideIcons.shieldCheck : LucideIcons.shieldAlert), size: 20, color: fw == null ? t.textSecondary : (fw.defaultDeny ? t.success : t.warning)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.secFwTitle, style: Theme.of(context).textTheme.titleSmall),
                Text(text, style: Theme.of(context).textTheme.bodyMedium),
                if (fw != null) Text(l.secFwChains(fw.inputChains), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

String _notAvailable(AppLocalizations l) => l.secNotAvailable;

class _PortsTab extends StatelessWidget {
  const _PortsTab({required this.detail, required this.report});
  final SecurityDetail detail;
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final listen = report.listen;
    if (listen == null) return _Block(title: l.secTabPorts, note: _notAvailable(l), children: const []);
    final flagged = detail.flaggedPorts;
    final sorted = [...listen]..sort((a, b) => (a.exposed && !a.filtered) != (b.exposed && !b.filtered) ? ((a.exposed && !a.filtered) ? -1 : 1) : a.port - b.port);
    return _Block(
      title: l.secTabPorts,
      note: listen.isEmpty ? l.secPortsEmpty : null,
      children: _capped(context, [
        for (final p in sorted)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: flagged.contains(p.spec) ? t.danger.withValues(alpha: 0.12) : null, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              SizedBox(width: 74, child: Text(p.spec, style: const TextStyle(fontFamily: monoFamily, fontSize: 13, fontWeight: FontWeight.w700))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.iface == null ? p.addr : '${p.addr} · ${p.iface}', style: tt.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (p.process != null) Text(p.process!, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (p.filtered) Text(l.secPortFiltered, style: tt.bodySmall),
                ]),
              ),
              const SizedBox(width: 8),
              if (!p.filtered) SecChip(securityScopeName(l, p.scope), p.exposed ? (flagged.contains(p.spec) ? t.danger : t.warning) : t.textSecondary),
            ]),
          ),
      ]),
    );
  }
}

class _SshTab extends StatelessWidget {
  const _SshTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = report.sshd;
    if (s == null) return _Block(title: l.secTabSsh, note: _notAvailable(l), children: const []);
    final keys = s.keys.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Block(title: l.secTabSsh, note: keys.isEmpty ? l.secEmptyList : null, children: [
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(report.sshdMode == 'effective' ? l.secSshEffective : l.secSshConfig, style: Theme.of(context).textTheme.bodySmall)),
        for (final k in keys) _KV(k, s[k]!.join(', '), mono: true),
      ]),
    ]);
  }
}

class _UsersTab extends StatelessWidget {
  const _UsersTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final pw = report.passwords;
    final groups = report.groups.entries.where((e) => e.value.isNotEmpty).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Block(title: l.secUsersTitle, note: report.users.isEmpty ? l.secEmptyList : null, children: _capped(context, [
        for (final u in report.users) _KV('${u.name} · ${u.uid}', u.shell, mono: true, color: u.uid == 0 && u.name != 'root' ? t.danger : null),
      ])),
      _Block(
        title: l.secPasswordsTitle,
        note: pw == null ? l.secNotAvailable : (pw.isEmpty ? l.secEmptyList : null),
        children: _capped(context, [
          if (pw != null)
            for (final e in pw.entries) _KV(e.key, e.value == 'empty' ? l.secPwEmpty : l.secPwSet, color: e.value == 'empty' ? t.danger : null),
        ]),
      ),
      _Block(title: l.secGroupsTitle, note: groups.isEmpty ? l.secEmptyList : null, children: _capped(context, [for (final g in groups) _KV(g.key, g.value.join(', '), mono: true)])),
      _Block(
        title: l.secKeysTitle,
        note: report.authKeys.isEmpty ? l.secEmptyList : null,
        children: _capped(context, [
          for (final k in report.authKeys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([k.user, if (k.comment.isNotEmpty) k.comment].join(' · '), style: Theme.of(context).textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(l.secKeyLine(k.type, '${k.bits}'), style: Theme.of(context).textTheme.bodySmall),
                _Mono(k.fingerprint, lines: 3),
              ]),
            ),
        ]),
      ),
      _Block(
        title: l.secSudoersTitle,
        note: report.sudoers == null ? l.secNotAvailable : (report.sudoers!.isEmpty ? l.secEmptyList : null),
        children: _capped(context, [for (final f in report.sudoers ?? const <SecHashed>[]) _Mono(f.path)]),
      ),
    ]);
  }
}

class _JobsTab extends StatelessWidget {
  const _JobsTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final auto = report.autostart;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Block(title: l.secCronTitle, note: report.cron.isEmpty ? l.secEmptyList : null, children: _capped(context, [for (final f in report.cron) _Mono(f.path)])),
      _Block(
        title: l.secTimersTitle,
        note: report.timers.isEmpty ? l.secEmptyList : null,
        children: _capped(context, [
          for (final tm in report.timers) _KV('${tm.scope == 'user' ? l.secTimerScopeUser : l.secTimerScopeSystem} · ${tm.name}', tm.unit, mono: true),
        ]),
      ),
      _Block(
        title: l.secAutostartTitle,
        note: auto == null ? l.secNotAvailable : (auto.isEmpty ? l.secEmptyList : null),
        children: _capped(context, [for (final f in auto ?? const <SecHashed>[]) _Mono(f.path)]),
      ),
    ]);
  }
}

class _UpdatesTab extends StatelessWidget {
  const _UpdatesTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final u = report.updates;
    String n(int? v) => v == null ? l.secUnknown : '$v';
    return _Block(title: l.secTabUpdates, children: [
      _KV(l.secUpdSecurity, n(u.security), color: (u.security ?? 0) > 0 ? t.warning : null),
      _KV(l.secUpdPending, n(u.pending)),
      _KV(l.secUpdUnattended, u.unattended == null ? l.secUnknown : (u.unattended! ? l.secOn : l.secOff), color: u.unattended == false ? t.warning : null),
      _KV(l.secUpdListsAt, u.listsUpdatedAt == null ? l.secUnknown : securityWhen(context, u.listsUpdatedAt!)),
      _KV(l.secUpdReboot, u.rebootRequiredSince == null ? l.secNo : l.secUpdRebootSince(securityWhen(context, u.rebootRequiredSince!)), color: u.rebootRequiredSince != null ? t.warning : null),
    ]);
  }
}

class _ContainersTab extends StatelessWidget {
  const _ContainersTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final dk = report.docker;
    if (dk == null) return _Block(title: l.secTabContainers, note: l.secDockerNone, children: const []);
    final list = [...dk.containers]..sort((a, b) => (b.risky ? 1 : 0) - (a.risky ? 1 : 0));
    return _Block(
      title: '${l.secTabContainers} · ${l.secDockerVersion(dk.version)} · ${l.secImagesCount(dk.images)}',
      note: list.isEmpty ? l.secContainersEmpty : null,
      children: _capped(context, [
        for (final c in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              _Mono(c.image, lines: 1, color: t.textSecondary),
              if (c.risky)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    if (c.privileged) SecChip(l.secFlagPrivileged, t.danger),
                    if (c.socketMounted) SecChip(l.secFlagSocket, t.danger),
                    if (c.hostPid) SecChip(l.secFlagHostPid, t.warning),
                    if (c.hostNetwork) SecChip(l.secFlagHostNet, t.warning),
                    if (c.capAdd.isNotEmpty) SecChip(l.secFlagCaps(c.capAdd.join(', ')), t.warning),
                  ]),
                ),
              if (c.ports.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(l.secContainerPorts(c.ports.join(', ')), style: tt.bodySmall)),
            ]),
          ),
      ]),
    );
  }
}

class _SystemTab extends StatelessWidget {
  const _SystemTab({required this.report});
  final SecurityReportData report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final r = report;
    String? meta(String k) => r.metaString(k);
    final up = r.uptimeSec;
    final sysctl = r.sysctl.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Block(title: l.secSysMeta, children: [
        if (meta('hostname') != null) _KV(l.secMetaHostname, meta('hostname')!),
        if (meta('os') != null) _KV(l.secMetaOs, meta('os')!),
        if (meta('kernel') != null) _KV(l.secMetaKernel, meta('kernel')!, mono: true),
        if (meta('arch') != null) _KV(l.secMetaArch, meta('arch')!),
        if (r.ipv6Global != null) _KV(l.secMetaIpv6, '${r.ipv6Global}'),
        if (up != null) _KV(l.secMetaUptime, l.secUptimeDays(up ~/ 86400, (up % 86400) ~/ 3600)),
        if (r.reportTime != null) _KV(l.secMetaTime, securityWhen(context, r.reportTime!)),
        _KV(l.secMetaMode, r.mode == 'report-full' ? l.secModeFull : l.secModeQuick),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(r.root ? l.secRunRoot : l.secRunNoRoot, style: Theme.of(context).textTheme.bodySmall)),
      ]),
      _Block(title: l.secServicesTitle, note: r.services.isEmpty ? l.secEmptyList : null, children: [for (final e in r.services.entries) _KV(e.key, e.value)]),
      _Block(title: l.secSysctlTitle, note: sysctl.isEmpty ? l.secEmptyList : null, children: _capped(context, [for (final e in sysctl) _KV(e.key, e.value, mono: true)])),
      _Block(
        title: l.secLoginsTitle,
        note: r.logins.isEmpty ? l.secEmptyList : null,
        children: _capped(context, [for (final x in r.logins) _Mono(x.raw.isNotEmpty ? x.raw : '${x.user} ${x.tty} ${x.from}', lines: 2)]),
      ),
      _Block(title: l.secSuidTitle, note: r.suid == null ? l.secFullOnly : (r.suid!.isEmpty ? l.secEmptyList : null), children: _capped(context, [for (final f in r.suid ?? const <SecFile>[]) _Mono('${f.mode} ${f.owner} ${f.path}')])),
      _Block(
        title: l.secWorldWritableTitle,
        note: r.worldWritable == null ? l.secFullOnly : (r.worldWritable!.isEmpty ? l.secEmptyList : null),
        children: _capped(context, [for (final f in r.worldWritable ?? const <SecFile>[]) _Mono('${f.mode} ${f.owner} ${f.path}')]),
      ),
      if (r.agentFiles != null && r.agentFiles!.isNotEmpty) _Block(title: l.secAgentFilesTitle, children: _capped(context, [for (final f in r.agentFiles!) _KV(f.path, f.mode, mono: true)])),
      if (r.unavailable.isNotEmpty)
        _Block(title: l.secUnavailableTitle, children: [Text(l.secUnavailableNote(r.unavailable.map((id) => securitySectionName(l, id)).join(', ')), style: Theme.of(context).textTheme.bodyMedium)]),
    ]);
  }
}
