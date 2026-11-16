// Live data shown on the home screen. Each source is wired up in its own phase;
// an unconnected source returns null and the card shows the "not connected" state.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/refresh.dart';
import '../../state/providers.dart';
import '../../widgets/painters.dart';
import '../claude/claude_screen.dart';
import '../monitoring/providers.dart';
import '../system/agent_providers.dart';
import '../terminal/sessions.dart';

class LogLine {
  const LogLine(this.source, this.text, {this.level = 'info'});
  final String source;
  final String text;
  final String level; // info | warn | error
}

class HomeData {
  const HomeData({
    this.hostStates = const {},
    this.cpu,
    this.ram,
    this.claudeSessions,
    this.claudeWaiting = 0,
    this.grafanaSpark,
    this.dozzleLines,
    this.terminalTabs = 0,
  });

  final Map<String, HostState> hostStates;
  final double? cpu; // 0..1
  final double? ram; // 0..1
  final int? claudeSessions;
  final int claudeWaiting;
  final List<double>? grafanaSpark;
  final List<LogLine>? dozzleLines;
  final int terminalTabs;
}

/// For hosts without an agent: is the SSH port open (replaced in tests).
final tcpProbeProvider = Provider<Future<bool> Function(String host, int port)>((ref) => (host, port) async {
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
        s.destroy();
        return true;
      } catch (_) {
        return false;
      }
    });

/// Is the host up: first the agent's tokenless health endpoint (no pairing needed), otherwise the SSH port.
final hostStateProvider = FutureProvider.autoDispose.family<HostState, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  final h = ref.watch(profileProvider.select((p) => p.host(hostId)));
  if (h == null) return HostState.unknown;
  if (h.agent != null) {
    try {
      await ref.read(agentHealthFnProvider)(h.agent!.url).timeout(const Duration(seconds: 8));
      return HostState.online;
    } catch (_) {
      // the agent may be down; check whether the host is still reachable over SSH
    }
  }
  if (h.ssh != null && await ref.read(tcpProbeProvider)(h.address, h.ssh!.port)) return HostState.online;
  return HostState.offline;
});

/// Combination of the sources. As phases progress, the pieces here are wired to real providers.
final homeDataProvider = Provider<HomeData>((ref) {
  final m = ref.watch(homeMetricsProvider).value;
  final claude = ref.watch(claudeSessionsProvider).value;
  final live = (claude?['live'] as List?)?.cast<Map>();
  final terminal = (claude?['terminal'] as List?) ?? const [];
  return HomeData(
    hostStates: {
      for (final h in ref.watch(profileProvider.select((p) => p.hosts))) h.id: ref.watch(hostStateProvider(h.id)).value ?? HostState.unknown,
    },
    cpu: m?.$1,
    ram: m?.$2,
    claudeSessions: live == null ? null : live.length + terminal.length,
    claudeWaiting: live?.where((s) => s['status'] == 'waiting').length ?? 0,
    grafanaSpark: ref.watch(grafanaSparkProvider).value,
    dozzleLines: switch (ref.watch(dozzleSummaryProvider).value) {
      (final up, final bad) => [LogLine('$up', 'running'), if (bad > 0) LogLine('$bad', 'stopped', level: 'warn')],
      null => null,
    },
    terminalTabs: ref.watch(terminalSessionsProvider).length,
  );
});
