// Outside view (PLAN.md §15 S-5): what the internet can reach on the machines' public addresses and domains: open
// ports, leaking paths, certificate expiry, HTTPS redirect and security headers. Runs weekly from the monitoring
// server, or on demand.
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
import 'security_data.dart' show securityCall, securityFindingSeverities;
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import 'security_texts.dart';
import 'security_widgets.dart';

const exposureListCap = 100;

class SecurityExposureScreen extends ConsumerWidget {
  const SecurityExposureScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secExposureTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _ExposureBlock(agent: a))],
    );
  }
}

class _ExposureBlock extends ConsumerStatefulWidget {
  const _ExposureBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_ExposureBlock> createState() => _ExposureBlockState();
}

class _ExposureBlockState extends ConsumerState<_ExposureBlock> {
  bool _busy = false;
  late final _key = (widget.agent.id, secExposurePath);

  Future<void> _run() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, widget.agent.id, 'POST', '$secExposurePath/run', body: <String, dynamic>{}), ok: l.secScanStarted);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_key));
  }

  Future<void> _put(Map<String, dynamic> body) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, widget.agent.id, 'PUT', secExposurePath, body: body), ok: l.secSaved);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_key));
  }

  Future<void> _edit(ExposureData d) async {
    final body = await showModalBottomSheet<Map<String, dynamic>>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _TargetsEditor(data: d));
    if (body != null) await _put(body);
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
        final d = ExposureData(j);
        final last = d.last;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          SecNote(l.secExposureInfo, icon: LucideIcons.radar),
          const SizedBox(height: 10),
          GroupedSection(footer: l.secExposureEnabledHint(d.intervalDays), children: [
            SwitchRow(
              title: l.secExposureEnabled,
              value: d.enabled,
              icon: LucideIcons.radar,
              onChanged: _busy ? (_) {} : (v) => _put(exposureBody(enabled: v, targets: d.targets, extraPorts: d.extraPorts, intervalDays: d.intervalDays)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || d.running || d.targets.isEmpty ? null : _run,
                icon: d.running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.play, size: 16),
                label: Text(d.running ? l.secScanRunning : l.secExposureRunNow),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : () => _edit(d), icon: const Icon(LucideIcons.pencil, size: 16), label: Text(l.secExposureEditTargets))),
          ]),
          if (d.targets.isEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: TCard(child: Text(l.secExposureNoTargets))),
          SectionLabel(l.secExposureLastRun),
          if (last == null)
            TCard(child: Text(l.secExposureNeverRun))
          else ...[
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(last.at == null ? '—' : l.secVulnScannedAgo(relativeTime(l, last.at!, now)), style: tt.titleSmall),
                const SizedBox(height: 6),
                for (final tg in last.targets.take(exposureListCap))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(tg.kind == 'ip' ? LucideIcons.network : LucideIcons.globe, size: 16, color: t.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(tg.value, style: tt.bodyMedium?.copyWith(fontFamily: monoFamily, fontSize: 13))),
                      ]),
                      if (tg.error != null) Text(l.secExposureTargetFailed, style: tt.bodySmall?.copyWith(color: t.danger)),
                      if (tg.scannedPorts)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: tg.openPorts.isEmpty
                              ? Text(l.secExposureNoOpenPorts, style: tt.bodySmall)
                              : Wrap(spacing: 6, runSpacing: 6, children: [for (final p in tg.openPorts) SecChip('$p', _expected(d, tg, p) ? t.textSecondary : t.danger)]),
                        ),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            if (last.findings.isEmpty)
              TCard(child: Text(l.secExposureClean))
            else
              for (final s in securityFindingSeverities)
                if (last.findings.any((f) => f.severity == s))
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: _FindingsCard(severity: s, findings: [for (final f in last.findings) if (f.severity == s) f])),
          ],
          if (d.history.length > 1) ...[
            SectionLabel(l.secExposureHistory),
            TCard(
              child: Column(children: [
                for (final (at, n) in d.history)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(at == null ? '—' : securityWhen(context, at))),
                      Text(l.secExposureFindingsCount(n), style: tt.bodyMedium?.copyWith(color: n > 0 ? t.warning : t.success, fontWeight: FontWeight.w700)),
                    ]),
                  ),
              ]),
            ),
          ],
        ]);
      },
    );
  }

  bool _expected(ExposureData d, ExposureRunTarget tg, int port) => d.targets.where((x) => x.id == tg.id).any((x) => x.expectedPorts.contains(port));
}

class _FindingsCard extends StatelessWidget {
  const _FindingsCard({required this.severity, required this.findings});
  final String severity;
  final List<ExposureFindingItem> findings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: SecChip('${securitySeverityName(l, severity)} · ${findings.length}', securitySeverityColor(t, severity), filled: severity == 'critical')),
        for (final f in findings.take(exposureListCap))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              container: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(exposureRuleTitle(l, f.rule, f.target, f.params), style: tt.titleSmall),
                if (exposureRuleFix(l, f.rule) case final fix?)
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

/// Targets, extra ports and interval in one sheet; "Save" returns the PUT body.
class _TargetsEditor extends StatefulWidget {
  const _TargetsEditor({required this.data});
  final ExposureData data;
  @override
  State<_TargetsEditor> createState() => _TargetsEditorState();
}

class _TargetsEditorState extends State<_TargetsEditor> {
  late List<ExposureTarget> _targets = [...widget.data.targets];
  late final _extra = TextEditingController(text: widget.data.extraPorts.join(', '));
  late final _days = TextEditingController(text: '${widget.data.intervalDays}');
  String? _error;

  @override
  void dispose() {
    _extra.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final r = await showDialog<ExposureTarget>(context: context, builder: (_) => _TargetDialog(taken: _targets.map((x) => x.id).toSet(), values: _targets.map((x) => x.value).toSet()));
    if (r != null) setState(() => _targets = [..._targets, r]);
  }

  void _save() {
    final l = AppLocalizations.of(context);
    final extra = parsePortList(_extra.text);
    final days = int.tryParse(_days.text.trim());
    if (extra == null || extra.length > 100 || days == null || days < 1 || days > 30 || _targets.length > 30) {
      setState(() => _error = l.secInvalid);
      return;
    }
    Navigator.pop(context, exposureBody(enabled: widget.data.enabled, targets: _targets, extraPorts: extra, intervalDays: days));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 8, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(header: true, child: Text(l.secExposureEditTargets, style: tt.titleLarge)),
          const SizedBox(height: 6),
          Text(l.secExposureTargetsHint, style: tt.bodySmall),
          const SizedBox(height: 10),
          if (_targets.isEmpty) TCard(child: Text(l.secExposureNoTargets)),
          for (final tg in _targets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TCard(
                child: Row(children: [
                  Icon(tg.kind == 'ip' ? LucideIcons.network : LucideIcons.globe, size: 18, color: t.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tg.value, style: tt.titleSmall?.copyWith(fontFamily: monoFamily, fontSize: 13)),
                      if (tg.kind == 'ip') Text(tg.expectedPorts.isEmpty ? l.secExposureExpectedNone : l.secExposureExpected(tg.expectedPorts.join(', ')), style: tt.bodySmall),
                    ]),
                  ),
                  IconButton(tooltip: l.secExposureRemoveTarget(tg.value), icon: const Icon(LucideIcons.trash2, size: 18), onPressed: () => setState(() => _targets = [..._targets]..remove(tg))),
                ]),
              ),
            ),
          OutlinedButton.icon(onPressed: _targets.length >= 30 ? null : _add, icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secExposureAddTarget)),
          const SizedBox(height: 14),
          TField(controller: _extra, label: l.secExposureExtraPorts, mono: true, hint: '8080, 9000', helper: l.secExposureExtraPortsHint),
          const SizedBox(height: 10),
          TField(controller: _days, label: l.secExposureInterval, keyboardType: TextInputType.number, helper: l.secExposureIntervalHint),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: t.danger))),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
            const SizedBox(width: 8),
            FilledButton(onPressed: _save, child: Text(l.commonSave)),
          ]),
        ]),
      ),
    );
  }
}

class _TargetDialog extends StatefulWidget {
  const _TargetDialog({required this.taken, required this.values});
  final Set<String> taken, values;
  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  final _form = GlobalKey<FormState>();
  final _value = TextEditingController();
  final _expected = TextEditingController();
  String _kind = 'domain';

  @override
  void dispose() {
    _value.dispose();
    _expected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secExposureAddTarget),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: 'domain', label: Text(l.secExposureKindDomain)), ButtonSegment(value: 'ip', label: Text(l.secExposureKindIp))],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.single),
            ),
            const SizedBox(height: 12),
            TField(
              controller: _value,
              label: _kind == 'ip' ? l.secExposureIpLabel : l.secExposureDomainLabel,
              mono: true,
              hint: _kind == 'ip' ? '203.0.113.10' : 'www.example.org',
              keyboardType: TextInputType.url,
              validator: (v) => !validExposureValue(_kind, v.trim()) ? l.secInvalid : (widget.values.contains(v.trim()) ? l.secExposureDuplicate : null),
            ),
            if (_kind == 'ip') ...[
              const SizedBox(height: 10),
              TField(
                controller: _expected,
                label: l.secExposureExpectedLabel,
                mono: true,
                hint: '22, 443',
                helper: l.secExposureExpectedHint,
                validator: (v) {
                  final p = parsePortList(v);
                  return p == null || p.length > 50 ? l.secInvalid : null;
                },
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            final v = _value.text.trim();
            Navigator.pop(context, ExposureTarget(id: exposureTargetId(_kind, v, widget.taken), kind: _kind, value: v, expectedPorts: _kind == 'ip' ? parsePortList(_expected.text) ?? const [] : const []));
          },
          child: Text(l.commonAdd),
        ),
      ],
    );
  }
}
