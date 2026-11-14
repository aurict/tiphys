// Sistem › Ajan: ajanın sürümü (geride kaldıysa uyarı), açık kalma süresi, bellek ve beklenmedik yeniden başlamalar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import 'agent_providers.dart';

String _mb(num bytes) => bytes >= 1024 * 1024 * 1024 ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB' : '${(bytes / (1024 * 1024)).round()} MB';

String _uptime(AppLocalizations l, int secs) {
  final d = Duration(seconds: secs);
  if (d.inDays > 0) return l.agentUptimeDays(d.inDays, d.inHours % 24);
  if (d.inHours > 0) return l.agentUptimeHours(d.inHours, d.inMinutes % 60);
  return l.agentUptimeMinutes(d.inMinutes);
}

class AgentSection extends ConsumerWidget {
  const AgentSection({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final health = ref.watch(healthProvider(host.id)).value;
    final status = ref.watch(agentStatusProvider(host.id));
    final version = (status.value?['version'] ?? health?['version']) as String?;
    final outdated = agentOutdated(version);
    final st = status.value;
    final restarts = (st?['unexpectedRestarts24h'] as num?)?.toInt() ?? 0;
    return GroupedSection(
      title: l.agentSection,
      footer: outdated ? l.agentOutdatedHint(kExpectedAgentVersion) : null,
      children: [
        GroupedRow(
          title: l.agentVersion,
          icon: LucideIcons.package,
          iconBackground: outdated ? t.warning : const Color(0xFF6C6C70),
          trailingText: version == null ? '—' : (outdated ? l.agentOutdated(version) : version),
          showChevron: false,
        ),
        if (st != null) ...[
          GroupedRow(
            title: l.agentUptime,
            icon: LucideIcons.clock,
            iconBackground: const Color(0xFF6C6C70),
            trailingText: _uptime(l, (st['uptimeSeconds'] as num).toInt()),
            showChevron: false,
          ),
          GroupedRow(
            title: l.agentMemory,
            subtitle: l.agentMemoryValue(_mb(st['memory']['agentBytes'] as num), _mb(st['memory']['childrenBytes'] as num)),
            icon: LucideIcons.memoryStick,
            iconBackground: const Color(0xFF6C6C70),
            showChevron: false,
          ),
          GroupedRow(
            title: l.agentRestarts,
            subtitle: l.agentRestartsWindow,
            icon: restarts > 0 ? LucideIcons.triangleAlert : LucideIcons.shieldCheck,
            iconBackground: restarts > 0 ? t.danger : t.success,
            trailingText: '$restarts',
            showChevron: false,
          ),
        ],
      ],
    );
  }
}
