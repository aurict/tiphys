// Claude stream controller: must not freeze when the agent restarts (new instance, sequence numbers start over).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/claude/claude_controller.dart';

/// Fake client whose GET response changes in turn (as if the agent restarted).
class _Client extends AgentClient {
  _Client(String base) : super(baseUrl: base, token: 't');
  final responses = <Map<String, dynamic>>[];
  int gets = 0;
  bool offline = false;
  final posts = <Map<String, dynamic>>[];
  final queries = <Map<String, String>?>[];
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    if (method == 'POST') {
      if (offline) throw const AgentError('net.unreachable');
      posts.add(Map<String, dynamic>.from(body! as Map));
      return {'ok': true};
    }
    queries.add(query);
    return responses[(gets++).clamp(0, responses.length - 1)];
  }
}

Map<String, dynamic> ev(int seq, String kind, [Map<String, dynamic> extra = const {}]) => {'seq': seq, 'at': '', 'kind': kind, ...extra};

/// Local WebSocket server: each incoming connection is taken in order.
class _Server {
  late final HttpServer http;
  final _waiting = <Completer<WebSocket>>[];
  final _ready = <WebSocket>[];
  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(ws);
      } else {
        _ready.add(ws);
      }
    });
  }

  Future<WebSocket> next() {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    final c = Completer<WebSocket>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  test('ajan yeniden başlayınca (yeni epoch) olaylar baştan yüklenir, yeni olaylar kaçmaz', () async {
    final server = _Server();
    await server.start();
    final client = _Client('http://127.0.0.1:${server.http.port}');
    // First open: old instance, large sequence numbers (streamed text chunks consume numbers too).
    client.responses.add({
      'session': {'id': 's', 'epoch': 'A', 'status': 'idle'},
      'events': [ev(3000, 'user', {'text': 'eski'}), ev(3050, 'text', {'text': 'eski cevap'})],
    });
    // Reload: the agent restarted, history came from the Claude transcript, numbers are small.
    client.responses.add({
      'session': {'id': 's', 'epoch': 'B', 'status': 'idle'},
      'events': [ev(1, 'user', {'text': 'eski'}), ev(2, 'text', {'text': 'eski cevap'}), ev(3, 'restored')],
    });
    final c = ClaudeSessionController(client: client, sessionId: 's');
    final started = c.start();
    final ws1 = await server.next();
    await started;
    expect(c.lastSeq, 3050);

    // The connection landed on the new agent instance: the hello carries a different epoch.
    ws1.add(jsonEncode({'kind': 'hello', 'seq': 0, 'epoch': 'B', 'lastSeq': 3}));
    final ws2 = await server.next(); // reloaded and reconnected
    expect(client.gets, 2);
    expect(c.events.map((e) => e.seq), [1, 2, 3]);

    // Event number 4 from the new instance must no longer be mistaken for a "duplicate" and dropped.
    ws2.add(jsonEncode({'kind': 'hello', 'seq': 0, 'epoch': 'B', 'lastSeq': 3}));
    ws2.add(jsonEncode(ev(4, 'user', {'text': 'yeni mesaj'})));
    await until(() => c.lastSeq == 4);
    expect(c.events.last.text, 'yeni mesaj');
    expect(client.gets, 2); // same epoch: no reload

    c.dispose();
    await server.http.close(force: true);
  });

  test('bağlantı koparsa yeniden bağlanır ve kaldığı numaradan ister', () async {
    final server = _Server();
    await server.start();
    final client = _Client('http://127.0.0.1:${server.http.port}');
    client.responses.add({
      'session': {'id': 's', 'epoch': 'A', 'status': 'running'},
      'events': [ev(1, 'user', {'text': 'merhaba'})],
    });
    final c = ClaudeSessionController(client: client, sessionId: 's');
    unawaited(c.start());
    final ws1 = await server.next();
    ws1.add(jsonEncode(ev(5, 'text', {'text': 'cevap'})));
    await until(() => c.lastSeq == 5);
    await ws1.close(); // network dropped
    await until(() => !c.connected);
    expect(c.connected, isFalse);
    final ws2 = await server.next(); // reconnected after 1 s
    await until(() => c.connected);
    expect(c.connected, isTrue);
    ws2.add(jsonEncode(ev(5, 'text', {'text': 'cevap'}))); // even if the server resends
    ws2.add(jsonEncode(ev(6, 'result', {'ok': true})));
    await until(() => c.lastSeq == 6);
    expect(c.events.where((e) => e.seq == 5), hasLength(1)); // duplicates are not added
    c.dispose();
    await server.http.close(force: true);
  });

  test('ağ yokken gönderilen mesaj kaybolmaz: diskte bekler, bağlantı gelince aynı kimlikle gider', () async {
    final dir = Directory.systemTemp.createTempSync('tiphys-outbox-test').path;
    final client = _Client('http://127.0.0.1:9')..responses.add({'session': {'id': 's', 'epoch': 'A', 'status': 'idle'}, 'events': []});
    client.offline = true;
    final c = ClaudeSessionController(client: client, sessionId: 's', stream: false, outboxDir: dir);
    await c.start();
    await c.send('ağ yokken yazdım'); // does not throw
    expect(c.outbox.single.text, 'ağ yokken yazdım');
    expect(File('$dir/claude-outbox-s.json').existsSync(), isTrue);
    final id = c.outbox.single.id;
    c.dispose();

    // App was closed and reopened: the outbox comes from disk; the network is back.
    final client2 = _Client('http://127.0.0.1:9')..responses.add({'session': {'id': 's', 'epoch': 'A', 'status': 'idle'}, 'events': []});
    final c2 = ClaudeSessionController(client: client2, sessionId: 's', stream: false, outboxDir: dir);
    await c2.start();
    expect(c2.outbox.single.id, id);
    await c2.send('ikinci');
    expect(client2.posts.map((p) => p['text']), ['ağ yokken yazdım', 'ikinci']); // in order
    expect(client2.posts.first['clientId'], id); // same id: the agent does not process it again
    expect(c2.outbox, isEmpty);
    expect(File('$dir/claude-outbox-s.json').existsSync(), isFalse);
    c2.dispose();
  });

  test('daha eski mesajlar kayıttan yüklenip başa eklenir; kalmayınca düğme kaybolur', () async {
    final client = _Client('http://127.0.0.1:9')
      ..responses.add({
        'events': [ev(1, 'user', {'text': 'en eski'}), ev(2, 'text', {'text': 'eski cevap'})],
        'more': false,
      });
    final c = ClaudeSessionController(
      client: client,
      sessionId: 'sdk-1',
      readOnlyEvents: [ClaudeEvent(ev(1, 'user', {'text': 'yeni'})), ClaudeEvent(ev(2, 'status', {'status': 'idle'})), ClaudeEvent(ev(3, 'text', {'text': 'yeni cevap'}))],
      olderAvailable: true,
    );
    await c.start();
    await c.loadOlder();
    expect(client.queries.single, {'skip': '2', 'limit': '200'}); // status isn't from the transcript: not counted
    expect(c.events.map((e) => e.text).where((t) => t.isNotEmpty), ['en eski', 'eski cevap', 'yeni', 'yeni cevap']);
    expect(c.olderAvailable, isFalse);
    c.dispose();
  });
}
