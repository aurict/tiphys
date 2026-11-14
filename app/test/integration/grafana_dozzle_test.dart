// Gerçek Grafana ve Dozzle'a karşı istemci testleri (sunucu). Hedefler: real_env.dart.
@Tags(['real'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/integrations/dozzle_client.dart';
import 'package:tiphys/core/integrations/grafana_client.dart';

import 'real_env.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);

  group('Grafana', () {
    late GrafanaClient g;
    setUpAll(() => g = GrafanaClient('https://${real.host(real.server)}:3030', token: File(real.grafanaToken).readAsStringSync().trim()));
    tearDownAll(() => g.close());

    test('dashboard listesi', () async {
      final list = await g.search();
      expect(list.map((d) => d.uid), contains('systems-overview'));
    });

    test('System overview: değişkenler, stat ve zaman serisi verisi', () async {
      final d = await g.dashboard('systems-overview');
      final vars = GrafanaClient.variables(d);
      for (final v in vars) {
        await g.loadOptions(v);
      }
      final system = vars.firstWhere((v) => v.name == 'system');
      expect(system.options, isNotEmpty);
      final panels = GrafanaClient.panels(d);
      final stat = panels.firstWhere((p) => p.type == 'stat');
      final sd = await g.query(stat, vars, from: 'now-1h');
      expect(sd.series, isNotEmpty);
      expect(sd.series.first.last, isNotNull);
      final ts = panels.firstWhere((p) => p.type == 'timeseries');
      final td = await g.query(ts, vars, from: 'now-1h');
      expect(td.series.first.values.length, greaterThan(10));
      final logs = panels.where((p) => p.type == 'logs').firstOrNull;
      if (logs != null) {
        final ld = await g.query(logs, vars, from: 'now-6h');
        expect(ld.logs, isA<List<LogRow>>());
      }
    });

    test('Home: metin, alarm listesi ve dashboard listesi panelleri', () async {
      final d = await g.dashboard('home');
      final panels = GrafanaClient.panels(d);
      final text = panels.firstWhere((p) => p.type == 'text');
      expect('${text.options['content']}', contains('Systems'));
      final al = panels.firstWhere((p) => p.type == 'alertlist');
      final ad = await g.query(al, const [], from: 'now-1h', prometheusUid: 'prom');
      expect(ad.alerts, isA<List<GrafanaAlert>>());
      for (final a in ad.alerts) {
        expect(['firing', 'pending', 'error', 'nodata'], contains(a.state));
      }
      final dl = panels.firstWhere((p) => p.type == 'dashlist');
      final dd = await g.query(dl, const [], from: 'now-1h');
      expect(dd.dashboards.map((x) => x.uid), contains('systems-overview'));
      expect(GrafanaClient.prometheusUid(await g.dashboard('systems-overview')), 'prom');
    });

    test('veri kaynakları, alarm kuralları ve serbest sorgu (Explore)', () async {
      final ds = await g.datasources();
      expect(ds.map((d) => (d.uid, d.type)), contains(('prom', 'prometheus')));
      final rules = await g.rules(['prom']);
      expect(rules.map((r) => r.name), contains('AurictBackupStale'));
      for (final r in rules) {
        expect(['firing', 'pending', 'normal', 'error', 'nodata'], contains(r.state));
      }
      final panel = GrafanaPanel({
        'id': 0,
        'type': 'timeseries',
        'title': '',
        'datasource': {'type': 'prometheus', 'uid': 'prom'},
        'targets': [
          {'refId': 'A', 'expr': 'up', 'datasource': {'type': 'prometheus', 'uid': 'prom'}},
        ],
      });
      final d = await g.query(panel, const [], from: 'now-15m');
      expect(d.series, isNotEmpty);
    });

    test('yerleştirme: Hepsi ve çoklu değer', () {
      final v = GrafanaVariable(name: 'c', label: 'c', type: 'query', multi: true, includeAll: true, options: ['a.b', 'x'], current: [r'$__all']);
      expect(GrafanaClient.interpolate('{c=~"\$c"}', [v]), r'{c=~"(a\.b|x)"}');
      v.current = ['x'];
      expect(GrafanaClient.interpolate(r'{c=~"${c}"} [[c]]', [v]), '{c=~"x"} x');
    });

    test('birimler', () {
      expect(formatValue(0.181, 'percentunit'), '18.1%');
      expect(formatValue(1536, 'bytes'), '1.5 KB');
      expect(formatValue(0.25, 's'), '250 ms');
      expect(formatValue(3600 * 5, 's'), '5.0 sa');
    });
  });

  group('Dozzle', () {
    late DozzleClient d;
    setUpAll(() => d = DozzleClient('https://${real.host(real.server)}:8888'));
    tearDownAll(() => d.close());

    test('container listesi ve geçmiş log', () async {
      final cs = await d.containers();
      expect(cs.where((c) => c.running), isNotEmpty);
      final pg = cs.firstWhere((c) => c.name.contains('postgres'), orElse: () => cs.first);
      final logs = await d.history(pg, window: const Duration(hours: 12));
      expect(logs, isA<List<DozzleLog>>());
      if (logs.isNotEmpty) expect(logs.first.text, isNotEmpty);
    });
  });
}
