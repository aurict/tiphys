// Telegram › feed: summary, preview / run now, the issue archive; the feed editor (schedule picker shared with
// Claude schedules) and the template chooser.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/schedules.dart' show ScheduleWhenPicker, scheduleChip, scheduleLabel, scheduleWhenText, scheduleWhenValid;
import '../system/agent_providers.dart';
import 'issue_screen.dart';
import 'telegram_data.dart';

/// Template chooser: the agent's two templates (daily / weekly Monday) or a blank feed.
Future<void> showFeedTemplateSheet(BuildContext context, {required String hostId}) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (c) => SafeArea(
        child: Consumer(builder: (c, ref, _) {
          final l = AppLocalizations.of(c);
          final locale = Localizations.localeOf(c).toLanguageTag();
          final templates = ref.watch(telegramTemplatesProvider(hostId));
          void open(Json? feed) {
            Navigator.pop(c);
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeedEditScreen(hostId: hostId, template: feed)));
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l.tgFeedAdd, style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 10),
              GroupedSection(children: [
                for (final tpl in templates.value ?? const <Json>[])
                  GroupedRow(
                    title: '${(tpl['feed'] as Map)['name']}',
                    subtitle: '${scheduleWhenText(l, locale, (tpl['feed'] as Map)['when'] as Map)} · '
                        '${l.tgFeedItemsRange((tpl['feed'] as Map)['minItems'] as int, (tpl['feed'] as Map)['maxItems'] as int)}',
                    icon: LucideIcons.layoutTemplate,
                    iconBackground: const Color(0xFFFF9F0A),
                    onTap: () => open(Map<String, dynamic>.from(tpl['feed'] as Map)),
                  ),
                if (templates.isLoading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                GroupedRow(title: l.tgFeedBlank, icon: LucideIcons.filePlus, iconBackground: const Color(0xFF6C6C70), onTap: () => open(null)),
              ]),
            ]),
          );
        }),
      ),
    );

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key, required this.hostId, required this.feedId});
  final String hostId;
  final String feedId;
  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  bool _busy = false;

  Future<void> _start(Json feed, bool preview) async {
    final l = AppLocalizations.of(context);
    if (!preview) {
      final ask = (feed['approval'] as Map?)?['mode'] != 'auto';
      final n = ((feed['recipientIds'] as List?) ?? const []).length;
      if (!await confirmDialog(context, message: ask ? l.tgRunConfirmApproval(n) : l.tgRunConfirmSend(n), confirmLabel: l.claudeScheduleRunNow)) return;
    }
    setState(() => _busy = true);
    try {
      final r = await agentCall(ref, widget.hostId, 'POST', '/v1/telegram/feeds/${widget.feedId}/${preview ? 'preview' : 'run'}') as Map;
      ref.invalidate(telegramFeedsProvider(widget.hostId));
      ref.invalidate(telegramIssuesProvider((widget.hostId, widget.feedId)));
      final id = (r['issue'] as Map?)?['id'];
      if (mounted && id != null) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IssueScreen(hostId: widget.hostId, issueId: '$id')));
      }
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = ref.watch(clockProvider)();
    final feeds = ref.watch(telegramFeedsProvider(widget.hostId));
    final feed = feeds.value?.where((f) => f['id'] == widget.feedId).firstOrNull;
    if (feed == null) {
      return SettingsPage(title: l.tgFeed, children: [
        if (feeds.isLoading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (feeds.hasError) TCard(child: Text(agentErrorText(l, feeds.error!))),
        if (feeds.hasValue) Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.tgGone))),
      ]);
    }
    final issues = ref.watch(telegramIssuesProvider((widget.hostId, widget.feedId)));
    final running = feed['running'] == true;
    final fmt = DateFormat('d MMM EEE HH:mm', locale);
    Widget info(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(icon, size: 16, color: t.textSecondary),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: tt.bodyMedium)),
          ]),
        );
    return SettingsPage(
      title: '${feed['name']}',
      actions: [
        IconButton(
          tooltip: l.commonEdit,
          icon: const Icon(LucideIcons.pencil),
          onPressed: () async {
            final deleted = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => FeedEditScreen(hostId: widget.hostId, existing: feed)));
            if (deleted == true && context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
      children: [
        const SizedBox(height: 12),
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${feed['topic']}', style: tt.bodyMedium, maxLines: 4, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            info(LucideIcons.alarmClock, feedScheduleSummary(l, locale, feed, now)),
            info(LucideIcons.listOrdered, '${windowText(l, (feed['windowHours'] as num).toInt())} · ${l.tgFeedItemsRange((feed['minItems'] as num).toInt(), (feed['maxItems'] as num).toInt())}'),
            info(LucideIcons.shieldCheck, approvalText(l, feed['approval'] as Map)),
            info(LucideIcons.users, l.tgRecipientCount(((feed['recipientIds'] as List?) ?? const []).length)),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy || running ? null : () => _start(feed, true),
              icon: const Icon(LucideIcons.eye, size: 18),
              label: Text(l.tgPreviewAction),
              style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy || running ? null : () => _start(feed, false),
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.play, size: 18),
              label: Text(l.claudeScheduleRunNow),
              style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
            ),
          ),
        ]),
        if (running) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.tgFeedRunning, style: tt.bodySmall)),
        GroupedSection(
          title: l.tgArchive,
          footer: issues.hasError ? agentErrorText(l, issues.error!) : ((issues.value ?? const []).isEmpty ? l.tgArchiveEmpty : null),
          children: [
            for (final i in issues.value ?? const <Json>[])
              GroupedRow(
                title: fmt.format(DateTime.parse('${i['createdAt']}').toLocal()),
                subtitle: [
                  issueStatusText(l, '${i['status']}'),
                  if (i['kind'] == 'preview') l.tgPreviewAction else if (i['kind'] == 'manual') l.claudeScheduleManual,
                  if ((i['itemCount'] as num? ?? 0) > 0) l.tgItemCount((i['itemCount'] as num).toInt()),
                  if (((i['deliveryCounts'] as Map?)?['sent'] as num? ?? 0) > 0) l.tgSentTo(((i['deliveryCounts'] as Map)['sent'] as num).toInt()),
                ].join(' · '),
                icon: LucideIcons.newspaper,
                iconBackground: issueStatusColor(t, '${i['status']}'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IssueScreen(hostId: widget.hostId, issueId: '${i['id']}'))),
              ),
          ],
        ),
      ],
    );
  }
}

/// Create (from [template] or blank) or edit ([existing]) a feed. Pops `true` when the feed was deleted.
class FeedEditScreen extends ConsumerStatefulWidget {
  const FeedEditScreen({super.key, required this.hostId, this.existing, this.template});
  final String hostId;
  final Json? existing;
  final Json? template;
  @override
  ConsumerState<FeedEditScreen> createState() => _FeedEditScreenState();
}

class _FeedEditScreenState extends ConsumerState<FeedEditScreen> {
  late final Json _src = widget.existing ?? widget.template ?? const {};
  late final _name = TextEditingController(text: _src['name'] as String?);
  late final _topic = TextEditingController(text: _src['topic'] as String?);
  late final _instructions = TextEditingController(text: _src['instructions'] as String?);
  late final _window = TextEditingController(text: '${_src['windowHours'] ?? 24}');
  late final _min = TextEditingController(text: '${_src['minItems'] ?? 5}');
  late final _max = TextEditingController(text: '${_src['maxItems'] ?? 8}');
  late final _allow = TextEditingController(text: ((_src['allowDomains'] as List?) ?? const []).join(', '));
  late final _block = TextEditingController(text: ((_src['blockDomains'] as List?) ?? const []).join(', '));
  late final _n = TextEditingController(text: '${(_src['approval'] as Map?)?['n'] ?? 3}');
  late final _deadline = TextEditingController(text: '${_src['deadlineMinutes'] ?? 30}');
  late bool _enabled = _src['enabled'] as bool? ?? true;
  late Map<String, dynamic> _when = ScheduleWhenPicker.normalize(_src['when'] as Map?);
  late int _sources = (_src['maxSourcesPerItem'] as num?)?.toInt() ?? 3;
  late bool _skip = _src['skipIfNothingNew'] as bool? ?? true;
  late String _approval = '${(_src['approval'] as Map?)?['mode'] ?? 'firstN'}';
  late final Set<String> _recipients = {...((widget.existing?['recipientIds'] as List?) ?? const []).cast<String>()};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _topic, _instructions, _window, _min, _max, _allow, _block, _n, _deadline]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Input for the agent, or an error text.
  (Json?, String?) _input(AppLocalizations l) {
    int? n(TextEditingController c) => int.tryParse(c.text.trim());
    final min = n(_min), max = n(_max), window = n(_window), deadline = n(_deadline), approvalN = n(_n);
    if (_name.text.trim().isEmpty || _topic.text.trim().isEmpty) return (null, l.tgFeedNeedsNameTopic);
    if (!scheduleWhenValid(_when)) return (null, l.claudeScheduleNeedsDays);
    if (min == null || max == null || min < 1 || max > 20 || min > max) return (null, l.tgFeedBadItems);
    if (window == null || window < 1 || window > 720) return (null, l.tgFeedBadWindow);
    if (deadline == null || deadline < 5 || deadline > 360) return (null, l.tgFeedBadDeadline);
    if (_approval == 'firstN' && (approvalN == null || approvalN < 1 || approvalN > 100)) return (null, l.tgFeedBadApprovalN);
    return (
      feedInput({
        'name': _name.text.trim(),
        'enabled': _enabled,
        'when': _when,
        'topic': _topic.text.trim(),
        'instructions': _instructions.text.trim(),
        'windowHours': window,
        'language': _src['language'] ?? 'tr',
        'minItems': min,
        'maxItems': max,
        'maxSourcesPerItem': _sources,
        'allowDomains': parseDomains(_allow.text),
        'blockDomains': parseDomains(_block.text),
        'skipIfNothingNew': _skip,
        'approval': {'mode': _approval, 'n': approvalN ?? 3},
        'deadlineMinutes': deadline,
      }),
      null,
    );
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final (body, error) = _input(l);
    if (body == null) return setState(() => _error = error);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = widget.existing?['id'];
      final r = await agentCall(ref, widget.hostId, id == null ? 'POST' : 'PUT', id == null ? '/v1/telegram/feeds' : '/v1/telegram/feeds/$id', body) as Map;
      final feedId = '${(r['feed'] as Map)['id']}';
      // Who receives the feed lives on the recipients (subscriptions): update the ones that changed.
      final recipients = await ref.read(telegramRecipientsProvider(widget.hostId).future);
      for (final (rid, subs) in subscriptionChanges(recipients, feedId, _recipients)) {
        await agentCall(ref, widget.hostId, 'PATCH', '/v1/telegram/recipients/$rid', {'subscriptions': subs});
      }
      ref.invalidate(telegramFeedsProvider(widget.hostId));
      ref.invalidate(telegramRecipientsProvider(widget.hostId));
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) setState(() => _error = agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    final e = widget.existing!;
    if (!await confirmDialog(context, message: l.tgFeedDeleteConfirm('${e['name']}'), confirmLabel: l.commonDelete, destructive: true)) return;
    try {
      await agentCall(ref, widget.hostId, 'DELETE', '/v1/telegram/feeds/${e['id']}');
      ref.invalidate(telegramFeedsProvider(widget.hostId));
      ref.invalidate(telegramRecipientsProvider(widget.hostId));
      if (mounted) Navigator.of(context).pop(true);
    } catch (err) {
      if (mounted) setState(() => _error = agentErrorText(l, err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final recipients = (ref.watch(telegramRecipientsProvider(widget.hostId)).value ?? const <Json>[]).where((r) => r['status'] != 'stopped').toList();
    return SettingsPage(
      title: widget.existing == null ? l.tgFeedAdd : l.tgFeedEdit,
      onSave: _save,
      saving: _busy,
      children: [
        FieldCard(title: l.tgFeedBasics, children: [
          TField(controller: _name, label: l.claudeScheduleName),
          TField(controller: _topic, label: l.tgFeedTopic, maxLines: 4, helper: l.tgFeedTopicHint),
          TField(controller: _instructions, label: l.tgFeedInstructions, maxLines: 4, hint: l.tgFeedInstructionsHint),
        ]),
        const SizedBox(height: 12),
        GroupedSection(children: [SwitchRow(title: l.tgFeedEnabled, value: _enabled, onChanged: (v) => setState(() => _enabled = v))]),
        const SizedBox(height: 12),
        TCard(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
          child: ScheduleWhenPicker(initial: _when, onChanged: (w) => setState(() => _when = w)),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text(l.tgFeedScheduleHint, style: tt.bodySmall)),
        FieldCard(title: l.tgFeedRules, children: [
          TField(controller: _window, label: l.tgFeedWindow, keyboardType: TextInputType.number, helper: l.tgFeedWindowHint),
          Row(children: [
            Expanded(child: TField(controller: _min, label: l.tgFeedMinItems, keyboardType: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(child: TField(controller: _max, label: l.tgFeedMaxItems, keyboardType: TextInputType.number)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            scheduleLabel(context, l.tgFeedSourcesPerItem),
            Wrap(spacing: 6, children: [for (final n in const [1, 2, 3]) scheduleChip(context, '$n', n == _sources, () => setState(() => _sources = n))]),
          ]),
          TField(controller: _allow, label: l.tgFeedAllowDomains, mono: true, maxLines: 2, hint: 'reuters.com, apnews.com', helper: l.tgFeedAllowDomainsHint),
          TField(controller: _block, label: l.tgFeedBlockDomains, mono: true, maxLines: 2),
        ]),
        const SizedBox(height: 12),
        GroupedSection(children: [
          SwitchRow(title: l.tgFeedSkip, subtitle: l.tgFeedSkipHint, value: _skip, onChanged: (v) => setState(() => _skip = v)),
        ]),
        SectionLabel(l.tgFeedApproval),
        TCard(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (v, name) in [('firstN', l.tgApprovalFirstNShort), ('ask', l.tgApprovalAsk), ('auto', l.tgApprovalAuto)])
                scheduleChip(context, name, v == _approval, () => setState(() => _approval = v)),
            ]),
            if (_approval == 'firstN') Padding(padding: const EdgeInsets.only(top: 10), child: TField(controller: _n, label: l.tgFeedApprovalN, keyboardType: TextInputType.number)),
            const SizedBox(height: 10),
            TField(controller: _deadline, label: l.tgFeedDeadline, keyboardType: TextInputType.number, helper: l.tgFeedDeadlineHint),
          ]),
        ),
        GroupedSection(
          title: l.tgFeedRecipients,
          footer: recipients.isEmpty ? l.tgRecipientsEmpty : null,
          children: [
            for (final r in recipients)
              SwitchRow(
                title: recipientName(r),
                subtitle: r['status'] == 'active' ? null : recipientStatusText(l, '${r['status']}'),
                value: _recipients.contains(r['id']),
                onChanged: (v) => setState(() => v ? _recipients.add('${r['id']}') : _recipients.remove(r['id'])),
              ),
          ],
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: TextStyle(color: t.danger))),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.check),
          label: Text(l.commonSave),
          style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
        ),
        if (widget.existing != null)
          TextButton(onPressed: _busy ? null : _delete, style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.commonDelete)),
      ],
    );
  }
}
