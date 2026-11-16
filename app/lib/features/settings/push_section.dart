// Settings › Notifications › This phone: UnifiedPush distributor, registration state, test, site alerts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/push/push_service.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';

/// Replaced with the real instance in main.dart; absent in tests (the section is hidden).
final pushServiceProvider = Provider<PushService?>((ref) => null);

class PushSection extends ConsumerStatefulWidget {
  const PushSection({super.key});
  @override
  ConsumerState<PushSection> createState() => _PushSectionState();
}

class _PushSectionState extends ConsumerState<PushSection> {
  String? _distributor;
  List<String> _available = const [];
  List<String>? _registered;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final p = ref.read(pushServiceProvider);
    if (p == null) return;
    final d = await p.distributor();
    final a = await p.distributors();
    final ep = await p.endpoint();
    List<String>? reg;
    if (ep != null) reg = await p.registerWithAgents();
    if (mounted) {
      setState(() {
        _distributor = d;
        _available = a;
        _registered = reg;
      });
    }
  }

  Future<void> _enable() async {
    final l = AppLocalizations.of(context);
    final p = ref.read(pushServiceProvider)!;
    var pick = _available.length == 1 ? _available.first : null;
    if (pick == null && _available.length > 1) {
      pick = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(l.pushChooseDistributor),
          children: [for (final d in _available) SimpleDialogOption(onPressed: () => Navigator.pop(c, d), child: Text(d))],
        ),
      );
    }
    if (pick == null) return;
    setState(() => _busy = true);
    await p.enable(pick);
    // The endpoint arrives within a few seconds (onNewEndpoint) and is registered with the agents.
    await Future<void>.delayed(const Duration(seconds: 3));
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    final l = AppLocalizations.of(context);
    for (final h in ref.read(profileProvider).hosts.where((h) => h.agent != null)) {
      try {
        await agentCall(ref, h.id, 'POST', '/v1/push/test');
      } catch (e) {
        if (mounted) toast(context, '${h.name}: ${agentErrorText(l, e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final push = ref.watch(pushServiceProvider);
    if (push == null) return const SizedBox.shrink();
    final ntfy = ref.watch(profileProvider.select((p) => p.integrations.ntfy));
    final agentHosts = ref.watch(profileProvider.select((p) => p.hosts)).where((h) => h.agent != null);
    final on = _distributor != null;
    // Agents the registration couldn't reach can't send that host's notifications (Claude, alerts) to the phone.
    final missing = on && _registered != null ? [for (final h in agentHosts) if (!_registered!.contains(h.id)) h.name] : const <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GroupedSection(
        title: l.pushThisPhone,
        footer: _available.isEmpty
            ? l.pushNoDistributor
            : !on
                ? l.pushSetupHint
                : missing.isNotEmpty
                    ? l.pushNotRegistered(missing.join(', '))
                    : l.pushBatteryHint,
        children: [
          GroupedRow(
            title: on ? l.pushEnabled : l.pushEnable,
            subtitle: on ? '$_distributor${_registered == null ? '' : ' · ${l.pushRegistered(_registered!.join(', '))}'}' : null,
            icon: on ? LucideIcons.bellRing : LucideIcons.bellOff,
            iconBackground: on ? t.success : const Color(0xFF6C6C70),
            onTap: _busy || _available.isEmpty ? null : (on ? _refresh : _enable),
            trailing: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          ),
          if (on) GroupedRow(title: l.pushSendTest, icon: LucideIcons.send, iconBackground: t.accent, onTap: _test),
          if (on)
            GroupedRow(
              title: l.pushDisable,
              destructive: true,
              showChevron: false,
              onTap: () async {
                await push.disable();
                await _refresh();
              },
            ),
        ],
      ),
      if (ntfy != null && ntfy.topics.isNotEmpty)
        GroupedSection(footer: l.pushSitesTopic, children: [
          for (final topic in ntfy.topics)
            GroupedRow(
              title: '${l.pushOpenNtfy}: $topic',
              icon: LucideIcons.activity,
              iconBackground: t.success,
              external: true,
              onTap: () {
                final u = Uri.parse(ntfy.url);
                launchUrl(Uri.parse('ntfy://${u.host}${u.hasPort ? ':${u.port}' : ''}/$topic'), mode: LaunchMode.externalApplication);
              },
            ),
        ]),
    ]);
  }
}
