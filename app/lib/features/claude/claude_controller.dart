// Bir Claude oturumunun canlı durumu: WebSocket ile ajandan olay akışı, kopunca kaldığı yerden devam.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/refresh.dart';

class ClaudeEvent {
  ClaudeEvent(this.json);
  final Map<String, dynamic> json;
  int get seq => json['seq'] as int? ?? 0;
  String get kind => json['kind'] as String;
  String get text => json['text'] as String? ?? '';
  T? get<T>(String k) => json[k] as T?;
}

class ClaudeSessionController extends ChangeNotifier {
  ClaudeSessionController({required this.client, required this.sessionId, this.readOnlyEvents, this.stream = true}) {
    if (isLive && stream) appVisible.addListener(_onVisibility);
  }

  /// Testlerde canlı akış kapatılır.
  final bool stream;

  final AgentClient client;
  final String sessionId;

  /// Geçmiş (canlı olmayan) oturum için sabit olaylar.
  final List<ClaudeEvent>? readOnlyEvents;

  final events = <ClaudeEvent>[];
  String live = ''; // akan metin
  String status = 'starting';
  Map<String, dynamic>? summary;
  bool connected = false;
  Object? error;

  /// Oturum ajanda artık yok (kapatılmış ya da 6 saat boşta kalıp temizlenmiş).
  bool gone = false;
  WebSocket? _ws;
  Timer? _retry;
  bool _disposed = false;
  int _attempt = 0;

  /// Her bağlantı denemesinin numarası: eski (kapanmış) bağlantıdan gelen olay/kapanış yok sayılır.
  int _gen = 0;

  int get lastSeq => events.isEmpty ? 0 : events.last.seq;
  bool get isLive => readOnlyEvents == null;
  bool get busy => status == 'running' || status == 'starting';

  /// Cevap bekleyen izin istekleri.
  List<ClaudeEvent> get pendingPermissions {
    final resolved = events.where((e) => e.kind == 'permissionResolved').map((e) => e.get<String>('requestId')).toSet();
    return events.where((e) => e.kind == 'permission' && !resolved.contains(e.get<String>('requestId'))).toList();
  }

  Future<void> start() async {
    if (!isLive) {
      events.addAll(readOnlyEvents!);
      status = 'history';
      notifyListeners();
      return;
    }
    final gen = ++_gen;
    try {
      final j = await client.get('/v1/claude/sessions/$sessionId');
      if (_disposed || gen != _gen) return;
      summary = Map<String, dynamic>.from(j['session'] as Map);
      status = summary!['status'] as String;
      events.clear();
      live = '';
      for (final e in (j['events'] as List)) {
        _add(ClaudeEvent(Map<String, dynamic>.from(e as Map)));
      }
      error = null;
      notifyListeners();
      if (stream) await _connect();
    } catch (e) {
      if (_disposed || gen != _gen) return;
      if (e is AgentError && e.code == 'agent.claude.session.notFound') {
        gone = true;
        error = e;
        status = 'stopped';
        notifyListeners();
        return;
      }
      // Açılışta ağ kesintisi: sonsuza dek "yazıyor" göstermek yerine artan aralıklarla yeniden dene.
      error = e;
      notifyListeners();
      _later(start);
    }
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = ++_gen;
    _ws?.close();
    _ws = null;
    final base = Uri.parse(client.baseUrl);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/v1/claude/sessions/$sessionId/stream',
      queryParameters: {'after': '$lastSeq'},
    );
    try {
      final ws = await WebSocket.connect(uri.toString(), headers: {'Authorization': 'Bearer ${client.token}'}).timeout(const Duration(seconds: 10));
      if (_disposed || gen != _gen) {
        ws.close(); // bu arada ekran kapandı ya da yeni bir bağlantı başladı
        return;
      }
      // Mobil ağ değişince/Doze'da TCP sessizce ölebilir: ping cevapsız kalırsa bağlantı kapanır, yeniden bağlanılır.
      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      connected = true;
      _attempt = 0;
      error = null;
      live = ''; // kopukken kaçan parçalar; tam metin "text" olayıyla gelir
      notifyListeners();
      ws.listen(
        (data) {
          if (gen != _gen) return;
          final e = ClaudeEvent(Map<String, dynamic>.from(jsonDecode(data as String) as Map));
          if (e.kind == 'hello') {
            // Ajan yeniden başladıysa (farklı örnek) ya da sıra numaraları geriye gittiyse: baştan yükle.
            final known = summary?['epoch'];
            final serverLast = e.get<int>('lastSeq') ?? 0;
            if ((known != null && e.get<String>('epoch') != known) || serverLast < lastSeq) _resync();
            return;
          }
          _add(e);
          notifyListeners();
        },
        onDone: () {
          if (gen != _gen) return;
          if (ws.closeCode == 4404) {
            gone = true;
            connected = false;
            notifyListeners();
            return;
          }
          _scheduleReconnect();
        },
        onError: (_) {
          if (gen == _gen) _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_disposed || gen != _gen) return;
      error = e;
      _scheduleReconnect();
    }
  }

  /// Olayları bırakıp oturumu baştan yükler (ajan yeniden başladığında).
  void _resync() {
    _gen++;
    _ws?.close();
    _ws = null;
    connected = false;
    unawaited(start());
  }

  void _scheduleReconnect() {
    connected = false;
    if (_disposed) return;
    notifyListeners();
    _later(_connect);
  }

  void _later(Future<void> Function() fn) {
    _retry?.cancel();
    final delay = Duration(seconds: [1, 2, 5, 10, 20][_attempt.clamp(0, 4)]);
    _attempt++;
    _retry = Timer(delay, fn);
  }

  /// Uygulama öne gelince: bağlantı sağlıklı görünse bile (arka planda ölmüş olabilir) hemen yeniden bağlan.
  void _onVisibility() {
    if (!appVisible.value || _disposed || gone) return;
    _retry?.cancel();
    _attempt = 0;
    if (summary == null) {
      unawaited(start());
    } else {
      unawaited(_connect());
    }
  }

  void _add(ClaudeEvent e) {
    if (e.kind == 'delta') {
      live += e.text;
      return;
    }
    if (e.seq != 0 && e.seq <= lastSeq) return; // yinelenen (yeniden bağlanınca)
    if (e.kind == 'text') live = '';
    if (e.kind == 'status') status = e.get<String>('status') ?? status;
    if (e.kind == 'result') {
      live = '';
      // Maliyet ve bağlam doluluğu başlıkta güncel kalsın.
      final sm = summary;
      if (sm != null) {
        for (final k in const ['costUsd', 'contextTokens', 'contextWindow']) {
          if (e.json[k] != null) sm[k] = e.json[k];
        }
      }
    }
    events.add(e);
  }

  Future<void> send(String text, {List<Map<String, String>> images = const []}) =>
      client.post('/v1/claude/sessions/$sessionId/messages', {'text': text, if (images.isNotEmpty) 'images': images});

  Future<void> interrupt() => client.post('/v1/claude/sessions/$sessionId/interrupt');

  Future<void> decide(String requestId, bool allow) =>
      client.post('/v1/claude/sessions/$sessionId/permissions/$requestId', {'allow': allow});

  Future<void> setMode(String mode) => client.post('/v1/claude/sessions/$sessionId/mode', {'permissionMode': mode});

  Future<void> close() => client.delete('/v1/claude/sessions/$sessionId');

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    appVisible.removeListener(_onVisibility);
    _retry?.cancel();
    _ws?.close();
    client.close();
    super.dispose();
  }
}

/// Edit/Write/MultiEdit araç girdisinden basit satır farkı (- eski, + yeni).
List<(String, String)> toolDiff(String tool, Map<String, dynamic> input) {
  List<(String, String)> lines(String sign, String? text) =>
      (text ?? '').split('\n').map((l) => (sign, l)).toList();
  switch (tool) {
    case 'Write':
      return lines('+', input['content'] as String?);
    case 'Edit':
      return [...lines('-', input['old_string'] as String?), ...lines('+', input['new_string'] as String?)];
    case 'MultiEdit':
      return [
        for (final e in (input['edits'] as List? ?? const []).cast<Map>()) ...[
          ...lines('-', e['old_string'] as String?),
          ...lines('+', e['new_string'] as String?),
          (' ', '⋯'),
        ],
      ];
    default:
      return const [];
  }
}

/// Araç çağrısının tek satırlık özeti.
String toolSummary(String tool, Map<String, dynamic> input) {
  String s(String k) => (input[k] ?? '').toString();
  final v = switch (tool) {
    'Bash' => s('command'),
    'Read' || 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => s('file_path'),
    'Glob' => s('pattern'),
    'Grep' => '${s('pattern')}${input['path'] == null ? '' : '  ${s('path')}'}',
    'WebFetch' => s('url'),
    'WebSearch' => s('query'),
    'Agent' || 'Task' => s('description'),
    'TodoWrite' => '${(input['todos'] as List?)?.length ?? 0} madde',
    _ => jsonEncode(input),
  };
  return v.length > 200 ? '${v.substring(0, 200)}…' : v;
}

@visibleForTesting
ClaudeEvent ev(Map<String, dynamic> j) => ClaudeEvent(j);
