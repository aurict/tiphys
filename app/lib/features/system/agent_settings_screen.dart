// Ajanın kendi ayarları (agent.json), telefondan: özellikler, izinli klasörler, Homepage dosyası,
// Uptime Kuma girişi, eşleşmiş cihazlar ve "her şeyi kilitle".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'agent_providers.dart';

final agentConfigProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) {
  return withAgent(ref, hostId, (c) => c.get('/v1/config'));
});

const agentFeatures = ['system', 'services', 'docker', 'power', 'git', 'desktop', 'ports', 'transcribe', 'alerts', 'homepage', 'claude', 'uptime', 'wake', 'watch'];

class AgentSettingsScreen extends ConsumerStatefulWidget {
  const AgentSettingsScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<AgentSettingsScreen> createState() => _AgentSettingsState();
}

class _AgentSettingsState extends ConsumerState<AgentSettingsScreen> {
  Map<String, bool>? _features;
  final _roots = TextEditingController();
  final _hpPath = TextEditingController();
  final _ukUrl = TextEditingController();
  final _ukUser = TextEditingController();
  final _ukPass = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  final _diskPct = TextEditingController();
  final _alertEvery = TextEditingController();
  bool _failedServices = true;
  final _gfUrl = TextEditingController();
  final _gfToken = TextEditingController();
  final _gfDs = TextEditingController();
  bool _gfHasToken = false;

  @override
  void dispose() {
    for (final c in [_roots, _hpPath, _ukUrl, _ukUser, _ukPass, _diskPct, _alertEvery, _gfUrl, _gfToken, _gfDs]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> c) {
    if (_loaded) return;
    _loaded = true;
    _features = Map<String, bool>.from(c['features'] as Map);
    _roots.text = (c['allowedRoots'] as List).join('\n');
    _hpPath.text = (c['homepage'] as Map)['servicesPath'] as String;
    final uk = c['uptimeKuma'] as Map?;
    _ukUrl.text = uk?['url'] as String? ?? '';
    _ukUser.text = uk?['username'] as String? ?? '';
    final al = (c['alerts'] as Map?) ?? const {};
    _diskPct.text = '${al['diskFullPercent'] ?? 90}';
    _alertEvery.text = '${al['intervalSeconds'] ?? 300}';
    _failedServices = al['failedServices'] as bool? ?? true;
    final gf = al['grafana'] as Map?;
    _gfUrl.text = gf?['url'] as String? ?? '';
    _gfDs.text = ((gf?['datasourceUids'] as List?) ?? const []).join(', ');
    _gfHasToken = gf?['hasToken'] == true;
  }

  /// Profildeki ilk Grafana tanımının adresini ve token'ını (kasadan) alanlara kopyalar.
  Future<void> _useProfileGrafana() async {
    final g = ref.read(profileProvider).integrations.grafana.firstOrNull;
    if (g == null) return;
    _gfUrl.text = g.url;
    final ref0 = g.tokenRef;
    if (ref0 != null) _gfToken.text = await ref.read(secretStoreProvider).read(secretIdOf(ref0)) ?? '';
    setState(() {});
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'features': _features,
        'allowedRoots': _roots.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        'homepage': {'servicesPath': _hpPath.text.trim(), 'checkTimeoutMs': 5000},
        if (_ukUrl.text.trim().isNotEmpty)
          'uptimeKuma': {'url': _ukUrl.text.trim(), 'username': _ukUser.text.trim(), if (_ukPass.text.isNotEmpty) 'password': _ukPass.text},
        'alerts': {
          'intervalSeconds': int.tryParse(_alertEvery.text) ?? 300,
          'diskFullPercent': int.tryParse(_diskPct.text) ?? 90,
          'failedServices': _failedServices,
          'grafana': _gfUrl.text.trim().isEmpty
              ? null
              : {
                  'url': _gfUrl.text.trim(),
                  if (_gfToken.text.trim().isNotEmpty) 'token': _gfToken.text.trim(),
                  'datasourceUids': _gfDs.text.split(RegExp(r'[,\s]+')).where((x) => x.isNotEmpty).toList(),
                },
        },
      };
      final res = await agentCall(ref, widget.hostId, 'PATCH', '/v1/config', body) as Map;
      // Ajan ayarlarının kopyası profile de yazılır (dışa aktarmada yer alsın).
      final copy = Map<String, dynamic>.from(res['config'] as Map)..remove('devices')..remove('push');
      await ref.read(profileProvider.notifier).update((p) => p.copyWith(agentConfigs: {...p.agentConfigs, widget.hostId: copy}));
      ref.invalidate(agentConfigProvider(widget.hostId));
      if (!mounted) return;
      toast(context, res['restartRequired'] == true ? l.agentRestartRequired : l.systemDone);
      context.pop();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    final cfg = ref.watch(agentConfigProvider(widget.hostId));
    return SettingsPage(
      title: '${l.hostAgent} · ${host?.name ?? widget.hostId}',
      onSave: _loaded ? _save : null,
      saving: _saving,
      children: [
        cfg.when(
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
          data: (c) {
            _fill(c);
            final devices = (c['devices'] as List).cast<Map>();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              GroupedSection(title: l.agentFeatures, footer: l.agentRestartHint, children: [
                for (final f in agentFeatures)
                  SwitchRow(
                    title: agentFeatureName(l, f),
                    value: _features![f] ?? false,
                    onChanged: (v) => setState(() => _features![f] = v),
                  ),
              ]),
              FieldCard(title: l.agentAllowedRoots, children: [
                TField(controller: _roots, label: l.agentAllowedRoots, helper: l.agentAllowedRootsHint, mono: true, maxLines: 4),
              ]),
              FieldCard(title: 'Homepage', children: [TField(controller: _hpPath, label: l.integrationServicesFile, mono: true)]),
              FieldCard(title: 'Uptime Kuma', children: [
                TField(controller: _ukUrl, label: 'URL', hint: 'http://127.0.0.1:3001', mono: true),
                TField(controller: _ukUser, label: l.hostSshUser),
                TField(
                  controller: _ukPass,
                  label: l.hostSshPassword,
                  obscure: true,
                  helper: (c['uptimeKuma'] as Map?)?['hasPassword'] == true ? l.secretStoredSafely : null,
                ),
              ]),
              if (_features!['alerts'] == true) ...[
                FieldCard(title: l.agentAlerts, children: [
                  TField(controller: _diskPct, label: l.agentAlertsDiskPercent, keyboardType: TextInputType.number, validator: intV(50, 100)),
                  TField(controller: _alertEvery, label: l.agentAlertsInterval, keyboardType: TextInputType.number, validator: intV(30, 86400)),
                ]),
                GroupedSection(children: [
                  SwitchRow(title: l.agentAlertsFailedServices, value: _failedServices, onChanged: (v) => setState(() => _failedServices = v)),
                ]),
                FieldCard(title: l.agentAlertsGrafana, children: [
                  TField(controller: _gfUrl, label: 'URL', hint: 'https://…:3030', mono: true),
                  TField(controller: _gfToken, label: l.integrationServiceAccountToken, obscure: true, helper: _gfHasToken ? l.secretStoredSafely : null),
                  TField(controller: _gfDs, label: l.agentAlertsDatasources, hint: 'prom', mono: true, helper: l.agentAlertsDatasourcesHint),
                ]),
                if (ref.watch(profileProvider).integrations.grafana.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(onPressed: _useProfileGrafana, icon: const Icon(LucideIcons.copy, size: 16), label: Text(l.agentAlertsUseProfileGrafana)),
                  ),
              ],
              GroupedSection(title: l.agentDevices, children: [
                for (final d in devices)
                  GroupedRow(
                    title: '${d['name']}',
                    subtitle: '${d['id']}',
                    icon: LucideIcons.smartphone,
                    iconBackground: t.accent,
                    trailing: IconButton(
                      tooltip: l.agentRevoke,
                      icon: Icon(LucideIcons.trash2, color: t.danger, size: 20),
                      onPressed: () async {
                        if (!await confirmDialog(context, message: l.agentRevokeConfirm('${d['name']}'), confirmLabel: l.agentRevoke, destructive: true)) return;
                        try {
                          await agentCall(ref, widget.hostId, 'DELETE', '/v1/devices/${d['id']}');
                          ref.invalidate(agentConfigProvider(widget.hostId));
                        } catch (e) {
                          if (context.mounted) toast(context, agentErrorText(l, e));
                        }
                      },
                    ),
                  ),
              ]),
              const SizedBox(height: 18),
              GroupedSection(footer: l.agentLockAllHint, children: [
                GroupedRow(
                  title: l.agentLockAll,
                  destructive: true,
                  showChevron: false,
                  onTap: () async {
                    if (!await confirmDialog(context, message: l.agentLockAllConfirm, confirmLabel: l.agentLockAll, destructive: true)) return;
                    try {
                      await agentCall(ref, widget.hostId, 'POST', '/v1/devices/revoke-all', {'confirm': true});
                      if (context.mounted) toast(context, l.systemDone);
                    } catch (e) {
                      if (context.mounted) toast(context, agentErrorText(l, e));
                    }
                  },
                ),
              ]),
            ]);
          },
        ),
      ],
    );
  }
}

String agentFeatureName(AppLocalizations l, String f) => switch (f) {
      'system' => l.agentFeatSystem,
      'services' => l.agentFeatServices,
      'docker' => 'Docker',
      'power' => l.systemPower,
      'homepage' => 'Homepage',
      'claude' => 'Claude',
      'uptime' => 'Uptime Kuma',
      'wake' => 'Wake-on-LAN',
      'git' => 'Git',
      'desktop' => l.agentFeatDesktop,
      'ports' => l.toolsPorts,
      'transcribe' => l.agentFeatTranscribe,
      'alerts' => l.agentAlerts,
      _ => l.agentFeatWatch,
    };

/// Host düzenleme ekranından ajan ayarlarına geçiş satırı.
class AgentSettingsLink extends StatelessWidget {
  const AgentSettingsLink({super.key, required this.host});
  final Host host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GroupedRow(
      title: l.agentSettings,
      icon: LucideIcons.slidersHorizontal,
      iconBackground: const Color(0xFF6C6C70),
      onTap: () => context.push('/settings/hosts/agent?id=${host.id}'),
    );
  }
}
