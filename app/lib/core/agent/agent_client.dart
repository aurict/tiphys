// Tiphys Agent client: REST over JSON. Error responses have the form { error: { code, params } };
// the code is translated into the app's selected language.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../profile/model.dart';
import '../secrets/secret_store.dart';

/// Agent version this app version expects; an "out of date" warning is shown for an older agent.
const kExpectedAgentVersion = '0.6.0';

/// Compares x.y.z with [kExpectedAgentVersion]: <0 older, 0 same, >0 newer; null if either isn't numeric x.y.z.
int? compareAgentVersion(String? version) {
  if (version == null) return null;
  List<int>? p(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  final a = p(version), b = p(kExpectedAgentVersion);
  if (a == null || b == null) return null;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/// "0.2.0" < "0.3.0" ? (numeric x.y.z only; an unparseable version isn't considered old)
bool agentOutdated(String? version) => (compareAgentVersion(version) ?? 0) < 0;

/// Agent newer than this app expects (the app may not know its newest features yet).
bool agentNewer(String? version) => (compareAgentVersion(version) ?? 0) > 0;

class AgentError implements Exception {
  const AgentError(this.code, [this.params = const {}, this.status]);

  /// e.g. agent.auth.invalidToken, agent.services.permissionDenied, net.unreachable, net.timeout
  final String code;
  final Map<String, dynamic> params;
  final int? status;
  @override
  String toString() => 'AgentError($code, $params)';
}

class AgentClient {
  AgentClient({required this.baseUrl, required this.token, HttpClient? http, this.timeout = const Duration(seconds: 15)})
      : _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));

  final String baseUrl;
  final String token;
  final Duration timeout;
  final HttpClient _http;

  static Future<AgentClient> forHost(Host host, SecretStore secrets) async {
    final a = host.agent;
    if (a == null) throw const AgentError('agent.notConfigured');
    final token = await secrets.read(secretIdOf(a.tokenRef));
    if (token == null) throw AgentError('agent.tokenMissing', {'id': secretIdOf(a.tokenRef)});
    return AgentClient(baseUrl: a.url, token: token);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl);
    // If a query is given inside the path ("/v1/git/diff?path=…"), split it off; otherwise "?" would be encoded into
    // the path (%3F) and give a 404.
    final q = path.indexOf('?');
    if (q >= 0) {
      query = {...Uri.splitQueryString(path.substring(q + 1)), ...?query};
      path = path.substring(0, q);
    }
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  /// [headers]: extra headers (e.g. the desktop control session token X-Tiphys-Control).
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    final bytes = await _send(method, path, body: body, query: query, timeout: timeout, accept: 'application/json', headers: headers);
    try {
      return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AgentError('net.badResponse');
    }
  }

  /// Binary response (e.g. a screenshot). Error responses still come as a JSON code.
  Future<Uint8List> requestBytes(String path, {Map<String, String>? query, Duration? timeout}) =>
      _send('GET', path, query: query, timeout: timeout ?? const Duration(seconds: 40), accept: '*/*');

  Future<Uint8List> _send(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, required String accept, Map<String, String>? headers}) async {
    final t = timeout ?? this.timeout;
    try {
      final req = await _http.openUrl(method, _uri(path, query)).timeout(t);
      // No token = an anonymous call (the lost-phone lockdown): no Authorization header at all.
      if (token.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, accept);
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(t);
      final builder = BytesBuilder(copy: false);
      await res.forEach(builder.add).timeout(t);
      final bytes = builder.takeBytes();
      if (res.statusCode >= 400) throw _errorOf(res.statusCode, bytes);
      return bytes;
    } on AgentError {
      rethrow;
    } on TimeoutException {
      throw const AgentError('net.timeout');
    } on SocketException catch (e) {
      throw AgentError('net.unreachable', {'detail': e.message});
    } on HandshakeException {
      throw const AgentError('net.tls');
    }
  }

  static AgentError _errorOf(int status, List<int> bytes) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (_) {}
    final err = json is Map ? json['error'] : null;
    if (err is Map) {
      return AgentError(err['code'] as String? ?? 'agent.unknown', Map<String, dynamic>.from((err['params'] as Map?) ?? {}), status);
    }
    return AgentError('net.http', {'status': status}, status);
  }

  /// Streams a response body to [onData] without buffering it (the CSV export) and returns the response headers
  /// (lower-case names). dart:io doesn't expose HTTP trailers; a proxy that merges them into the headers shows up
  /// here, otherwise the caller counts what it received. Errors before the first byte come as AgentError; a stream
  /// that breaks half way as net.unreachable. [timeout] bounds the whole transfer.
  Future<Map<String, String>> download(String method, String path, {Object? body, required void Function(List<int>) onData, Duration timeout = const Duration(minutes: 6)}) async {
    try {
      final req = await _http.openUrl(method, _uri(path)).timeout(this.timeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(this.timeout);
      if (res.statusCode >= 400) {
        final b = BytesBuilder(copy: false);
        await res.forEach(b.add).timeout(this.timeout);
        throw _errorOf(res.statusCode, b.takeBytes());
      }
      await res.forEach(onData).timeout(timeout);
      final headers = <String, String>{};
      res.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      return headers;
    } on AgentError {
      rethrow;
    } on TimeoutException {
      throw const AgentError('net.timeout');
    } on SocketException catch (e) {
      throw AgentError('net.unreachable', {'detail': e.message});
    } on HttpException catch (e) {
      throw AgentError('net.unreachable', {'detail': e.message});
    } on HandshakeException {
      throw const AgentError('net.tls');
    }
  }

  /// SSE (text/event-stream): (event name, data) pairs; the stream ends when the connection closes. Opening error:
  /// AgentError; no bytes at all for [idle] (the agent sends a ping every 25 s): net.timeout. When the listener
  /// cancels, the connection closes immediately (same pattern as sse in integrations/http_json.dart).
  Stream<(String, String)> sse(String path, {Map<String, String>? headers, Duration idle = const Duration(seconds: 70)}) {
    StreamSubscription<String>? sub;
    var cancelled = false;
    late final StreamController<(String, String)> ctrl;
    ctrl = StreamController<(String, String)>(
      onListen: () async {
        final HttpClientResponse res;
        try {
          final req = await _http.openUrl('GET', _uri(path)).timeout(timeout);
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          headers?.forEach(req.headers.set);
          res = await req.close().timeout(timeout);
          if (res.statusCode >= 400) {
            final b = BytesBuilder(copy: false);
            await res.forEach(b.add).timeout(timeout);
            throw _errorOf(res.statusCode, b.takeBytes());
          }
        } catch (e, st) {
          if (!cancelled) {
            ctrl.addError(switch (e) {
              AgentError() => e,
              TimeoutException() => const AgentError('net.timeout'),
              SocketException() => AgentError('net.unreachable', {'detail': e.message}),
              HandshakeException() => const AgentError('net.tls'),
              _ => e,
            }, st);
            await ctrl.close();
          }
          return;
        }
        if (cancelled) {
          await res.listen(null).cancel();
          return;
        }
        var event = 'message';
        final data = StringBuffer();
        sub = res
            .timeout(idle, onTimeout: (s) {
              s.addError(const AgentError('net.timeout'));
              s.close();
            })
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
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
              onError: (Object e) => ctrl.addError(e is SocketException || e is HttpException ? const AgentError('net.unreachable') : e),
              onDone: ctrl.close,
            );
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async =>
      Map<String, dynamic>.from(await request('GET', path, query: query) as Map);
  Future<dynamic> post(String path, [Object? body]) => request('POST', path, body: body ?? const {});
  Future<dynamic> patch(String path, Object body) => request('PATCH', path, body: body);
  Future<dynamic> put(String path, Object body) => request('PUT', path, body: body);
  Future<dynamic> delete(String path) => request('DELETE', path);

  /// Health check that needs no token.
  static Future<Map<String, dynamic>> health(String baseUrl) async {
    final c = AgentClient(baseUrl: baseUrl, token: '');
    try {
      return await c.get('/v1/health');
    } finally {
      c.close();
    }
  }

  void close() => _http.close(force: true);
}

/// Contents of the pairing QR code: {"v":1,"type":"tiphys-pair","agent":"argo","url":"…","token":"tph_…"}
class PairPayload {
  const PairPayload({required this.agent, required this.url, required this.token});
  final String agent;
  final String url;
  final String token;

  static PairPayload? tryParse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['type'] != 'tiphys-pair' || j['v'] != 1) return null;
      final url = j['url'], token = j['token'], agent = j['agent'];
      if (url is! String || token is! String || !token.startsWith('tph_') || agent is! String) return null;
      if (!(url.startsWith('https://') || url.startsWith('http://'))) return null;
      return PairPayload(agent: agent, url: url, token: token);
    } catch (_) {
      return null;
    }
  }
}
