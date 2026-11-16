// Live screen (10.2 Stage A) logic: WS /v1/desktop/stream connection (with the 10.1 control session's token),
// binary frame parsing and decoding to ui.Image (frames arriving during decoding don't pile up, only the latest waits),
// image ↔ screen coordinate mapping (fit/margin + image zoom), touch → input event
// mapping helpers, quality levels and automatic adaptation by measured fps/latency, reconnect on disconnect.
// 10.2 Stage C: if the phone has a video/avc decoder, `codec=h264` is requested; frames (Annex-B, with a header flag)
// go to the native MediaCodec decoder (tiphys_native) and the image is drawn on a Flutter texture. If the agent can't
// start H.264 (notice), the decoder errors or no key frame decodes within 3 s, it falls back to MJPEG ([CodecChooser]).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:tiphys_native/tiphys_native.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../system/agent_providers.dart';
import 'desktop_data.dart';

// ---- protocol ----

/// The agent's binary frame: u8 flags, u24 seq, f64 time (ms; pts for H.264), u16 width, u16 height (big
/// endian) + data. Flags 0 = JPEG (same layout as the old u32-seq header); for H.264 [flagH264] | [flagKey] (IDR) |
/// [flagConfig] (SPS+PPS, before every IDR).
class LiveFrame {
  const LiveFrame(this.seq, this.ts, this.width, this.height, this.image, {this.flags = 0});
  final int seq;
  final double ts;
  final int width;
  final int height;

  /// JPEG or an H.264 access unit (Annex-B).
  final Uint8List image;
  final int flags;

  static const headerSize = 16;
  static const flagH264 = 0x10, flagKey = 0x01, flagConfig = 0x02;

  bool get isH264 => flags & flagH264 != 0;
  bool get isKey => flags & flagKey != 0;
  bool get isConfig => flags & flagConfig != 0;

  static LiveFrame? parse(Uint8List b) {
    if (b.length <= headerSize) return null;
    final d = ByteData.sublistView(b, 0, headerSize);
    final w = d.getUint16(12), h = d.getUint16(14);
    if (w == 0 || h == 0) return null;
    return LiveFrame(d.getUint32(0) & 0xffffff, d.getFloat64(4), w, h, Uint8List.sublistView(b, headerSize), flags: b[0]);
  }
}

/// PC region shown by the stream (global logical coordinates).
class LiveRegion {
  const LiveRegion(this.x, this.y, this.w, this.h);
  final int x, y, w, h;
  factory LiveRegion.fromJson(Map j) =>
      LiveRegion((j['x'] as num).toInt(), (j['y'] as num).toInt(), (j['w'] as num).toInt(), (j['h'] as num).toInt());
}

/// Focused PC window (the agent's `focus` message, 11 "app context"); selects the toolbar profile.
class LiveFocus {
  const LiveFocus({this.address, this.cls = '', this.initialClass = '', this.title = '', this.appId});
  final String? address;
  final String cls;
  final String initialClass;
  final String title;

  /// .desktop app matching the class (icon); otherwise null.
  final String? appId;

  factory LiveFocus.fromJson(Map j) => LiveFocus(
        address: j['address'] as String?,
        cls: j['class'] is String ? j['class'] as String : '',
        initialClass: j['initialClass'] is String ? j['initialClass'] as String : '',
        title: j['title'] is String ? j['title'] as String : '',
        appId: j['appId'] as String?,
      );
}

// ---- quality ----

enum LiveQuality { auto, high, medium, low }

class LiveParams {
  const LiveParams(this.fps, this.scale, this.q, {this.kbps});
  final int fps;
  final double scale;
  final int q;

  /// H.264 target bitrate (kbit/s); null for JPEG.
  final int? kbps;
  Map<String, Object> toJson() => {'fps': fps, 'scale': scale, 'q': q, 'kbps': ?kbps};
  @override
  bool operator ==(Object other) => other is LiveParams && other.fps == fps && other.scale == scale && other.q == q && other.kbps == kbps;
  @override
  int get hashCode => Object.hash(fps, scale, q, kbps);
  @override
  String toString() => 'LiveParams($fps fps, ×$scale, q$q${kbps == null ? '' : ', $kbps kbit/sn'})';
}

/// Steps of auto mode (low to high); manually chosen qualities are from these too.
const liveLevels = [
  LiveParams(5, 0.35, 45),
  LiveParams(8, 0.45, 55), // Low
  LiveParams(12, 0.6, 70), // Medium (default)
  LiveParams(15, 0.8, 80), // High
];

/// H.264 steps: 2–3x the fps of JPEG in the same bandwidth (NVENC, P-frame ~200 bytes on a static screen).
const liveLevelsH264 = [
  LiveParams(10, 0.45, 55, kbps: 500),
  LiveParams(15, 0.6, 70, kbps: 1000), // Low
  LiveParams(24, 0.6, 70, kbps: 2000), // Medium (default)
  LiveParams(30, 0.8, 80, kbps: 4000), // High
];

LiveParams paramsFor(LiveQuality q, int autoLevel, {bool h264 = false}) {
  final levels = h264 ? liveLevelsH264 : liveLevels;
  return switch (q) {
    LiveQuality.high => levels[3],
    LiveQuality.medium => levels[2],
    LiveQuality.low => levels[1],
    LiveQuality.auto => levels[autoLevel],
  };
}

// ---- codec ----

/// User preference (quality menu): Auto (H.264 if there's a hardware decoder) / H.264 / JPEG.
enum LiveCodec { auto, h264, jpeg }

/// H.264 decoder on the phone.
class H264Support {
  const H264Support({this.available = false, this.hardware = false, this.name});
  final bool available;
  final bool hardware;
  final String? name;
  static const none = H264Support();
}

/// Codec choice and fallback: whether H.264 is used; whether a key frame is awaited (the controller falls back if it's
/// still awaited after [keyTimeout]); once fallen back (agent reported / decoder error / no key frame) it stays on
/// JPEG for the life of this screen; retried if the preference changes.
class CodecChooser {
  CodecChooser({this.pref = LiveCodec.auto, this.support = H264Support.none});
  LiveCodec pref;
  H264Support support;
  static const keyTimeout = Duration(seconds: 3);

  /// Fallback reason: agent | decoder | noKey; null = no fallback.
  String? failure;

  /// H.264 stream started / key frame requested, no key frame given to the decoder yet.
  bool waitingKey = false;

  bool get useH264 =>
      failure == null &&
      switch (pref) {
        LiveCodec.jpeg => false,
        LiveCodec.h264 => support.available,
        LiveCodec.auto => support.hardware,
      };

  void awaitKey() => waitingKey = true;

  /// A key frame was given to the decoder (or waiting ended: connection closed).
  void gotKey() => waitingKey = false;

  void fail(String reason) {
    failure ??= reason;
    waitingKey = false;
  }

  void setPref(LiveCodec p) {
    pref = p;
    failure = null;
    waitingKey = false;
  }
}

/// Native H.264 decoder (the method channel is mocked in tests). Absent (null) outside Android.
abstract class LiveVideoBackend {
  Future<H264Support> support();
  Future<int> create(int width, int height);

  /// 0 ok, 1 key frame needed, 2 unrecoverable error.
  Future<int> queue(int id, LiveFrame f, int ptsUs);
  Future<Map<String, Object?>> stats(int id);
  Future<void> dispose(int id);
}

class NativeVideoBackend implements LiveVideoBackend {
  const NativeVideoBackend();
  @override
  Future<H264Support> support() async {
    try {
      final m = await TiphysNative.h264Support();
      return H264Support(available: m['available'] == true, hardware: m['hardware'] == true, name: m['name'] as String?);
    } catch (_) {
      return H264Support.none; // no plugin / old version
    }
  }

  @override
  Future<int> create(int width, int height) => TiphysNative.h264Create(width, height);
  @override
  Future<int> queue(int id, LiveFrame f, int ptsUs) =>
      TiphysNative.h264Queue(id, f.image, ptsUs: ptsUs, key: f.isKey, config: f.isConfig, width: f.width, height: f.height);
  @override
  Future<Map<String, Object?>> stats(int id) => TiphysNative.h264Stats(id);
  @override
  Future<void> dispose(int id) => TiphysNative.h264Dispose(id);
}

final liveVideoProvider = Provider<LiveVideoBackend?>((ref) => Platform.isAndroid ? const NativeVideoBackend() : null);

/// Auto quality: decides on each per-second measurement (frames skipped by the agent, incoming fps, round-trip time).
/// Steps down one level immediately when things get worse (2 s hold), steps up one level after 8 s of good results.
class AutoQuality {
  AutoQuality({this.level = 2});
  int level;
  int _good = 0;
  int _cooldown = 0;

  /// New step (if changed) or null.
  int? sample({required int dropped, required double fps, required int targetFps, required int? rttMs}) {
    if (_cooldown > 0) {
      _cooldown--;
      return null;
    }
    final slow = (rttMs != null && rttMs > 450);
    // No frames arrive while the screen is static; low fps alone doesn't count as degradation (the agent skips
    // identical frames).
    final bad = dropped > 1 || slow;
    if (bad) {
      _good = 0;
      if (level > 0) {
        level--;
        _cooldown = 2;
        return level;
      }
      return null;
    }
    final healthy = dropped == 0 && (rttMs == null || rttMs < 200);
    _good = healthy ? _good + 1 : 0;
    if (_good >= 8 && level < liveLevels.length - 1) {
      _good = 0;
      level++;
      _cooldown = 3;
      return level;
    }
    return null;
  }
}

// ---- coordinates ----

/// Image placement on screen: fitted into [viewport] (with margins), then image zoom
/// ([zoom], [pan]: screen pixels) is applied. Only the VIEW changes; coordinates sent to the PC are image pixels.
class LiveView {
  const LiveView({required this.viewport, required this.image, this.zoom = 1, this.pan = Offset.zero});
  final Size viewport;
  final Size image;
  final double zoom;
  final Offset pan;

  double get fit => math.min(viewport.width / image.width, viewport.height / image.height);

  /// Image rectangle without zoom (with margins).
  Rect get baseRect {
    final s = fit;
    final w = image.width * s, h = image.height * s;
    return Rect.fromLTWH((viewport.width - w) / 2, (viewport.height - h) / 2, w, h);
  }

  /// Image rectangle drawn on screen.
  Rect get rect {
    final b = baseRect;
    return Rect.fromLTWH(b.left * zoom + pan.dx, b.top * zoom + pan.dy, b.width * zoom, b.height * zoom);
  }

  /// Screen point → image pixel; null if outside the image while [clamp] is false.
  Offset? toImage(Offset p, {bool clamp = false}) {
    final r = rect;
    final x = (p.dx - r.left) / r.width * image.width, y = (p.dy - r.top) / r.height * image.height;
    final inside = x >= 0 && y >= 0 && x < image.width && y < image.height;
    if (!inside && !clamp) return null;
    return Offset(x.clamp(0, image.width - 1).toDouble(), y.clamp(0, image.height - 1).toDouble());
  }

  /// Image pixel → screen point.
  Offset toScreen(Offset img) {
    final r = rect;
    return Offset(r.left + img.dx / image.width * r.width, r.top + img.dy / image.height * r.height);
  }

  /// Image-pixel equivalent of a movement on screen (relative cursor in touchpad mode).
  Offset deltaToImage(Offset d) => d / (fit * zoom);

  /// Pinch: new zoom (1–5) and pan keeping the [focal] point in place; the image doesn't escape the screen.
  LiveView zoomed(double newZoom, Offset focal, {Offset panBy = Offset.zero}) {
    final z = newZoom.clamp(1.0, 5.0);
    // focal = base*zoom + pan → the same content point stays at focal at the new zoom too.
    final content = (focal - pan) / zoom;
    final p = focal - content * z + panBy;
    return LiveView(viewport: viewport, image: image, zoom: z, pan: _clampPan(z, p));
  }

  Offset _clampPan(double z, Offset p) {
    if (z <= 1.0001) return Offset.zero;
    final b = baseRect;
    // The image edge must not come inside the screen edge (if the image is smaller than the screen, it stays centered).
    double axis(double pan, double start, double len, double view) {
      final w = len * z;
      if (w <= view) return (view - w) / 2 - start * z;
      return pan.clamp(view - w - start * z, -start * z).toDouble();
    }

    return Offset(axis(p.dx, b.left, b.width, viewport.width), axis(p.dy, b.top, b.height, viewport.height));
  }
}

/// Two taps in a row (double click): if the second tap is close (24 px, 400 ms) it snaps to the first one's point,
/// so the PC sees both clicks at the same spot and counts a double click. A single click is sent without delay.
class TapSnapper {
  TapSnapper({this.window = const Duration(milliseconds: 400), this.radius = 24});
  final Duration window;
  final double radius;
  Offset? _last;
  Offset? _lastScreen;
  DateTime? _at;

  Offset snap(Offset screen, Offset image, DateTime now) {
    final last = _last, ls = _lastScreen, at = _at;
    if (last != null && ls != null && at != null && now.difference(at) <= window && (screen - ls).distance <= radius) {
      _at = null; // a third tap starts a new series
      return last;
    }
    _last = image;
    _lastScreen = screen;
    _at = now;
    return image;
  }
}

/// Wheel steps from a two-finger drag: [step] screen pixels = 1 notch. Finger up → scroll down
/// (touchscreen habit: content follows the finger).
class ScrollAccumulator {
  ScrollAccumulator({this.step = 36});
  final double step;
  Offset _acc = Offset.zero;

  /// (dx, dy) notches; not sent if 0,0.
  (int, int) add(Offset delta) {
    _acc += delta;
    final nx = (_acc.dx / step).truncate(), ny = (_acc.dy / step).truncate();
    _acc = Offset(_acc.dx - nx * step, _acc.dy - ny * step);
    return (-nx, -ny);
  }

  void reset() => _acc = Offset.zero;
}

// ---- keyboard ----

const liveModifiers = ['ctrl', 'alt', 'shift', 'super'];
const liveFKeys = ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];

/// Typed single letter/digit + held modifier (Ctrl/Alt/Super) → shortcut key (e.g. Ctrl+C); otherwise null.
String? chordKey(String ch, Set<String> mods) {
  if (!mods.any((m) => m != 'shift')) return null;
  final u = ch.toUpperCase();
  if (u.length == 1 && RegExp(r'^[A-Z0-9]$').hasMatch(u)) return u;
  return null;
}

/// Does the text contain control characters the agent doesn't accept (other than \n and \t)?
bool liveTextOk(String s) => s.isNotEmpty && s.length <= 2000 && !RegExp(r'[\u0000-\u0008\u000b-\u001f\u007f-\u009f]').hasMatch(s);

// ---- connection ----

/// Stream connection (a fake is given in tests). [messages]: String (JSON) or Uint8List (frame).
abstract class LiveConnection {
  Stream<dynamic> get messages;
  void send(String text);
  Future<void> close([int? code]);
  int? get closeCode;
}

class _WsConnection implements LiveConnection {
  _WsConnection(this.ws);
  final WebSocket ws;
  @override
  Stream<dynamic> get messages => ws;
  @override
  void send(String text) => ws.add(text);
  @override
  Future<void> close([int? code]) => ws.close(code ?? 1000);
  @override
  int? get closeCode => ws.closeCode;
}

typedef LiveConnector = Future<LiveConnection> Function(Host host, String controlToken, Map<String, String> query);

/// Real connection: agent address and device token from the client factory, control token in the header.
final liveConnectorProvider = Provider<LiveConnector>((ref) => (host, controlToken, query) async {
      final c = await ref.read(agentClientFactoryProvider)(host);
      final base = Uri.parse(c.baseUrl);
      final token = c.token;
      c.close();
      final uri = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/v1/desktop/stream', queryParameters: query);
      try {
        final ws = await WebSocket.connect(uri.toString(), headers: {'Authorization': 'Bearer $token', controlHeader: controlToken}).timeout(const Duration(seconds: 10));
        ws.pingInterval = const Duration(seconds: 10);
        return _WsConnection(ws);
      } on WebSocketException catch (e) {
        // Upgrade rejected (403: no session/ended, 404: feature off): the agent's code doesn't arrive, inferred from the
        // status.
        final m = RegExp(r'status code (\d+)').firstMatch(e.message) ?? RegExp(r'\b(40\d)\b').firstMatch(e.message);
        final status = int.tryParse(m?.group(1) ?? '');
        if (status == 403) throw const AgentError('agent.control.sessionRequired', {}, 403);
        if (status == 404) throw const AgentError('agent.route.notFound', {}, 404);
        throw AgentError('net.unreachable', {'detail': e.message});
      } on TimeoutException {
        throw const AgentError('net.timeout');
      } on SocketException catch (e) {
        throw AgentError('net.unreachable', {'detail': e.message});
      }
    });

/// Frame decoder (same in tests; the real decoding engine).
typedef FrameDecoder = Future<ui.Image> Function(Uint8List bytes);
final liveDecoderProvider = Provider<FrameDecoder>((ref) => (bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    });

enum LiveStatus { connecting, live, reconnecting, ended }

/// State of one live stream. Lives as long as the screen; [pause]/[resume] are used when the app goes to the
/// background.
class LiveController extends ChangeNotifier {
  LiveController({
    required this.host,
    required this.connector,
    required this.decoder,
    required this.token,
    this.window,
    this.clock = DateTime.now,
    this.fixed,
    this.video,
  });

  /// Native H.264 decoder; null (non-Android, small strip) → JPEG only.
  final LiveVideoBackend? video;

  /// Fixed quality (the small strip in the Claude chat: low fps/scale); if given, no auto adaptation.
  final LiveParams? fixed;

  final Host host;
  final LiveConnector connector;
  final FrameDecoder decoder;
  final String? window;
  final DateTime Function() clock;

  /// Control session token (replaced if the session is renewed).
  String token;

  LiveStatus status = LiveStatus.connecting;

  /// Stream ended/failed to start: agent error code (e.g. agent.control.sessionRequired, agent.desktop.windowNotVisible).
  String? errorCode;

  /// The agent fell back to grim (no wf-recorder): low fps warning.
  bool fallback = false;

  ui.Image? image;
  Size? imageSize;
  LiveRegion? region;

  /// Cursor (image pixels); in touchpad mode relative movement starts from here.
  Offset? cursor;

  /// Focused window (reported by the agent; always null on an old agent → the toolbar isn't shown).
  LiveFocus? focus;

  /// Frames/s shown on screen, excluding identical frames the agent produced and skipped.
  double fps = 0;
  int? rttMs;
  int bytesPerSec = 0;

  LiveQuality quality = LiveQuality.auto;
  final auto = AutoQuality();
  LiveParams get params => fixed ?? paramsFor(quality, auto.level, h264: _wantH264);

  // ---- codec (H.264 / JPEG) ----
  final codecChooser = CodecChooser();
  bool _supportChecked = false;
  bool get _wantH264 => fixed == null && video != null && codecChooser.useH264;

  /// The stream's codec (the agent's hello): 'mjpeg' | 'h264'.
  String codec = 'mjpeg';

  /// H.264 decoder texture ([Texture]); null for JPEG.
  int? textureId;

  /// H.264: the first key frame was given to the decoder (there's an image).
  bool videoShown = false;

  /// H.264 decode latency (enqueue → output, ms).
  double? decodeMs;
  bool get hasPicture => image != null || (textureId != null && videoShown);

  bool _texCreating = false;
  final List<LiveFrame> _texPending = [];
  Timer? _keyTimer;
  Timer? _keyCooldown;
  double? _firstTs;
  int _lastPts = -1;
  String? _codecNotice;

  /// If fallen back, the reason once (the UI shows a short notification).
  String? takeCodecNotice() {
    final n = _codecNotice;
    _codecNotice = null;
    return n;
  }

  LiveConnection? _conn;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _retry;
  Timer? _moveTimer;
  Map<String, Object>? _pendingMove;
  DateTime? _lastMoveAt;
  int _attempt = 0;

  /// Time of the last hello: if the connection stayed healthy for at least [_healthyAfter] the retry delay is reset
  /// (so we don't connect every second to an agent that accepts and closes right away).
  DateTime? _liveSince;
  static const _healthyAfter = Duration(seconds: 5);
  int _gen = 0;
  bool _disposed = false;
  bool _paused = false;
  bool _decoding = false;
  LiveFrame? _next;
  int _shown = 0;
  DateTime? _fpsSince;

  Map<String, String> get _query => {
        ...params.toJson().map((k, v) => MapEntry(k, '$v')),
        if (_wantH264) 'codec': 'h264',
        'window': ?window,
      };

  Future<void> start() async {
    if (_disposed || _paused) return;
    final gen = ++_gen;
    await _closeConn();
    final v = video;
    if (v != null && fixed == null && !_supportChecked) {
      _supportChecked = true;
      codecChooser.support = await v.support();
      if (_disposed || gen != _gen || _paused) return;
    }
    try {
      final conn = await connector(host, token, _query);
      if (_disposed || gen != _gen || _paused) {
        await conn.close();
        return;
      }
      _conn = conn;
      _sub = conn.messages.listen(
        (m) => _onMessage(gen, m),
        onDone: () => _onDone(gen, conn.closeCode),
        onError: (_) => _onDone(gen, null),
        cancelOnError: true,
      );
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 2), (_) => _send({'type': 'ping', 't': clock().millisecondsSinceEpoch}));
    } on AgentError catch (e) {
      if (gen != _gen) return;
      if (e.code == 'agent.control.sessionRequired' || e.code == 'agent.route.notFound' || e.code == 'agent.control.disabled') {
        _end(e.code);
      } else {
        _scheduleRetry();
      }
    } catch (_) {
      if (gen == _gen) _scheduleRetry();
    }
  }

  void _onMessage(int gen, dynamic m) {
    if (gen != _gen || _disposed) return;
    if (m is String) {
      final j = jsonDecode(m);
      if (j is! Map) return;
      _onJson(j);
    } else if (m is List<int>) {
      final f = LiveFrame.parse(m is Uint8List ? m : Uint8List.fromList(m));
      if (f == null) return;
      if (f.isH264) {
        _onVideo(f);
      } else {
        _onFrame(f);
      }
    }
  }

  void _onJson(Map j) {
    switch (j['type']) {
      case 'hello':
        status = LiveStatus.live;
        _liveSince = clock();
        errorCode = null;
        imageSize = Size((j['width'] as num).toDouble(), (j['height'] as num).toDouble());
        region = j['region'] is Map ? LiveRegion.fromJson(j['region'] as Map) : null;
        fallback = j['source'] == 'grim';
        _onCodec(j['codec'] == 'h264' ? 'h264' : 'mjpeg');
        final c = j['cursor'];
        if (c is Map) cursor = Offset((c['x'] as num).toDouble(), (c['y'] as num).toDouble());
        cursor ??= imageSize!.center(Offset.zero);
        notifyListeners();
      case 'focus':
        focus = LiveFocus.fromJson(j);
        notifyListeners();
      case 'notice':
        if (j['code'] == 'agent.desktop.streamFallback') {
          fallback = true;
          notifyListeners();
        } else if (j['code'] == 'agent.desktop.codecFallback') {
          _fallbackCodec('agent'); // the agent is already switching to JPEG; a hello follows
        }
      case 'pong':
        final t = j['t'];
        if (t is num) rttMs = clock().millisecondsSinceEpoch - t.toInt();
      case 'stats':
        bytesPerSec = (j['bytes'] as num?)?.toInt() ?? 0;
        if (codec == 'h264') {
          _videoStats();
        } else {
          _sampleFps();
        }
        if (quality == LiveQuality.auto && !fallback && fixed == null) {
          final next = auto.sample(dropped: (j['dropped'] as num?)?.toInt() ?? 0, fps: fps, targetFps: params.fps, rttMs: rttMs);
          if (next != null) _send({'type': 'quality', ...params.toJson()});
        }
        notifyListeners();
      case 'error':
        final code = '${j['code']}';
        // A setup error (followed by a close with 4400) ends the stream; input errors only show a short notification.
        if (status != LiveStatus.live) errorCode = code;
        _lastError = code;
        notifyListeners();
    }
  }

  /// Last input error (e.g. rate limit); the UI shows a short notification.
  String? _lastError;
  String? takeError() {
    final e = _lastError;
    _lastError = null;
    return e;
  }

  void _sampleFps() {
    final now = clock();
    final since = _fpsSince;
    if (since != null) {
      final ms = now.difference(since).inMilliseconds;
      if (ms > 0) fps = _shown * 1000 / ms;
    }
    _shown = 0;
    _fpsSince = now;
  }

  void _onFrame(LiveFrame f) {
    // If the decoder is busy only the latest frame waits (old frames don't pile up, latency doesn't grow).
    _next = f;
    if (!_decoding) _decodeLoop();
  }

  Future<void> _decodeLoop() async {
    _decoding = true;
    while (_next != null && !_disposed) {
      final f = _next!;
      _next = null;
      try {
        final img = await decoder(f.image);
        if (_disposed) {
          img.dispose();
          break;
        }
        if (codec == 'h264') {
          img.dispose(); // an old JPEG frame decoded while switching to H.264
          continue;
        }
        final old = image;
        image = img;
        imageSize = Size(f.width.toDouble(), f.height.toDouble());
        old?.dispose();
        _shown++;
        notifyListeners();
      } catch (_) {
        // corrupt frame: skipped
      }
    }
    _decoding = false;
  }

  // ---- H.264 ----

  /// hello: the stream's codec. If JPEG came although H.264 was requested (old agent, no wf-recorder), fall back.
  void _onCodec(String c) {
    if (_wantH264 && c != 'h264') _fallbackCodec('agent');
    codec = c;
    if (c != 'h264') {
      _releaseTexture();
      return;
    }
    // If switched from JPEG the old image goes away: a waiting indicator shows until the first H.264 frame decodes.
    image?.dispose();
    image = null;
    // A new process starts with an IDR; still, a key frame is requested on (re)connect (the agent ignores it if an IDR
    // is on the way).
    _keyCooldown?.cancel();
    _requestKey();
  }

  void _onVideo(LiveFrame f) {
    if (codec != 'h264' || video == null || codecChooser.failure != null) return;
    if (imageSize?.width != f.width || imageSize?.height != f.height) {
      imageSize = Size(f.width.toDouble(), f.height.toDouble());
      notifyListeners();
    }
    final id = textureId;
    if (id != null) return _queueVideo(id, f);
    // Frames arriving while the texture is being created wait in order (so config + IDR aren't lost).
    if (_texPending.length >= 120) return _fallbackCodec('decoder');
    _texPending.add(f);
    if (!_texCreating) unawaited(_createTexture(f.width, f.height));
  }

  Future<void> _createTexture(int w, int h) async {
    _texCreating = true;
    final gen = _gen;
    try {
      final id = await video!.create(w, h);
      if (_disposed || gen != _gen || codec != 'h264' || codecChooser.failure != null) {
        unawaited(video!.dispose(id));
        return;
      }
      textureId = id;
      notifyListeners();
      for (final f in _texPending) {
        _queueVideo(id, f);
      }
      _texPending.clear();
    } catch (_) {
      if (!_disposed && gen == _gen) _fallbackCodec('decoder');
    } finally {
      _texCreating = false;
    }
  }

  int _pts(double ts) {
    final first = _firstTs ??= ts;
    var p = ((ts - first) * 1000).round();
    if (p <= _lastPts) p = _lastPts + 1;
    return _lastPts = p;
  }

  void _queueVideo(int id, LiveFrame f) {
    final pts = f.isConfig ? math.max(_lastPts, 0) : _pts(f.ts);
    video!.queue(id, f, pts).then((st) {
      if (_disposed || textureId != id) return;
      if (st == 2) return _fallbackCodec('decoder');
      if (f.isKey) {
        codecChooser.gotKey();
        if (!videoShown) {
          videoShown = true;
          notifyListeners();
        }
      } else if (st == 1 && !f.isConfig) {
        _requestKey(); // decoder reset / fell behind
      }
    }, onError: (Object _) {
      if (!_disposed && textureId == id) _fallbackCodec('decoder');
    });
  }

  /// Requests a key frame (at most once a second); if no key frame is given to the decoder within
  /// [CodecChooser.keyTimeout],
  /// it switches to JPEG.
  void _requestKey() {
    if (_keyCooldown?.isActive ?? false) return;
    _keyCooldown = Timer(const Duration(seconds: 1), () {});
    _send({'type': 'keyframe'});
    if (!codecChooser.waitingKey) {
      codecChooser.awaitKey();
      _keyTimer?.cancel();
      _keyTimer = Timer(CodecChooser.keyTimeout, () {
        if (codecChooser.waitingKey && codec == 'h264' && status == LiveStatus.live) _fallbackCodec('noKey');
      });
    }
  }

  void _videoStats() {
    final id = textureId;
    if (id == null) return;
    video!.stats(id).then((m) {
      if (_disposed || textureId != id) return;
      if (m['failed'] != null) return _fallbackCodec('decoder');
      fps = (m['fps'] as num?)?.toDouble() ?? fps;
      decodeMs = (m['latencyMs'] as num?)?.toDouble();
      notifyListeners();
    }, onError: (Object _) {});
  }

  /// Switch from H.264 to JPEG: the decoder is released, JPEG is requested from the agent (only locally if the agent
  /// switched itself).
  void _fallbackCodec(String reason) {
    if (codecChooser.failure != null) return;
    codecChooser.fail(reason);
    _codecNotice = reason;
    _keyTimer?.cancel();
    _releaseTexture();
    if (reason != 'agent') _send({'type': 'quality', 'codec': 'mjpeg', ...params.toJson()});
    notifyListeners();
  }

  void _releaseTexture() {
    final id = textureId;
    textureId = null;
    videoShown = false;
    decodeMs = null;
    _texPending.clear();
    _firstTs = null;
    _lastPts = -1;
    _keyTimer?.cancel();
    codecChooser.gotKey();
    if (id != null) unawaited(video?.dispose(id).catchError((Object _) {}));
  }

  /// Codec preference from the quality menu: the stream restarts on the same connection.
  void setCodec(LiveCodec p) {
    codecChooser.setPref(p);
    _send({'type': 'quality', 'codec': _wantH264 ? 'h264' : 'mjpeg', ...params.toJson()});
    notifyListeners();
  }

  void _onDone(int gen, int? code) {
    if (gen != _gen || _disposed) return;
    _ping?.cancel();
    // Stream ended: the subscription and connection are already closed.
    _sub = null;
    _conn = null;
    switch (code) {
      case 4401:
        return _end('agent.control.sessionRequired');
      case 4409:
        return _end('agent.desktop.streamReplaced');
      case 4400:
      case 4502:
      case 4503:
        return _end(errorCode ?? 'agent.desktop.streamFailed');
    }
    if (_paused) return;
    _scheduleRetry();
  }

  void _end(String code) {
    status = LiveStatus.ended;
    errorCode = code;
    _retry?.cancel();
    unawaited(_closeConn());
    notifyListeners();
  }

  void _scheduleRetry() {
    if (_disposed || _paused) return;
    final since = _liveSince;
    _liveSince = null;
    if (since != null && clock().difference(since) >= _healthyAfter) _attempt = 0;
    status = LiveStatus.reconnecting;
    notifyListeners();
    _retry?.cancel();
    _retry = Timer(Duration(seconds: const [1, 2, 3, 5, 10][_attempt.clamp(0, 4)]), start);
    _attempt++;
  }

  Future<void> _closeConn() async {
    _ping?.cancel();
    _keyTimer?.cancel();
    codecChooser.gotKey();
    final c = _conn, sub = _sub;
    _conn = null;
    _sub = null;
    unawaited(sub?.cancel());
    await c?.close(); // the agent kills the capture processes on the PC when the WS closes
  }

  /// The app went to the background: the stream (and capture on the PC) stops, the H.264 decoder is released.
  Future<void> pause() async {
    _paused = true;
    _retry?.cancel();
    _gen++;
    _releaseTexture();
    await _closeConn();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    if (status == LiveStatus.ended) return;
    status = LiveStatus.reconnecting;
    notifyListeners();
    await start();
  }

  /// Reconnect manually (ended stream; e.g. with a new session).
  Future<void> reconnect({String? newToken}) async {
    if (newToken != null) token = newToken;
    // Restart even if it ended while the stream was paused (background, session ended elsewhere).
    _paused = false;
    _attempt = 0;
    errorCode = null;
    status = LiveStatus.connecting;
    notifyListeners();
    await start();
  }

  void setQuality(LiveQuality q) {
    quality = q;
    _send({'type': 'quality', ...params.toJson()});
    notifyListeners();
  }

  bool _send(Map<String, Object?> m) {
    final c = _conn;
    if (c == null || status != LiveStatus.live) return false;
    c.send(jsonEncode(m));
    return true;
  }

  // ---- input (image pixels) ----

  Map<String, Object> _pt(Offset p) {
    final s = imageSize!;
    return {'x': double.parse(p.dx.toStringAsFixed(1)), 'y': double.parse(p.dy.toStringAsFixed(1)), 'w': s.width.toInt(), 'h': s.height.toInt()};
  }

  /// Cursor movement: at most ~30 per second (the agent accepts 60 events per second; leave room for clicks/keys).
  void move(Offset p) {
    if (imageSize == null) return;
    cursor = p;
    _pendingMove = {'type': 'move', ..._pt(p)};
    final now = clock();
    final last = _lastMoveAt;
    if (last == null || now.difference(last) >= const Duration(milliseconds: 33)) {
      _flushMove();
    } else {
      _moveTimer ??= Timer(const Duration(milliseconds: 33) - now.difference(last), _flushMove);
    }
    notifyListeners();
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final m = _pendingMove;
    _pendingMove = null;
    if (m == null) return;
    _lastMoveAt = clock();
    _send(m);
  }

  void click(Offset? at, {String button = 'left', int count = 1}) {
    if (imageSize == null) return;
    _flushMove();
    if (at != null) cursor = at;
    _send({'type': 'click', 'button': button, if (count > 1) 'count': count, if (at != null) ..._pt(at)});
  }

  void down({String button = 'left'}) {
    _flushMove();
    _send({'type': 'down', 'button': button});
  }

  void up({String button = 'left'}) {
    _flushMove();
    _send({'type': 'up', 'button': button});
  }

  void scroll(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    _send({'type': 'scroll', 'dx': dx.clamp(-20, 20), 'dy': dy.clamp(-20, 20)});
  }

  void key(String key, [Iterable<String> mods = const []]) => _send({'type': 'key', 'key': key, 'mods': mods.toList()});

  /// Wait in the agent's input queue (0–1000 ms): the following events run at intervals independent of network latency.
  void wait(int ms) => _send({'type': 'wait', 'ms': ms.clamp(0, 1000)});

  void text(String t) {
    if (liveTextOk(t)) _send({'type': 'text', 'text': t});
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _moveTimer?.cancel();
    _ping?.cancel();
    _keyCooldown?.cancel();
    unawaited(_closeConn());
    _releaseTexture();
    image?.dispose();
    image = null;
    super.dispose();
  }
}
