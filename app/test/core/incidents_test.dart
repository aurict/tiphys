// Incident room: notification texts and links, list filtering and grouping, preview expiry, host lookup, profile pref.
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/incidents/incident_screen.dart';
import 'package:tiphys/features/incidents/incident_texts.dart';
import 'package:tiphys/features/incidents/incidents_data.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/features/system/agent_providers.dart';

import '../helpers/harness.dart' show exampleProfile;
import '../helpers/incident_fixtures.dart';

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));
  final profile = exampleProfile();
  final argo = profile.host('argo')!;
  final atlas = profile.host('atlas')!;

  List<IncidentSummary> all() => [
        for (final e in sampleIncidents().entries)
          for (final i in e.value) IncidentSummary(profile.host(e.key)!, incidentSummary(i)),
      ];

  group('bildirimler', () {
    test('olay bildirim metinleri iki dilde', () {
      expect(noticeText(tr, 'incident.resolved', {'host': 'argo', 'kind': 'docker.died', 'target': 'web'}), ('Olay çözüldü · argo', 'Container çöktü: web'));
      expect(noticeText(en, 'incident.resolved', {'host': 'argo', 'kind': 'docker.died', 'target': 'web'}), ('Incident resolved · argo', 'Container crashed: web'));
      expect(noticeText(en, 'incident.actionFailed', {'host': 'argo', 'target': 'web', 'action': 'container.restart', 'stage': 'command'})!.$2, 'Container restart on web failed');
      expect(noticeText(tr, 'incident.actionFailed', {'host': 'argo', 'target': 'web', 'action': 'container.restart', 'stage': 'postCheck'})!.$2, contains('sonrasında sağlıklı değil'));
      expect(noticeText(tr, 'uptime.down', {'host': 'atlas', 'monitor': 'Blog', 'monitorId': 4}), ('Site kapalı: Blog', 'atlas'));
      expect(noticeText(en, 'uptime.up', {'host': 'atlas', 'monitor': 'Blog', 'monitorId': 4}), ('Site back up: Blog', 'atlas'));
      expect(noticeText(tr, 'docker.unhealthy', {'host': 'argo', 'container': 'api'}), ('Container sağlıksız · argo', 'api'));
      expect(noticeText(en, 'docker.restartLoop', {'host': 'argo', 'container': 'api', 'count': 3}), ('Container restart loop · argo', 'api · 3 restarts in 10 min'));
      expect(noticeText(tr, 'docker.restartLoop', {'host': 'argo', 'container': 'api', 'count': 3})!.$2, 'api · 10 dk içinde 3 yeniden başlama');
    });

    test('bağlantı ve yük: tiphys://incidents/<id> olay ekranını açar, host adı taşınır', () {
      expect(routeForLink('tiphys://incidents/inc-aaaaaaaaaaaa'), '/incidents/inc-aaaaaaaaaaaa');
      expect(routeForLink('tiphys://incidents'), '/incidents');
      expect(routeForLink('tiphys://incidents/../x'), isNull);
      final payload = incidentPayload('tiphys://incidents/inc-aaaaaaaaaaaa', {'host': 'argo (PC)'});
      expect(jsonDecode(payload!), {'link': 'tiphys://incidents/inc-aaaaaaaaaaaa', 'host': 'argo (PC)'});
      expect(routeForPayload(payload), '/incidents/inc-aaaaaaaaaaaa?host=argo+%28PC%29');
      expect(routeForPayload('tiphys://incidents/inc-aaaaaaaaaaaa'), '/incidents/inc-aaaaaaaaaaaa');
      expect(incidentPayload('tiphys://system', {'host': 'argo'}), isNull);
      expect(incidentPayload('tiphys://incidents/inc-aaaaaaaaaaaa', {}), isNull);
    });

    test('tercih notifications.incidents yalnız olay bildirimlerini kapatır', () {
      const off = Profile(notifications: NotificationSettings(incidents: false));
      for (final k in ['incident.resolved', 'incident.actionFailed', 'uptime.down', 'uptime.up', 'docker.unhealthy', 'docker.restartLoop']) {
        expect(noticeAllowed(off, k), isFalse, reason: k);
        expect(noticeAllowed(const Profile(), k), isTrue, reason: k);
      }
      expect(noticeAllowed(off, 'docker.died'), isTrue);
      expect(NotificationSettings.fromJson({}).incidents, isTrue);
      expect(NotificationSettings.fromJson({'incidents': false}).toJson()['incidents'], false);
    });

    test('aynı konudaki bildirimler birbirinin yerine geçer', () {
      expect(noticeId('incident.resolved', {'incidentId': 'inc-a'}), noticeId('incident.actionFailed', {'incidentId': 'inc-a'}));
      expect(noticeId('docker.restartLoop', {'host': 'argo', 'container': 'api'}), noticeId('docker.died', {'host': 'argo', 'container': 'api'}));
    });
  });

  group('hata kodları', () {
    test('agent.incident.* ve agent.preview.invalid çevrilir', () {
      for (final c in ['agent.incident.notFound', 'agent.incident.action.notFound', 'agent.incident.confirmRequired', 'agent.incident.actionRunning', 'agent.incident.actionUnavailable', 'agent.incident.rateLimited', 'agent.incident.analysisUnavailable', 'agent.preview.invalid']) {
        expect(agentErrorText(tr, AgentError(c)), isNot(contains('(agent.')), reason: c);
      }
      expect(agentErrorText(en, const AgentError('agent.incident.badState', {'status': 'resolved'})), 'Not possible while the incident is resolved.');
      expect(agentErrorText(tr, const AgentError('agent.preview.invalid')), contains('Önizleme'));
    });
  });

  group('liste', () {
    test('sekme, host ve tür süzgeci; kritik önce, sonra yeni', () {
      final a = all();
      expect(filterIncidents(a, status: 'open').map((i) => i.id), ['inc-aaaaaaaaaaaa', 'inc-cccccccccccc']);
      expect(filterIncidents(a, status: 'open', hostId: 'atlas').map((i) => i.id), ['inc-cccccccccccc']);
      expect(filterIncidents(a, status: 'open', family: 'container').map((i) => i.id), ['inc-aaaaaaaaaaaa']);
      expect(filterIncidents(a, status: 'open', family: 'site').single.host, atlas);
      expect(filterIncidents(a, status: 'acknowledged').single.family, 'disk');
      // Resolved: newest resolution first.
      expect(filterIncidents(a, status: 'resolved').map((i) => i.id), ['inc-dddddddddddd', 'inc-eeeeeeeeeeee']);
      expect(filterIncidents(a, status: 'open', hostId: 'argo', family: 'site'), isEmpty);
    });

    test('günlere göre gruplama sırayı korur', () {
      final groups = groupIncidentsByDay(filterIncidents(all(), status: 'resolved'));
      expect(groups.map((g) => g.day), [DateTime(2026, 11, 13), DateTime(2026, 11, 12)]);
      expect(groups.map((g) => g.items.length), [1, 1]);
      expect(groupIncidentsByDay(const []), isEmpty);
    });

    test('tür ailesi ve başlık', () {
      expect(incidentFamily('docker.restartLoop'), 'container');
      expect(incidentFamily('uptime.down'), 'site');
      expect(incidentFamily('grafana.alert'), 'alert');
      expect(incidentFamily('x.y'), 'other');
      expect(incidentTitle(tr, 'disk.full', '/'), 'Disk dolu: /');
      expect(incidentTitle(en, 'weird.kind', 'x'), 'weird.kind: x');
    });

    test('host ipucu: kimlik, ajan adı ya da tüm ajanlar', () {
      expect(incidentHostsFor(profile, 'atlas').hosts.map((h) => h.id), ['atlas']);
      expect(incidentHostsFor(profile, 'argo (PC)').exact, isTrue);
      expect(incidentHostsFor(profile, 'ARGO').hosts.single, argo);
      final any = incidentHostsFor(profile, 'bilinmeyen');
      expect(any.exact, isFalse);
      expect(any.hosts.map((h) => h.id), ['argo', 'atlas']);
      expect(incidentHostsFor(profile, null).exact, isFalse);
    });
  });

  group('önizleme', () {
    final received = DateTime(2026, 11, 14, 14, 5);
    Map<String, dynamic> json(DateTime expires) => {
          'steps': [
            {'argv': ['docker', 'restart', 'web']}
          ],
          'risk': 'low',
          'previewToken': 'tpv_x',
          'expiresAt': expires.toUtc().toIso8601String(),
        };

    test('agentın son kullanma anı geri sayım ve süre dolması', () {
      final p = ActionPreview(json(received.add(const Duration(seconds: 118))), received);
      expect(p.remaining(received), const Duration(seconds: 118));
      expect(formatCountdown(p.remaining(received)), '1:58');
      expect(p.expired(received.add(const Duration(seconds: 117))), isFalse);
      expect(p.expired(received.add(const Duration(seconds: 118))), isTrue);
      expect(p.remaining(received.add(const Duration(minutes: 10))), Duration.zero);
      expect(formatCountdown(const Duration(seconds: 5)), '0:05');
    });

    test('telefon saati ayrıksa 120 sn alınış anından sayılır', () {
      final ahead = ActionPreview(json(received.subtract(const Duration(minutes: 5))), received);
      expect(ahead.remaining(received), previewLifetime);
      final behind = ActionPreview(json(received.add(const Duration(minutes: 30))), received);
      expect(behind.remaining(received), previewLifetime);
      expect(ActionPreview({'previewToken': 't'}, received).remaining(received), previewLifetime);
    });

    test('komutlar düz argv metni olarak gösterilir', () {
      expect(formatArgv(['docker', 'restart', 'web']), 'docker restart web');
      expect(formatArgv(['sh', '-c', 'rm -rf /; echo "x"']), "sh -c 'rm -rf /; echo \"x\"'");
      expect(formatArgv(['echo', "it's"]), r"echo 'it'\''s'");
      expect(formatArgv(['a', '']), "a ''");
    });
  });

  group('ayrıştırma ve metinler', () {
    test('tam olay: ipuçları, zaman çizelgesi, bağlam', () {
      final d = IncidentDetail(argo, sampleIncidents()['argo']!.first);
      expect(d.hints.map((h) => h.code), ['oom', 'restartLoop', 'recentDeploy']);
      expect(d.logs!['lines'], hasLength(6));
      expect(d.inspect!['exitCode'], 137);
      expect(d.git!['log'], hasLength(2));
      expect(d.summary.family, 'container');
      expect(IncidentDetail(argo, {...sampleIncidents()['argo']!.first}..remove('context')).context, isNull);
    });

    test('ipuçları ve zaman çizelgesi metinleri', () {
      expect(incidentHintText(tr, 'diskFull', {'mount': '/', 'percent': 96}), '/ %96 dolu.');
      expect(incidentHintText(en, 'restartLoop', {'restartCount': 4}), 'Restart loop: 4 restarts so far.');
      expect(incidentHintText(en, 'restartLoop', {}), 'Restart loop: the container keeps restarting.');
      expect(incidentHintText(en, 'future', {}), 'Hint: future');
      TimelineItem tl(Map<String, dynamic> m) => TimelineItem({'at': '2026-11-14T12:00:00Z', ...m});
      expect(incidentTimelineText(en, tl({'type': 'actionResult', 'data': {'action': 'container.restart', 'ok': false, 'code': 1}, 'text': 'boom'})), ('Action failed: Container restart (code 1)', 'boom'));
      expect(incidentTimelineText(tr, tl({'type': 'postCheck', 'data': {'ok': true, 'state': 'running'}})).$1, 'Denetim geçti: running');
      expect(incidentTimelineText(tr, tl({'type': 'resolved', 'text': 'not'})), ('Çözüldü', 'not'));
      expect(incidentTimelineText(en, tl({'type': 'context', 'data': {'ok': true, 'logLines': 12}})).$1, 'Context collected (12 log lines)');
      expect(incidentActor(en, 'device:phone'), 'device phone');
      expect(incidentActionLabel(tr, 'compose.recreate', {'stack': 'shop', 'service': 'web'}), 'web servisini yeniden oluştur');
    });
  });
}
