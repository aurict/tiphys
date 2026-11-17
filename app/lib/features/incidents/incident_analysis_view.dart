// The AI analysis part of the "Likely cause" card (PLAN.md §13.1, I-3): state (queued/running with a spinner, done,
// failed, unavailable, off), hypotheses with a confidence bar and evidence chips, suggested actions (open the normal
// preview flow), open questions, and the "investigate with Claude on the PC" button. Every text that comes from the
// model is shown as plain `Text`: no markdown, no links.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../claude/claude_screen.dart' show relativeTime;
import 'incident_analysis.dart';
import 'incident_texts.dart';
import 'incidents_data.dart';

class AnalysisSection extends StatelessWidget {
  const AnalysisSection({
    super.key,
    required this.detail,
    required this.now,
    required this.off,
    required this.busy,
    required this.index,
    required this.actions,
    required this.onAnalyze,
    required this.onEvidence,
    required this.onAction,
    required this.onInvestigate,
  });
  final IncidentDetail detail;
  final DateTime now;

  /// The host's analysis mode is `off` (or the agent just answered 409 analysisOff): no button, only the hint.
  final bool off;
  final bool busy;
  final EvidenceIndex index;

  /// Candidates the agent offers right now (null for a resolved incident or while loading).
  final IncidentActions? actions;
  final VoidCallback onAnalyze;
  final ValueChanged<EvidenceTarget> onEvidence;
  final void Function(ActionCandidate) onAction;
  final VoidCallback onInvestigate;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final a = detail.analysis;
    final analyze = FilledButton.tonalIcon(onPressed: busy ? null : onAnalyze, icon: const Icon(LucideIcons.sparkles, size: 16), label: Text(l.incAnalyze));
    final retry = OutlinedButton.icon(onPressed: busy || off ? null : onAnalyze, icon: const Icon(LucideIcons.rotateCw, size: 16), label: Text(l.incAiRetry));
    final body = <Widget>[];
    if (off) {
      body.add(_Notice(icon: LucideIcons.powerOff, color: t.textSecondary, title: l.incAiOffTitle, text: l.incAiOffHint));
    } else if (a == null) {
      body.add(Align(alignment: Alignment.centerLeft, child: analyze));
    } else if (a.active) {
      body.add(Row(children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Expanded(child: Text(a.status == 'queued' ? l.incAiQueued : l.incAiRunning, style: tt.bodyMedium)),
      ]));
      body.add(Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.incAiRunningHint, style: tt.bodySmall)));
    } else if (a.failed) {
      body.add(_Notice(icon: LucideIcons.circleX, color: t.danger, title: l.incAiFailed, text: analysisFailedText(l, a.errorCode)));
      body.add(Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft, child: retry)));
    } else if (a.unavailable) {
      body.add(_Notice(icon: LucideIcons.cloudOff, color: t.warning, title: l.incAiUnavailable, text: '${analysisReasonText(l, a.reason)} ${l.incAiNoWake} ${l.incAiRulesStay}'));
      body.add(Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft, child: retry)));
    } else if (a.done) {
      body.addAll(_done(context, a.result!, a));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Divider(color: t.separator, height: 24),
      Row(children: [
        Icon(LucideIcons.sparkles, size: 18, color: t.accent),
        const SizedBox(width: 8),
        Expanded(child: Text(l.incAiTitle, style: tt.titleMedium)),
      ]),
      const SizedBox(height: 8),
      ...body,
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: onInvestigate, icon: const Icon(LucideIcons.terminal, size: 16), label: Text(l.incInvestigate))),
    ]);
  }

  List<Widget> _done(BuildContext context, AnalysisResult r, IncidentAnalysis a) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return [
      if (r.summary.isNotEmpty) SelectableText(r.summary, style: tt.bodyMedium),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text([if (a.finishedAt != null) l.incAiDoneAt(relativeTime(l, a.finishedAt!, now)), l.incAiDisclaimer].join(' · '), style: tt.bodySmall),
      ),
      const SizedBox(height: 10),
      Text(l.incAiHypotheses, style: tt.titleSmall),
      const SizedBox(height: 6),
      if (r.hypotheses.isEmpty) Text(l.incAiNoHypotheses, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
      for (final h in r.hypotheses) _HypothesisTile(h: h, index: index, onEvidence: onEvidence),
      if (r.suggestedActions.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(l.incAiActions, style: tt.titleSmall),
        const SizedBox(height: 6),
        for (final s in r.suggestedActions) _ActionTile(suggestion: s, candidate: actions?.actions.where((c) => c.id == s.candidateId).firstOrNull, running: actions?.running, onTap: onAction),
      ],
      if (r.questions.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(l.incAiQuestions, style: tt.titleSmall),
        const SizedBox(height: 4),
        for (final q in r.questions)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2, right: 8), child: Icon(LucideIcons.circleQuestionMark, size: 16, color: t.textSecondary)),
              Expanded(child: SelectableText(q, style: tt.bodyMedium)),
            ]),
          ),
      ],
      const SizedBox(height: 6),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: busy ? null : onAnalyze, icon: const Icon(LucideIcons.rotateCw, size: 16), label: Text(l.incAnalyze))),
    ];
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.color, required this.title, required this.text});
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: color)),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: tt.titleSmall),
          const SizedBox(height: 2),
          Text(text, style: tt.bodyMedium),
        ]),
      ),
    ]);
  }
}

class _HypothesisTile extends StatelessWidget {
  const _HypothesisTile({required this.h, required this.index, required this.onEvidence});
  final Hypothesis h;
  final EvidenceIndex index;
  final ValueChanged<EvidenceTarget> onEvidence;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final percent = (h.confidence * 100).round();
    final color = h.unsupported ? t.textSecondary : (h.confidence >= 0.7 ? t.success : (h.confidence >= 0.4 ? t.warning : t.textSecondary));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: SelectableText(h.cause, style: tt.bodyMedium?.copyWith(color: h.unsupported ? t.textSecondary : null))),
          if (h.unsupported)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: l.incAiUnsupportedHint,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: t.warning.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
                  child: Text(l.incAiUnsupported, style: TextStyle(color: t.warning, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Semantics(
              label: l.incAiConfidence(percent),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(value: h.confidence, minHeight: 6, color: color, backgroundColor: t.separator),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(l.incAiConfidence(percent), style: tt.bodySmall),
        ]),
        if (h.evidenceRefs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final ref in h.evidenceRefs)
                Builder(builder: (_) {
                  final target = resolveEvidenceRef(ref, index);
                  return ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(evidenceRefLabel(l, ref), style: const TextStyle(fontSize: 12)),
                    tooltip: target == null ? l.incEvMissing : null,
                    onPressed: target == null ? null : () => onEvidence(target),
                  );
                }),
            ]),
          ),
      ]),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.suggestion, required this.candidate, required this.running, required this.onTap});
  final SuggestedAction suggestion;
  final ActionCandidate? candidate;
  final String? running;
  final void Function(ActionCandidate) onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final c = candidate;
    final enabled = c != null && running == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => onTap(c) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(LucideIcons.wrench, size: 18, color: enabled ? t.accent : t.textSecondary)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c == null ? incidentActionName(l, suggestion.kind) : incidentActionLabel(l, c.kind, c.target), style: tt.titleSmall),
                  if (suggestion.why.isNotEmpty) Text(suggestion.why, style: tt.bodyMedium),
                  if (c == null) Text(l.incAiActionGone, style: tt.bodySmall),
                ]),
              ),
              if (enabled) Padding(padding: const EdgeInsets.only(left: 6, top: 2), child: Icon(Icons.chevron_right_rounded, size: 20, color: t.textSecondary)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Wraps one row of an evidence tab: when it is the target of [focus] it is highlighted and scrolled into view (once
/// per tap, whatever the tab's own scroll position).
class EvidenceHighlight extends StatefulWidget {
  const EvidenceHighlight({super.key, required this.focus, required this.active, required this.child});
  final EvidenceFocus? focus;
  final bool active;
  final Widget child;

  @override
  State<EvidenceHighlight> createState() => _EvidenceHighlightState();
}

class _EvidenceHighlightState extends State<EvidenceHighlight> {
  int _scrolled = -1;

  void _maybeScroll() {
    final f = widget.focus;
    if (!widget.active || f == null || f.nonce == _scrolled) return;
    _scrolled = f.nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context, duration: Duration.zero, alignment: 0.15);
    });
  }

  @override
  Widget build(BuildContext context) {
    _maybeScroll();
    if (!widget.active) return widget.child;
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(color: t.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8), border: Border.all(color: t.accent.withValues(alpha: 0.5))),
      child: widget.child,
    );
  }
}
