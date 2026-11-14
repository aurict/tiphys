// Bildirimler: UnifiedPush (dağıtıcı = telefondaki ntfy uygulaması). Ajanlar şifreli JSON gönderir;
// burada çözülmüş halini alıp seçili dilde yerel bildirim olarak gösteririz. Uygulama kapalıyken de çalışır
// (UnifiedPush uygulamayı "--unifiedpush-bg" argümanıyla arka planda başlatır).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../../l10n/gen/app_localizations.dart';
import '../agent/agent_client.dart';
import '../profile/model.dart';
import '../security/app_lock.dart';
import '../secrets/secret_store.dart';

const pushInstance = 'tiphys';
const _endpointKey = 'app:pushEndpoint';

/// Bildirim anahtarı + parametrelerden seçili dilde başlık/metin. Bilinmeyen anahtarlar için null.
(String, String)? noticeText(AppLocalizations l, String key, Map<String, dynamic> p) {
  String s(String k) => '${p[k] ?? ''}';
  int n(String k) => (p[k] as num?)?.toInt() ?? 0;
  return switch (key) {
    'claude.done' => (l.notifClaudeDoneTitle, s('title')),
    'claude.waiting' => (l.notifClaudeWaitingTitle, l.notifClaudeWaitingBody(s('title'), s('tool'))),
    'claude.error' => (l.notifClaudeErrorTitle, s('title')),
    'host.offline' => (l.notifHostOfflineTitle(s('host')), l.notifHostOfflineBody(n('minutes'))),
    'host.online' => (l.notifHostOnlineTitle(s('host')), ''),
    'agent.restarted' => (l.notifAgentRestartedTitle(s('host')), l.notifAgentRestartedBody),
    'push.test' => (l.notifTestTitle, s('device')),
    'disk.full' => (l.notifDiskFullTitle(s('host')), l.notifDiskFullBody(s('mount'), n('percent'))),
    'disk.ok' => (l.notifDiskOkTitle(s('host')), s('name')),
    'service.failed' => (l.notifServiceFailedTitle(s('host')), s('unit')),
    'service.recovered' => (l.notifServiceRecoveredTitle(s('host')), s('name')),
    'grafana.alert' => (l.notifGrafanaAlertTitle(s('name')), s('severity')),
    'grafana.resolved' => (l.notifGrafanaResolvedTitle(s('name')), ''),
    'command.done' => (l.notifCommandDoneTitle(s('host')), l.notifCommandBody(s('command'), n('seconds'))),
    'command.failed' => (l.notifCommandFailedTitle(s('host'), n('code')), l.notifCommandBody(s('command'), n('seconds'))),
    _ => null,
  };
}

/// Profil tercihlerine göre gösterilsin mi?
bool noticeAllowed(Profile p, String key) => switch (key) {
      'claude.done' => p.claude.notifyDone,
      'claude.waiting' => p.claude.notifyWaiting,
      'claude.error' => p.claude.notifyError,
      'host.offline' || 'host.online' => p.notifications.pcOffline,
      'service.failed' || 'service.recovered' || 'agent.restarted' => p.notifications.serviceDown,
      'grafana.alert' || 'grafana.resolved' => p.notifications.grafanaAlerts,
      _ => true,
    };

/// Bildirim düğmeleri (Claude izin isteği).
const actionAllow = 'claude-allow';
const actionDeny = 'claude-deny';

/// Bildirim yükü: düz bağlantı, ya da düğmeli bildirimde JSON {link, sessionId, requestId}.
String? routeForPayload(String? payload) {
  if (payload != null && payload.startsWith('{')) {
    try {
      return routeForLink((jsonDecode(payload) as Map)['link'] as String?);
    } catch (_) {
      return null;
    }
  }
  return routeForLink(payload);
}

/// Bildirimdeki "İzin ver / Reddet": uygulamayı açmadan Claude ajanına karar gönderir. Başarılıysa true.
Future<bool> decideFromNotification(
  String payload,
  bool allow, {
  required Profile profile,
  required SecretStore secrets,
  AgentClient Function(String url, String token)? clientFor,
}) async {
  final Map j;
  try {
    j = jsonDecode(payload) as Map;
  } catch (_) {
    return false;
  }
  final host = profile.host(profile.claude.agentHostId) ?? profile.hosts.where((h) => h.agent != null).firstOrNull;
  final agent = host?.agent;
  if (agent == null || j['sessionId'] == null || j['requestId'] == null) return false;
  final token = await secrets.read(secretIdOf(agent.tokenRef));
  if (token == null) return false;
  final c = (clientFor ?? (u, t) => AgentClient(baseUrl: u, token: t))(agent.url, token);
  try {
    await c.post('/v1/claude/sessions/${j['sessionId']}/permissions/${j['requestId']}', {'allow': allow});
    return true;
  } catch (_) {
    return false;
  } finally {
    c.close();
  }
}

/// Uygulama kapalıyken bildirim düğmesine basılınca Android'in çalıştırdığı giriş noktası (ayrı isolate).
@pragma('vm:entry-point')
Future<void> onNotificationActionBackground(NotificationResponse r) async {
  if (r.actionId != actionAllow && r.actionId != actionDeny) return;
  DartPluginRegistrant.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final profile = Profile.fromJson(jsonDecode(await File('${docs.path}/profile.json').readAsString()) as Map<String, dynamic>);
  final ok = await decideFromNotification(r.payload ?? '', r.actionId == actionAllow, profile: profile, secrets: KeystoreSecretStore());
  if (!ok) await _showDecisionFailed(FlutterLocalNotificationsPlugin(), profile, init: true);
}

Future<void> _showDecisionFailed(FlutterLocalNotificationsPlugin n, Profile profile, {bool init = false}) async {
  if (init) await n.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')));
  final l = lookupAppLocalizations(_localeOf(profile));
  await n.show(
    id: 9000,
    title: l.claudeDecisionFailedTitle,
    body: l.claudeDecisionFailedBody,
    notificationDetails: const NotificationDetails(android: AndroidNotificationDetails('tiphys-urgent', 'Tiphys · acil', importance: Importance.high)),
  );
}

Locale _localeOf(Profile profile) => switch (profile.app.language) {
      LanguagePref.tr => const Locale('tr'),
      LanguagePref.en => const Locale('en'),
      LanguagePref.system => Platform.localeName.startsWith('tr') ? const Locale('tr') : const Locale('en'),
    };

/// `tiphys://claude/ID` → `/claude/session/ID`; `tiphys://system` → `/system`
String? routeForLink(String? link) {
  if (link == null || !link.startsWith('tiphys://')) return null;
  final rest = link.substring('tiphys://'.length);
  if (rest.startsWith('claude/')) return '/claude/session/${rest.substring(7)}';
  if (rest == 'system') return '/system';
  if (rest == 'sites') return '/monitor/sites';
  if (rest == 'monitor/grafana') return '/monitor/grafana';
  if (rest == 'terminal') return '/terminal';
  return null;
}

class PushService {
  PushService({required this.vault, required this.loadProfile, required this.secrets});
  final KeyValueVault vault;
  final Future<Profile> Function() loadProfile;
  final SecretStore secrets;
  final notifications = FlutterLocalNotificationsPlugin();
  void Function(String route)? onOpen;
  int _id = 0;

  Future<void> init({required bool background}) async {
    await notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
      onDidReceiveNotificationResponse: (r) async {
        if (r.actionId == actionAllow || r.actionId == actionDeny) {
          final profile = await loadProfile();
          final ok = await decideFromNotification(r.payload ?? '', r.actionId == actionAllow, profile: profile, secrets: secrets);
          if (!ok) await _showDecisionFailed(notifications, profile);
          return;
        }
        final route = routeForPayload(r.payload);
        if (route != null) onOpen?.call(route);
      },
      onDidReceiveBackgroundNotificationResponse: onNotificationActionBackground,
    );
    final registered = await UnifiedPush.initialize(
      onNewEndpoint: (e, _) => _saveEndpoint(e),
      onMessage: (m, _) => _onMessage(m),
      onUnregistered: (_) => vault.delete(_endpointKey),
    );
    // Dağıtıcıya yeniden kayıt arka planda sürsün; ilk ekranı bekletmesin.
    if (registered && !background) unawaited(UnifiedPush.register(instance: pushInstance));
  }

  /// Uygulama bildirime dokunularak açıldıysa gidilecek rota.
  Future<String?> launchRoute() async {
    final d = await notifications.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true ? routeForPayload(d!.notificationResponse?.payload) : null;
  }

  Future<List<String>> distributors() => UnifiedPush.getDistributors();
  Future<String?> distributor() => UnifiedPush.getDistributor();

  Future<bool> enable(String distributor) async {
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await UnifiedPush.saveDistributor(distributor);
    await UnifiedPush.register(instance: pushInstance);
    return true;
  }

  Future<void> disable() async {
    await UnifiedPush.unregister(pushInstance);
    await vault.delete(_endpointKey);
  }

  Future<Map<String, dynamic>?> endpoint() async {
    final raw = await vault.read(_endpointKey);
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> _saveEndpoint(PushEndpoint e) async {
    final j = {'url': e.url, 'pubKey': e.pubKeySet?.pubKey, 'auth': e.pubKeySet?.auth};
    await vault.write(_endpointKey, jsonEncode(j));
    await registerWithAgents();
  }

  /// Uç noktayı ajanlı tüm hostlara bildirir; başarılı host kimliklerini döner.
  Future<List<String>> registerWithAgents() async {
    final ep = await endpoint();
    if (ep == null) return const [];
    final p = await loadProfile();
    final ok = <String>[];
    for (final h in p.hosts.where((h) => h.agent != null)) {
      try {
        final c = await AgentClient.forHost(h, secrets);
        await c.put('/v1/push/endpoint', {'url': ep['url'], if (ep['pubKey'] != null) 'pubKey': ep['pubKey'], if (ep['auth'] != null) 'auth': ep['auth']});
        c.close();
        ok.add(h.id);
      } catch (_) {
        // Ajan şu an kapalıysa bir sonraki açılışta tekrar denenir.
      }
    }
    return ok;
  }

  Future<void> _onMessage(PushMessage m) async {
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(utf8.decode(m.content)) as Map);
    } catch (_) {
      return;
    }
    final key = j['key'] as String? ?? '';
    final profile = await loadProfile();
    if (!noticeAllowed(profile, key)) return;
    final l = lookupAppLocalizations(_localeOf(profile));
    final text = noticeText(l, key, Map<String, dynamic>.from((j['params'] as Map?) ?? {}));
    if (text == null) return;
    final high = const {'claude.waiting', 'host.offline', 'disk.full', 'service.failed', 'grafana.alert', 'agent.restarted'}.contains(key);
    // Claude izin isteği: bildirimde "İzin ver / Reddet" düğmeleri (uygulamayı açmadan karar).
    final data = j['data'] is Map ? Map<String, dynamic>.from(j['data'] as Map) : null;
    final decision = key == 'claude.waiting' && data?['sessionId'] != null && data?['requestId'] != null;
    await notifications.show(
      id: _id++,
      title: text.$1,
      body: text.$2,
      payload: decision ? jsonEncode({'link': j['link'], 'sessionId': data!['sessionId'], 'requestId': data['requestId']}) : j['link'] as String?,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          high ? 'tiphys-urgent' : 'tiphys',
          high ? 'Tiphys · acil' : 'Tiphys',
          importance: high ? Importance.high : Importance.defaultImportance,
          priority: high ? Priority.high : Priority.defaultPriority,
          color: const Color(0xFF4338CA), // marka çivit rengi (bildirim ikonu vurgusu)
          actions: decision
              ? [
                  AndroidNotificationAction(actionAllow, l.claudeAllow, cancelNotification: true),
                  AndroidNotificationAction(actionDeny, l.claudeDeny, cancelNotification: true),
                ]
              : null,
        ),
      ),
    );
  }
}
