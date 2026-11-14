// Tiphys Ajanı istemcisi: JSON üzerinden REST. Hata yanıtları { error: { code, params } } biçimindedir;
// kod uygulamada seçili dile çevrilir.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../profile/model.dart';
import '../secrets/secret_store.dart';

/// Bu uygulama sürümünün beklediği ajan sürümü; daha eski ajan için "güncel değil" uyarısı gösterilir.
const kExpectedAgentVersion = '0.3.0';

/// "0.2.0" < "0.3.0" ? (yalnız sayısal x.y.z; anlaşılmayan sürüm eski sayılmaz)
bool agentOutdated(String? version) {
  if (version == null) return false;
  List<int>? p(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  final a = p(version), b = p(kExpectedAgentVersion);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return false;
}

class AgentError implements Exception {
  const AgentError(this.code, [this.params = const {}, this.status]);

  /// ör. agent.auth.invalidToken, agent.services.permissionDenied, net.unreachable, net.timeout
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
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }

  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async {
    final bytes = await _send(method, path, body: body, query: query, timeout: timeout, accept: 'application/json');
    try {
      return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AgentError('net.badResponse');
    }
  }

  /// İkili yanıt (ör. ekran görüntüsü). Hata yanıtları yine JSON koduyla gelir.
  Future<Uint8List> requestBytes(String path, {Map<String, String>? query, Duration? timeout}) =>
      _send('GET', path, query: query, timeout: timeout ?? const Duration(seconds: 40), accept: '*/*');

  Future<Uint8List> _send(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, required String accept}) async {
    final t = timeout ?? this.timeout;
    try {
      final req = await _http.openUrl(method, _uri(path, query)).timeout(t);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.acceptHeader, accept);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(t);
      final builder = BytesBuilder(copy: false);
      await res.forEach(builder.add).timeout(t);
      final bytes = builder.takeBytes();
      if (res.statusCode >= 400) {
        Object? json;
        try {
          json = jsonDecode(utf8.decode(bytes));
        } catch (_) {}
        final err = json is Map ? json['error'] : null;
        if (err is Map) {
          throw AgentError(err['code'] as String? ?? 'agent.unknown', Map<String, dynamic>.from((err['params'] as Map?) ?? {}), res.statusCode);
        }
        throw AgentError('net.http', {'status': res.statusCode}, res.statusCode);
      }
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

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async =>
      Map<String, dynamic>.from(await request('GET', path, query: query) as Map);
  Future<dynamic> post(String path, [Object? body]) => request('POST', path, body: body ?? const {});
  Future<dynamic> patch(String path, Object body) => request('PATCH', path, body: body);
  Future<dynamic> put(String path, Object body) => request('PUT', path, body: body);
  Future<dynamic> delete(String path) => request('DELETE', path);

  /// Token gerektirmeyen sağlık kontrolü.
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

/// Eşleşme QR kodunun içeriği: {"v":1,"type":"tiphys-pair","agent":"argo","url":"…","token":"tph_…"}
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
