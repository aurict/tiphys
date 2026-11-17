// Incident screen (PLAN.md §13.1, I-1): header with lifecycle actions, rule-based "likely cause" hints, suggested
// actions (preview sheet → confirm → run) and the evidence tabs. Text that comes from the agent (logs, notes, stderr)
// is always shown as plain text.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/push/push_service.dart' show noticeText;
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import '../system/agent_providers.dart';
import '../system/events.dart' show ChipRow, filterChip;
import '../claude/claude_screen.dart' show claudeHostProvider, showNewSession;
import 'incident_action_sheet.dart';
import 'incident_analysis.dart';
import 'incident_analysis_view.dart';
import 'incident_metrics_view.dart';
import 'incident_texts.dart';
import 'incidents_data.dart';
import 'incidents_screen.dart';

/// One timeline entry → (text, plain detail). Detail is a note, a resolution note or the command's stderr.
(String, String?) incidentTimelineText(AppLocalizations l, TimelineItem e) {
  String s(String k) => '${e.data[k] ?? ''}';
  final action = incidentActionName(l, s('action'));
  return switch (e.type) {
    'opened' => (l.incTlOpened, null),
    'signal' => (l.incTlSignal(e.key ?? ''), null),
    'merged' => (l.incTlMerged(s('target')), null),
    'recovered' => (l.incTlRecovered(e.key ?? ''), null),
    'acknowledged' => (l.incTlAck, null),
    'resolved' => (l.incTlResolved, e.text),
    'reopened' => (l.incTlReopened, null),
    'note' => (l.incTlNote, e.text),
    'context' => e.data['ok'] == false ? (l.incTlContextFailed, null) : (l.incTlContext((e.data['logLines'] as num?)?.toInt() ?? 0), null),
    'action' => (l.incTlAction(action), null),
    'actionResult' => e.data['ok'] == true ? (l.incTlActionOk(action), e.text) : (l.incTlActionFailed(action, s('code')), e.text),
    'postCheck' => e.data['ok'] == true ? (l.incTlPostOk(s('state')), null) : (l.incTlPostFailed(s('state')), null),
    'analysis' => (l.incTlAnalysisStart, null),
    'analysisResult' => switch (s('status')) {
        'done' => (l.incTlAnalysisDone((e.data['hypotheses'] as num?)?.toInt() ?? 0, (e.data['actions'] as num?)?.toInt() ?? 0), null),
        'unavailable' => (l.incTlAnalysisUnavailable, analysisReasonText(l, s('code').split('.').last)),
        _ => (l.incTlAnalysisFailed, analysisFailedText(l, s('code'))),
      },
    _ => (e.type, e.text),
  };
}

(IconData, Color) _timelineVisual(TiphysTokens t, TimelineItem e) => switch (e.type) {
      'opened' || 'signal' || 'merged' || 'reopened' => (LucideIcons.triangleAlert, t.danger),
      'recovered' || 'resolved' => (LucideIcons.circleCheck, t.success),
      'acknowledged' => (LucideIcons.eye, t.warning),
      'note' => (LucideIcons.stickyNote, t.accent),
      'context' => (LucideIcons.search, t.textSecondary),
      'action' => (LucideIcons.play, t.accent),
      'analysis' => (LucideIcons.sparkles, t.accent),
      'analysisResult' => e.data['status'] == 'done' ? (LucideIcons.sparkles, t.success) : (LucideIcons.sparkles, t.warning),
      'actionResult' || 'postCheck' => e.data['ok'] == true ? (LucideIcons.circleCheck, t.success) : (LucideIcons.circleX, t.danger),
      _ => (LucideIcons.dot, t.textSecondary),
    };

class IncidentScreen extends ConsumerStatefulWidget {
  const IncidentScreen({super.key, required this.incidentId, this.hostHint});
  final String incidentId;

  /// Host id or the agent's host name (from the notification); null = look on every agent host.
  final String? hostHint;
  @override
  ConsumerState<IncidentScreen> createState() => _IncidentScreenState();
}

class _IncidentScreenState extends ConsumerState<IncidentScreen> {
  String _tab = 'logs';
  bool _busy = false;
  bool _analysisOff = false;
  int _nonce = 0;
  EvidenceFocus? _focus;
  final _search = TextEditingController();
  final _tabsKey = GlobalKey();
  late final AnalysisPoller _poller = AnalysisPoller(refresh: () {
    if (mounted) ref.invalidate(incidentDetailProvider(_key));
  });

  IncidentRef get _key => (widget.incidentId, widget.hostHint);

  @override
  void dispose() {
    _poller.stop();
    _search.dispose();
    super.dispose();
  }

  void _refresh(IncidentDetail d) {
    ref.invalidate(incidentDetailProvider(_key));
    ref.invalidate(incidentActionsProvider((d.host.id, d.summary.id)));
    ref.invalidate(incidentsFeedProvider);
  }

  Future<void> _call(IncidentDetail d, String what, [Object? body]) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await agentCall(ref, d.host.id, 'POST', '/v1/incidents/${d.summary.id}/$what', body);
      _refresh(d);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolve(IncidentDetail d) async {
    final l = AppLocalizations.of(context);
    final note = await showDialog<String>(context: context, builder: (_) => _NoteDialog(title: l.incResolveTitle, label: l.incNoteOptional, confirm: l.incResolve, required: false));
    if (note == null) return;
    await _call(d, 'resolve', note.isEmpty ? null : {'note': note});
  }

  Future<void> _addNote(IncidentDetail d) async {
    final l = AppLocalizations.of(context);
    final note = await showDialog<String>(context: context, builder: (_) => _NoteDialog(title: l.incNoteTitle, label: l.incNoteField, confirm: l.commonSave, required: true));
    if (note == null || note.isEmpty) return;
    await _call(d, 'notes', {'text': note});
  }

  /// Asks the agent for an AI analysis (202 → queued; the screen polls until it is finished). 409 analysisOff: the
  /// host has it switched off, so the button gives way to a hint how to turn it on.
  Future<void> _analyze(IncidentDetail d) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await agentCall(ref, d.host.id, 'POST', '/v1/incidents/${d.summary.id}/analyze');
      _refresh(d);
    } on AgentError catch (e) {
      if (!mounted) return;
      if (e.code == 'agent.incident.analysisOff') setState(() => _analysisOff = true);
      toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Investigate with Claude on the PC": after a confirmation that the text is redacted, fetches the redacted bundle
  /// and opens the normal new-session sheet with it as the first message (same hand-off as "Ask Claude" in the logs).
  Future<void> _investigate(IncidentDetail d) async {
    final l = AppLocalizations.of(context);
    if (ref.read(claudeHostProvider) == null) return toast(context, l.dozzleNoClaudeHost);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.incInvestigateTitle),
        content: Text(l.incInvestigateBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(l.incInvestigateGo)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final j = await agentCall(ref, d.host.id, 'GET', '/v1/incidents/${d.summary.id}/bundle?redacted=1');
      if (!mounted) return;
      final text = '${(j as Map)['text'] ?? ''}';
      if (j['truncated'] == true) toast(context, l.incInvestigateTruncated);
      await showNewSession(context, ref, prompt: l.incInvestigatePrompt(text));
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// An evidence chip: switch to its tab, drop a log filter that would hide the line, and scroll to it.
  void _showEvidence(EvidenceTarget target) {
    _search.clear();
    setState(() {
      _tab = target.tab;
      _focus = EvidenceFocus(target, ++_nonce);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _tabsKey.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: Duration.zero, alignment: 0.05);
    });
  }

  Future<void> _openAction(IncidentDetail d, ActionCandidate c, String? runningId) async {
    final ran = await showIncidentActionSheet(context, host: d.host, incidentId: d.summary.id, candidate: c, runningId: runningId);
    if (ran) _refresh(d);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(incidentDetailProvider(_key));
    final d = async.value;
    return SettingsPage(
      title: l.incScreenTitle,
      onRefresh: () async {
        ref.invalidate(incidentDetailProvider(_key));
        await ref.read(incidentDetailProvider(_key).future).then((_) {}, onError: (_) {});
      },
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(incidentDetailProvider(_key)))],
      children: async.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          TCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(agentErrorText(l, e)),
            const SizedBox(height: 8),
            TextButton(onPressed: () => ref.invalidate(incidentDetailProvider(_key)), child: Text(l.commonRetry)),
          ])),
        ],
        // One child instead of a lazy list: an evidence chip scrolls to a row far below it, which must exist already.
        data: (det) => [Column(crossAxisAlignment: CrossAxisAlignment.start, children: _body(context, d ?? det))],
      ),
    );
  }

  List<Widget> _body(BuildContext context, IncidentDetail d) {
    final l = AppLocalizations.of(context);
    final s = d.summary;
    final actions = s.status == 'resolved' ? null : ref.watch(incidentActionsProvider((d.host.id, s.id)));
    _poller.sync(d.analysis);
    final mode = ref.watch(incidentAnalysisModeProvider(d.host.id)).value;
    return [
      _Header(detail: d, busy: _busy, onAck: () => _call(d, 'ack'), onResolve: () => _resolve(d), onReopen: () => _call(d, 'reopen'), onNote: () => _addNote(d)),
      const SizedBox(height: 12),
      _WhyCard(
        detail: d,
        busy: _busy,
        analysisOff: _analysisOff || mode == 'off',
        actions: actions?.value,
        onAnalyze: () => _analyze(d),
        onEvidence: _showEvidence,
        onAction: (c) => _openAction(d, c, actions?.value?.running),
        onInvestigate: () => _investigate(d),
      ),
      if (actions != null) ...[
        SectionLabel(l.incActionsTitle),
        _ActionsCard(actions: actions, onOpen: (c, running) => _openAction(d, c, running)),
      ],
      const SizedBox(height: 4),
      ChipRow(key: _tabsKey, children: [
        for (final (id, label) in [
          ('logs', l.incTabLogs),
          ('container', l.incTabContainer),
          ('deploys', l.incTabDeploys),
          ('metrics', l.incEvMetrics),
          ('git', l.incTabGit),
          ('events', l.incTabEvents),
          ('similar', l.incTabSimilar),
          ('timeline', l.incTabTimeline),
        ])
          filterChip(context, label, _tab == id, () => setState(() {
            _tab = id;
            _focus = null;
          })),
      ]),
      const SizedBox(height: 10),
      if (d.context == null && _tab != 'timeline')
        TCard(child: Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), Expanded(child: Text(l.incContextPending))]))
      else
        switch (_tab) {
          'logs' => _LogsView(detail: d, controller: _search, focus: _focus),
          'container' => _ContainerView(detail: d),
          'deploys' => _DeploysView(detail: d, focus: _focus),
          'metrics' => MetricsView(metrics: d.metrics, focus: _focus),
          'git' => _GitView(detail: d, focus: _focus),
          'events' => _EventsView(detail: d, focus: _focus),
          'similar' => _SimilarView(detail: d),
          _ => _TimelineView(detail: d),
        },
      if (d.errors.isNotEmpty && d.context != null && _tab != 'timeline')
        Padding(padding: const EdgeInsets.only(top: 8, left: 4), child: Text(l.incContextFailed(d.errors.keys.join(', ')), style: Theme.of(context).textTheme.bodySmall)),
    ];
  }
}

String _when(BuildContext context, DateTime d) => DateFormat('d MMM HH:mm', Localizations.localeOf(context).toLanguageTag()).format(d);

class _Header extends ConsumerWidget {
  const _Header({required this.detail, required this.busy, required this.onAck, required this.onResolve, required this.onReopen, required this.onNote});
  final IncidentDetail detail;
  final bool busy;
  final VoidCallback onAck, onResolve, onReopen, onNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = detail.summary;
    final now = ref.watch(clockProvider)();
    final meta = [
      detail.host.name,
      s.target,
      if (s.service != null && s.service != s.target) s.service!,
    ].join(' · ');
    final times = [
      l.incOpenedAt(relativeTime(l, s.openedAt, now)),
      if (s.resolvedAt != null) l.incResolvedAt(relativeTime(l, s.resolvedAt!, now)),
      l.incSignals(s.signalCount),
    ].join(' · ');
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(incidentTitle(l, s.kind, s.target), style: tt.titleLarge),
        const SizedBox(height: 4),
        Text(meta, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          IncidentStatusChip(s.status),
          _Chip(s.severity == 'critical' ? l.incSeverityCritical : l.incSeverityWarning, s.severity == 'critical' ? t.danger : t.warning),
          if (s.test) _Chip(l.incTest, t.textSecondary),
        ]),
        const SizedBox(height: 8),
        Text(times, style: tt.bodySmall),
        if (s.status == 'resolved' && detail.resolvedBy != null) Text(l.incResolvedBy(incidentActor(l, detail.resolvedBy!)), style: tt.bodySmall),
        if (s.resolutionNote != null && s.resolutionNote!.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(s.resolutionNote!, style: tt.bodyMedium)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (s.status == 'open') FilledButton.tonalIcon(onPressed: busy ? null : onAck, icon: const Icon(LucideIcons.eye, size: 16), label: Text(l.incAck)),
          if (s.status != 'resolved') FilledButton.tonalIcon(onPressed: busy ? null : onResolve, icon: const Icon(LucideIcons.check, size: 16), label: Text(l.incResolve)),
          if (s.status == 'resolved') FilledButton.tonalIcon(onPressed: busy ? null : onReopen, icon: const Icon(LucideIcons.rotateCcw, size: 16), label: Text(l.incReopen)),
          OutlinedButton.icon(onPressed: busy ? null : onNote, icon: const Icon(LucideIcons.stickyNote, size: 16), label: Text(l.incNote)),
        ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

/// "Likely cause": the agent's rule-based hints (labelled "rules") and, below them, the AI analysis.
class _WhyCard extends ConsumerWidget {
  const _WhyCard({
    required this.detail,
    required this.busy,
    required this.analysisOff,
    required this.actions,
    required this.onAnalyze,
    required this.onEvidence,
    required this.onAction,
    required this.onInvestigate,
  });
  final IncidentDetail detail;
  final bool busy;
  final bool analysisOff;
  final IncidentActions? actions;
  final VoidCallback onAnalyze;
  final ValueChanged<EvidenceTarget> onEvidence;
  final void Function(ActionCandidate) onAction;
  final VoidCallback onInvestigate;

  String? _tabOf(String evidence) => switch (evidence) {
        'logs' => 'logs',
        'inspect' => 'container',
        'deploys' => 'deploys',
        'git' => 'git',
        'events' => 'events',
        'metrics' => 'metrics',
        'signals' => 'timeline',
        _ => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    String evName(String e) => switch (e) {
          'logs' => l.incTabLogs,
          'inspect' => l.incTabContainer,
          'deploys' => l.incTabDeploys,
          'git' => l.incTabGit,
          'events' => l.incTabEvents,
          'metrics' => l.incEvMetrics,
          _ => l.incTabTimeline,
        };
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(LucideIcons.lightbulb, size: 18, color: t.accent),
          const SizedBox(width: 8),
          Expanded(child: Text(l.incWhyTitle, style: tt.titleMedium)),
          _Chip(l.incWhyRules, t.textSecondary),
        ]),
        const SizedBox(height: 10),
        if (detail.hints.isEmpty) Text(l.incWhyEmpty, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
        for (final h in detail.hints)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(incidentHintText(l, h.code, h.params), style: tt.bodyMedium),
              if (h.evidence.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final e in h.evidence)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(evName(e), style: const TextStyle(fontSize: 12)),
                        onPressed: _tabOf(e) == null ? null : () => onEvidence(EvidenceTarget(_tabOf(e)!)),
                      ),
                  ]),
                ),
            ]),
          ),
        AnalysisSection(
          detail: detail,
          now: ref.watch(clockProvider)(),
          off: analysisOff,
          busy: busy,
          index: detail.evidenceIndex,
          actions: actions,
          onAnalyze: onAnalyze,
          onEvidence: onEvidence,
          onAction: onAction,
          onInvestigate: onInvestigate,
        ),
      ]),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.actions, required this.onOpen});
  final AsyncValue<IncidentActions> actions;
  final void Function(ActionCandidate c, String? runningId) onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return actions.when(
      skipLoadingOnRefresh: true,
      loading: () => const TCard(child: Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))),
      error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
      data: (a) {
        if (a.actions.isEmpty) return TCard(child: Text(l.incActionsEmpty));
        return GroupedSection(children: [
          for (final c in a.actions)
            GroupedRow(
              title: incidentActionLabel(l, c.kind, c.target),
              subtitle: a.running == c.id ? l.incActionRunning : (c.risk == 'medium' ? l.incRiskMedium : l.incRiskLow),
              icon: LucideIcons.wrench,
              iconBackground: c.risk == 'medium' ? t.warning : t.accent,
              // One action at a time: while one runs the others are disabled.
              onTap: a.running != null ? null : () => onOpen(c, a.running),
            ),
        ]);
      },
    );
  }
}

/// Plain monospace block in a card.
class _Mono extends StatelessWidget {
  const _Mono(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      SelectableText(text, style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, height: 1.4, color: context.tokens.text));
}

class _LogsView extends StatefulWidget {
  const _LogsView({required this.detail, required this.controller, this.focus});
  final IncidentDetail detail;
  final TextEditingController controller;

  /// A `log:<source>#<line>` target: that line is highlighted and scrolled into view.
  final EvidenceFocus? focus;
  @override
  State<_LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<_LogsView> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final logs = widget.detail.logs;
    final lines = [for (final x in (logs?['lines'] as List? ?? const [])) '$x'];
    if (lines.isEmpty) return TCard(child: Text(l.incLogsEmpty));
    final q = widget.controller.text.trim().toLowerCase();
    final shown = q.isEmpty ? lines : [for (final x in lines) if (x.toLowerCase().contains(q)) x];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: widget.controller,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          hintText: l.incLogsSearch,
          prefixIcon: const Icon(LucideIcons.search, size: 18),
          suffixIcon: q.isEmpty ? null : IconButton(icon: const Icon(LucideIcons.x, size: 18), onPressed: () => setState(widget.controller.clear)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text([l.incLogsCount(shown.length, lines.length), if (logs?['truncated'] == true) l.incLogsTruncated].join(' · '), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.textSecondary)),
      ),
      TCard(radius: TiphysTokens.radiusList, child: shown.isEmpty ? Text(l.incLogsNoMatch) : _mono(lines, shown, q.isEmpty)),
    ]);
  }

  /// The log text; with a focused line (and no filter) it is split around that line so the line can be highlighted.
  Widget _mono(List<String> lines, List<String> shown, bool unfiltered) {
    final f = widget.focus;
    final i = f != null && f.target.kind == 'log' ? f.target.index : null;
    if (!unfiltered || i == null || i < 0 || i >= lines.length) return _Mono(shown.join('\n'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (i > 0) _Mono(lines.sublist(0, i).join('\n')),
      EvidenceHighlight(focus: f, active: true, child: SizedBox(width: double.infinity, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _Mono(lines[i])))),
      if (i < lines.length - 1) _Mono(lines.sublist(i + 1).join('\n')),
    ]);
  }
}

class _KeyValues extends StatelessWidget {
  const _KeyValues(this.rows);
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      radius: TiphysTokens.radiusList,
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(color: t.separator, height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(rows[i].$1, style: tt.bodySmall)),
            Expanded(child: SelectableText(rows[i].$2, style: tt.bodyMedium)),
          ]),
        ],
      ]),
    );
  }
}

class _ContainerView extends StatelessWidget {
  const _ContainerView({required this.detail});
  final IncidentDetail detail;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final i = detail.inspect;
    if (i == null) return TCard(child: Text(l.incNothing));
    DateTime? d(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
    String when(Object? v) => d(v) == null ? '—' : _when(context, d(v)!);
    String yn(Object? v) => v == true ? l.incYes : l.incNo;
    return _KeyValues([
      (l.incInspImage, '${i['image'] ?? ''}'),
      (l.incInspStatus, '${i['status'] ?? ''}'),
      (l.incInspCreated, when(i['created'])),
      (l.incInspStarted, when(i['startedAt'])),
      (l.incInspFinished, when(i['finishedAt'])),
      (l.incInspExit, '${i['exitCode'] ?? '—'}'),
      (l.incInspOom, yn(i['oomKilled'])),
      (l.incInspRestarts, '${i['restartCount'] ?? 0}'),
      (l.incInspPolicy, '${i['restartPolicy'] ?? '—'}'),
      (l.incInspHealth, '${i['health'] ?? '—'}'),
      if (i['project'] != null) (l.incInspCompose, '${i['project']}/${i['service'] ?? ''}'),
    ]);
  }
}

/// Deploys of the incident's stack/service (the agent's history merged with what was collected at the time) and the
/// config changes made through Tiphys in the last 48 hours (key names only, never values).
class _DeploysView extends ConsumerWidget {
  const _DeploysView({required this.detail, this.focus});
  final IncidentDetail detail;

  /// A `deploy:<n>` / `config:<n>` target: that row is highlighted and scrolled into view.
  final EvidenceFocus? focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = detail.summary;
    final hasFilter = s.stack != null || s.service != null;
    final history = hasFilter ? ref.watch(incidentDeploysProvider((detail.host.id, s.stack, s.service))) : const AsyncData(<DeployRecord>[]);
    final deploys = mergeDeploys(history.value ?? const [], detail.deploys);
    final changes = detail.configChanges;
    final ft = focus?.target;
    final focusedDeploy = ft?.kind == 'deploy' && ft!.index! < detail.deploys.length ? detail.deploys[ft.index!].identity : null;
    final focusedConfig = ft?.kind == 'config' ? ft!.index : null;
    String relation(DeployRecord d) {
      final before = s.openedAt.difference(d.at);
      if (before.isNegative) return l.incDeployAfter;
      return before < const Duration(hours: 1) ? l.incDeployMinBefore(before.inMinutes) : l.incDeployBefore;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (history.isLoading && deploys.isEmpty)
        const TCard(child: Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())))
      else if (deploys.isEmpty)
        TCard(child: Text(l.incDeploysEmpty))
      else
        TCard(
          radius: TiphysTokens.radiusList,
          child: Column(children: [
            for (var i = 0; i < deploys.length; i++) ...[
              if (i > 0) Divider(color: t.separator, height: 20),
              EvidenceHighlight(focus: focus, active: deploys[i].identity == focusedDeploy, child: _DeployRow(deploy: deploys[i], relation: relation(deploys[i]), near: deploys[i].changed && s.openedAt.difference(deploys[i].at) < const Duration(hours: 1) && !s.openedAt.isBefore(deploys[i].at))),
            ],
          ]),
        ),
      if (history.hasError)
        Padding(padding: const EdgeInsets.only(top: 8, left: 4), child: Text(agentErrorText(l, history.error!), style: tt.bodySmall)),
      SectionLabel(l.incConfigChanges),
      if (changes.isEmpty)
        TCard(child: Text(l.incConfigChangesEmpty))
      else
        TCard(
          radius: TiphysTokens.radiusList,
          child: Column(children: [
            for (var i = 0; i < changes.length; i++) ...[
              if (i > 0) Divider(color: t.separator, height: 20),
              EvidenceHighlight(focus: focus, active: focusedConfig == i, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(LucideIcons.fileCog, size: 18, color: t.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(changes[i].restored ? l.incConfigRestored(changes[i].file) : l.incConfigSaved(changes[i].file), style: tt.bodyMedium),
                    Text(_when(context, changes[i].at), style: tt.bodySmall),
                    if (changes[i].keys.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(spacing: 6, runSpacing: 4, children: [for (final k in changes[i].keys) _Chip(k, t.textSecondary)]),
                      ),
                  ]),
                ),
              ])),
            ],
          ]),
        ),
    ]);
  }
}

class _DeployRow extends StatelessWidget {
  const _DeployRow({required this.deploy, required this.relation, required this.near});
  final DeployRecord deploy;
  final String relation;

  /// A change within the hour before the incident opened: highlighted.
  final bool near;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final d = deploy;
    final ids = d.changed && d.prevImageId != null ? '${shortImageId(d.imageId)} ← ${shortImageId(d.prevImageId!)}' : shortImageId(d.imageId);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(d.service, style: tt.titleSmall, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        _Chip(d.changed ? l.incDeployChanged : l.incDeploySeen, d.changed ? (near ? t.warning : t.accent) : t.textSecondary),
      ]),
      const SizedBox(height: 2),
      Text(d.imageRef, style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: t.text), maxLines: 2, overflow: TextOverflow.ellipsis),
      Text(ids, style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: t.textSecondary)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${_when(context, d.at)} · $relation', style: tt.bodySmall?.copyWith(color: near ? t.warning : null)),
        if (d.changed) _Chip(d.rollbackTag == null ? l.incDeployNoRollback : l.incDeployRollbackReady, d.rollbackTag == null ? t.textSecondary : t.success),
      ]),
    ]);
  }
}

class _GitView extends StatelessWidget {
  const _GitView({required this.detail, this.focus});
  final IncidentDetail detail;

  /// A `git:<hash>` / `git:status` target: that commit (or the status block) is highlighted and scrolled into view.
  final EvidenceFocus? focus;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final g = detail.git;
    if (g == null) return TCard(child: Text(l.incGitNone));
    final log = [for (final e in (g['log'] as List? ?? const [])) if (e is Map) e];
    final status = [for (final x in (g['status'] as List? ?? const [])) '$x'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.incGitLog),
      if (log.isEmpty)
        TCard(child: Text(l.incGitNoCommits))
      else
        TCard(
          radius: TiphysTokens.radiusList,
          child: Column(children: [
            for (var i = 0; i < log.length; i++) ...[
              if (i > 0) Divider(color: t.separator, height: 16),
              EvidenceHighlight(focus: focus, active: focus?.target.kind == 'git' && focus?.target.name != null && '${log[i]['hash']}' == focus!.target.name, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${log[i]['hash'] ?? ''}'.padRight(7).substring(0, 7).trim(), style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: t.accent)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SelectableText('${log[i]['subject'] ?? ''}', style: tt.bodyMedium),
                    Text(DateTime.tryParse('${log[i]['date']}') == null ? '${log[i]['date'] ?? ''}' : _when(context, DateTime.parse('${log[i]['date']}').toLocal()), style: tt.bodySmall),
                  ]),
                ),
              ])),
            ],
          ]),
        ),
      SectionLabel(l.incGitStatus),
      EvidenceHighlight(
        focus: focus,
        active: focus?.target.kind == 'git' && focus?.target.name == null,
        child: TCard(radius: TiphysTokens.radiusList, child: status.isEmpty ? Text(l.incGitClean) : _Mono(status.join('\n'))),
      ),
    ]);
  }
}

class _EventsView extends StatelessWidget {
  const _EventsView({required this.detail, this.focus});
  final IncidentDetail detail;

  /// An `event:<n>` target: that event is highlighted and scrolled into view.
  final EvidenceFocus? focus;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final events = detail.events;
    if (events.isEmpty) return TCard(child: Text(l.incEventsEmpty));
    final hm = DateFormat.Hm(Localizations.localeOf(context).toLanguageTag());
    return GroupedSection(children: [
      for (final (i, e) in events.indexed.toList().reversed)
        Builder(builder: (_) {
          final key = '${e['key']}';
          final text = noticeText(l, key, Map<String, dynamic>.from((e['params'] as Map?) ?? const {}));
          final at = DateTime.tryParse('${e['at']}')?.toLocal();
          return EvidenceHighlight(
            focus: focus,
            active: focus?.target.kind == 'event' && focus?.target.index == i,
            child: GroupedRow(
              title: text?.$1 ?? key,
              subtitle: [if (at != null) hm.format(at), if (text != null && text.$2.isNotEmpty) text.$2.split('\n').first].join(' · '),
              showChevron: false,
            ),
          );
        }),
    ]);
  }
}

/// Incidents with the same fingerprint in the last 90 days (from the response's own `similar`): what they were, when,
/// the resolution note and the action that worked. Tapping one opens it.
class _SimilarView extends StatelessWidget {
  const _SimilarView({required this.detail});
  final IncidentDetail detail;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final similar = detail.similar;
    if (similar.isEmpty) return TCard(child: Text(l.incSimilarEmpty));
    return GroupedSection(children: [
      for (final s in similar)
        InkWell(
          onTap: () => context.push('/incidents/${s['id']}?host=${detail.host.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(9)),
                child: const Icon(LucideIcons.history, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(incidentTitle(l, s['kind'] is String ? s['kind'] as String : detail.summary.kind, detail.summary.target), style: tt.titleMedium),
                  Text(
                    [
                      if (DateTime.tryParse('${s['openedAt']}') != null) l.incSimilarDate(_when(context, DateTime.parse('${s['openedAt']}').toLocal())),
                      if (s['resolvedAt'] == null) l.incSimilarOpen else l.incStatusResolved,
                    ].join(' · '),
                    style: tt.bodySmall,
                  ),
                  if (s['resolutionNote'] is String && (s['resolutionNote'] as String).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(l.incSimilarResolvedNote(s['resolutionNote'] as String), style: tt.bodyMedium)),
                  if (s['workedAction'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _Chip(l.incSimilarWorked(incidentActionName(l, '${s['workedAction']}')), t.success),
                    ),
                ]),
              ),
              Padding(padding: const EdgeInsets.only(left: 6, top: 4), child: Icon(Icons.chevron_right_rounded, size: 20, color: t.textSecondary)),
            ]),
          ),
        ),
    ]);
  }
}

class _TimelineView extends StatelessWidget {
  const _TimelineView({required this.detail});
  final IncidentDetail detail;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      radius: TiphysTokens.radiusList,
      child: Column(children: [
        for (final e in detail.timeline.reversed)
          Builder(builder: (_) {
            final (text, extra) = incidentTimelineText(l, e);
            final (icon, color) = _timelineVisual(t, e);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(text, style: tt.bodyMedium),
                    if (extra != null && extra.isNotEmpty) SelectableText(extra, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
                    Text([_when(context, e.at), if (e.by != null) incidentActor(l, e.by!)].join(' · '), style: tt.bodySmall),
                  ]),
                ),
              ]),
            );
          }),
      ]),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.title, required this.label, required this.confirm, required this.required});
  final String title;
  final String label;
  final String confirm;
  final bool required;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(controller: _c, autofocus: true, maxLength: 2000, maxLines: 4, minLines: 2, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: widget.label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(onPressed: widget.required && _c.text.trim().isEmpty ? null : () => Navigator.pop(context, _c.text.trim()), child: Text(widget.confirm)),
      ],
    );
  }
}
