// Deep links (notifications) name a host by id or by the agent's host name. When that doesn't point at exactly one
// host, the screen asks instead of guessing: acting on (or revealing secrets of) the wrong host is worse than one tap.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';

/// Thrown when a link's host hint matched no single host and the item was found on more than one candidate.
class AmbiguousHostError implements Exception {
  const AmbiguousHostError(this.hosts);
  final List<Host> hosts;
}

/// "Which host?" — a hint line and one row per candidate; [onPick] opens the item on that host.
class HostPicker extends StatelessWidget {
  const HostPicker({super.key, required this.hosts, required this.onPick});
  final List<Host> hosts;
  final ValueChanged<Host> onPick;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(hosts.isEmpty ? l.hostPickNone : l.hostPickHint, style: Theme.of(context).textTheme.bodyMedium),
      ),
      for (final h in hosts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TCard(
            onTap: () => onPick(h),
            semanticLabel: h.name,
            child: Row(children: [
              Icon(LucideIcons.server, size: 20, color: t.hostColor(hexColor(h.color))),
              const SizedBox(width: 12),
              Expanded(child: Text(h.name, style: Theme.of(context).textTheme.titleMedium)),
              const Icon(LucideIcons.chevronRight, size: 18),
            ]),
          ),
        ),
    ]);
  }
}

/// The host a screen acts on, shown prominently (an icon and the name in the host's color).
class HostBadge extends StatelessWidget {
  const HostBadge(this.host, {super.key});
  final Host host;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = t.hostColor(hexColor(host.color));
    return Row(children: [
      Icon(LucideIcons.server, size: 16, color: c),
      const SizedBox(width: 6),
      Flexible(child: Text(host.name, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: t.text, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
    ]);
  }
}
