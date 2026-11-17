// Host page › Research (agent feature "research", the PC): connect a Telegram agent (atlas) to this PC, the service
// tokens other agents use, and the recent research jobs. The connect flow creates a service token on the PC and
// hands it straight to the Telegram agent's config; the token lives only in memory during the transfer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart' show Host;
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'telegram_data.dart';
import 'telegram_screen.dart' show telegramBlue;

final serviceTokensProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/service-tokens'));
  return [for (final x in (j['tokens'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
});

final researchJobsProvider = FutureProvider.autoDispose.family<List<Json>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 15));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/research/jobs'));
  return [for (final x in (j['jobs'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
});

/// Outcome of [connectResearch].
class ResearchLink {
  const ResearchLink({required this.tokenId, required this.wakeHostId, required this.reachable});
  final String tokenId;
  final String? wakeHostId;

  /// The Telegram agent's view of the PC (GET /v1/telegram/status → research.reachable); null if unknown.
  final bool? reachable;
}

/// Wake target for [pc] on the Telegram agent: its config has a `wake.targets` entry for the PC's host id, or the
/// profile wakes the PC through that agent (`wake.viaHostId`).
String? researchWakeTarget(Map<String, dynamic> tgConfig, Host pc, Host tg) {
  final targets = ((tgConfig['wake'] as Map?)?['targets'] as List?) ?? const [];
  final known = targets.any((x) => x is Map && x['hostId'] == pc.id);
  return known || pc.wake?.viaHostId == tg.id ? pc.id : null;
}

/// Connects the Telegram agent [tg] to the research PC [pc]:
/// 1. read the Telegram agent's config (wake targets),
/// 2. create a service token on the PC (`POST /v1/service-tokens {name: <tg name>, scopes: [research]}`),
/// 3. store `research: {url, token, wakeHostId}` on the Telegram agent (`PATCH /v1/config`); if that fails the new
///    token is revoked again,
/// 4. check the link (`GET /v1/telegram/status`).
/// The token is never returned, logged or stored on the phone.
Future<ResearchLink> connectResearch({required Host pc, required Host tg, required AgentClient pcClient, required AgentClient tgClient}) async {
  final cfg = await tgClient.get('/v1/config');
  final wake = researchWakeTarget(cfg, pc, tg);
  final created = await pcClient.post('/v1/service-tokens', {
    'name': tg.name,
    'scopes': ['research'],
  }) as Map;
  final tokenId = '${(created['serviceToken'] as Map)['id']}';
  try {
    await tgClient.patch('/v1/config', {
      'research': {'url': pc.agent!.url, 'token': created['token'] as String, 'wakeHostId': wake},
    });
  } catch (_) {
    try {
      await pcClient.delete('/v1/service-tokens/$tokenId');
    } catch (_) {
      // The token stays listed on the PC; the user can revoke it there.
    }
    rethrow;
  }
  bool? reachable;
  try {
    final st = await tgClient.get('/v1/telegram/status');
    reachable = (st['research'] as Map?)?['reachable'] as bool?;
  } catch (_) {
    // Telegram feature off or the agent busy: the link is stored anyway.
  }
  return ResearchLink(tokenId: tokenId, wakeHostId: wake, reachable: reachable);
}

class ResearchScreen extends ConsumerStatefulWidget {
  const ResearchScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<ResearchScreen> createState() => _ResearchScreenState();
}

class _ResearchScreenState extends ConsumerState<ResearchScreen> {
  bool _busy = false;
  Host? _tg;

  /// Last connect / test result: (ok, text).
  (bool, String)? _result;

  Future<Host?> _pickTelegramHost() async {
    final l = AppLocalizations.of(context);
    final hosts = (await ref.read(hostsWithFeatureProvider('telegram').future)).where((h) => h.id != widget.hostId).toList();
    if (!mounted) return null;
    if (hosts.isEmpty) {
      toast(context, l.researchNoTelegramHost);
      return null;
    }
    return showModalBottomSheet<Host>(
      context: context,
      useRootNavigator: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.researchPickHost, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 10),
            GroupedSection(children: [
              for (final h in hosts)
                GroupedRow(title: h.name, subtitle: h.agent?.url, icon: LucideIcons.server, iconBackground: telegramBlue, onTap: () => Navigator.pop(c, h)),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _connect() async {
    final l = AppLocalizations.of(context);
    final pc = ref.read(profileProvider).host(widget.hostId);
    final tg = await _pickTelegramHost();
    if (pc == null || tg == null || !mounted) return;
    if (!await confirmDialog(context, message: l.researchConnectConfirm(tg.name, pc.name), confirmLabel: l.researchConnect)) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final factory = ref.read(agentClientFactoryProvider);
    AgentClient? pcClient, tgClient;
    try {
      pcClient = await factory(pc);
      tgClient = await factory(tg);
      final link = await connectResearch(pc: pc, tg: tg, pcClient: pcClient, tgClient: tgClient);
      _tg = tg;
      _result = (
        link.reachable != false,
        [
          l.researchConnected(tg.name),
          link.reachable == null ? l.researchReachUnknown : (link.reachable! ? l.tgResearchReachable : l.tgResearchUnreachable),
          if (link.wakeHostId != null) l.tgResearchWake,
        ].join(' · '),
      );
      ref.invalidate(serviceTokensProvider(widget.hostId));
    } catch (e) {
      _result = (false, l.researchConnectFailed(agentErrorText(l, e)));
    } finally {
      pcClient?.close();
      tgClient?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final l = AppLocalizations.of(context);
    final tg = _tg ?? await _pickTelegramHost();
    if (tg == null || !mounted) return;
    setState(() {
      _busy = true;
      _tg = tg;
    });
    try {
      final st = await agentCall(ref, tg.id, 'GET', '/v1/telegram/status') as Map;
      final r = (st['research'] as Map?) ?? const {};
      final pcUrl = ref.read(profileProvider).host(widget.hostId)?.agent?.url;
      _result = r['configured'] != true
          ? (false, l.tgResearchNotSet)
          : r['url'] != pcUrl
              ? (false, l.researchOtherPc(tg.name, '${r['url']}'))
              : (r['reachable'] == true, '${tg.name}: ${r['reachable'] == true ? l.tgResearchReachable : l.tgResearchUnreachable}');
    } catch (e) {
      _result = (false, agentErrorText(l, e));
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
    final fmt = DateFormat('d MMM HH:mm', locale);
    final host = ref.watch(profileProvider).host(widget.hostId);
    // Kept alive for the host picker of the connect / test flows.
    ref.watch(hostsWithFeatureProvider('telegram'));
    final tokens = ref.watch(serviceTokensProvider(widget.hostId));
    final jobs = ref.watch(researchJobsProvider(widget.hostId));
    final tokenNames = {for (final x in tokens.value ?? const <Json>[]) 'service:${x['id']}': '${x['name']}'};
    return SettingsPage(title: '${l.researchTitle} · ${host?.name ?? widget.hostId}', children: [
      GroupedSection(title: l.researchConnectSection, footer: l.researchConnectHint, children: [
        GroupedRow(
          title: l.researchConnect,
          icon: LucideIcons.link,
          iconBackground: telegramBlue,
          onTap: _busy ? null : _connect,
          trailing: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
        ),
        GroupedRow(title: l.researchTest, icon: LucideIcons.activity, iconBackground: t.success, showChevron: false, onTap: _busy ? null : _test),
      ]),
      if (_result != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TCard(
            borderColor: _result!.$1 ? t.success : t.danger,
            child: Row(children: [
              Icon(_result!.$1 ? LucideIcons.circleCheck : LucideIcons.circleAlert, color: _result!.$1 ? t.success : t.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(_result!.$2, style: tt.bodyMedium)),
            ]),
          ),
        ),
      GroupedSection(
        title: l.researchTokens,
        footer: tokens.hasError ? agentErrorText(l, tokens.error!) : l.researchTokensHint,
        children: [
          if ((tokens.value ?? const []).isEmpty && !tokens.hasError) GroupedRow(title: l.researchTokensEmpty, showChevron: false),
          for (final x in tokens.value ?? const <Json>[])
            GroupedRow(
              title: '${x['name']}',
              subtitle: [
                ((x['scopes'] as List?) ?? const []).join(', '),
                l.researchTokenCreated(fmt.format(DateTime.parse('${x['createdAt']}').toLocal())),
                if (x['lastUsedAt'] != null) l.researchTokenUsed(fmt.format(DateTime.parse('${x['lastUsedAt']}').toLocal())),
              ].join(' · '),
              icon: LucideIcons.keyRound,
              iconBackground: const Color(0xFF6C6C70),
              trailing: IconButton(
                tooltip: l.agentRevoke,
                icon: Icon(LucideIcons.trash2, color: t.danger, size: 20),
                onPressed: () async {
                  if (!await confirmDialog(context, message: l.researchTokenRevokeConfirm('${x['name']}'), confirmLabel: l.agentRevoke, destructive: true)) return;
                  try {
                    await agentCall(ref, widget.hostId, 'DELETE', '/v1/service-tokens/${x['id']}');
                    ref.invalidate(serviceTokensProvider(widget.hostId));
                  } catch (e) {
                    if (context.mounted) toast(context, agentErrorText(l, e));
                  }
                },
              ),
            ),
        ],
      ),
      GroupedSection(
        title: l.researchJobs,
        footer: jobs.hasError ? agentErrorText(l, jobs.error!) : l.researchJobsHint,
        children: [
          if ((jobs.value ?? const []).isEmpty && !jobs.hasError) GroupedRow(title: l.researchJobsEmpty, showChevron: false),
          for (final j in (jobs.value ?? const <Json>[]).take(20))
            GroupedRow(
              title: '${j['topic']}',
              subtitle: [
                researchJobStatusText(l, '${j['status']}'),
                fmt.format(DateTime.parse('${j['createdAt']}').toLocal()),
                if (secondsBetween(j['startedAt'], j['finishedAt']) case final s?) shortDuration(l, s),
                if (j['itemCount'] != null) l.tgItemCount((j['itemCount'] as num).toInt()),
                ?tokenNames['${j['requestedBy']}'],
                if (j['error'] is Map) agentErrorText(l, AgentError('${(j['error'] as Map)['code']}', Map<String, dynamic>.from(((j['error'] as Map)['params'] as Map?) ?? const {}))),
              ].join(' · '),
              icon: LucideIcons.search,
              iconBackground: switch (j['status']) { 'done' => t.success, 'failed' => t.danger, _ => t.accent },
              showChevron: false,
              trailing: j['status'] == 'queued' || j['status'] == 'running'
                  ? IconButton(
                      tooltip: l.researchCancel,
                      icon: Icon(LucideIcons.circleStop, color: t.danger, size: 20),
                      onPressed: () async {
                        try {
                          await agentCall(ref, widget.hostId, 'DELETE', '/v1/research/jobs/${j['id']}');
                          ref.invalidate(researchJobsProvider(widget.hostId));
                        } catch (e) {
                          if (context.mounted) toast(context, agentErrorText(l, e));
                        }
                      },
                    )
                  : null,
            ),
        ],
      ),
    ]);
  }
}

String researchJobStatusText(AppLocalizations l, String status) => switch (status) {
      'queued' => l.researchQueued,
      'running' => l.researchRunning,
      'done' => l.researchDone,
      _ => l.researchFailed,
    };
