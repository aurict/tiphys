// Small HTTP helpers for integrations: JSON requests, JSONL and SSE (Server-Sent Events) streams.
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

  /// JSON lines (application/x-jsonl).
  Future<List<Map<String, dynamic>>> jsonl(String path, {Map<String, dynamic>? query}) async {
    final res = await open('GET', uri(path, query));
    final out = <Map<String, dynamic>>[];
    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter()).timeout(timeout)) {
      if (line.trim().isEmpty) continue;
      out.add(Map<String, dynamic>.from(jsonDecode(line) as Map));
    }
    return out;
  }

  /// SSE: (event name, data) pairs. The stream ends when the connection closes.
  /// Uses a controller instead of `async*`: when the listener cancels, the connection closes immediately. (An
  /// `async*` generator cancelled while awaiting data only stops when the next line arrives; on a quiet log stream
  /// that can take minutes.)
  Stream<(String, String)> sse(String path, {Map<String, dynamic>? query}) {
    StreamSubscription<String>? sub;
    var cancelled = false;
    late final StreamController<(String, String)> ctrl;
    ctrl = StreamController<(String, String)>(
      onListen: () async {
        final HttpClientResponse res;
        try {
          res = await open('GET', uri(path, query), extra: {'Accept': 'text/event-stream'});
        } catch (e, st) {
          if (!cancelled) {
            ctrl.addError(e, st);
            await ctrl.close();
          }
          return;
        }
        if (cancelled) {
          // Cancelled while connecting: listen to the response and drop it right away (the socket closes).
          await res.listen(null).cancel();
          return;
        }
        var event = 'message';
        final data = StringBuffer();
        sub = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.isEmpty) {
              if (data.isNotEmpty) ctrl.add((event, data.toString()));
              event = 'message';
              data.clear();
            } else if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.write('\n');
              data.write(line.substring(5).trimLeft());
            }
          },
          onError: ctrl.addError,
          onDone: ctrl.close,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  void close() => _http.close(force: true);
}
