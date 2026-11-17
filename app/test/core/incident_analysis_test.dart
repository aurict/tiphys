// Incident AI analysis (PLAN.md §13.1, I-3): the analysis state machine and polling stop, evidence reference resolution,
// the notification that replaces its source, texts, metrics series, and the rotation list order (C-2).
import 'dart:convert';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/configfiles/configfiles_data.dart';
import 'package:tiphys/features/incidents/incident_analysis.dart';
import 'package:tiphys/features/incidents/incident_screen.dart';
import 'package:tiphys/features/incidents/incident_texts.dart';
import 'package:tiphys/features/incidents/incidents_data.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

import '../helpers/config_fixtures.dart';
import '../helpers/harness.dart' show exampleProfile;
import '../helpers/incident_fixtures.dart';

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));
  final profile = exampleProfile();
  final argo = profile.host('argo')!;
  final atlas = profile.host('atlas')!;

  Map<String, dynamic> incident({Map<String, dynamic>? analysis}) {
    final inc = sampleIncidents()['argo']!.first;
    if (analysis != null) inc['analysis'] = analysis;
    return inc;
  }

  IncidentDetail detail({Map<String, dynamic>? analysis}) {
    final inc = incident(analysis: analysis);
    return IncidentDetail(argo, inc, responseSimilar: [for (final e in (inc['context'] as Map)['similar'] as List) Map<String, dynamic>.from(e as Map)]);
  }

  group('analiz durumu', () {
    test('beş durum ve bayrakları', () {
      expect(detail().analysis, isNull, reason: 'hiç istenmemiş');
      final queued = detail(analysis: sampleAnalysis('queued')).analysis!;
      expect([queued.active, queued.done, queued.failed, queued.unavailable], [true, false, false, false]);
      expect(detail(analysis: sampleAnalysis('running')).analysis!.active, isTrue);
      final done = detail(analysis: sampleAnalysis('done')).analysis!;
      expect([done.active, done.done], [false, true]);
      expect(done.result!.hypotheses, hasLength(3));
      final failed = detail(analysis: sampleAnalysis('failed', errorCode: 'agent.analysis.invalidOutput')).analysis!;
      expect([failed.failed, failed.errorCode], [true, 'agent.analysis.invalidOutput']);
      final off = detail(analysis: sampleAnalysis('unavailable', reason: 'unreachable', errorCode: 'agent.incident.analysis.unreachable')).analysis!;
      expect([off.unavailable, off.reason, off.active], [true, 'unreachable', false]);
      // done without a result is not shown as done.
      expect(IncidentAnalysis({'status': 'done'}).done, isFalse);
    });

    test('sonuç: güven 0..1, kanıtsız işareti, öneriler ve sorular', () {
      final r = detail(analysis: sampleAnalysis('done')).analysis!.result!;
      expect(r.hypotheses.map((h) => h.unsupported), [false, false, true]);
      expect(r.hypotheses.first.confidence, 0.86);
      expect(r.hypotheses.first.evidenceRefs, contains('metric:host.memPct'));
      expect(r.suggestedActions.map((s) => s.candidateId), ['c-aaaaaaaaaaaa', 'c-999999999999']);
      expect(r.questions, hasLength(2));
      expect(Hypothesis({'cause': 'x', 'confidence': 7}).confidence, 1.0);
      expect(Hypothesis({'cause': 'x', 'confidence': -1}).confidence, 0.0);
    });

    test('yoklama: sıradaki/çalışan sürede döner, bitince (done/failed/unavailable/yok) durur', () {
      fakeAsync((async) {
        var polls = 0;
        final p = AnalysisPoller(refresh: () => polls++);
        p.sync(null);
        async.elapse(const Duration(seconds: 30));
        expect(polls, 0);
        expect(p.polling, isFalse);

        p.sync(IncidentAnalysis(sampleAnalysis('queued')));
        p.sync(IncidentAnalysis(sampleAnalysis('running')));
        expect(p.polling, isTrue);
        async.elapse(const Duration(seconds: 9));
        expect(polls, 3, reason: '3 sn aralık, ikinci sync ikinci zamanlayıcı başlatmaz');

        p.sync(IncidentAnalysis(sampleAnalysis('done')));
        expect(p.polling, isFalse);
        async.elapse(const Duration(seconds: 30));
        expect(polls, 3, reason: 'bittikten sonra istek yok');

        for (final s in ['failed', 'unavailable']) {
          p.sync(IncidentAnalysis(sampleAnalysis('running')));
          expect(p.polling, isTrue);
          p.sync(IncidentAnalysis(sampleAnalysis(s)));
          expect(p.polling, isFalse, reason: s);
        }
        p.sync(IncidentAnalysis(sampleAnalysis('queued')));
        p.sync(null);
        expect(p.polling, isFalse);
      });
    });

    test('yoklama güvenlik sınırı: en çok maxPolls istekten sonra kendiliğinden durur', () {
      fakeAsync((async) {
        var polls = 0;
        final p = AnalysisPoller(refresh: () => polls++, interval: const Duration(seconds: 1), maxPolls: 5);
        p.sync(IncidentAnalysis(sampleAnalysis('running')));
        async.elapse(const Duration(seconds: 60));
        expect(polls, 5);
        expect(p.polling, isFalse);
      });
    });
  });

  group('kanıt başvurusu çözümleme', () {
    final idx = detail().evidenceIndex;

    test('dizin bağlamdan kurulur', () {
      expect(idx.logLines, 6);
      expect(idx.deploys, 2);
      expect(idx.events, 2);
      expect(idx.configChanges, 2);
      expect(idx.hasInspect, isTrue);
      expect(idx.gitHashes, ['a1b2c3d4e5f6', '9f8e7d6c5b4a']);
      expect(idx.metricNames, containsAll(['host.cpu', 'host.memPct', 'disk:/', 'container.memMB']));
    });

    test('her biçim doğru sekmeye ve doğru satıra gider (kimlikler 1 tabanlı)', () {
      EvidenceTarget? r(String ref) => resolveEvidenceRef(ref, idx);
      expect(r('log:docker#4'), const EvidenceTarget('logs', kind: 'log', index: 3));
      expect(r('log:docker#1'), const EvidenceTarget('logs', kind: 'log', index: 0));
      expect(r('log:docker#6')!.index, 5);
      expect(r('deploy:2'), const EvidenceTarget('deploys', kind: 'deploy', index: 1));
      expect(r('config:1'), const EvidenceTarget('deploys', kind: 'config', index: 0));
      expect(r('event:2'), const EvidenceTarget('events', kind: 'event', index: 1));
      expect(r('inspect:container'), const EvidenceTarget('container'));
      expect(resolveEvidenceRef('signal:3', const EvidenceIndex(signals: 3)), const EvidenceTarget('timeline'));
      expect(r('signal:1'), isNull, reason: 'fixture incident has no signals');
      expect(r('git:9f8e7d6'), const EvidenceTarget('git', kind: 'git', name: '9f8e7d6c5b4a'));
      expect(r('git:9f8e7d6c5b4a'), const EvidenceTarget('git', kind: 'git', name: '9f8e7d6c5b4a'));
      expect(r('git:status'), const EvidenceTarget('git', kind: 'git'));
      expect(r('metric:host.memPct'), const EvidenceTarget('metrics', kind: 'metric', name: 'host.memPct'));
      expect(r('metric:disk:/'), const EvidenceTarget('metrics', kind: 'metric', name: 'disk:/'));
    });

    test('olmayan ya da bozuk başvuru çözülmez (çip pasif kalır)', () {
      for (final bad in ['log:docker#7', 'log:docker#0', 'log:docker', 'deploy:3', 'deploy:0', 'deploy:x', 'event:99', 'config:3', 'git:deadbeef', 'git:', 'metric:host.nope', 'inspect:other', 'foo:1', 'nocolon', '', ':1', 'deploy:01']) {
        expect(resolveEvidenceRef(bad, idx), isNull, reason: bad);
      }
      // No collected data at all.
      expect(resolveEvidenceRef('log:docker#1', const EvidenceIndex()), isNull);
      expect(resolveEvidenceRef('inspect:container', const EvidenceIndex()), isNull);
      expect(resolveEvidenceRef('git:status', const EvidenceIndex()), isNull);
    });

    test('örnek sonucun tüm başvuruları çözülür; kanıtsız hipotezin başvurusu yok', () {
      final r = detail(analysis: sampleAnalysis('done')).analysis!.result!;
      for (final h in r.hypotheses.where((h) => !h.unsupported)) {
        for (final ref in h.evidenceRefs) {
          expect(resolveEvidenceRef(ref, idx), isNotNull, reason: ref);
        }
      }
      expect(r.hypotheses.last.evidenceRefs, isEmpty);
    });

    test('çip etiketleri', () {
      expect(evidenceRefLabel(tr, 'log:docker#12'), 'Günlük satırı 12');
      expect(evidenceRefLabel(en, 'deploy:2'), 'Deploy 2');
      expect(evidenceRefLabel(en, 'git:9f8e7d6c5b4a'), 'Commit 9f8e7d6');
      expect(evidenceRefLabel(tr, 'git:status'), 'Kaydedilmemiş değişiklikler');
      expect(evidenceRefLabel(en, 'metric:host.memPct'), 'Metric host.memPct');
      expect(evidenceRefLabel(en, 'weird'), 'weird');
    });
  });

  group('metrikler', () {
    test('seriler bağlamdan, ad bundle kimliğiyle aynı', () {
      final s = metricSeries(detail().metrics);
      expect(s.map((e) => e.name), ['host.cpu', 'host.load1', 'host.memPct', 'host.swapPct', 'disk:/', 'container.cpu', 'container.memPct', 'container.memMB']);
      final mem = s.firstWhere((e) => e.name == 'host.memPct');
      expect(mem.points, hasLength(16));
      expect(mem.min, 40.0);
      expect(mem.max, 92.5);
      expect(mem.last, 92.5);
      expect(s.firstWhere((e) => e.name == 'container.memMB').points.first.$2, 200.0);
      expect(metricSeries(null), isEmpty);
      expect(metricSeries({'host': <Object>[]}), isEmpty);
      expect(metricSeries({'host': [{'t': 1, 'cpu': 5}]}), isEmpty, reason: 'tek örnekle çizgi çizilmez');
      expect(metricTitle(tr, 'disk:/'), 'Disk / (% dolu)');
      expect(metricTitle(en, 'container.memPct'), 'Container memory (% of limit)');
    });
  });

  group('bildirim incident.analyzed', () {
    final source = {'host': 'argo', 'container': 'web', 'code': 137};
    final data = {'incidentId': 'inc-aaaaaaaaaaaa', 'silent': '1', 'replaceKey': 'docker.died', 'replaceParams': jsonEncode(source)};

    test('kaynak bildirimin kimliğini alır, yani onun yerine geçer', () {
      final id = noticeIdFor('incident.analyzed', {'host': 'argo', 'incidentId': 'inc-aaaaaaaaaaaa', 'summary': 's'}, data: data);
      expect(id, noticeId('docker.died', source));
      expect(id, lessThan(0x40000000), reason: 'konu kimliği, rastgele değil');
      // The restart-loop notification of the same container shares the topic, so it is replaced as well.
      expect(id, noticeId('docker.restartLoop', {'host': 'argo', 'container': 'web', 'count': 3}));
    });

    test('farklı konteyner/host başka bildirimi değiştirmez', () {
      final other = noticeIdFor('incident.analyzed', {}, data: {...data, 'replaceParams': jsonEncode({'host': 'argo', 'container': 'db'})});
      expect(other, isNot(noticeId('docker.died', source)));
      expect(other, noticeId('docker.died', {'host': 'argo', 'container': 'db'}));
    });

    test('farklı kaynak türleri: uptime ve disk', () {
      expect(noticeIdFor('incident.analyzed', {}, data: {'replaceKey': 'uptime.down', 'replaceParams': jsonEncode({'host': 'atlas', 'monitorId': 4})}), noticeId('uptime.up', {'host': 'atlas', 'monitorId': 4}));
      expect(noticeIdFor('incident.analyzed', {}, data: {'replaceKey': 'disk.full', 'replaceParams': jsonEncode({'host': 'argo', 'mount': '/'})}), noticeId('disk.full', {'host': 'argo', 'mount': '/'}));
    });

    test('replaceParams eksik/bozuksa olayın kendi konusuna düşer (rastgele kimlik değil)', () {
      final own = noticeId('incident.resolved', {'incidentId': 'inc-aaaaaaaaaaaa'});
      expect(noticeIdFor('incident.analyzed', {'incidentId': 'inc-aaaaaaaaaaaa'}, data: null), own);
      expect(noticeIdFor('incident.analyzed', {'incidentId': 'inc-aaaaaaaaaaaa'}, data: {'replaceKey': 'docker.died', 'replaceParams': '{not json'}), own);
      expect(noticeIdFor('incident.analyzed', {'incidentId': 'inc-aaaaaaaaaaaa'}, data: {'replaceKey': '', 'replaceParams': '{}'}), own);
      expect(noticeIdFor('incident.analyzed', {'incidentId': 'inc-aaaaaaaaaaaa'}, data: {'replaceKey': 'docker.died', 'replaceParams': '[1,2]'}), own);
    });

    test('replaceParams düz harita olarak da gelebilir', () {
      expect(noticeIdFor('incident.analyzed', {}, data: {'replaceKey': 'docker.died', 'replaceParams': source}), noticeId('docker.died', source));
    });

    test('diğer anahtarlar noticeId ile aynı', () {
      expect(noticeIdFor('host.offline', {'host': 'argo'}, data: data), noticeId('host.offline', {'host': 'argo'}));
      expect(noticeIdFor('claude.done', {}, link: 'tiphys://claude/x'), noticeId('claude.done', {}, link: 'tiphys://claude/x'));
    });

    test('sessiz gösterim yalnız data.silent == "1" ise', () {
      expect(noticeSilent(data), isTrue);
      expect(noticeSilent({'silent': '0'}), isFalse);
      expect(noticeSilent({'silent': true}), isFalse);
      expect(noticeSilent(null), isFalse);
    });

    test('metin: özet düz metin olarak, tercih notifications.incidents ile kapanır', () {
      expect(noticeText(tr, 'incident.analyzed', {'host': 'argo', 'summary': 'Bellek bitti.'}), ('Yapay zekâ analizi · argo', 'Bellek bitti.'));
      expect(noticeText(en, 'incident.analyzed', {'host': 'argo', 'summary': 'Out of memory.'}), ('AI analysis · argo', 'Out of memory.'));
      expect(noticeAllowed(const Profile(notifications: NotificationSettings(incidents: false)), 'incident.analyzed'), isFalse);
      expect(noticeAllowed(const Profile(), 'incident.analyzed'), isTrue);
      expect(routeForPayload(incidentPayload('tiphys://incidents/inc-aaaaaaaaaaaa', {'host': 'argo'})), '/incidents/inc-aaaaaaaaaaaa?host=argo');
    });
  });

  group('metinler', () {
    test('iş hatası ve PC erişilemez nedenleri iki dilde, ham kod yok', () {
      for (final c in ['agent.analysis.toolMissing', 'agent.analysis.toolFailed', 'agent.analysis.invalidOutput', 'agent.analysis.timeout', 'agent.analysis.cancelled', 'agent.analysis.interrupted', 'agent.analysis.whatever', null]) {
        expect(analysisFailedText(tr, c), isNot(contains('agent.')), reason: '$c');
        expect(analysisFailedText(en, c), isNotEmpty);
      }
      for (final r in ['unreachable', 'unauthorized', 'busy', 'rejected', 'badResponse', 'timeout', 'lost', 'other', null]) {
        expect(analysisReasonText(tr, r), isNot(contains('unreachable')), reason: '$r');
      }
      expect(analysisReasonText(tr, 'unreachable'), 'PC kapalı ya da ulaşılamıyor.');
      expect(analysisReasonText(en, 'unreachable'), 'The analysis PC is off or unreachable.');
    });

    test('analiz hata kodları: kapalı, oran sınırı, paket oran sınırı', () {
      expect(agentErrorText(tr, const AgentError('agent.incident.analysisOff')), contains('kapalı'));
      expect(agentErrorText(en, const AgentError('agent.incident.analysisRateLimited', {'limit': 3, 'windowSeconds': 600})), 'Too many analyses of this incident (3 per 10 min). Try again later.');
      expect(agentErrorText(tr, const AgentError('agent.incident.analysisRateLimited', {'limit': 3, 'windowSeconds': 600})), contains('10 dakikada 3'));
      expect(agentErrorText(tr, const AgentError('agent.incident.bundleRateLimited')), isNot(contains('(agent.')));
    });

    test('zaman çizelgesi: analysis ve analysisResult', () {
      TimelineItem t(String type, [Map<String, dynamic> data = const {}]) => TimelineItem({'at': '2026-11-14T13:00:00Z', 'type': type, 'data': data});
      expect(incidentTimelineText(tr, t('analysis', {'status': 'queued', 'mode': 'local'})).$1, 'Yapay zekâ analizi istendi');
      expect(incidentTimelineText(en, t('analysisResult', {'status': 'done', 'hypotheses': 3, 'actions': 2})).$1, 'AI analysis done: 3 hypotheses, 2 suggested actions');
      expect(incidentTimelineText(tr, t('analysisResult', {'status': 'failed', 'code': 'agent.analysis.timeout'})), ('Yapay zekâ analizi başarısız', 'Analiz çok uzun sürdü.'));
      expect(incidentTimelineText(tr, t('analysisResult', {'status': 'unavailable', 'code': 'agent.incident.analysis.unreachable'})), ('Yapay zekâ analizi yapılamadı', 'PC kapalı ya da ulaşılamıyor.'));
    });
  });

  group('benzer olaylar', () {
    test('yanıtın kendi similar alanı bağlamdakinin önüne geçer', () {
      final inc = incident();
      final fresh = [
        {'id': 'inc-zzzzzzzzzzzz', 'kind': 'docker.oom', 'status': 'resolved', 'openedAt': '2026-11-01T10:00:00Z', 'resolvedAt': '2026-11-01T10:10:00Z', 'resolutionNote': 'n', 'workedAction': 'compose.rollback'},
      ];
      expect(IncidentDetail(argo, inc, responseSimilar: fresh).similar.single['id'], 'inc-zzzzzzzzzzzz');
      expect(IncidentDetail(argo, inc).similar, hasLength(2), reason: 'yanıtta yoksa bağlamdan');
      expect(IncidentDetail(argo, inc, responseSimilar: const []).similar, isEmpty, reason: 'taze boş liste de geçerli');
    });
  });

  group('yenilenmesi gerekenler sırası', () {
    RotationItem item(Host h, String file, String key, {int? age, int? max, bool? due}) => RotationItem(h, 'cf-$file', file, {'key': key, 'ageDays': age, 'maxAgeDays': max, 'due': due ?? (age != null && max != null && age > max)});

    test('gecikenler önce (en çok geciken üstte), sonra sınıra en yakın; limitsizler en sonda, yaşa göre', () {
      final items = [
        item(argo, 'shop/.env', 'DB_PASSWORD', age: 12, max: 90),
        item(argo, 'shop/.env', 'SESSION_SECRET', age: 40, max: 30),
        item(atlas, 'blog/.env', 'WP_DB_PASSWORD', age: 5),
        item(argo, 'shop/.env', 'API_TOKEN', age: 120, max: 90),
        item(argo, 'shop/api.env', 'STRIPE_KEY', age: 80, max: 90),
        item(argo, 'shop/api.env', 'OLD_UNLIMITED', age: 300),
        item(argo, 'shop/api.env', 'UNKNOWN_AGE'),
      ]..sort(compareRotation);
      expect(items.map((i) => i.key), ['API_TOKEN', 'SESSION_SECRET', 'STRIPE_KEY', 'DB_PASSWORD', 'OLD_UNLIMITED', 'WP_DB_PASSWORD', 'UNKNOWN_AGE']);
    });

    test('ajanın due kararı sınırda gecikmiş sayılır; eşitlikte host, dosya, anahtar sırası', () {
      final a = item(argo, 'a.env', 'B_KEY', age: 90, max: 90, due: true);
      final b = item(argo, 'a.env', 'A_KEY', age: 90, max: 90, due: true);
      final c = item(atlas, 'a.env', 'A_KEY', age: 90, max: 90, due: true);
      final notDue = item(argo, 'a.env', 'C_KEY', age: 100, max: 200);
      expect(a.overdue, isTrue);
      expect(notDue.overdue, isFalse);
      expect(([c, a, notDue, b]..sort(compareRotation)).map((i) => '${i.host.name}/${i.key}'), ['${argo.name}/A_KEY', '${argo.name}/B_KEY', '${atlas.name}/A_KEY', '${argo.name}/C_KEY']);
    });

    test('GET /v1/secrets/meta yanıtı ayrıştırılır; limitli/limitsiz ve geciken sayısı', () {
      final st = FakeConfigState();
      final response = fakeConfigRoute('argo', 'GET', '/v1/secrets/meta', null, st);
      final items = parseRotation(argo, response)..sort(compareRotation);
      expect(items.map((i) => i.key), ['API_TOKEN', 'DB_PASSWORD', 'SESSION_SECRET', 'STRIPE_KEY']);
      final feed = RotationFeed(items: items, errors: const {});
      expect(feed.dueCount, 1);
      expect(feed.withPolicy.map((i) => i.key), ['API_TOKEN', 'DB_PASSWORD']);
      expect(feed.withoutPolicy.map((i) => i.key), ['SESSION_SECRET', 'STRIPE_KEY']);
      final api = items.first;
      expect([api.ageDays, api.maxAgeDays, api.overdueDays, api.fileId, api.file], [120, 90, 30, 'cf-aaaaaaaaaaaaaaaaaaaaaaaa', 'shop/.env']);
      expect(parseRotation(argo, null), isEmpty);
      expect(parseRotation(argo, {'files': [{'fileId': 'cf-x', 'file': 'x.env', 'keys': 'bad'}]}), isEmpty);
    });
  });
}
