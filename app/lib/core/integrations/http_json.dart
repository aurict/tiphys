// Entegrasyonlar için küçük HTTP yardımcıları: JSON istekleri, JSONL ve SSE (Server-Sent Events) akışı.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class IntegrationError implements Exception {
  const IntegrationError(this.code, [this.detail]);

  /// net.unreachable | net.timeout | net.tls | http.401 | http.403 | http.404 | http.5xx | badResponse
  final String code;
  final String? detail;
  @override
  String toString() => 'IntegrationError($code${detail == null ? '' : ': $detail'})';
}

class HttpJson {
  HttpJson(this.baseUrl, {this.headers = const {}, this.timeout = const Duration(seconds: 20)})
      : _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  final String baseUrl;
  final Map<String, String> headers;
  final Duration timeout;
  final HttpClient _http;

  Uri uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  Future<HttpClientResponse> open(String method, Uri u, {Object? body, Map<String, String> extra = const {}}) async {
    try {
      final req = await _http.openUrl(method, u).timeout(timeout);
      headers.forEach(req.headers.set);
      extra.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(timeout);
      if (res.statusCode >= 400) {
        final text = await res.transform(utf8.decoder).join().catchError((_) => '');
        throw IntegrationError(res.statusCode >= 500 ? 'http.5xx' : 'http.${res.statusCode}', text.length > 300 ? text.substring(0, 300) : text);
      }
      return res;
    } on IntegrationError {
      rethrow;
    } on TimeoutException {
      throw const IntegrationError('net.timeout');
    } on SocketException catch (e) {
      throw IntegrationError('net.unreachable', e.message);
    } on HandshakeException {
      throw const IntegrationError('net.tls');
    }
  }

  Future<dynamic> json(String method, String path, {Object? body, Map<String, dynamic>? query}) async {
    final res = await open(method, uri(path, query), body: body);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    try {
      return text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      throw const IntegrationError('badResponse');
    }
  }

  /// JSON satırları (application/x-jsonl).
  Future<List<Map<String, dynamic>>> jsonl(String path, {Map<String, dynamic>? query}) async {
    final res = await open('GET', uri(path, query));
    final out = <Map<String, dynamic>>[];
    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter()).timeout(timeout)) {
      if (line.trim().isEmpty) continue;
      out.add(Map<String, dynamic>.from(jsonDecode(line) as Map));
    }
    return out;
  }

  /// SSE: (olay adı, veri) çiftleri. Bağlantı kapanınca akış biter.
  Stream<(String, String)> sse(String path, {Map<String, dynamic>? query}) async* {
    final res = await open('GET', uri(path, query), extra: {'Accept': 'text/event-stream'});
    var event = 'message';
    final data = StringBuffer();
    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) yield (event, data.toString());
        event = 'message';
        data.clear();
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  void close() => _http.close(force: true);
}
