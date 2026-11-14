// Bir Claude oturumunun canlı durumu: WebSocket ile ajandan olay akışı, kopunca kaldığı yerden devam.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// Gönderilmeyi bekleyen mesaj (ağ yokken yazılan ya da cevabı gelmeden bağlantısı kopan).
class OutboxItem {
  OutboxItem({required this.id, required this.text, this.images = const []});
  final String id; // ajan bu kimliği ikinci kez görürse mesajı tekrar işlemez
  final String text;
  final List<Map<String, String>> images;
  bool sending = false;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'images': images};
  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
        id: j['id'] as String,
        text: j['text'] as String,
        images: [for (final i in (j['images'] as List? ?? const [])) Map<String, String>.from(i as Map)],
      );
}

class ClaudeSessionController extends ChangeNotifier {
  ClaudeSessionController({required this.client, required this.sessionId, this.readOnlyEvents, this.stream = true, this.outboxDir}) {
    if (isLive && stream) appVisible.addListener(_onVisibility);
  }

  /// Gönderim kutusunun diskteki klasörü (uygulama kapansa da bekleyen mesajlar kalsın). null: yalnız bellekte.
  final String? outboxDir;

  /// Henüz ajana ulaşmamış mesajlar (sırayla gönderilir).
  final outbox = <OutboxItem>[];

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
    await _loadOutbox();
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
      unawaited(_flush()); // bağlantı yokken bekleyen mesajlar
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
    unawaited(_flush());
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

  /// Mesajı gönderim kutusuna koyar ve göndermeyi dener. Ağ yoksa hata vermez: mesaj "bekliyor" olarak
  /// kalır, bağlantı gelince kendiliğinden gider. Ajan mesajı reddederse (ör. oturum kapalı) hata fırlatır.
  Future<void> send(String text, {List<Map<String, String>> images = const []}) async {
    outbox.add(OutboxItem(id: _newId(), text: text, images: images));
    await _saveOutbox();
    notifyListeners();
    await _flush(throwOnReject: true);
  }

  /// Bekleyen mesajı vazgeçip siler.
  Future<void> discard(OutboxItem item) async {
    outbox.remove(item);
    await _saveOutbox();
    notifyListeners();
  }

  bool _flushing = false;

  Future<void> _flush({bool throwOnReject = false}) async {
    if (_flushing || _disposed) return;
    _flushing = true;
    Object? rejected;
    try {
      while (outbox.isNotEmpty && !_disposed) {
        final item = outbox.first;
        item.sending = true;
        notifyListeners();
        try {
          await client.post('/v1/claude/sessions/$sessionId/messages', {
            'text': item.text,
            if (item.images.isNotEmpty) 'images': item.images,
            'clientId': item.id,
          });
          outbox.remove(item); // ulaştı (ya da daha önce ulaşmıştı: duplicate)
        } on AgentError catch (e) {
          item.sending = false;
          if (e.code.startsWith('net.')) break; // ağ yok: sonra tekrar denenecek
          outbox.remove(item); // ajan reddetti: bekletmenin anlamı yok
          rejected = e;
        }
        await _saveOutbox();
      }
    } finally {
      _flushing = false;
      if (!_disposed) notifyListeners();
    }
    if (rejected != null && throwOnReject) throw rejected;
  }

  static final _rand = Random.secure();
  static String _newId() => List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  File? get _outboxFile => outboxDir == null ? null : File('$outboxDir/claude-outbox-$sessionId.json');

  Future<void> _loadOutbox() async {
    final f = _outboxFile;
    if (f == null || outbox.isNotEmpty || !await f.exists()) return;
    try {
      outbox.addAll([for (final j in jsonDecode(await f.readAsString()) as List) OutboxItem.fromJson(Map<String, dynamic>.from(j as Map))]);
    } catch (_) {
      // bozuk dosya: yok say
    }
  }

  Future<void> _saveOutbox() async {
    final f = _outboxFile;
    if (f == null) return;
    if (outbox.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode([for (final i in outbox) i.toJson()]));
  }

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
