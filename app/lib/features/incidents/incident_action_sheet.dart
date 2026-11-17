// Incident action: preview → confirmation → execution (PLAN.md §13.1). The agent builds the candidates; this sheet only
// shows the commands it will run (plain argv text, no shell), a countdown for the one-time preview token, and runs the
// action after an explicit confirmation.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import '../system/agent_providers.dart';
import 'incident_texts.dart';
import 'incidents_data.dart';

/// Opens the sheet; true when the action was run (the caller refreshes the incident).
Future<bool> showIncidentActionSheet(BuildContext context, {required Host host, required String incidentId, required ActionCandidate candidate, String? runningId}) async {
  // Once run, closing the sheet any way (barrier, back) still reports it, so the incident is refreshed.
  var ran = false;
  final r = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    // No drag-to-dismiss: a drag would close the sheet while the action runs (PopScope only stops back and barrier).
    enableDrag: false,
    builder: (_) => IncidentActionSheet(host: host, incidentId: incidentId, candidate: candidate, runningId: runningId, onRan: () => ran = true),
  );
  return r ?? ran;
}

class IncidentActionSheet extends ConsumerStatefulWidget {
  const IncidentActionSheet({super.key, required this.host, required this.incidentId, required this.candidate, this.runningId, this.onRan});
  final Host host;

  /// Called once the action ran (whatever its outcome).
  final VoidCallback? onRan;
  final String incidentId;
  final ActionCandidate candidate;

  /// Candidate running right now on the agent (another action blocks this one).
  final String? runningId;

  @override
  ConsumerState<IncidentActionSheet> createState() => _IncidentActionSheetState();
}

class _IncidentActionSheetState extends ConsumerState<IncidentActionSheet> {
  ActionPreview? _preview;
  Object? _error;
  bool _loading = true;

  /// disk.cleanup: the options chosen (null until the first preview names the default selection) and whether a new
  /// preview for a changed selection is on its way (the old one stays on screen meanwhile, but can't be run).
  Set<String>? _selected;
  bool _reloading = false;
  bool _running = false;

  /// The confirmation dialog is open (a second tap must not open another).
  bool _confirming = false;
  ActionResult? _result;
  Timer? _tick;
  late DateTime _now = ref.read(clockProvider)();

  String get _path => '/v1/incidents/${widget.incidentId}/actions/${widget.candidate.id}';

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
    await _fetch();
  }

  /// A preview of the current selection: disk.cleanup sends its options (the token is bound to the commands).
  Future<void> _fetch() async {
    final sel = _selected;
    try {
      final j = await agentCall(ref, widget.host.id, 'POST', '$_path/preview', sel == null ? null : {'options': sel.toList()});
      if (!mounted) return;
      final received = ref.read(clockProvider)();
      final p = ActionPreview(Map<String, dynamic>.from(j as Map), received);
      setState(() {
        _preview = p;
        _selected ??= p.cleanup == null ? null : {...p.cleanup!.selected};
        _now = received;
        _loading = false;
        _reloading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
          _reloading = false;
          _preview = null;
        });
      }
    }
  }

  void _toggle(String option, bool on) {
    final sel = {...?_selected};
    on ? sel.add(option) : sel.remove(option);
    setState(() {
      _selected = sel;
      _error = null;
      _reloading = sel.isNotEmpty;
    });
    if (sel.isNotEmpty) _fetch();
  }

  Future<void> _execute() async {
    final l = AppLocalizations.of(context);
    final p = _preview;
    if (p == null || _running || _confirming) return;
    final label = incidentActionLabel(l, widget.candidate.kind, widget.candidate.target);
    _confirming = true;
    final bool ok;
    try {
      ok = await confirmDialog(context, message: l.incExecuteConfirm(label, widget.host.name), confirmLabel: l.incExecute, destructive: true);
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
      final c = await ref.read(agentClientFactoryProvider)(widget.host);
      final dynamic j;
      try {
        j = await c.request('POST', '$_path/execute',
            body: {'previewToken': p.token, 'confirm': true, if (p.cleanup != null) 'options': _selected!.toList()}, timeout: const Duration(seconds: 90));
      } finally {
        c.close();
      }
      final res = ActionResult(Map<String, dynamic>.from(j as Map));
      widget.onRan?.call();
      if (mounted) setState(() => _result = res);
    } catch (e) {
      // The token is spent either way; a new preview is needed to try again.
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
    final c = widget.candidate;
    final label = incidentActionLabel(l, c.kind, c.target);
    final p = _preview;
    final expired = p != null && p.expired(_now);
    final blocked = widget.runningId != null && widget.runningId != c.id;
    final noOptions = p?.cleanup != null && (_selected?.isEmpty ?? true);
    final canRun = p != null && !expired && !_running && _result == null && !blocked && !_reloading && !noOptions;
    return PopScope(
      canPop: !_running,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(l.incPreviewTitle, style: tt.bodySmall),
            const SizedBox(height: 4),
            Text(label, style: tt.titleLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _Pill(c.risk == 'medium' ? l.incRiskMedium : l.incRiskLow, c.risk == 'medium' ? t.warning : t.success),
              if (p != null && _result == null) _Countdown(preview: p, now: _now),
            ]),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (p != null) ...[
              if (p.rollback != null) _RollbackCard(details: p.rollback!),
              for (final w in p.warnings) _Note(previewWarningText(l, w), t.warning),
              if (p.cleanup != null) _CleanupCard(details: p.cleanup!, selected: _selected ?? const {}, busy: _reloading || _running || _result != null, onToggle: _toggle),
              if (noOptions) _Note(l.incCleanPickOne, t.warning),
              SectionLabel(l.incPreviewSteps),
              TCard(
                radius: TiphysTokens.radiusList,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (var i = 0; i < p.steps.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    if (p.steps[i].cwd != null) Text(l.incPreviewCwd(p.steps[i].cwd!), style: tt.bodySmall?.copyWith(fontFamily: monoFamily, fontSize: 11.5)),
                    SelectableText('\$ ${formatArgv(p.steps[i].argv)}', style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, height: 1.4, color: t.text)),
                  ],
                ]),
              ),
            ],
            if (blocked) _Note(l.incActionBusy, t.warning),
            if (_running)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), Text(l.incRunning)]),
              ),
            if (_result != null) _ResultView(result: _result!),
            if (_error != null) _Note(agentErrorText(l, _error!), t.danger),
            if (expired && _result == null && _error == null) _Note(l.incPreviewExpired, t.danger),
            const SizedBox(height: 16),
            Row(children: [
              TextButton(onPressed: _running ? null : () => Navigator.pop(context, _result != null), child: Text(_result != null ? l.commonClose : l.commonCancel)),
              const Spacer(),
              if (_result == null && (_error != null || expired))
                OutlinedButton.icon(onPressed: _running ? null : _load, icon: const Icon(LucideIcons.refreshCw, size: 16), label: Text(l.incPreviewRefresh))
              else if (_result == null)
                FilledButton(onPressed: canRun ? _execute : null, child: Text(l.incExecute)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

/// "Valid for 1:58", turning red when it ran out.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.preview, required this.now});
  final ActionPreview preview;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final left = preview.remaining(now);
    final low = left < const Duration(seconds: 20);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(LucideIcons.timer, size: 15, color: low ? t.danger : t.textSecondary),
      const SizedBox(width: 4),
      Text(l.incPreviewExpiresIn(formatCountdown(left)), style: TextStyle(fontSize: 12.5, color: low ? t.danger : t.textSecondary)),
    ]);
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(LucideIcons.circleAlert, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ]),
      );
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result});
  final ActionResult result;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(result.ok ? LucideIcons.circleCheck : LucideIcons.circleX, size: 18, color: result.ok ? t.success : t.danger),
          const SizedBox(width: 8),
          Expanded(child: Text(result.ok ? l.incResultOk : l.incResultFailed(result.code), style: Theme.of(context).textTheme.bodyMedium)),
        ]),
        if (result.stderr != null && result.stderr!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TCard(
              radius: TiphysTokens.radiusList,
              child: SelectableText(result.stderr!, style: TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.35, color: t.text)),
            ),
          ),
      ]),
    );
  }
}

String _date(BuildContext context, DateTime? d) =>
    d == null ? '—' : DateFormat('d MMM yyyy HH:mm', Localizations.localeOf(context).toLanguageTag()).format(d);

/// compose.rollback: the image running now and the previous one that will run instead.
class _RollbackCard extends StatelessWidget {
  const _RollbackCard({required this.details});
  final RollbackDetails details;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    Widget side(String label, ImageRef i, Color color, IconData icon) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: tt.bodySmall),
              Text(i.shortId, style: TextStyle(fontFamily: monoFamily, fontSize: 13.5, color: t.text)),
              Text(l.incRollbackBuilt(_date(context, i.created)), style: tt.bodySmall),
            ]),
          ),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.incRollbackTitle),
      TCard(
        radius: TiphysTokens.radiusList,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(details.imageRef, style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: t.text)),
          const SizedBox(height: 10),
          side(l.incRollbackCurrent, details.current, t.danger, LucideIcons.circleDot),
          Padding(padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4), child: Icon(LucideIcons.arrowDown, size: 16, color: t.textSecondary)),
          side(l.incRollbackPrevious, details.previous, t.success, LucideIcons.history),
        ]),
      ),
    ]);
  }
}

/// disk.cleanup: one switch per option with its estimate; options the agent can't run are disabled with the reason.
class _CleanupCard extends StatelessWidget {
  const _CleanupCard({required this.details, required this.selected, required this.busy, required this.onToggle});
  final CleanupDetails details;
  final Set<String> selected;
  final bool busy;
  final void Function(String option, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final total = estimateTotal(details.options, selected);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionLabel(l.incCleanTitle),
      TCard(
        radius: TiphysTokens.radiusList,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          for (final o in details.options)
            SwitchListTile(
              value: o.available && selected.contains(o.option),
              onChanged: o.available && !busy ? (v) => onToggle(o.option, v) : null,
              title: Text(cleanupOptionName(l, o.option)),
              subtitle: Text(
                o.available
                    ? [
                        o.reclaimableBytes == null ? l.incCleanNoEstimate : l.incCleanReclaim(formatSize(o.reclaimableBytes!, locale)),
                        if (o.usageBytes != null) l.incCleanUsage(formatSize(o.usageBytes!, locale)),
                        cleanupOptionHint(l, o.option),
                      ].where((x) => x.isNotEmpty).join(' · ')
                    : cleanupReasonText(l, o.reason),
                style: tt.bodySmall?.copyWith(color: o.available ? null : t.warning),
              ),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          if (total != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(children: [
                Icon(LucideIcons.hardDrive, size: 16, color: t.accent),
                const SizedBox(width: 8),
                Expanded(child: Text(l.incCleanTotal(formatSize(total, locale)), style: tt.titleSmall)),
              ]),
            ),
        ]),
      ),
    ]);
  }
}
