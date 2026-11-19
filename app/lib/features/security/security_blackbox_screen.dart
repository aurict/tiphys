// Black box (PLAN.md §15 S-4): an append-only, hash-chained record of what was done through the agents. The monitoring
// server keeps the chain ("local"), other agents push their records to it ("push"). Every night the chain's head goes
// to the owner's Telegram as an outside anchor; "Verify the chain" recomputes it and compares the anchors.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import 'security_data.dart' show securityCall;
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import '../system/agent_providers.dart';
import 'security_widgets.dart';

/// Verifying reads the whole chain: allow the agent a while.
const blackboxVerifyTimeout = Duration(minutes: 3);

class SecurityBlackboxScreen extends ConsumerWidget {
  const SecurityBlackboxScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secBbTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _BlackboxBlock(agent: a))],
    );
  }
}

class _BlackboxBlock extends ConsumerStatefulWidget {
  const _BlackboxBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_BlackboxBlock> createState() => _BlackboxBlockState();
}

class _BlackboxBlockState extends ConsumerState<_BlackboxBlock> {
  bool _busy = false;
  BlackboxVerify? _verify;
  Object? _verifyError;
  List<BlackboxAnchor>? _anchors;
  String _mode = 'off';
  String? _modeFor;
  bool _restartRequired = false;
  final _url = TextEditingController();
  final _token = TextEditingController();
  late final _key = (widget.agent.id, secBlackboxStatusPath);

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  String get _id => widget.agent.id;

  void _load(BlackboxStatus s) {
    final sig = '${s.mode}|${s.url}';
    if (_modeFor == sig) return;
    _modeFor = sig;
    _mode = s.mode;
    _url.text = s.url ?? '';
  }

  Future<void> _doVerify() async {
    setState(() {
      _busy = true;
      _verifyError = null;
    });
    try {
      final j = await securityCall(ref, _id, 'GET', '/v1/blackbox/verify', timeout: blackboxVerifyTimeout);
      if (mounted) setState(() => _verify = BlackboxVerify(j is Map ? Map<String, dynamic>.from(j) : {}));
    } catch (e) {
      if (mounted) setState(() => _verifyError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _anchor() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () async {
      final j = await securityCall(ref, _id, 'POST', '/v1/blackbox/anchor', body: <String, dynamic>{});
      if (j is Map && mounted) setState(() => _anchors = [for (final e in (j['anchors'] as List? ?? const [])) if (e is Map) BlackboxAnchor(Map<String, dynamic>.from(e))]);
    }, ok: l.secBbAnchored);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveSettings(BlackboxStatus s) async {
    final l = AppLocalizations.of(context);
    final url = _url.text.trim(), token = _token.text.trim();
    if (_mode == 'push') {
      if (!url.startsWith('https://') || Uri.tryParse(url)?.host.isNotEmpty != true) return toast(context, l.secInvalid);
      if (token.isNotEmpty && !validServiceToken(token)) return toast(context, l.secInvalid);
      // The agent keeps a stored token only while the URL stays the same.
      if (token.isEmpty && !(s.mode == 'push' && s.url == url)) return toast(context, l.secErrTokenRequired);
    }
    final body = <String, dynamic>{'mode': _mode, if (_mode == 'push') 'url': url, if (_mode == 'push' && token.isNotEmpty) 'token': token};
    setState(() => _busy = true);
    final ok = await secAct(context, () async {
      final j = await securityCall(ref, _id, 'PUT', '/v1/blackbox/settings', body: body);
      if (j is Map && mounted) setState(() => _restartRequired = j['restartRequired'] == true);
    }, ok: l.secSaved);
    if (mounted) {
      setState(() => _busy = false);
      // A failed save keeps what was typed.
      if (ok) _token.clear();
    }
    if (mounted) ref.invalidate(securityGetProvider(_key));
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
        final s = BlackboxStatus(j);
        _load(s);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          SecNote(l.secBbInfo, icon: LucideIcons.archive),
          const SizedBox(height: 10),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(l.secBbModeNow(blackboxModeName(l, s.mode)), style: tt.titleSmall)),
                SecChip(blackboxModeName(l, s.mode), s.mode == 'off' ? t.textSecondary : t.success),
              ]),
              if (s.mode == 'local' && s.count != null) ...[
                const SizedBox(height: 6),
                Text(l.secBbHead(s.count!, (s.hash ?? '').length > 16 ? s.hash!.substring(0, 16) : (s.hash ?? '')), style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
              ],
              if (s.mode == 'push') ...[
                const SizedBox(height: 6),
                if (s.url != null) Text(s.url!, style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
                Text(l.secBbPending(s.pending ?? 0), style: tt.bodyMedium),
                Text(s.lastSentAt == null ? l.secBbNeverSent : l.secBbLastSent(relativeTime(l, s.lastSentAt!, now)), style: tt.bodySmall),
                if (s.lastError != null && s.lastError!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(LucideIcons.circleAlert, size: 16, color: t.danger),
                      const SizedBox(width: 8),
                      Expanded(child: Text(secretRunErrorText(l, s.lastError!), style: tt.bodyMedium)),
                    ]),
                  ),
              ],
              if (s.mode == 'off') Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.secBbOffHint, style: tt.bodySmall)),
            ]),
          ),
          if (s.mode == 'local') ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: FilledButton.icon(onPressed: _busy ? null : _doVerify, icon: const Icon(LucideIcons.shieldCheck, size: 16), label: Text(l.secBbVerify))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _anchor, icon: const Icon(LucideIcons.anchor, size: 16), label: Text(l.secBbAnchor, textAlign: TextAlign.center))),
            ]),
            if (_verifyError != null) Padding(padding: const EdgeInsets.only(top: 10), child: SecNote(agentErrorText(l, _verifyError!), warn: true)),
            if (_verify != null) Padding(padding: const EdgeInsets.only(top: 10), child: _VerifyCard(verify: _verify!, anchors: _anchors)),
            SectionLabel(l.secBbRecent),
            _Recent(agentId: _id),
          ],
          SectionLabel(l.secBbSettings),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'off', label: Text(l.secBbModeOff)),
                  ButtonSegment(value: 'local', label: Text(l.secBbModeLocal)),
                  ButtonSegment(value: 'push', label: Text(l.secBbModePush)),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.single),
              ),
              const SizedBox(height: 8),
              Text(switch (_mode) { 'local' => l.secBbLocalHint, 'push' => l.secBbPushHint, _ => l.secBbOffHint }, style: tt.bodySmall),
              if (_mode == 'push') ...[
                const SizedBox(height: 10),
                TField(controller: _url, label: l.secBbUrl, mono: true, keyboardType: TextInputType.url, hint: 'https://atlas.example.org:6767'),
                const SizedBox(height: 10),
                TField(controller: _token, label: l.secBbToken, obscure: true, mono: true, hint: s.mode == 'push' && s.url != null ? l.secTokenKeep : null, helper: l.secBbTokenHint),
              ],
              const SizedBox(height: 10),
              Align(alignment: AlignmentDirectional.centerEnd, child: FilledButton(onPressed: _busy ? null : () => _saveSettings(s), child: Text(l.commonSave))),
            ]),
          ),
          if (_restartRequired || _mode != s.mode) Padding(padding: const EdgeInsets.only(top: 10), child: SecNote(l.secBbRestartRequired, warn: true)),
        ]);
      },
    );
  }
}

class _VerifyCard extends StatelessWidget {
  const _VerifyCard({required this.verify, this.anchors});
  final BlackboxVerify verify;

  /// Anchors after "send today's anchor" (newer than the ones in the verification).
  final List<BlackboxAnchor>? anchors;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final v = verify;
    final good = v.trustworthy;
    final list = anchors ?? v.anchors;
    return TCard(
      borderColor: good ? t.success : t.danger,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(good ? LucideIcons.circleCheck : LucideIcons.octagonAlert, color: good ? t.success : t.danger),
          const SizedBox(width: 10),
          Expanded(child: Semantics(header: true, child: Text(!v.ok ? l.secBbBroken : (good ? l.secBbVerifiedOk : l.secBbAnchorMismatchTitle), style: tt.titleMedium?.copyWith(color: good ? t.success : t.danger)))),
        ]),
        const SizedBox(height: 8),
        if (v.ok) Text(l.secBbVerifiedCount(v.count), style: tt.bodyMedium),
        if (!v.ok) ...[
          Text(l.secBbBrokenAt(v.brokenAt ?? 0), style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text(blackboxReasonText(l, v.reason), style: tt.bodyMedium),
          const SizedBox(height: 6),
          Text(l.secBbBrokenAdvice, style: tt.bodySmall),
        ],
        if (v.anchorMismatch.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l.secBbAnchorMismatch(v.anchorMismatch.join(', ')), style: tt.bodyMedium?.copyWith(color: t.danger, fontWeight: FontWeight.w700)),
        ],
        const SizedBox(height: 10),
        Text(l.secBbAnchors(list.length), style: tt.titleSmall),
        if (list.isEmpty) Text(l.secBbAnchorsNone, style: tt.bodySmall),
        for (final a in list.take(30))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(a.telegram ? LucideIcons.send : LucideIcons.hardDrive, size: 14, color: v.anchorMismatch.contains(a.date) ? t.danger : t.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text('${a.date} · ${l.secBbRecords(a.count)} · ${a.hash.length > 12 ? a.hash.substring(0, 12) : a.hash}', style: tt.bodySmall?.copyWith(fontFamily: monoFamily))),
              Text(a.telegram ? l.secBbAnchorTelegram : l.secBbAnchorLocalOnly, style: tt.bodySmall),
            ]),
          ),
      ]),
    );
  }
}

class _Recent extends ConsumerWidget {
  const _Recent({required this.agentId});
  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final key = (agentId, secBlackboxRecentPath);
    return SecAsync<Map<String, dynamic>>(
      value: ref.watch(securityGetProvider(key)),
      onRetry: () => ref.invalidate(securityGetProvider(key)),
      error: (e) => e is AgentError && e.code == 'agent.blackbox.notLocal' ? TCard(child: Text(l.secErrBlackboxNotLocal)) : null,
      data: (j) {
        final records = [for (final e in (j['records'] as List? ?? const [])) if (e is Map) BlackboxRecord(Map<String, dynamic>.from(e))];
        if (records.isEmpty) return TCard(child: Text(l.secBbRecentEmpty));
        final shown = records.take(100).toList(); // the agent sends the newest first
        return TCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(children: [
            for (final r in shown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Semantics(
                  container: true,
                  label: '${r.seq}, ${r.at == null ? '' : securityWhen(context, r.at!)}, ${r.source}, ${blackboxKindName(l, r.kind)}, ${r.summary}',
                  child: ExcludeSemantics(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 44, child: Text('#${r.seq}', style: tt.bodySmall?.copyWith(fontFamily: monoFamily))),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.summary, style: tt.bodyMedium?.copyWith(fontFamily: monoFamily, fontSize: 12.5), maxLines: 2, overflow: TextOverflow.ellipsis),
                          Text([if (r.at != null) securityWhen(context, r.at!), r.source, blackboxKindName(l, r.kind)].join(' · '), style: tt.bodySmall?.copyWith(color: t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
}
