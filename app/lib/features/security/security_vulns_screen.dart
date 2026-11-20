// Vulnerabilities (PLAN.md §15 S-2): the images that run on the audited machines with the critical / high findings of
// the Trivy scan, and one image with its findings table. Everything the scanner says is shown as plain text.
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
import '../incidents/host_picker.dart';
import '../system/agent_providers.dart';
import 'security_data.dart' show securityCall;
import 'security_fix.dart';
import 'security_fix_sheet.dart';
import 'security_more_data.dart';
import 'security_more_texts.dart';
import 'security_section_widgets.dart';
import 'security_texts.dart';
import 'security_widgets.dart';

/// Rows shown per list; the rest is summarised.
const vulnListCap = 100;

/// One scan of an image can save and scan a whole image: minutes.
const vulnScanTimeout = Duration(minutes: 6);

class SecurityVulnsScreen extends ConsumerWidget {
  const SecurityVulnsScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secVulnsTitle,
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
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _VulnsBlock(agent: a))],
    );
  }
}

class _VulnsBlock extends ConsumerStatefulWidget {
  const _VulnsBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_VulnsBlock> createState() => _VulnsBlockState();
}

class _VulnsBlockState extends ConsumerState<_VulnsBlock> {
  bool _busy = false;
  late final _key = (widget.agent.id, secVulnsPath);

  Future<void> _scan() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, widget.agent.id, 'POST', '$secVulnsPath/scan', body: <String, dynamic>{}), ok: l.secScanStarted);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(securityGetProvider(_key));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(securityGetProvider(_key));
    return SecAsync<Map<String, dynamic>>(
      value: async,
      onRetry: () => ref.invalidate(securityGetProvider(_key)),
      data: (j) {
        final v = VulnList(j);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!v.enabled)
            SecNote(l.secVulnsOff, icon: LucideIcons.scanSearch, warn: true)
          else ...[
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(l.secVulnsSummary(v.images.length, v.images.fold(0, (a, i) => a + i.critical), v.images.fold(0, (a, i) => a + i.high)), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy || v.running ? null : _scan,
                  icon: _busy || v.running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.scanSearch, size: 16),
                  label: Text(v.running ? l.secScanRunning : l.secScanNow),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            SecNote(l.secVulnsInfo),
            const SizedBox(height: 10),
            if (v.images.isEmpty) TCard(child: Text(l.secVulnsEmpty)),
            for (final img in v.images.take(vulnListCap)) Padding(padding: const EdgeInsets.only(bottom: 10), child: _ImageCard(agent: widget.agent, image: img)),
            if (v.images.length > vulnListCap) Padding(padding: const EdgeInsets.all(8), child: Text(l.secMoreRows(v.images.length - vulnListCap))),
          ],
        ]);
      },
    );
  }
}

class _ImageCard extends ConsumerWidget {
  const _ImageCard({required this.agent, required this.image});
  final Host agent;
  final VulnImage image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    final i = image;
    final reason = vulnErrorText(l, i.status, i.error);
    final where = [for (final h in i.hosts) '${h.host}${h.containers.isEmpty ? '' : ': ${h.containers.join(', ')}'}'];
    final scanned = i.scannedAt == null ? l.secVulnNeverScanned : l.secVulnScannedAgo(relativeTime(l, i.scannedAt!, now));
    return TCard(
      semanticLabel: [i.title, vulnStatusName(l, i.status), if (i.status == 'ok') l.secVulnCounts(i.critical, i.high, i.fixable), ?reason, scanned].join(', '),
      onTap: () => context.push(securityVulnRoute(i.hex, agentId: agent.id)),
      child: ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(i.title, style: tt.titleSmall?.copyWith(fontFamily: monoFamily, fontSize: 13.5), maxLines: 2, overflow: TextOverflow.ellipsis)),
            const Icon(LucideIcons.chevronRight, size: 18),
          ]),
          if (i.refs.length > 1) Text(i.refs.skip(1).join(', '), style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            SecChip(vulnStatusName(l, i.status), vulnStatusColor(t, i.status), filled: i.status == 'failed'),
            if (i.status == 'ok' && i.critical > 0) SecChip(l.secSeverityCount(i.critical, l.secSeverityCritical), t.danger, filled: true),
            if (i.status == 'ok' && i.high > 0) SecChip(l.secSeverityCount(i.high, l.secSeverityHigh), t.danger),
            if (i.status == 'ok' && i.fixable > 0) SecChip(l.secVulnFixableChip(i.fixable), t.success),
            if (i.status == 'ok' && i.critical == 0 && i.high == 0) SecChip(l.secVulnClean, t.success),
            if (i.source != null) SecChip(vulnSourceName(l, i.source), t.textSecondary),
          ]),
          if (reason != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(reason, style: tt.bodySmall?.copyWith(color: t.textSecondary))),
          if (where.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${l.secVulnRunsOn}: ${where.join(' · ')}', style: tt.bodySmall)),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(scanned, style: tt.bodySmall)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// One image

class SecurityVulnDetailScreen extends ConsumerStatefulWidget {
  const SecurityVulnDetailScreen({super.key, required this.hex, this.agentHint});
  final String hex;
  final String? agentHint;
  @override
  ConsumerState<SecurityVulnDetailScreen> createState() => _VulnDetailState();
}

class _VulnDetailState extends ConsumerState<SecurityVulnDetailScreen> {
  bool _fixedOnly = false;
  bool _busy = false;

  /// Multi-select of CVEs for "Send to Claude".
  late final _sel = FixSelection()..addListener(_onSel);

  void _onSel() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  FixItem _item(VulnImage img, VulnItem v) => FixItem.vuln(hex: img.hex, cve: v.id, label: '${v.id} · ${v.pkg} ${v.installed}${v.fixed == null ? '' : ' → ${v.fixed}'}');

  (String, String?) get _key => (widget.hex, widget.agentHint);

  Future<void> _scan(Host agent, VulnImage img) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    await secAct(context, () => securityCall(ref, agent.id, 'POST', '$secVulnsPath/scan', body: {'imageId': img.imageId}, timeout: vulnScanTimeout), ok: l.secScanDone);
    if (mounted) setState(() => _busy = false);
    if (mounted) ref.invalidate(vulnImageProvider(_key));
    if (mounted) ref.invalidate(securityGetProvider((agent.id, secVulnsPath)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final async = ref.watch(vulnImageProvider(_key));
    final img = async.value?.$2;
    final agent = async.value?.$1;
    final all = img == null ? const <FixItem>[] : [for (final v in img.vulns) _item(img, v)];
    return SettingsPage(
      title: img?.title ?? l.secVulnsTitle,
      actions: [if (img != null && img.status == 'ok' && img.vulns.isNotEmpty) FixSelectButton(selection: _sel)],
      bottomBar: agent != null && _sel.selecting
          ? FixBar(selection: _sel, all: all, onSend: () async {
              if (await sendToClaude(context, ref, agentId: agent.id, items: _sel.items) && mounted) _sel.done();
            })
          : null,
      onRefresh: () async {
        ref.invalidate(vulnImageProvider(_key));
        await ref.read(vulnImageProvider(_key).future).then((_) {}, onError: (_) {});
      },
      children: async.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          if (e is AmbiguousHostError)
            HostPicker(hosts: e.hosts, onPick: (h) => context.replace(securityVulnRoute(widget.hex, agentId: h.id)))
          else
            TCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(agentErrorText(l, e)),
                TextButton(onPressed: () => ref.invalidate(vulnImageProvider(_key)), child: Text(l.commonRetry)),
              ]),
            ),
        ],
        data: (r) => [_body(context, r.$1, r.$2)],
      ),
    );
  }

  Widget _body(BuildContext context, Host agent, VulnImage i) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider)();
    final reason = vulnErrorText(l, i.status, i.error);
    final shown = [for (final v in i.vulns) if (!_fixedOnly || v.fixed != null) v];
    final capped = shown.take(vulnListCap).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in i.refs) Text(r, style: tt.titleSmall?.copyWith(fontFamily: monoFamily, fontSize: 13.5)),
          Text('sha256:${i.hex.substring(0, 12)}', style: tt.bodySmall?.copyWith(fontFamily: monoFamily)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            SecChip(vulnStatusName(l, i.status), vulnStatusColor(t, i.status), filled: i.status == 'failed'),
            if (i.status == 'ok') SecChip(l.secSeverityCount(i.critical, l.secSeverityCritical), i.critical > 0 ? t.danger : t.textSecondary, filled: i.critical > 0),
            if (i.status == 'ok') SecChip(l.secSeverityCount(i.high, l.secSeverityHigh), i.high > 0 ? t.danger : t.textSecondary),
            if (i.status == 'ok') SecChip(l.secVulnFixableChip(i.fixable), i.fixable > 0 ? t.success : t.textSecondary),
            if (i.source != null) SecChip(vulnSourceName(l, i.source), t.textSecondary),
          ]),
          if (reason != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(reason, style: tt.bodyMedium)),
          if (i.os != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.secVulnOs(i.os!), style: tt.bodySmall)),
          for (final h in i.hosts) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${h.host}${h.containers.isEmpty ? '' : ': ${h.containers.join(', ')}'}', style: tt.bodySmall)),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(i.scannedAt == null ? l.secVulnNeverScanned : l.secVulnScannedAgo(relativeTime(l, i.scannedAt!, now)), style: tt.bodySmall)),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : () => _scan(agent, i),
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.scanSearch, size: 16),
            label: Text(l.secScanNow),
          ),
        ]),
      ),
      if (i.status == 'needsCredentials') ...[const SizedBox(height: 10), SecNote(l.secVulnCredentialsHelp(i.error ?? ''), warn: true)],
      if (i.status == 'pending') ...[const SizedBox(height: 10), SecNote(l.secVulnsInfo)],
      if (i.status == 'ok') ...[
        const SizedBox(height: 10),
        GroupedSection(children: [
          SwitchRow(title: l.secVulnFixedOnly, subtitle: l.secVulnFixedOnlyHint, value: _fixedOnly, onChanged: (v) => setState(() => _fixedOnly = v)),
        ]),
        SectionLabel(l.secVulnTableTitle(shown.length)),
        if (shown.isEmpty) TCard(child: Text(_fixedOnly ? l.secVulnNoneFixed : l.secVulnNone)),
        for (final v in capped) Padding(padding: const EdgeInsets.only(bottom: 8), child: _VulnRow(vuln: v, selection: _sel, item: _item(i, v))),
        if (shown.length > capped.length) Padding(padding: const EdgeInsets.all(8), child: Text(l.secMoreRows(shown.length - capped.length))),
        if (i.truncated) Padding(padding: const EdgeInsets.all(8), child: Text(l.secVulnTruncated, style: tt.bodySmall?.copyWith(color: t.warning))),
      ],
    ]);
  }
}

class _VulnRow extends StatelessWidget {
  const _VulnRow({required this.vuln, required this.selection, required this.item});
  final VulnItem vuln;
  final FixSelection selection;
  final FixItem item;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final v = vuln;
    final version = v.fixed == null ? '${v.installed} · ${l.secVulnNoFix}' : '${v.installed} → ${v.fixed}';
    return FixPick(
      selection: selection,
      item: item,
      child: TCard(
      padding: const EdgeInsets.all(12),
      semanticLabel: '${v.id}, ${securitySeverityName(l, v.severity)}, ${v.pkg}, $version, ${v.title}',
      child: ExcludeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SecChip(securitySeverityName(l, v.severity), securitySeverityColor(t, v.severity), filled: v.severity == 'critical'),
            const SizedBox(width: 8),
            Expanded(child: Text(v.id, style: tt.titleSmall?.copyWith(fontFamily: monoFamily, fontSize: 13), overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 6),
          Text(v.pkg, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text(version, style: tt.bodySmall?.copyWith(fontFamily: monoFamily, color: v.fixed == null ? t.textSecondary : t.success)),
          if (v.title.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(v.title, style: tt.bodySmall, maxLines: 4, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      ),
    );
  }
}
