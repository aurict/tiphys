// Attacks (PLAN.md §15 S-5): sources that probe the sites behind Cloudflare (error responses, scanner paths), read from
// Cloudflare's analytics, and the Cloudflare settings (tokens are write-only, blocking is optional).
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
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import 'security_widgets.dart';

const offenderListCap = 100;

class SecurityAttacksScreen extends ConsumerWidget {
  const SecurityAttacksScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secAttacksTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      actions: [
        PopupMenuButton<String>(
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onSelected: (_) => context.push(securitySectionRoute('cloudflare', agentId: agentHint)),
          itemBuilder: (_) => [PopupMenuItem(value: 'cloudflare', child: Text(l.secCfTitle))],
        ),
      ],
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _AttacksBlock(agent: a))],
    );
  }
}

class _AttacksBlock extends ConsumerStatefulWidget {
  const _AttacksBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_AttacksBlock> createState() => _AttacksBlockState();
}

class _AttacksBlockState extends ConsumerState<_AttacksBlock> {
  bool _busy = false;
  late final _key = (widget.agent.id, secAttacksPath);

  Future<void> _run() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    var offenders = 0, blocked = 0;
    final ok = await secAct(context, () async {
      final j = await securityCall(ref, widget.agent.id, 'POST', '$secAttacksPath/run', body: <String, dynamic>{}, timeout: const Duration(seconds: 120));
      if (j is Map) {
        offenders = (j['offenders'] as num?)?.toInt() ?? 0;
        blocked = (j['blocked'] as num?)?.toInt() ?? 0;
      }
    });
    if (mounted) {
      setState(() => _busy = false);
      if (ok) toast(context, l.secAttacksChecked(offenders, blocked));
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
        final a = AttacksData(j);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!a.configured)
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SecNote(l.secAttacksNotConfigured, icon: LucideIcons.cloud, warn: true),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: () => context.push(securitySectionRoute('cloudflare', agentId: widget.agent.id)), icon: const Icon(LucideIcons.settings, size: 16), label: Text(l.secCfTitle)),
            ])
          else ...[
            SecNote(l.secAttacksInfo, icon: LucideIcons.shieldAlert),
            const SizedBox(height: 10),
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(a.hasRun && a.lastRunAt != null ? l.secAttacksLastRun(relativeTime(l, a.lastRunAt!, now), a.zones) : l.secAttacksNeverRun, style: tt.titleSmall),
                if (a.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(LucideIcons.circleAlert, size: 16, color: t.danger),
                      const SizedBox(width: 8),
                      Expanded(child: Text(secretRunErrorText(l, a.error!), style: tt.bodyMedium)),
                    ]),
                  ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : _run,
                  icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(l.secAttacksCheckNow),
                ),
              ]),
            ),
            SectionLabel(l.secAttacksOffenders(a.offenders.length)),
            if (a.offenders.isEmpty) TCard(child: Text(l.secAttacksNone)),
            for (final o in a.offenders.take(offenderListCap)) Padding(padding: const EdgeInsets.only(bottom: 10), child: _OffenderCard(offender: o, now: now)),
            if (a.offenders.length > offenderListCap) Padding(padding: const EdgeInsets.all(8), child: Text(l.secMoreRows(a.offenders.length - offenderListCap))),
          ],
        ]);
      },
    );
  }
}

class _OffenderCard extends StatelessWidget {
  const _OffenderCard({required this.offender, required this.now});
  final Offender offender;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final o = offender;
    final blocked = o.blockedUntil != null && o.blockedUntil!.isAfter(now);
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(o.ip, style: tt.titleSmall?.copyWith(fontFamily: monoFamily))),
          if (blocked) SecChip(l.secAttacksBlockedUntil(securityWhen(context, o.blockedUntil!)), t.success, filled: true, icon: LucideIcons.ban),
        ]),
        Text([o.zone, if (o.country.isNotEmpty) o.country].join(' · '), style: tt.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          SecChip(l.secAttacksErrors(o.errors), t.warning),
          SecChip(l.secAttacksScannerHits(o.scannerHits), o.scannerHits > 0 ? t.danger : t.textSecondary),
        ]),
        if (o.paths.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(o.paths.take(10).join('\n'), style: tt.bodySmall?.copyWith(fontFamily: monoFamily, fontSize: 12), maxLines: 10, overflow: TextOverflow.ellipsis),
          ),
        if (o.firstSeenAt != null && o.lastSeenAt != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.secAttacksSeen(securityWhen(context, o.firstSeenAt!), securityWhen(context, o.lastSeenAt!)), style: tt.bodySmall)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Cloudflare settings

class SecurityCloudflareScreen extends ConsumerWidget {
  const SecurityCloudflareScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secCfTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _CloudflareBlock(agent: a))],
    );
  }
}

class _CloudflareBlock extends ConsumerStatefulWidget {
  const _CloudflareBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_CloudflareBlock> createState() => _CloudflareBlockState();
}

class _CloudflareBlockState extends ConsumerState<_CloudflareBlock> {
  bool _busy = false;
  final _read = TextEditingController();
  final _block = TextEditingController();
  final _hours = TextEditingController();
  String? _loadedFor;
  late final _key = (widget.agent.id, secCloudflarePath);

  @override
  void dispose() {
    for (final c in [_read, _block, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(CloudflareConfig c) {
    final sig = '${c.blockHours}';
    if (_loadedFor == sig) return;
    _loadedFor = sig;
    _hours.text = '${c.blockHours}';
  }

  Future<bool> _put(Map<String, dynamic> body) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    final ok = await secAct(context, () => securityCall(ref, widget.agent.id, 'PUT', secCloudflarePath, body: body), ok: l.secSaved);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_key));
    if (mounted) ref.invalidate(securityGetProvider((widget.agent.id, secAttacksPath)));
    return ok;
  }

  /// Saves what was typed: tokens only when entered (omitted = kept), the hours when valid.
  Future<void> _saveTokens(CloudflareConfig c) async {
    final l = AppLocalizations.of(context);
    final body = <String, dynamic>{
      if (_read.text.trim().isNotEmpty) 'readToken': _read.text.trim(),
      if (_block.text.trim().isNotEmpty) 'blockToken': _block.text.trim(),
    };
    if (body.isEmpty) return toast(context, l.secCfNothingToSave);
    if (await _put(body)) {
      _read.clear();
      _block.clear();
    }
  }

  Future<void> _removeToken(String field) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: field == 'readToken' ? l.secCfRemoveReadConfirm : l.secCfRemoveBlockConfirm, confirmLabel: l.secTokenRemove, destructive: true)) return;
    await _put({field: null, if (field == 'blockToken') 'block': false});
  }

  Future<void> _setBlock(CloudflareConfig c, bool on) async {
    final l = AppLocalizations.of(context);
    if (on) {
      if (!c.hasBlockToken && _block.text.trim().isEmpty) return toast(context, l.secErrTokenRequired);
      if (!await confirmDialog(context, message: l.secCfBlockConfirm(c.blockHours), confirmLabel: l.secCfBlockOn, destructive: true)) return;
    }
    // A failed save keeps the typed token.
    final ok = await _put({'block': on, if (on && _block.text.trim().isNotEmpty) 'blockToken': _block.text.trim()});
    if (ok && on && mounted) _block.clear();
  }

  Future<void> _saveHours() async {
    final l = AppLocalizations.of(context);
    final h = int.tryParse(_hours.text.trim());
    if (h == null || h < 1 || h > 720) return toast(context, l.secInvalid);
    await _put({'blockHours': h});
  }

  Future<void> _addZone(CloudflareConfig c) async {
    final l = AppLocalizations.of(context);
    final v = await secAskText(context, title: l.secCfAddZone, label: l.secCfZone, hint: 'example.org', mono: true, validator: (v) => v.isEmpty || v.length > 253 ? l.secInvalid : null);
    if (v == null || c.zones.contains(v)) return;
    await _put({'zones': [...c.zones, v]});
  }

  Future<void> _addAllow(CloudflareConfig c) async {
    final l = AppLocalizations.of(context);
    final v = await secAskText(context, title: l.secCfAddAllow, label: l.secCfAllowIp, hint: '198.51.100.7', mono: true, validator: (v) => validAllowIp(v) ? null : l.secInvalid);
    if (v == null || c.allowIps.contains(v)) return;
    await _put({'allowIps': [...c.allowIps, v]});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return SecAsync<Map<String, dynamic>>(
      value: ref.watch(securityGetProvider(_key)),
      onRetry: () => ref.invalidate(securityGetProvider(_key)),
      data: (j) {
        final c = CloudflareConfig(j);
        _load(c);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          SecNote(l.secCfPermissions, title: l.secCfPermissionsTitle, icon: LucideIcons.keyRound),
          const SizedBox(height: 10),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TField(controller: _read, label: l.secCfReadToken, obscure: true, mono: true, hint: c.hasReadToken ? l.secTokenKeep : null, helper: l.secCfReadTokenHint),
              if (c.hasReadToken) Align(alignment: AlignmentDirectional.centerStart, child: TextButton(onPressed: _busy ? null : () => _removeToken('readToken'), style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.secCfRemoveRead))),
              const SizedBox(height: 10),
              TField(controller: _block, label: l.secCfBlockToken, obscure: true, mono: true, hint: c.hasBlockToken ? l.secTokenKeep : null, helper: l.secCfBlockTokenHint),
              if (c.hasBlockToken) Align(alignment: AlignmentDirectional.centerStart, child: TextButton(onPressed: _busy ? null : () => _removeToken('blockToken'), style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.secCfRemoveBlock))),
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerEnd, child: FilledButton(onPressed: _busy ? null : () => _saveTokens(c), child: Text(l.commonSave))),
            ]),
          ),
          const SizedBox(height: 10),
          GroupedSection(footer: l.secCfBlockWarn, children: [
            SwitchRow(title: l.secCfBlock, value: c.block, icon: LucideIcons.ban, iconBackground: t.danger, onChanged: _busy ? (_) {} : (v) => _setBlock(c, v)),
          ]),
          const SizedBox(height: 10),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TField(controller: _hours, label: l.secCfBlockHours, keyboardType: TextInputType.number, helper: l.secCfBlockHoursHint),
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerEnd, child: FilledButton(onPressed: _busy ? null : _saveHours, child: Text(l.commonSave))),
            ]),
          ),
          SectionLabel(l.secCfZones),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.secCfZonesHint, style: tt.bodySmall),
              const SizedBox(height: 8),
              SecChipList(items: c.zones, addLabel: l.secCfAddZone, enabled: !_busy, removeLabel: (_) => l.secCfRemoveZone, onAdd: () => _addZone(c), onRemove: (z) => _put({'zones': [for (final x in c.zones) if (x != z) x]})),
            ]),
          ),
          SectionLabel(l.secCfAllow),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.secCfAllowHint, style: tt.bodySmall),
              const SizedBox(height: 8),
              SecChipList(items: c.allowIps, addLabel: l.secCfAddAllow, enabled: !_busy, removeLabel: (_) => l.secCfRemoveAllow, onAdd: () => _addAllow(c), onRemove: (z) => _put({'allowIps': [for (final x in c.allowIps) if (x != z) x]})),
            ]),
          ),
        ]);
      },
    );
  }
}
