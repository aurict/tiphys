// Gerçek Tiphys ajanlarına karşı istemci testi (Tailscale üzerinden HTTPS).
// Hedefler ve token dosyaları: real_env.dart (~/.config/tiphys/real-test.json).
@Tags(['real'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';

import 'real_env.dart';

void main() {
  // flutter_test HTTP'yi sahte bir istemciyle değiştirir; bu testler gerçek ağa çıkar.
  setUpAll(() => HttpOverrides.global = null);

  for (final (name, url, tokenFile) in [
    (real.pc, real.agent(real.pc), real.pcToken),
    (real.server, real.agent(real.server), real.serverToken),
  ]) {
    group(name, () {
      late AgentClient c;
      setUpAll(() => c = AgentClient(baseUrl: url, token: File(tokenFile).readAsStringSync().trim()));
      tearDownAll(() => c.close());

      test('health token istemez ve adı döner', () async {
        final h = await AgentClient.health(url);
        expect(h['name'], name);
      });

      test('sistem metrikleri', () async {
        final s = await c.get('/v1/system');
        expect(s['hostname'], name);
        expect((s['memory'] as Map)['totalBytes'], greaterThan(1 << 30));
      });

      test('servis listesi ve günlük', () async {
        final s = await c.get('/v1/services/user');
        final units = (s['units'] as List).cast<Map>();
        expect(units.any((u) => u['unit'] == 'tiphys-agent.service'), isTrue);
        final logs = await c.get('/v1/services/user/tiphys-agent.service/logs', query: {'lines': '5'});
        expect(logs['entries'], isA<List>());
      });

      test('Docker listesi', () async {
        final d = await c.get('/v1/docker/containers');
        expect((d['containers'] as List), isNotEmpty);
      });

      test('yanlış token kodlu hata', () async {
        final bad = AgentClient(baseUrl: url, token: 'tph_yanlis');
        await expectLater(bad.get('/v1/system'), throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.auth.invalidToken')));
        bad.close();
      });

      test('ayarlar gizli bilgi sızdırmaz', () async {
        final cfg = await c.get('/v1/config');
        final text = cfg.toString();
        expect(text, isNot(contains('tokenHash')));
        expect(text, isNot(contains('password:')));
      });
    });
  }

  test('sunucu: Uptime Kuma köprüsü monitörleri ve geçmişi verir', () async {
    final c = AgentClient(baseUrl: real.agent(real.server), token: File(real.serverToken).readAsStringSync().trim());
    final d = await c.get('/v1/uptime/monitors');
    expect((d['state'] as Map)['loggedIn'], isTrue);
    final ms = (d['monitors'] as List).cast<Map>();
    expect(ms.map((m) => m['name']), contains(real.uptimeSite));
    final beats = await c.get('/v1/uptime/monitors/${ms.first['id']}/beats', query: {'hours': '1'});
    expect((beats['beats'] as List), isNotEmpty);
    c.close();
  });

  test('sunucu: bakım penceresi ekle, listele, sil; uyarılar, süreçler ve işlem kaydı', () async {
    final c = AgentClient(baseUrl: real.agent(real.server), token: File(real.serverToken).readAsStringSync().trim());
    final ms = ((await c.get('/v1/uptime/monitors'))['monitors'] as List).cast<Map>();
    // Gerçek uyarıları bastırmamak için pencere iki gün sonrasına, 30 dakikalık.
    final start = DateTime.now().toUtc().add(const Duration(days: 2));
    final added = await c.post('/v1/uptime/maintenance', {
      'title': 'tiphys-test',
      'monitorIds': [ms.first['id']],
      'start': start.toIso8601String(),
      'end': start.add(const Duration(minutes: 30)).toIso8601String(),
    }) as Map;
    final id = added['id'] as int;
    try {
      final list = ((await c.get('/v1/uptime/maintenance'))['maintenances'] as List).cast<Map>();
      final m = list.firstWhere((x) => x['id'] == id);
      expect(m['title'], 'tiphys-test');
      expect(m['monitorIds'], [ms.first['id']]);
      expect(m['status'], 'scheduled');
      expect(m['start'], isNotNull);
    } finally {
      await c.delete('/v1/uptime/maintenance/$id');
    }
    final after = ((await c.get('/v1/uptime/maintenance'))['maintenances'] as List).cast<Map>();
    expect(after.where((x) => x['id'] == id), isEmpty);

    expect((await c.get('/v1/alerts'))['active'], isA<List>());
    final procs = await c.get('/v1/processes', query: {'sort': 'mem', 'limit': '5'});
    expect((procs['processes'] as List), hasLength(5));
    final audit = ((await c.get('/v1/audit'))['entries'] as List).cast<Map>();
    expect(audit.first['path'], '/v1/uptime/maintenance/$id');
    expect(audit.first['method'], 'DELETE');
    c.close();
  });

  test('erişilemeyen ajan → net.unreachable / net.timeout', () async {
    final c = AgentClient(baseUrl: 'https://100.64.0.250:7443', token: 'tph_x', timeout: const Duration(seconds: 4));
    await expectLater(c.get('/v1/system'), throwsA(isA<AgentError>().having((e) => e.code, 'code', anyOf('net.unreachable', 'net.timeout'))));
    c.close();
  });

  test('eşleşme QR içeriği ayrıştırılır, sahte içerik reddedilir', () {
    expect(PairPayload.tryParse('{"v":1,"type":"tiphys-pair","agent":"argo","url":"https://x:7443","token":"tph_abc"}')?.agent, 'argo');
    expect(PairPayload.tryParse('{"v":1,"type":"tiphys-pair","agent":"x","url":"javascript:alert(1)","token":"tph_abc"}'), isNull);
    expect(PairPayload.tryParse('https://evil.example'), isNull);
  });
}
