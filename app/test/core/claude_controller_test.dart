// Claude akış denetleyicisi: ajan yeniden başlayınca (yeni örnek, sıra numaraları baştan) donmamalı.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/claude/claude_controller.dart';

/// GET yanıtı sırayla değişen sahte istemci (ajan yeniden başlamış gibi).
class _Client extends AgentClient {
  _Client(String base) : super(baseUrl: base, token: 't');
  final responses = <Map<String, dynamic>>[];
  int gets = 0;
  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async =>
      responses[(gets++).clamp(0, responses.length - 1)];
}

Map<String, dynamic> ev(int seq, String kind, [Map<String, dynamic> extra = const {}]) => {'seq': seq, 'at': '', 'kind': kind, ...extra};

/// Yerel WebSocket sunucusu: gelen her bağlantı sırayla alınır.
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
    // İlk açılış: eski örnek, büyük sıra numaraları (akan metin parçaları da numara tüketir).
    client.responses.add({
      'session': {'id': 's', 'epoch': 'A', 'status': 'idle'},
      'events': [ev(3000, 'user', {'text': 'eski'}), ev(3050, 'text', {'text': 'eski cevap'})],
    });
    // Yeniden yükleme: ajan yeniden başlamış, geçmiş Claude kaydından gelmiş, numaralar küçük.
    client.responses.add({
      'session': {'id': 's', 'epoch': 'B', 'status': 'idle'},
      'events': [ev(1, 'user', {'text': 'eski'}), ev(2, 'text', {'text': 'eski cevap'}), ev(3, 'restored')],
    });
    final c = ClaudeSessionController(client: client, sessionId: 's');
    final started = c.start();
    final ws1 = await server.next();
    await started;
    expect(c.lastSeq, 3050);

    // Bağlantı yeni ajan örneğine düştü: selam farklı epoch taşıyor.
    ws1.add(jsonEncode({'kind': 'hello', 'seq': 0, 'epoch': 'B', 'lastSeq': 3}));
    final ws2 = await server.next(); // yeniden yükleyip tekrar bağlandı
    expect(client.gets, 2);
    expect(c.events.map((e) => e.seq), [1, 2, 3]);

    // Yeni örnekten gelen 4 numaralı olay artık "yinelenen" sanılıp atılmamalı.
    ws2.add(jsonEncode({'kind': 'hello', 'seq': 0, 'epoch': 'B', 'lastSeq': 3}));
    ws2.add(jsonEncode(ev(4, 'user', {'text': 'yeni mesaj'})));
    await until(() => c.lastSeq == 4);
    expect(c.events.last.text, 'yeni mesaj');
    expect(client.gets, 2); // aynı epoch: tekrar yükleme yok

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
    await ws1.close(); // ağ koptu
    await until(() => !c.connected);
    expect(c.connected, isFalse);
    final ws2 = await server.next(); // 1 sn sonra yeniden bağlandı
    await until(() => c.connected);
    expect(c.connected, isTrue);
    ws2.add(jsonEncode(ev(5, 'text', {'text': 'cevap'}))); // sunucu tekrar gönderse bile
    ws2.add(jsonEncode(ev(6, 'result', {'ok': true})));
    await until(() => c.lastSeq == 6);
    expect(c.events.where((e) => e.seq == 5), hasLength(1)); // yinelenen eklenmez
    c.dispose();
    await server.http.close(force: true);
  });
}
