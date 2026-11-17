// Telegram › issue: status, approve/reject while it waits, a Telegram-like preview of the rendered parts, the items
// with their sources, deliveries per recipient and "send test". Opened from the archive, after preview / run now,
// and from notifications (tiphys://telegram/issues/<id>, no host: every telegram agent is asked).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'telegram_data.dart';
import 'telegram_html.dart';
import 'telegram_screen.dart' show deliveryStatusText, telegramBlue;

class IssueScreen extends ConsumerStatefulWidget {
  const IssueScreen({super.key, this.hostId, required this.issueId});
  final String? hostId;
  final String issueId;
  @override
  ConsumerState<IssueScreen> createState() => _IssueScreenState();
}

class _IssueScreenState extends ConsumerState<IssueScreen> {
  bool _busy = false;

  Future<void> _act(String hostId, Future<void> Function() body, String done) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await body();
      if (mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      // The screen may have been left while the call ran: ref is unusable after dispose.
      if (mounted) {
        ref.invalidate(telegramIssueProvider((widget.hostId, widget.issueId)));
        ref.invalidate(telegramIssuesProvider((hostId, null)));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _approve(String hostId, Json issue, int recipients) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.tgApproveConfirm(recipients), confirmLabel: l.tgApprove)) return;
    await _act(hostId, () => agentCall(ref, hostId, 'POST', '/v1/telegram/issues/${widget.issueId}/approve'), l.tgApproved);
  }

  Future<void> _reject(String hostId) async {
    final l = AppLocalizations.of(context);
    await _act(hostId, () => agentCall(ref, hostId, 'POST', '/v1/telegram/issues/${widget.issueId}/reject'), l.tgRejected);
  }

  Future<void> _test(String hostId, List<Json> recipients) async {
    final l = AppLocalizations.of(context);
    final candidates = recipients.where((r) => r['status'] != 'stopped').toList();
    if (candidates.isEmpty) return toast(context, l.tgRecipientsEmpty);
    final rid = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.tgSendTestTo, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 10),
            GroupedSection(children: [
              for (final r in candidates)
                GroupedRow(
                  title: recipientName(r),
                  subtitle: recipientStatusText(l, '${r['status']}'),
                  icon: LucideIcons.user,
                  iconBackground: telegramBlue,
                  onTap: () => Navigator.pop(c, '${r['id']}'),
                ),
            ]),
          ]),
        ),
      ),
    );
    if (rid == null || !mounted) return;
    await _act(hostId, () async {
      final r = await agentCall(ref, hostId, 'POST', '/v1/telegram/issues/${widget.issueId}/test', {'recipientId': rid}) as Map;
      final d = r['delivery'] as Map?;
      if (d?['status'] != 'sent') throw AgentError('${d?['error'] ?? 'agent.telegram.sendFailed'}');
    }, l.tgTestSent);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final data = ref.watch(telegramIssueProvider((widget.hostId, widget.issueId)));
    return SettingsPage(
      title: l.tgIssue,
      actions: [IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(telegramIssueProvider((widget.hostId, widget.issueId))))],
      children: [
        ...data.when(
          skipLoadingOnRefresh: true,
          loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(agentErrorText(l, e))))],
          data: (d) => _body(context, d.$1, d.$2),
        ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, String hostId, Json issue) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final fmt = DateFormat('d MMM EEE HH:mm', locale);
    final feeds = ref.watch(telegramFeedsProvider(hostId)).value ?? const <Json>[];
    final recipients = ref.watch(telegramRecipientsProvider(hostId)).value ?? const <Json>[];
    final bot = (ref.watch(telegramStatusProvider(hostId)).value?['bot'] as Map?)?['username'];
    final feed = feeds.where((f) => f['id'] == issue['feedId']).firstOrNull;
    final status = '${issue['status']}';
    final items = [for (final x in (issue['items'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
    final parts = ((issue['renderedParts'] as List?) ?? const []).cast<String>();
    final deliveries = [for (final x in (issue['deliveries'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
    final names = {for (final r in recipients) '${r['id']}': recipientName(r)};
    final stats = issue['stats'] as Map?;
    final at = DateTime.parse('${issue['finishedAt'] ?? issue['createdAt']}').toLocal();
    final subscribers = feed == null ? 0 : recipients.where((r) => r['status'] == 'active' && ((r['subscriptions'] as List?) ?? const []).contains(feed['id'])).length;
    final error = issue['error'];
    return [
      const SizedBox(height: 12),
      TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${feed?['name'] ?? l.tgFeed}', style: tt.titleMedium)),
            _StatusPill(text: issueStatusText(l, status), color: issueStatusColor(t, status)),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              fmt.format(DateTime.parse('${issue['createdAt']}').toLocal()),
              switch (issue['kind']) { 'preview' => l.tgPreviewAction, 'manual' => l.claudeScheduleManual, _ => l.tgScheduled },
              if (items.isNotEmpty) l.tgItemCount(items.length),
            ].join(' · '),
            style: tt.bodySmall,
          ),
          if (stats != null && (stats['received'] as num? ?? 0) > 0)
            Text(l.tgStats((stats['kept'] as num).toInt(), (stats['received'] as num).toInt(), (stats['droppedSources'] as num? ?? 0).toInt()), style: tt.bodySmall),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(agentErrorText(l, AgentError('$error')), style: TextStyle(color: t.danger))),
        ]),
      ),
      if (status == 'awaiting_approval')
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TCard(
            borderColor: t.warning,
            color: t.isDark ? null : const Color(0xFFFFF7E6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(LucideIcons.hourglass, size: 18, color: t.warning),
                const SizedBox(width: 8),
                Expanded(child: Text(l.tgApprovalWaiting(subscribers), style: tt.titleMedium)),
              ]),
              if (issue['expiresAt'] != null)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.tgApprovalExpires(fmt.format(DateTime.parse('${issue['expiresAt']}').toLocal())), style: tt.bodySmall)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _reject(hostId),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48), foregroundColor: t.danger),
                    child: Text(l.tgReject),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _approve(hostId, issue, subscribers),
                    icon: const Icon(LucideIcons.send, size: 18),
                    label: Text(l.tgApprove),
                    style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      if (telegramBusyStatuses.contains(status))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(status == 'sending' ? l.tgIssueSending : l.tgIssueResearchingHint, style: tt.bodyMedium),
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ]),
          ),
        ),
      if (parts.isNotEmpty) ...[
        SectionLabel(l.tgPreview),
        TelegramPreview(parts: parts, botName: bot == null ? null : '@$bot', time: DateFormat.Hm(locale).format(at)),
      ],
      if (items.isNotEmpty) ...[
        SectionLabel(l.tgItems),
        for (final (i, it) in items.indexed) Padding(padding: const EdgeInsets.only(bottom: 10), child: _ItemCard(index: i + 1, item: it)),
      ],
      if (deliveries.isNotEmpty)
        GroupedSection(title: l.tgDeliveries, children: [
          for (final d in deliveries)
            GroupedRow(
              title: names['${d['recipientId']}'] ?? '${d['recipientId']}',
              subtitle: [
                deliveryStatusText(l, '${d['status']}'),
                DateFormat.Hm(locale).format(DateTime.parse('${d['at']}').toLocal()),
                if (d['test'] == true) l.tgTest,
                if (d['error'] != null) agentErrorText(l, AgentError('${d['error']}')),
              ].join(' · '),
              icon: d['status'] == 'sent' ? LucideIcons.check : LucideIcons.x,
              iconBackground: d['status'] == 'sent' ? t.success : t.danger,
              showChevron: false,
            ),
        ]),
      if (parts.isNotEmpty)
        GroupedSection(children: [
          GroupedRow(
            title: l.tgSendTest,
            icon: LucideIcons.messageSquare,
            iconBackground: telegramBlue,
            showChevron: false,
            onTap: _busy ? null : () => _test(hostId, recipients),
          ),
        ]),
    ];
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      );
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.index, required this.item});
  final int index;
  final Json item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final sources = [for (final s in (item['sources'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    return TCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$index. ${item['headline']}', style: tt.titleMedium),
        const SizedBox(height: 4),
        Text('${item['summary']}', style: tt.bodyMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in sources)
            if (safeHttpUrl('${s['url']}') case final url?)
              ActionChip(
                avatar: Icon(LucideIcons.externalLink, size: 14, color: t.accent),
                label: Text(Uri.parse(url).host.replaceFirst(RegExp(r'^www\.'), ''), style: const TextStyle(fontSize: 12)),
                tooltip: '${s['title'] ?? url}',
                onPressed: () => openExternal(url),
                visualDensity: VisualDensity.compact,
              ),
        ]),
      ]),
    );
  }
}
