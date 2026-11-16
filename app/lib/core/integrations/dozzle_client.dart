// Dozzle (v11) client: container list (from the SSE event stream), historical logs (JSONL) and live stream (SSE).
import 'dart:async';
import 'dart:convert';

import 'http_json.dart';

class DozzleContainer {
  DozzleContainer(this.j);
  final Map<String, dynamic> j;
  String get id => j['id'] as String;
  String get name => j['name'] as String;
  String get host => j['host'] as String;
  String get image => (j['image'] as String? ?? '').split('@').first;
  String get state => j['state'] as String? ?? '';
  String? get health => j['health'] as String?;
  String? get project => (j['labels'] as Map?)?['com.docker.compose.project'] as String?;
  double? get cpu => (((j['stats'] as List?)?.lastOrNull as Map?)?['cpu'] as num?)?.toDouble();
  int? get memoryBytes => (((j['stats'] as List?)?.lastOrNull as Map?)?['memoryUsage'] as num?)?.toInt();
  bool get running => state == 'running';
}

class DozzleLog {
  DozzleLog(this.j);
  final Map<String, dynamic> j;
  int get id => (j['id'] as num?)?.toInt() ?? 0;
  DateTime get time => DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0);
  String get level => j['l'] as String? ?? 'unknown';
  String get stream => j['s'] as String? ?? 'stdout';

  /// The message may be plain text or (for JSON log lines) an object.
  Object? get message => j['m'];
  bool get isJson => message is Map || message is List;
  String get text => message is String ? message as String : const JsonEncoder.withIndent('  ').convert(message);
}

const dozzleLevels = ['error', 'warn', 'info', 'debug', 'trace', 'fatal', 'unknown'];

class DozzleClient {
  DozzleClient(String url, {String? username, String? password})
      : _h = HttpJson(url, headers: {
          if (username != null && password != null) 'Authorization': 'Basic ${base64.encode(utf8.encode('$username:$password'))}',
        });
  final HttpJson _h;

  /// Waits for the first "containers-changed" message in the event stream.
  Future<List<DozzleContainer>> containers() async {
    await for (final (event, data) in _h.sse('/api/events/stream').timeout(const Duration(seconds: 15))) {
      if (event == 'containers-changed') {
        return [for (final c in jsonDecode(data) as List) DozzleContainer(Map<String, dynamic>.from(c as Map))]
          ..sort((a, b) => a.running != b.running ? (a.running ? -1 : 1) : a.name.compareTo(b.name));
      }
    }
    return const [];
  }

  Future<List<DozzleLog>> history(DozzleContainer c, {Duration window = const Duration(hours: 1), List<String> levels = dozzleLevels}) async {
    final now = DateTime.now().toUtc();
    final rows = await _h.jsonl('/api/hosts/${c.host}/containers/${c.id}/logs', query: {
      'stdout': '1',
      'stderr': '1',
      'from': now.subtract(window).toIso8601String(),
      'to': now.toIso8601String(),
      'levels': levels,
    });
    return rows.map(DozzleLog.new).toList();
  }

  /// Live logs. Lasts until the stream is cancelled or the connection drops.
  Stream<DozzleLog> stream(DozzleContainer c) => _h
      .sse('/api/hosts/${c.host}/containers/${c.id}/logs/stream', query: {'stdout': '1', 'stderr': '1', 'levels': dozzleLevels})
      .where((e) => e.$1 == 'message')
      .map((e) => jsonDecode(e.$2))
      .where((j) => j is Map && j.containsKey('m'))
      .map((j) => DozzleLog(Map<String, dynamic>.from(j as Map)));

  /// Are container actions (start/stop/restart) enabled on the server? Dozzle has no official settings endpoint;
  /// the settings embedded in its UI (`<script id="config__json">`) are read. Actions are enabled only with
  /// `DOZZLE_ENABLE_ACTIONS=true`; when disabled, the action endpoints return 404.
  Future<bool> actionsEnabled() async {
    final res = await _h.open('GET', _h.uri('/'));
    final html = await res.transform(utf8.decoder).join().timeout(_h.timeout);
    return parseActionsEnabled(html);
  }

  static bool parseActionsEnabled(String html) {
    final m = RegExp(r'id="config__json"[^>]*>([\s\S]*?)</script>').firstMatch(html);
    if (m == null) return false;
    try {
      final j = jsonDecode(m.group(1)!);
      return j is Map && j['enableActions'] == true;
    } on FormatException {
      return false;
    }
  }

  /// `action`: start | stop | restart
  Future<void> action(DozzleContainer c, String action) => _h.json('POST', '/api/hosts/${c.host}/containers/${c.id}/actions/$action');

  void close() => _h.close();
}
