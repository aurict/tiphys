// Grafana client: dashboard JSON, variables, data via /api/ds/query, unit formatting.
// Panel types: stat, timeseries, table, logs are drawn in the app; others open in the browser.
import 'dart:math' as math;

import 'http_json.dart';

class GrafanaDashboardRef {
  const GrafanaDashboardRef({required this.uid, required this.title, this.folder});
  final String uid;
  final String title;
  final String? folder;
}

class GrafanaVariable {
  GrafanaVariable({
    required this.name,
    required this.label,
    required this.type,
    required this.multi,
    required this.includeAll,
    this.allValue,
    this.options = const [],
    this.current = const [],
    this.datasourceUid,
    this.datasourceType,
    this.query,
  });
  final String name;
  final String label;
  final String type; // query | custom | textbox | constant | interval
  final bool multi;
  final bool includeAll;
  final String? allValue;
  List<String> options;
  List<String> current; // '$__all' = All
  final String? datasourceUid;
  final String? datasourceType;
  final String? query;

  bool get isAll => current.contains(r'$__all');
}

class GrafanaTarget {
  const GrafanaTarget({required this.refId, required this.expr, this.legendFormat, this.instant = false, this.datasourceUid, this.datasourceType});
  final String refId;
  final String expr;
  final String? legendFormat;
  final bool instant;
  final String? datasourceUid;
  final String? datasourceType;
}

class GrafanaPanel {
  GrafanaPanel(this.j, {this.row});
  final Map<String, dynamic> j;
  final String? row;
  int get id => (j['id'] as num?)?.toInt() ?? 0;
  String get type => j['type'] as String? ?? '';
  String get title => j['title'] as String? ?? '';
  Map<String, dynamic> get defaults => Map<String, dynamic>.from(((j['fieldConfig'] as Map?)?['defaults'] as Map?) ?? {});
  String? get unit => defaults['unit'] as String?;
  int? get decimals => (defaults['decimals'] as num?)?.toInt();
  num? get min => defaults['min'] as num?;
  num? get max => defaults['max'] as num?;
  List<(double?, String)> get thresholds => [
        for (final s in ((defaults['thresholds'] as Map?)?['steps'] as List?) ?? const [])
          (((s as Map)['value'] as num?)?.toDouble(), '${s['color']}'),
      ];
  bool get native => const {'stat', 'timeseries', 'table', 'logs', 'gauge', 'bargauge', 'text', 'alertlist', 'dashlist'}.contains(type);
  Map<String, dynamic> get options => Map<String, dynamic>.from((j['options'] as Map?) ?? {});

  List<GrafanaTarget> targets() {
    final pds = j['datasource'] as Map?;
    return [
      for (final t in (j['targets'] as List?) ?? const [])
        if ((t as Map)['hide'] != true && (t['expr'] is String))
          GrafanaTarget(
            refId: t['refId'] as String? ?? 'A',
            expr: t['expr'] as String,
            legendFormat: t['legendFormat'] as String?,
            instant: t['instant'] == true || type == 'stat' && t['range'] == false || type == 'table' && t['format'] == 'table',
            datasourceUid: ((t['datasource'] as Map?)?['uid'] ?? pds?['uid']) as String?,
            datasourceType: ((t['datasource'] as Map?)?['type'] ?? pds?['type']) as String?,
          ),
    ];
  }
}

class Series {
  Series(this.name, this.times, this.values);
  final String name;
  final List<int> times; // ms
  final List<double?> values;
  double? get last => values.lastWhere((v) => v != null, orElse: () => null);
}

class LogRow {
  const LogRow(this.time, this.line, this.labels);
  final DateTime time;
  final String line;
  final Map<String, String> labels;
}

class GrafanaRule {
  const GrafanaRule({
    required this.name,
    required this.group,
    required this.source,
    required this.state,
    this.severity,
    this.summary,
    this.query,
    this.activeAt,
    this.activeCount = 0,
  });
  final String name;
  final String group;
  final String source;

  /// firing | pending | normal | error | nodata
  final String state;
  final String? severity;
  final String? summary;
  final String? query;
  final DateTime? activeAt;
  final int activeCount;
}

class GrafanaAlert {
  const GrafanaAlert({required this.name, required this.state, this.summary, this.severity, this.activeAt});
  final String name;
  final String state; // firing | pending | error | nodata | normal
  final String? summary;
  final String? severity;
  final DateTime? activeAt;
}

class PanelData {
  const PanelData({this.series = const [], this.logs = const [], this.table, this.alerts = const [], this.dashboards = const []});
  final List<Series> series;
  final List<LogRow> logs;
  final (List<String>, List<List<String>>)? table;
  final List<GrafanaAlert> alerts;
  final List<GrafanaDashboardRef> dashboards;
}

class GrafanaClient {
  GrafanaClient(String url, {String? token}) : _h = HttpJson(url, headers: {if (token != null) 'Authorization': 'Bearer $token'});
  final HttpJson _h;
  String get baseUrl => _h.baseUrl;

  Future<List<GrafanaDashboardRef>> search([String q = '']) async {
    final list = await _h.json('GET', '/api/search', query: {'type': 'dash-db', 'query': q}) as List;
    return [
      for (final d in list.cast<Map>()) GrafanaDashboardRef(uid: d['uid'] as String, title: d['title'] as String, folder: d['folderTitle'] as String?),
    ];
  }

  Future<Map<String, dynamic>> dashboard(String uid) async =>
      Map<String, dynamic>.from(((await _h.json('GET', '/api/dashboards/uid/$uid')) as Map)['dashboard'] as Map);

  /// Rows are flattened; panels of collapsed rows are included too.
  static List<GrafanaPanel> panels(Map<String, dynamic> d) {
    final out = <GrafanaPanel>[];
    String? row;
    for (final p in (d['panels'] as List? ?? const []).cast<Map>()) {
      final m = Map<String, dynamic>.from(p);
      if (m['type'] == 'row') {
        row = m['title'] as String?;
        for (final c in (m['panels'] as List? ?? const []).cast<Map>()) {
          out.add(GrafanaPanel(Map<String, dynamic>.from(c), row: row));
        }
      } else {
        out.add(GrafanaPanel(m, row: row));
      }
    }
    return out;
  }

  static List<GrafanaVariable> variables(Map<String, dynamic> d) {
    final out = <GrafanaVariable>[];
    for (final v in ((d['templating'] as Map?)?['list'] as List? ?? const []).cast<Map>()) {
      if (v['hide'] == 2) continue;
      final cur = v['current'] as Map?;
      final curVal = cur?['value'];
      final q = v['query'];
      out.add(GrafanaVariable(
        name: v['name'] as String,
        label: (v['label'] as String?)?.isNotEmpty == true ? v['label'] as String : v['name'] as String,
        type: v['type'] as String? ?? 'custom',
        multi: v['multi'] == true,
        includeAll: v['includeAll'] == true,
        allValue: v['allValue'] as String?,
        options: [for (final o in (v['options'] as List? ?? const []).cast<Map>()) '${o['value']}'].where((o) => o != r'$__all').toList(),
        current: curVal is List ? curVal.map((e) => '$e').toList() : [if (curVal != null) '$curVal'],
        datasourceUid: (v['datasource'] as Map?)?['uid'] as String?,
        datasourceType: (v['datasource'] as Map?)?['type'] as String?,
        query: q is Map ? (q['query'] as String?) : (q is String ? q : null),
      ));
    }
    return out;
  }

  /// Loads options from the server (label_values and constant lists).
  Future<void> loadOptions(GrafanaVariable v) async {
    if (v.type == 'custom' && v.query != null) {
      v.options = v.query!.split(RegExp(r'\s*,\s*')).where((s) => s.isNotEmpty).toList();
    } else if (v.type == 'query' && v.query != null && v.datasourceUid != null) {
      final m = RegExp(r'label_values\(\s*(?:(.+?)\s*,\s*)?(\w+)\s*\)').firstMatch(v.query!);
      if (m != null) {
        final metric = m[1], label = m[2]!;
        final loki = v.datasourceType == 'loki';
        final path = loki ? '/api/datasources/uid/${v.datasourceUid}/resources/label/$label/values' : '/api/datasources/uid/${v.datasourceUid}/resources/api/v1/label/$label/values';
        final res = await _h.json('GET', path, query: {(loki ? 'query' : 'match[]'): ?metric}) as Map;
        v.options = ((res['data'] as List?) ?? const []).map((e) => '$e').toList();
      }
    }
    if (v.current.isEmpty || (!v.isAll && v.current.any((c) => !v.options.contains(c)) && v.type != 'textbox')) {
      v.current = v.includeAll ? [r'$__all'] : [if (v.options.isNotEmpty) v.options.first];
    }
  }

  /// $variable / ${variable} / [[variable]] substitution. Multiple values and "All" are converted to a regex.
  static String interpolate(String expr, List<GrafanaVariable> vars) {
    var out = expr;
    for (final v in vars) {
      String value;
      if (v.isAll) {
        value = v.allValue ?? (v.options.isEmpty ? '.*' : '(${v.options.map(_re).join('|')})');
      } else if (v.current.length > 1) {
        value = '(${v.current.map(_re).join('|')})';
      } else {
        value = v.current.firstOrNull ?? '';
        if (v.type != 'textbox' && v.multi) value = _re(value);
      }
      out = out
          .replaceAll(RegExp('\\\$\\{${v.name}(?::[a-z]+)?\\}'), value)
          .replaceAll('[[${v.name}]]', value)
          .replaceAll(RegExp('\\\$${v.name}(?![A-Za-z0-9_])'), value);
    }
    return out;
  }

  static String _re(String s) => s.replaceAllMapped(RegExp(r'[.*+?^${}()|\[\]\\]'), (m) => '\\${m[0]}');

  /// Id of the dashboard's first Prometheus data source (for the alert list).
  static String? prometheusUid(Map<String, dynamic> d) {
    for (final p in panels(d)) {
      final ds = p.j['datasource'] as Map?;
      if (ds?['type'] == 'prometheus' && ds?['uid'] is String) return ds!['uid'] as String;
      for (final t in p.targets()) {
        if (t.datasourceType == 'prometheus' && t.datasourceUid != null) return t.datasourceUid;
      }
    }
    return null;
  }

  /// Data sources (uid, type, name).
  Future<List<({String uid, String type, String name})>> datasources() async {
    final list = await _h.json('GET', '/api/datasources') as List;
    return [for (final d in list.cast<Map>()) (uid: '${d['uid']}', type: '${d['type']}', name: '${d['name']}')];
  }

  /// All alert rules and states: Grafana's own rules + the rules of each Prometheus data source.
  Future<List<GrafanaRule>> rules(List<String> prometheusUids) async {
    final out = <GrafanaRule>[];
    Future<void> load(String path, String source) async {
      try {
        final res = await _h.json('GET', path) as Map;
        for (final g in (((res['data'] as Map?)?['groups'] as List?) ?? const []).cast<Map>()) {
          for (final r in ((g['rules'] as List?) ?? const []).cast<Map>()) {
            if (r['type'] != null && r['type'] != 'alerting') continue;
            final labels = Map<String, dynamic>.from((r['labels'] as Map?) ?? {});
            final ann = Map<String, dynamic>.from((r['annotations'] as Map?) ?? {});
            var state = '${r['state'] ?? 'inactive'}'.toLowerCase();
            if (state == 'alerting') state = 'firing';
            if (state == 'inactive') state = 'normal';
            if (r['health'] == 'err' || r['health'] == 'error') state = 'error';
            final active = ((r['alerts'] as List?) ?? const []).cast<Map>();
            out.add(GrafanaRule(
              name: '${r['name']}',
              group: '${g['name']}',
              source: source,
              state: state,
              severity: labels['severity'] as String?,
              summary: (ann['summary'] ?? ann['description']) as String?,
              query: r['query'] as String?,
              activeAt: active.map((a) => DateTime.tryParse('${a['activeAt'] ?? ''}')).whereType<DateTime>().fold<DateTime?>(
                  null, (m, d) => m == null || d.isBefore(m) ? d : m),
              activeCount: active.length,
            ));
          }
        }
      } on IntegrationError {
        // If this source is unreachable, the others are still shown.
      }
    }

    await load('/api/prometheus/grafana/api/v1/rules', 'Grafana');
    for (final uid in prometheusUids) {
      await load('/api/datasources/uid/$uid/resources/api/v1/rules', uid);
    }
    const order = {'firing': 0, 'error': 1, 'nodata': 2, 'pending': 3, 'normal': 4};
    out.sort((a, b) {
      final c = (order[a.state] ?? 5).compareTo(order[b.state] ?? 5);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return out;
  }

  /// Grafana's own alerts + Prometheus/Alertmanager alerts (if any).
  Future<List<GrafanaAlert>> alerts({String? prometheusUid}) async {
    final out = <GrafanaAlert>[];
    Future<void> load(String path) async {
      try {
        final res = await _h.json('GET', path) as Map;
        for (final a in (((res['data'] as Map?)?['alerts'] as List?) ?? const []).cast<Map>()) {
          final labels = Map<String, dynamic>.from((a['labels'] as Map?) ?? {});
          final ann = Map<String, dynamic>.from((a['annotations'] as Map?) ?? {});
          var state = '${a['state']}'.toLowerCase();
          if (state == 'alerting') state = 'firing';
          if (state == 'inactive') state = 'normal';
          out.add(GrafanaAlert(
            name: '${labels['alertname'] ?? labels['__alert_rule_title__'] ?? '?'}',
            state: state,
            summary: (ann['summary'] ?? ann['description']) as String?,
            severity: labels['severity'] as String?,
            activeAt: DateTime.tryParse('${a['activeAt'] ?? ''}'),
          ));
        }
      } on IntegrationError {
        // If this source is unreachable, the others are still shown.
      }
    }

    await load('/api/prometheus/grafana/api/v1/alerts');
    if (prometheusUid != null) await load('/api/datasources/uid/$prometheusUid/resources/api/v1/alerts');
    const order = {'firing': 0, 'error': 1, 'nodata': 2, 'pending': 3, 'normal': 4};
    out.sort((a, b) => (order[a.state] ?? 5).compareTo(order[b.state] ?? 5));
    return out;
  }

  Future<PanelData> query(
    GrafanaPanel p,
    List<GrafanaVariable> vars, {
    required String from,
    String to = 'now',
    int maxDataPoints = 120,
    String? prometheusUid,
  }) async {
    switch (p.type) {
      case 'text':
        return const PanelData();
      case 'alertlist':
        final o = p.options;
        final f = Map<String, dynamic>.from((o['stateFilter'] as Map?) ?? {'firing': true, 'pending': true});
        bool want(String s) => switch (s) {
              'firing' => f['firing'] != false,
              'pending' => f['pending'] == true,
              'error' => f['error'] == true,
              'nodata' => f['noData'] == true,
              _ => f['normal'] == true,
            };
        final list = (await alerts(prometheusUid: prometheusUid)).where((a) => want(a.state)).take((o['maxItems'] as num?)?.toInt() ?? 20).toList();
        return PanelData(alerts: list);
      case 'dashlist':
        final o = p.options;
        final ds = await search('${o['query'] ?? ''}');
        return PanelData(dashboards: ds.take((o['maxItems'] as num?)?.toInt() ?? 10).toList());
    }
    final targets = p.targets();
    if (targets.isEmpty) return const PanelData();
    final res = await _h.json('POST', '/api/ds/query', body: {
      'from': from,
      'to': to,
      'queries': [
        for (final t in targets)
          {
            'refId': t.refId,
            'datasource': {'uid': t.datasourceUid, 'type': t.datasourceType},
            'expr': interpolate(t.expr, vars),
            'legendFormat': t.legendFormat,
            'instant': t.instant,
            'range': !t.instant,
            'maxDataPoints': maxDataPoints,
            'intervalMs': 15000,
            if (t.datasourceType == 'loki' && p.type == 'logs') ...{'queryType': 'range', 'maxLines': 200},
          },
      ],
    }) as Map;
    final series = <Series>[];
    final logs = <LogRow>[];
    for (final r in ((res['results'] as Map?) ?? {}).values) {
      final err = (r as Map)['error'];
      if (err != null) throw IntegrationError('grafana.query', '$err');
      final legend = targets.firstWhere((t) => t.refId == r['refId'], orElse: () => targets.first).legendFormat;
      for (final f in (r['frames'] as List? ?? const []).cast<Map>()) {
        final fields = ((f['schema'] as Map)['fields'] as List).cast<Map>();
        final values = ((f['data'] as Map?)?['values'] as List?) ?? const [];
        if (values.isEmpty) continue;
        final lineIdx = fields.indexWhere((x) => x['name'] == 'Line' || x['name'] == 'line');
        final timeIdx = fields.indexWhere((x) => x['type'] == 'time');
        if (lineIdx >= 0 && timeIdx >= 0) {
          final labelsIdx = fields.indexWhere((x) => x['name'] == 'labels');
          final lines = values[lineIdx] as List, times = values[timeIdx] as List;
          for (var i = 0; i < lines.length; i++) {
            final lab = labelsIdx >= 0 ? (values[labelsIdx] as List)[i] : null;
            logs.add(LogRow(DateTime.fromMillisecondsSinceEpoch((times[i] as num).toInt()), '${lines[i]}',
                lab is Map ? lab.map((k, v) => MapEntry('$k', '$v')) : const {}));
          }
          continue;
        }
        for (var fi = 0; fi < fields.length; fi++) {
          if (fi == timeIdx || fields[fi]['type'] != 'number') continue;
          final labels = Map<String, String>.from(((fields[fi]['labels'] as Map?) ?? {}).map((k, v) => MapEntry('$k', '$v')));
          final name = (fields[fi]['config'] as Map?)?['displayNameFromDS'] as String? ??
              _legend(legend, labels) ??
              (labels.isEmpty ? (fields[fi]['name'] as String? ?? p.title) : labels.values.join(' '));
          series.add(Series(
            name,
            timeIdx >= 0 ? [for (final t in values[timeIdx] as List) (t as num).toInt()] : const [],
            [for (final v in values[fi] as List) (v as num?)?.toDouble()],
          ));
        }
      }
    }
    logs.sort((a, b) => b.time.compareTo(a.time));
    return PanelData(series: series, logs: logs);
  }

  static String? _legend(String? format, Map<String, String> labels) {
    if (format == null || format.isEmpty || format == '__auto') return null;
    return format.replaceAllMapped(RegExp(r'\{\{\s*(\w+)\s*\}\}'), (m) => labels[m[1]] ?? '');
  }

  void close() => _h.close();
}

/// Value formatting with Grafana units (common units).
String formatValue(double? v, String? unit, {int? decimals}) {
  if (v == null || v.isNaN) return '–';
  String n(double x, [int d = 1]) => x.toStringAsFixed(decimals ?? (x.abs() >= 100 ? 0 : d));
  String bytes(double x, int base, List<String> u) {
    var i = 0;
    while (x.abs() >= base && i < u.length - 1) {
      x /= base;
      i++;
    }
    return '${n(x)} ${u[i]}';
  }

  switch (unit) {
    case 'percent':
      return '${n(v)}%';
    case 'percentunit':
      return '${n(v * 100)}%';
    case 'bytes' || 'decbytes':
      return bytes(v, unit == 'bytes' ? 1024 : 1000, const ['B', 'KB', 'MB', 'GB', 'TB']);
    case 'Bps' || 'binBps':
      return '${bytes(v, unit == 'binBps' ? 1024 : 1000, const ['B', 'KB', 'MB', 'GB'])}/s';
    case 'bps':
      return bytes(v, 1000, const ['b/s', 'kb/s', 'Mb/s', 'Gb/s']);
    case 's' || 'dtdurations':
      if (v.abs() < 1) return '${n(v * 1000, 0)} ms';
      if (v.abs() < 120) return '${n(v)} s';
      if (v.abs() < 7200) return '${n(v / 60)} dk';
      if (v.abs() < 172800) return '${n(v / 3600)} sa';
      return '${n(v / 86400)} g';
    case 'ms':
      return v.abs() < 1000 ? '${n(v, 0)} ms' : '${n(v / 1000)} s';
    case 'reqps':
      return '${n(v)} req/s';
    case 'short' || 'none' || null:
      final a = v.abs();
      if (a >= 1e9) return '${n(v / 1e9)}B';
      if (a >= 1e6) return '${n(v / 1e6)}M';
      if (a >= 1e3) return '${n(v / 1e3)}K';
      return n(v, a < 10 ? 2 : 1).replaceFirst(RegExp(r'\.0+$'), '');
    default:
      return '${n(v)} $unit';
  }
}

/// By threshold color (Grafana named colors with approximate equivalents).
int thresholdColor(List<(double?, String)> steps, double? v) {
  var color = steps.isEmpty ? 'green' : steps.first.$2;
  if (v != null) {
    for (final (t, c) in steps) {
      if (t == null || v >= t) color = c;
    }
  }
  return switch (color) {
    'red' || 'dark-red' || 'semi-dark-red' => 0xFFFF6961,
    'orange' || 'dark-orange' => 0xFFFFB340,
    'yellow' || 'dark-yellow' => 0xFFFFD60A,
    'blue' || 'dark-blue' => 0xFF64B5F6,
    'purple' => 0xFFA39DF5,
    'text' || 'transparent' => 0xFF98989F,
    _ when color.startsWith('#') && color.length == 7 => int.parse('FF${color.substring(1)}', radix: 16),
    _ => 0xFF30D158,
  };
}

/// Round step for the axis.
double niceStep(double range, int ticks) {
  if (range <= 0) return 1;
  final raw = range / ticks;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final f = raw / mag;
  return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag;
}
