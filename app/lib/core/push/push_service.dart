// Bildirimler: UnifiedPush (dağıtıcı = telefondaki ntfy uygulaması). Ajanlar şifreli JSON gönderir;
// burada çözülmüş halini alıp seçili dilde yerel bildirim olarak gösteririz. Uygulama kapalıyken de çalışır
// (UnifiedPush uygulamayı "--unifiedpush-bg" argümanıyla arka planda başlatır).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
      'service.failed' || 'service.recovered' => p.notifications.serviceDown,
      'grafana.alert' || 'grafana.resolved' => p.notifications.grafanaAlerts,
      _ => true,
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
      onDidReceiveNotificationResponse: (r) {
        final route = routeForLink(r.payload);
        if (route != null) onOpen?.call(route);
      },
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
    return d?.didNotificationLaunchApp == true ? routeForLink(d!.notificationResponse?.payload) : null;
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
    final locale = switch (profile.app.language) {
      LanguagePref.tr => const Locale('tr'),
      LanguagePref.en => const Locale('en'),
      LanguagePref.system => Platform.localeName.startsWith('tr') ? const Locale('tr') : const Locale('en'),
    };
    final text = noticeText(lookupAppLocalizations(locale), key, Map<String, dynamic>.from((j['params'] as Map?) ?? {}));
    if (text == null) return;
    final high = const {'claude.waiting', 'host.offline', 'disk.full', 'service.failed', 'grafana.alert'}.contains(key);
    await notifications.show(
      id: _id++,
      title: text.$1,
      body: text.$2,
      payload: j['link'] as String?,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          high ? 'tiphys-urgent' : 'tiphys',
          high ? 'Tiphys · acil' : 'Tiphys',
          importance: high ? Importance.high : Importance.defaultImportance,
          priority: high ? Priority.high : Priority.defaultPriority,
          color: const Color(0xFF4338CA), // marka çivit rengi (bildirim ikonu vurgusu)
        ),
      ),
    );
  }
}
