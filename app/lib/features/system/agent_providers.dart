// Ajan verileri için sağlayıcılar (host başına). Metrikler 5 sn'de bir yenilenir.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/refresh.dart';
import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';

/// Testlerde değiştirilir.
final agentClientFactoryProvider = Provider<Future<AgentClient> Function(Host)>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  return (h) => AgentClient.forHost(h, secrets);
});

Future<T> withAgent<T>(Ref ref, String hostId, Future<T> Function(AgentClient c) body) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await body(c);
  } finally {
    c.close();
  }
}

/// Bir kerelik çağrı (butonlar için).
Future<dynamic> agentCall(WidgetRef ref, String hostId, String method, String path, [Object? body]) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return await c.request(method, path, body: body);
  } finally {
    c.close();
  }
}

final systemProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 5));
  return withAgent(ref, hostId, (c) => c.get('/v1/system'));
});

final servicesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, (String, String)>((ref, key) async {
  final (hostId, scope) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/services/$scope'));
  return (j['units'] as List).cast<Map<String, dynamic>>();
});

final containersProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 15));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/docker/containers'));
  return (j['containers'] as List).cast<Map<String, dynamic>>();
});

/// Ajanın kendi durumu: sürüm, açık kalma süresi, bellek, beklenmedik yeniden başlamalar (0.3.0+).
final agentStatusProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 30));
  return withAgent(ref, hostId, (c) => c.get('/v1/agent/status'));
});

/// Token'sız sağlık kontrolü (testlerde değiştirilir).
final agentHealthFnProvider = Provider<Future<Map<String, dynamic>> Function(String url)>((ref) => AgentClient.health);

final healthProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  final h = ref.read(profileProvider).host(hostId);
  if (h?.agent == null) throw const AgentError('agent.notConfigured');
  return ref.read(agentHealthFnProvider)(h!.agent!.url);
});

/// Ana ekran için PC metrikleri (Claude ajanı hostu ya da ajanlı ilk host).
final homeMetricsProvider = FutureProvider.autoDispose<(double, double)?>((ref) async {
  final p = ref.watch(profileProvider);
  final host = p.host(p.claude.agentHostId) ?? p.hosts.where((h) => h.agent != null).firstOrNull;
  if (host == null) return null;
  final s = await ref.watch(systemProvider(host.id).future);
  final cpu = ((s['cpu'] as Map)['loadPercent'] as num).toDouble() / 100;
  final mem = s['memory'] as Map;
  return (cpu, (mem['usedBytes'] as num) / (mem['totalBytes'] as num));
});

String agentErrorText(AppLocalizations l, Object e) {
  if (e is! AgentError) return '${l.commonError}: $e';
  return switch (e.code) {
    'net.unreachable' => l.agentUnreachable,
    'net.timeout' => l.sshTimeout,
    'net.tls' => l.agentTls,
    'agent.auth.missingToken' || 'agent.auth.invalidToken' => l.agentBadToken,
    'agent.auth.tailnetUserNotAllowed' => l.agentWrongTailnetUser,
    'agent.tokenMissing' => l.secretMissing('${e.params['id']}'),
    'agent.notConfigured' => l.hostAgentNone,
    'agent.services.permissionDenied' => l.agentPermissionDenied,
    'agent.power.confirmRequired' => l.commonConfirm,
    'agent.route.notFound' => l.agentFeatureOff,
    'agent.claude.notGitRepo' => l.gitNotRepo,
    'agent.claude.terminalBusy' => l.claudeTerminalBusy,
    'agent.claude.terminalNotFound' => l.claudeTerminalGone,
    'agent.claude.terminalStuck' => l.claudeTerminalStuck,
    'agent.claude.historyNotFound' || 'agent.claude.session.notFound' => l.claudeSessionGone,
    'agent.path.notAllowed' || 'agent.claude.folderNotAllowed' => l.agentPathNotAllowed,
    'agent.desktop.noDisplay' => l.agentNoDisplay,
    'agent.ports.alreadyPublic' => l.agentPortPublic,
    'agent.processes.permissionDenied' => l.agentPermissionDenied,
    _ => '${l.commonError} (${e.code})',
  };
}

