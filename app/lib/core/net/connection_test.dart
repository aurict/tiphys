// Simple HTTP probe (with timeout) for the "Test connection" buttons.
import 'dart:async';
import 'dart:io';

class TestResult {
  const TestResult(this.ok, [this.reason]);
  final bool ok;
  final String? reason;
}

Future<TestResult> testHttp(String url, {String? bearer, bool acceptRedirect = false, Duration timeout = const Duration(seconds: 8)}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return const TestResult(false, 'URL');
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.followRedirects = false;
    if (bearer != null && bearer.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    final ok = res.statusCode >= 200 && res.statusCode < 300 || (acceptRedirect && res.statusCode >= 300 && res.statusCode < 400);
    return TestResult(ok, ok ? null : 'HTTP ${res.statusCode}');
  } on TimeoutException {
    return const TestResult(false, 'timeout');
  } on SocketException catch (e) {
    return TestResult(false, e.osError?.message ?? e.message);
  } on HandshakeException {
    return const TestResult(false, 'TLS');
  } catch (e) {
    // Message, not class name: release builds obfuscate class names (--obfuscate).
    final m = '$e'.split('\n').first;
    return TestResult(false, m.length > 120 ? '${m.substring(0, 120)}…' : m);
  } finally {
    client.close(force: true);
  }
}
