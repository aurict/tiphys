// Client factories and providers for monitoring integrations.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/refresh.dart';
import '../../core/integrations/dozzle_client.dart';
import '../../core/integrations/grafana_client.dart';
import '../../core/integrations/http_json.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../system/agent_providers.dart';

final grafanaFactoryProvider = Provider<Future<GrafanaClient> Function(GrafanaConfig)>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  return (g) async => GrafanaClient(g.url, token: g.tokenRef == null ? null : await secrets.read(secretIdOf(g.tokenRef!)));
});

final dozzleFactoryProvider = Provider<Future<DozzleClient> Function(DozzleConfig)>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  return (d) async => DozzleClient(
        d.url,
        username: d.username,
        password: d.passwordRef == null ? null : await secrets.read(secretIdOf(d.passwordRef!)),
      );
});

/// Uptime Kuma bridge (via the agent) — monitor list, refreshed every 30 s.
final uptimeProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final u = ref.watch(profileProvider.select((p) => p.integrations.uptimeKuma));
  if (u == null) throw const IntegrationError('notConfigured');
  autoRefresh(ref, const Duration(seconds: 30));
  return withAgent(ref, u.viaHostId, (c) => c.get('/v1/uptime/monitors'));
});

/// Homepage services (via the agent).
final homepageProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final h = ref.watch(profileProvider.select((p) => p.integrations.homepage));
  if (h == null) throw const IntegrationError('notConfigured');
  return withAgent(ref, h.hostId, (c) => c.get('/v1/homepage'));
});

/// Grafana mini chart on the home screen: first series of the default dashboard's first time series panel.
final grafanaSparkProvider = FutureProvider.autoDispose<List<double>?>((ref) async {
  final g = ref.watch(profileProvider.select((p) => p.integrations.grafana.firstOrNull));
  if (g == null || g.defaultDashboardUid == null) return null;
  autoRefresh(ref, const Duration(seconds: 60));
  final c = await ref.read(grafanaFactoryProvider)(g);
  try {
    final d = await c.dashboard(g.defaultDashboardUid!);
    final vars = GrafanaClient.variables(d);
    for (final v in vars) {
      await c.loadOptions(v);
    }
    final panel = GrafanaClient.panels(d).where((p) => p.type == 'timeseries').firstOrNull;
    if (panel == null) return null;
    final data = await c.query(panel, vars, from: g.defaultRange, maxDataPoints: 30);
    final s = data.series.firstOrNull;
    return s?.values.whereType<double>().toList();
  } finally {
    c.close();
  }
});

/// Dozzle card on the home screen: container counts.
final dozzleSummaryProvider = FutureProvider.autoDispose<(int, int)?>((ref) async {
  final d = ref.watch(profileProvider.select((p) => p.integrations.dozzle.firstOrNull));
  if (d == null) return null;
  autoRefresh(ref, const Duration(seconds: 60));
  final c = await ref.read(dozzleFactoryProvider)(d);
  try {
    final cs = await c.containers();
    return (cs.where((x) => x.running).length, cs.where((x) => !x.running || x.health == 'unhealthy').length);
  } finally {
    c.close();
  }
});

String integrationErrorText(AppLocalizations l, Object e) {
  if (e is IntegrationError) {
    return switch (e.code) {
      'notConfigured' => l.integrationNotSet,
      'net.unreachable' => l.sshUnreachable,
      'net.timeout' => l.sshTimeout,
      'net.tls' => l.agentTls,
      'http.401' || 'http.403' => l.integrationAuthFailed,
      _ => '${l.commonError} (${e.code})',
    };
  }
  return agentErrorText(l, e);
}
