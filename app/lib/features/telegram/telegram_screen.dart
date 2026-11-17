// Host page › Telegram (agent feature "telegram", e.g. atlas): bot setup, recipients and invites, feeds.
// The bot token is sent once (PUT /v1/telegram/bot) and never shown again; the agent never returns it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'feed_screens.dart';
import 'telegram_data.dart';

const telegramBlue = Color(0xFF2AABEE);

/// Entry point. Without [hostId] (deep link) the first agent with the telegram feature is used.
class TelegramScreen extends ConsumerWidget {
  const TelegramScreen({super.key, this.hostId});
  final String? hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hostId != null && hostId!.isNotEmpty) return TelegramHome(hostId: hostId!);
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(hostsWithFeatureProvider('telegram'));
    return hosts.when(
      loading: () => SettingsPage(title: 'Telegram', children: const [Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))]),
      error: (e, _) => SettingsPage(title: 'Telegram', children: [TCard(child: Text(agentErrorText(l, e)))]),
      data: (list) => list.isEmpty
          ? SettingsPage(title: 'Telegram', children: [Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.tgNoHost)))])
          : TelegramHome(hostId: list.first.id),
    );
  }
}

class TelegramHome extends ConsumerWidget {
  const TelegramHome({super.key, required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final host = ref.watch(profileProvider).host(hostId);
    final status = ref.watch(telegramStatusProvider(hostId));
    return SettingsPage(
      title: 'Telegram · ${host?.name ?? hostId}',
      actions: [
        IconButton(
          tooltip: l.commonRetry,
          icon: const Icon(LucideIcons.refreshCw),
          onPressed: () {
            ref.invalidate(telegramStatusProvider(hostId));
            ref.invalidate(telegramRecipientsProvider(hostId));
            ref.invalidate(telegramInvitesProvider(hostId));
            ref.invalidate(telegramFeedsProvider(hostId));
            ref.invalidate(telegramIssuesProvider((hostId, null)));
          },
        ),
      ],
      children: [
        ...status.when(
          skipLoadingOnRefresh: true,
          loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(agentErrorText(l, e))))],
          data: (st) => (st['bot'] as Map?)?['configured'] == true
              ? [
                  _BotSection(hostId: hostId, status: st),
                  _RecipientsSection(hostId: hostId),
                  _InvitesSection(hostId: hostId),
                  _FeedsSection(hostId: hostId),
                ]
              : [
                  const SizedBox(height: 12),
                  BotTokenCard(hostId: hostId),
                  _ResearchSection(hostId: hostId, status: st),
                ],
        ),
      ],
    );
  }
}

/// Token field + "Save and check" (getMe on the agent). Used for the first setup and to replace the bot.
class BotTokenCard extends ConsumerStatefulWidget {
  const BotTokenCard({super.key, required this.hostId, this.onDone});
  final String hostId;
  final VoidCallback? onDone;
  @override
  ConsumerState<BotTokenCard> createState() => _BotTokenCardState();
}

class _BotTokenCardState extends ConsumerState<BotTokenCard> {
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final token = _token.text.trim();
    if (token.isEmpty) return setState(() => _error = l.commonRequired);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await agentCall(ref, widget.hostId, 'PUT', '/v1/telegram/bot', {'token': token}) as Map;
      _token.clear();
      ref.invalidate(telegramStatusProvider(widget.hostId));
      if (!mounted) return;
      toast(context, l.tgBotSaved('@${(r['bot'] as Map?)?['username'] ?? ''}'));
      widget.onDone?.call();
    } catch (e) {
      if (mounted) setState(() => _error = agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: telegramBlue, borderRadius: BorderRadius.circular(9)),
            child: const Icon(LucideIcons.send, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(l.tgBotSetupTitle, style: tt.titleMedium)),
        ]),
        const SizedBox(height: 10),
        Text(l.tgBotSetupSteps, style: tt.bodyMedium),
        const SizedBox(height: 8),
        TField(controller: _token, label: l.tgBotToken, hint: '123456:ABC…', obscure: true, mono: true, helper: l.tgBotTokenHint),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: t.danger))),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.check),
          label: Text(l.tgBotSave),
        ),
        const SizedBox(height: 10),
        _PrivacyNote(text: l.tgPrivacyNote),
      ]),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(LucideIcons.shieldAlert, size: 16, color: t.warning),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}

/// Research PC row: configured URL and whether the agent can reach it (GET status probes the PC's /v1/health).
GroupedRow researchStatusRow(BuildContext context, AppLocalizations l, Map st, {VoidCallback? onTap}) {
  final t = context.tokens;
  final r = (st['research'] as Map?) ?? const {};
  final configured = r['configured'] == true;
  final reachable = r['reachable'];
  final host = configured ? (Uri.tryParse('${r['url']}')?.host ?? '${r['url']}') : null;
  return GroupedRow(
    title: l.tgResearchPc,
    subtitle: !configured
        ? l.tgResearchNotSet
        : '$host · ${reachable == true ? l.tgResearchReachable : l.tgResearchUnreachable}${r['wakeHostId'] != null ? ' · ${l.tgResearchWake}' : ''}',
    icon: LucideIcons.monitorSmartphone,
    iconBackground: !configured ? const Color(0xFF8E8E93) : (reachable == true ? t.success : t.danger),
    onTap: onTap,
    showChevron: false,
    trailing: onTap == null ? null : Icon(LucideIcons.refreshCw, size: 18, color: t.textSecondary),
  );
}

class _ResearchSection extends ConsumerWidget {
  const _ResearchSection({required this.hostId, required this.status});
  final String hostId;
  final Map status;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return GroupedSection(
      title: l.tgResearchTitle,
      footer: l.tgResearchHint,
      children: [researchStatusRow(context, l, status, onTap: () => ref.invalidate(telegramStatusProvider(hostId)))],
    );
  }
}

class _BotSection extends ConsumerWidget {
  const _BotSection({required this.hostId, required this.status});
  final String hostId;
  final Map status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final bot = status['bot'] as Map;
    return GroupedSection(title: 'Bot', footer: l.tgPrivacyNote, children: [
      GroupedRow(
        title: '@${bot['username']}',
        subtitle: (status['pendingInvites'] as num? ?? 0) > 0 ? '${l.tgBotReady} · ${l.tgBotPolling}' : l.tgBotReady,
        icon: LucideIcons.send,
        iconBackground: telegramBlue,
        showChevron: false,
      ),
      researchStatusRow(context, l, status, onTap: () => ref.invalidate(telegramStatusProvider(hostId))),
      GroupedRow(
        title: l.tgBotChange,
        icon: LucideIcons.keyRound,
        iconBackground: const Color(0xFF6C6C70),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          builder: (c) => Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.viewInsetsOf(c).bottom + 12),
            child: SafeArea(child: BotTokenCard(hostId: hostId, onDone: () => Navigator.pop(c))),
          ),
        ),
      ),
      GroupedRow(
        title: l.tgBotRemove,
        destructive: true,
        showChevron: false,
        onTap: () async {
          if (!await confirmDialog(context, message: l.tgBotRemoveConfirm, confirmLabel: l.tgBotRemove, destructive: true)) return;
          try {
            await agentCall(ref, hostId, 'DELETE', '/v1/telegram/bot');
            ref.invalidate(telegramStatusProvider(hostId));
          } catch (e) {
            if (context.mounted) toast(context, agentErrorText(l, e));
          }
        },
      ),
    ]);
  }
}

// ───────────────────────── Recipients ─────────────────────────

class _RecipientsSection extends ConsumerWidget {
  const _RecipientsSection({required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final recipients = ref.watch(telegramRecipientsProvider(hostId));
    final feeds = ref.watch(telegramFeedsProvider(hostId)).value ?? const [];
    final names = {for (final f in feeds) '${f['id']}': '${f['name']}'};
    final list = recipients.value ?? const <Json>[];
    return GroupedSection(
      title: l.tgRecipients,
      footer: recipients.hasError ? agentErrorText(l, recipients.error!) : (list.isEmpty ? l.tgRecipientsEmpty : null),
      children: [
        for (final r in list)
          RecipientTile(
            recipient: r,
            feedNames: [for (final s in (r['subscriptions'] as List? ?? const [])) ?names['$s']],
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RecipientScreen(hostId: hostId, recipientId: '${r['id']}'))),
          ),
        GroupedRow(
          title: l.tgInviteAdd,
          icon: LucideIcons.userPlus,
          iconBackground: t.accent,
          onTap: () => showInviteSheet(context, hostId: hostId, feeds: feeds),
        ),
      ],
    );
  }
}

/// Recipient row: initial avatar (status colour), name, status and the subscribed feeds as chips.
class RecipientTile extends StatelessWidget {
  const RecipientTile({super.key, required this.recipient, required this.feedNames, this.onTap});
  final Json recipient;
  final List<String> feedNames;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final status = '${recipient['status']}';
    final name = recipientName(recipient);
    final color = recipientStatusColor(t, status);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: color,
            child: Text(name.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                [recipientStatusText(l, status), if (recipient['username'] != null) '@${recipient['username']}'].join(' · '),
                style: tt.bodySmall?.copyWith(color: status == 'active' ? null : color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              if (feedNames.isEmpty)
                Text(l.tgNoSubscriptions, style: tt.bodySmall)
              else
                Wrap(spacing: 6, runSpacing: 6, children: [for (final f in feedNames) _MiniChip(text: f)]),
            ]),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Icon(Icons.chevron_right_rounded, size: 20, color: t.isDark ? const Color(0xFF636366) : const Color(0xFFAEAEB2)),
            ),
        ]),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(999), border: Border.all(color: t.separator)),
      child: Text(text, style: TextStyle(fontSize: 12, color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _InvitesSection extends ConsumerWidget {
  const _InvitesSection({required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final pending = (ref.watch(telegramInvitesProvider(hostId)).value ?? const <Json>[]).where((i) => i['status'] == 'pending').toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    return GroupedSection(title: l.tgInvitesPending, footer: l.tgInvitesPendingHint, children: [
      for (final i in pending)
        GroupedRow(
          title: '${i['label'] ?? l.tgInviteNoLabel}',
          subtitle: l.tgInviteExpires(DateFormat('d MMM HH:mm', locale).format(DateTime.parse('${i['expiresAt']}').toLocal())),
          icon: LucideIcons.link,
          iconBackground: telegramBlue,
          onTap: i['link'] == null ? null : () => showInviteSheet(context, hostId: hostId, feeds: const [], invite: i),
          trailing: IconButton(
            tooltip: l.tgInviteRevoke,
            icon: Icon(LucideIcons.x, color: t.danger, size: 20),
            onPressed: () async {
              if (!await confirmDialog(context, message: l.tgInviteRevokeConfirm, confirmLabel: l.tgInviteRevoke, destructive: true)) return;
              try {
                await agentCall(ref, hostId, 'DELETE', '/v1/telegram/invites/${i['id']}');
                ref.invalidate(telegramInvitesProvider(hostId));
              } catch (e) {
                if (context.mounted) toast(context, agentErrorText(l, e));
              }
            },
          ),
        ),
    ]);
  }
}

// ───────────────────────── Invite sheet ─────────────────────────

/// "Add person": optional label + feeds → one-time t.me link to share (or an existing pending [invite]).
Future<void> showInviteSheet(BuildContext context, {required String hostId, required List<Json> feeds, Json? invite}) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: InviteSheet(hostId: hostId, feeds: feeds, invite: invite),
      ),
    );

class InviteSheet extends ConsumerStatefulWidget {
  const InviteSheet({super.key, required this.hostId, required this.feeds, this.invite});
  final String hostId;
  final List<Json> feeds;
  final Json? invite;
  @override
  ConsumerState<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<InviteSheet> {
  final _label = TextEditingController();
  late final Set<String> _feeds = {for (final f in widget.feeds) if (f['enabled'] == true) '${f['id']}'};
  late Json? _invite = widget.invite;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await agentCall(ref, widget.hostId, 'POST', '/v1/telegram/invites', {
        if (_label.text.trim().isNotEmpty) 'label': _label.text.trim(),
        'feedIds': _feeds.toList(),
      }) as Map;
      ref.invalidate(telegramInvitesProvider(widget.hostId));
      ref.invalidate(telegramStatusProvider(widget.hostId));
      if (mounted) setState(() => _invite = Map<String, dynamic>.from(r['invite'] as Map));
    } catch (e) {
      if (mounted) setState(() => _error = agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final inv = _invite;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.tgInviteAdd, style: tt.titleLarge),
          const SizedBox(height: 12),
          if (inv == null) ...[
            TextField(controller: _label, decoration: InputDecoration(labelText: l.tgInviteLabel, hintText: l.tgInviteLabelHint), textCapitalization: TextCapitalization.words),
            if (widget.feeds.isNotEmpty) ...[
              Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(l.tgInviteFeeds, style: tt.labelMedium)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in widget.feeds)
                  FilterChip(
                    label: Text('${f['name']}'),
                    selected: _feeds.contains('${f['id']}'),
                    onSelected: (v) => setState(() => v ? _feeds.add('${f['id']}') : _feeds.remove('${f['id']}')),
                  ),
              ]),
            ],
            const SizedBox(height: 10),
            Text(l.tgInviteHint, style: tt.bodySmall),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: TextStyle(color: t.danger))),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.link),
              label: Text(l.tgInviteCreate),
            ),
          ] else
            _InviteShare(invite: inv),
        ]),
      ),
    );
  }
}

class _InviteShare extends StatelessWidget {
  const _InviteShare({required this.invite});
  final Json invite;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final link = '${invite['link'] ?? ''}';
    final expires = DateFormat('d MMM HH:mm', locale).format(DateTime.parse('${invite['expiresAt']}').toLocal());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (invite['label'] != null) Text('${invite['label']}', style: tt.titleMedium),
      const SizedBox(height: 8),
      TCard(
        color: t.chipBackground,
        radius: 14,
        child: SelectableText(link, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13)),
      ),
      const SizedBox(height: 8),
      Text(l.tgInviteShareHint(expires), style: tt.bodySmall),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) toast(context, l.tgInviteCopied);
            },
            icon: const Icon(LucideIcons.copy, size: 18),
            label: Text(l.commonCopy),
            style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: () => SharePlus.instance.share(ShareParams(text: l.tgInviteShareText(link))),
            icon: const Icon(LucideIcons.share2, size: 18),
            label: Text(l.commonShare),
            style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
          ),
        ),
      ]),
    ]);
  }
}

// ───────────────────────── Recipient detail ─────────────────────────

class RecipientScreen extends ConsumerStatefulWidget {
  const RecipientScreen({super.key, required this.hostId, required this.recipientId});
  final String hostId;
  final String recipientId;
  @override
  ConsumerState<RecipientScreen> createState() => _RecipientScreenState();
}

class _RecipientScreenState extends ConsumerState<RecipientScreen> {
  bool _busy = false;

  Future<void> _call(Future<void> Function() body, {String? done}) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await body();
      ref.invalidate(telegramRecipientsProvider(widget.hostId));
      ref.invalidate(telegramFeedsProvider(widget.hostId));
      if (mounted && done != null) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _patch(Map<String, dynamic> body) => _call(() => agentCall(ref, widget.hostId, 'PATCH', '/v1/telegram/recipients/${widget.recipientId}', body));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final recipients = ref.watch(telegramRecipientsProvider(widget.hostId));
    final feeds = ref.watch(telegramFeedsProvider(widget.hostId)).value ?? const <Json>[];
    final r = recipients.value?.where((x) => x['id'] == widget.recipientId).firstOrNull;
    if (r == null) {
      return SettingsPage(title: l.tgRecipients, children: [
        if (recipients.isLoading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (recipients.hasError) TCard(child: Text(agentErrorText(l, recipients.error!))),
        if (recipients.hasValue) Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.tgGone))),
      ]);
    }
    final status = '${r['status']}';
    final subs = ((r['subscriptions'] as List?) ?? const []).cast<String>().toSet();
    final deliveries = ref.watch(telegramDeliveriesProvider((widget.hostId, widget.recipientId)));
    final feedNames = {for (final f in feeds) '${f['id']}': '${f['name']}'};
    final fmt = DateFormat('d MMM HH:mm', locale);
    return SettingsPage(title: recipientName(r), children: [
      const SizedBox(height: 12),
      TCard(
        child: Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: recipientStatusColor(t, status),
            child: Text(recipientName(r).characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(recipientName(r), style: tt.titleLarge),
              if (r['username'] != null) Text('@${r['username']}', style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
              Text(
                '${recipientStatusText(l, status)} · ${l.tgAddedAt(fmt.format(DateTime.parse('${r['addedAt']}').toLocal()))}',
                style: tt.bodySmall?.copyWith(color: recipientStatusColor(t, status)),
              ),
            ]),
          ),
        ]),
      ),
      GroupedSection(
        footer: switch (status) {
          'stopped' => l.tgStoppedHint,
          'unreachable' => l.tgUnreachableHint,
          _ => null,
        },
        children: [
          SwitchRow(
            title: l.tgReceive,
            subtitle: status == 'paused' ? l.tgStatusPaused : null,
            value: status == 'active',
            onChanged: (v) {
              if (_busy || status == 'stopped') return;
              _patch({'status': v ? 'active' : 'paused'});
            },
          ),
        ],
      ),
      if (feeds.isNotEmpty)
        GroupedSection(title: l.tgSubscriptions, children: [
          for (final f in feeds)
            SwitchRow(
              title: '${f['name']}',
              value: subs.contains(f['id']),
              onChanged: (v) {
                if (_busy) return;
                final next = {...subs};
                v ? next.add('${f['id']}') : next.remove('${f['id']}');
                _patch({'subscriptions': next.toList()});
              },
            ),
        ]),
      GroupedSection(title: l.tgRecentDeliveries, children: [
        ...deliveries.when(
          loading: () => [const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [GroupedRow(title: agentErrorText(l, e), showChevron: false)],
          data: (list) => list.isEmpty
              ? [GroupedRow(title: l.tgNoDeliveries, showChevron: false)]
              : [
                  for (final d in list.take(10))
                    GroupedRow(
                      title: d['test'] == true ? '${feedNames[d['feedId']] ?? l.tgFeed} · ${l.tgTest}' : feedNames['${d['feedId']}'] ?? l.tgFeed,
                      subtitle: '${deliveryStatusText(l, '${d['status']}')} · ${fmt.format(DateTime.parse('${d['at']}').toLocal())}',
                      icon: d['status'] == 'sent' ? LucideIcons.check : LucideIcons.x,
                      iconBackground: d['status'] == 'sent' ? t.success : t.danger,
                      showChevron: false,
                    ),
                ],
        ),
      ]),
      GroupedSection(children: [
        GroupedRow(
          title: l.tgSendTestMessage,
          icon: LucideIcons.messageSquare,
          iconBackground: telegramBlue,
          showChevron: false,
          onTap: _busy || status == 'stopped' ? null : () => _call(() => agentCall(ref, widget.hostId, 'POST', '/v1/telegram/recipients/${widget.recipientId}/test'), done: l.tgTestSent),
        ),
        GroupedRow(
          title: l.tgRecipientDelete,
          destructive: true,
          showChevron: false,
          onTap: () async {
            if (!await confirmDialog(context, message: l.tgRecipientDeleteConfirm(recipientName(r)), confirmLabel: l.commonDelete, destructive: true)) return;
            await _call(() => agentCall(ref, widget.hostId, 'DELETE', '/v1/telegram/recipients/${widget.recipientId}'));
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ]),
    ]);
  }
}

String deliveryStatusText(AppLocalizations l, String status) => switch (status) {
      'sent' => l.tgDeliverySent,
      'unreachable' => l.tgStatusUnreachable,
      _ => l.tgDeliveryFailed,
    };

// ───────────────────────── Feeds ─────────────────────────

class _FeedsSection extends ConsumerWidget {
  const _FeedsSection({required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = ref.watch(clockProvider)();
    final feeds = ref.watch(telegramFeedsProvider(hostId));
    final issues = ref.watch(telegramIssuesProvider((hostId, null))).value ?? const <Json>[];
    final list = feeds.value ?? const <Json>[];
    return GroupedSection(
      title: l.tgFeeds,
      footer: feeds.hasError ? agentErrorText(l, feeds.error!) : (list.isEmpty ? l.tgFeedsEmpty : l.tgFeedsHint),
      children: [
        for (final f in list)
          GroupedRow(
            title: '${f['name']}',
            subtitle: [
              feedScheduleSummary(l, locale, f, now),
              [
                if (f['running'] == true)
                  l.tgIssueResearching
                else if (issues.where((i) => i['feedId'] == f['id'] && i['kind'] != 'preview').firstOrNull case final last?)
                  l.tgLastIssue(issueStatusText(l, '${last['status']}')),
                l.tgRecipientCount(((f['recipientIds'] as List?) ?? const []).length),
              ].join(' · '),
            ].join('\n'),
            icon: LucideIcons.newspaper,
            iconBackground: f['enabled'] == true ? const Color(0xFFFF9F0A) : const Color(0xFF8E8E93),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FeedScreen(hostId: hostId, feedId: '${f['id']}'))),
          ),
        GroupedRow(title: l.tgFeedAdd, icon: LucideIcons.plus, iconBackground: t.accent, onTap: () => showFeedTemplateSheet(context, hostId: hostId)),
      ],
    );
  }
}
