// Dozzle (v11) istemcisi: container listesi (SSE olay akışından), geçmiş loglar (JSONL) ve canlı akış (SSE).
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
  double? get cpu => ((j['stats'] as List?)?.lastOrNull as Map?)?['cpu'] as double?;
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

  /// Mesaj düz metin ya da (JSON log satırlarında) nesne olabilir.
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

  /// Olay akışındaki ilk "containers-changed" mesajını bekler.
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

  /// Canlı loglar. Akış iptal edilene ya da bağlantı kopana kadar sürer.
  Stream<DozzleLog> stream(DozzleContainer c) => _h
      .sse('/api/hosts/${c.host}/containers/${c.id}/logs/stream', query: {'stdout': '1', 'stderr': '1', 'levels': dozzleLevels})
      .where((e) => e.$1 == 'message')
      .map((e) => jsonDecode(e.$2))
      .where((j) => j is Map && j.containsKey('m'))
      .map((j) => DozzleLog(Map<String, dynamic>.from(j as Map)));

  Future<void> action(DozzleContainer c, String action) => _h.json('POST', '/api/hosts/${c.host}/containers/${c.id}/actions/$action');

  void close() => _h.close();
}
