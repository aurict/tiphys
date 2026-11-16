// Live screen (10.2 Stage A): the PC's screen (or a single window) fullscreen, rotatable to landscape. Opened from the
// desktop screen ("Live screen", "Show this window" in the window menu) and the home screen shortcut; uses the 10.1
// control session (if none, the lock is asked again and one is opened).
// Touch: in direct mode tap = left click (two taps in a row at the same spot = double click), long press = right
// click, one-finger drag = mouse drag, two-finger drag = scroll, pinch = zoom/pan the image (not sent to the
// PC). In touchpad mode one finger moves the cursor relatively, tap = click where the cursor is.
// Keyboard bar at the bottom (on-screen keyboard, Esc/Tab/Ctrl/Alt/Super, arrows, F keys, preset shortcuts); fps/latency,
// session time (tap = extend), quality, mode and "Stop" on top. The stream stops when the app goes to the background;
// if it stays longer than 60 s the session closes too.
// 10.2 Stage C: if the phone has an H.264 decoder the image is on a native MediaCodec texture ([LiveVideoView]); the
// same [LiveView] layout as JPEG is used, the touch → coordinate mapping is identical for both renderers. Codec in
// the quality menu (Auto / H.264 / JPEG), codec · fps · latency · bitrate on top.
// 11.1: when the agent reports the focused window, an app-specific toolbar above the keyboard bar (on the right in
// landscape) ([LiveRemoteStrip]); when hidden, a "show" button at the start of the keyboard bar.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../widgets/forms.dart';
import '../system/agent_providers.dart';
import 'desktop_data.dart';
import 'desktop_screen.dart' show controlBackgroundLimit;
import 'live_stream.dart';
import 'moonlight.dart';
import 'remote_strip.dart';

/// Opens the live screen. [window]: only this window (address). [endSessionOnExit]: the control session also closes
/// on exit
/// (when opened from the desktop screen the session lives along with that screen).
Future<void> openLiveScreen(BuildContext context, String hostId, {String? window, String? title, bool endSessionOnExit = false}) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
      builder: (_) => LiveScreen(hostId: hostId, window: window, title: title, endSessionOnExit: endSessionOnExit),
    ));

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key, required this.hostId, this.window, this.title, this.endSessionOnExit = true});
  final String hostId;
  final String? window;
  final String? title;
  final bool endSessionOnExit;
  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

enum _Mode { direct, touchpad }

class _LiveScreenState extends ConsumerState<LiveScreen> {
  LiveController? _live;
  late final ControlController _control;
  late final AppLifecycleListener _life;
  Timer? _bgTimer;
  DateTime? _bgAt;
  _Mode _mode = _Mode.direct;
  bool _chrome = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _control = ref.read(controlProvider.notifier);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight, DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _life = AppLifecycleListener(onStateChange: _onLifecycle);
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  void _onLifecycle(AppLifecycleState s) {
    if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
      unawaited(_live?.pause());
      _bgAt ??= DateTime.now();
      _bgTimer ??= Timer(controlBackgroundLimit, _control.release);
    } else if (s == AppLifecycleState.resumed) {
      _bgTimer?.cancel();
      _bgTimer = null;
      final at = _bgAt;
      _bgAt = null;
      if (at != null && DateTime.now().difference(at) >= controlBackgroundLimit) unawaited(_control.release());
      if (ref.read(controlProvider)?.hostId == widget.hostId) unawaited(_live?.resume());
    }
  }

  /// Opens the session (with the lock if needed) and starts the stream; the screen closes if cancelled.
  Future<void> _begin({bool restart = false}) async {
    if (_starting) return;
    _starting = true;
    final l = AppLocalizations.of(context);
    try {
      final s = await _control.ensure(context, widget.hostId);
      if (!mounted) return;
      if (s == null) {
        if (!restart) _exit();
        return;
      }
      final host = ref.read(profileProvider).host(widget.hostId)!;
      if (_live == null) {
        final c = LiveController(
          host: host,
          connector: ref.read(liveConnectorProvider),
          decoder: ref.read(liveDecoderProvider),
          token: s.token,
          window: widget.window,
          clock: ref.read(clockProvider),
          video: ref.read(liveVideoProvider),
        )..addListener(_onLive);
        setState(() => _live = c);
        await c.start();
      } else {
        await _live!.reconnect(newToken: s.token);
      }
    } catch (e) {
      if (mounted) {
        toast(context, agentErrorText(l, e));
        if (!restart && _live == null) _exit();
      }
    } finally {
      _starting = false;
    }
  }

  void _onLive() {
    final c = _live;
    if (c == null || !mounted) return;
    final err = c.takeError();
    if (err != null && c.status == LiveStatus.live) toast(context, liveErrorText(AppLocalizations.of(context), err));
    if (c.takeCodecNotice() != null) toast(context, AppLocalizations.of(context).liveCodecFallback);
    if (c.status == LiveStatus.ended && c.errorCode == 'agent.control.sessionRequired') {
      // If the session was renewed another way (same device got a new token), continue with the new token; otherwise it's
      // over.
      final s = ref.read(controlProvider);
      if (s != null && s.hostId == widget.hostId && s.token != c.token && s.expiresAt.isAfter(ref.read(clockProvider)())) {
        unawaited(c.reconnect(newToken: s.token));
      } else if (s?.token == c.token) {
        _control.forget();
      }
    }
  }

  @override
  void dispose() {
    _life.dispose();
    _bgTimer?.cancel();
    _live?.removeListener(_onLive);
    _live?.dispose();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (widget.endSessionOnExit) Future.microtask(_control.release);
    super.dispose();
  }

  Future<void> _stop() async {
    await _control.stop();
    _exit();
  }

  /// Close: returns to the page below if any, otherwise (if opened via a direct route) to the desktop screen.
  void _exit() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      context.go('/system/desktop?host=${Uri.encodeQueryComponent(widget.hostId)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _live;
    final session = ref.watch(controlProvider);
    // If the session was stopped elsewhere (strip, timeout), the stream ends too.
    if (c != null && session == null && c.status != LiveStatus.ended && !_starting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(controlProvider) == null) unawaited(c.pause());
      });
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        body: c == null
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  final ended = c.status == LiveStatus.ended || (session == null && !_starting);
                  final focus = c.focus;
                  final remote = _chrome && !ended && focus != null;
                  final collapsed = ref.watch(liveRemoteCollapsedProvider);
                  final size = MediaQuery.sizeOf(context);
                  final side = size.width > size.height;
                  return Column(children: [
                    Expanded(
                      child: Row(children: [
                        Expanded(
                          child: Stack(children: [
                            Positioned.fill(child: LiveCanvas(live: c, touchpad: _mode == _Mode.touchpad)),
                            if (!c.hasPicture && !ended) const Center(child: CircularProgressIndicator(color: Colors.white)),
                            if (_chrome)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                child: _TopBar(
                                  title: widget.title ?? l.liveTitle,
                                  live: c,
                                  session: session != null && session.hostId == widget.hostId ? session : null,
                                  touchpad: _mode == _Mode.touchpad,
                                  onMode: () => setState(() => _mode = _mode == _Mode.direct ? _Mode.touchpad : _Mode.direct),
                                  onHide: () => setState(() => _chrome = false),
                                  onStop: _stop,
                                  onBack: _exit,
                                  onMoonlight: () => showMoonlightSheet(context, widget.hostId),
                                ),
                              )
                            else
                              Positioned(
                                top: MediaQuery.paddingOf(context).top + 6,
                                right: 6,
                                child: _GlassIcon(icon: LucideIcons.eye, tooltip: l.liveShowBar, onTap: () => setState(() => _chrome = true)),
                              ),
                            if (c.status == LiveStatus.reconnecting && !ended)
                              Positioned(left: 12, right: 12, bottom: 12, child: _Banner(icon: LucideIcons.wifiOff, text: l.liveReconnecting)),
                            if (c.fallback && c.status == LiveStatus.live && _chrome)
                              Positioned(left: 12, right: 12, bottom: 12, child: _Banner(icon: LucideIcons.gauge, text: l.liveFallback)),
                            if (ended)
                              Positioned.fill(
                                child: _Ended(
                                  text: liveErrorText(l, c.errorCode ?? 'agent.control.sessionRequired'),
                                  onRestart: () => _begin(restart: true),
                                  onClose: _exit,
                                ),
                              ),
                          ]),
                        ),
                        if (remote && !collapsed && side) LiveRemoteStrip(hostId: widget.hostId, live: c, focus: focus, vertical: true),
                      ]),
                    ),
                    if (remote && !collapsed && !side) LiveRemoteStrip(hostId: widget.hostId, live: c, focus: focus),
                    if (_chrome && !ended)
                      LiveKeyboardBar(live: c, leading: [
                        if (remote && collapsed)
                          _KeyButton(icon: LucideIcons.squareMousePointer, label: l.remoteShow, onTap: () => ref.read(liveRemoteCollapsedProvider.notifier).set(false)),
                      ]),
                  ]);
                },
              ),
      ),
    );
  }
}

/// Agent code → user text (including codes specific to the live screen).
String liveErrorText(AppLocalizations l, String code) => agentErrorText(l, AgentError(code));

// ---- image and touch ----

/// Draws the frame fitted, turns touches into input events. Image zoom happens only on the phone.
/// JPEG ([_FramePainter]) and H.264 ([LiveVideoView]) are drawn into the same [LiveView.rect]: touch mapping is shared.
class LiveCanvas extends StatefulWidget {
  const LiveCanvas({super.key, required this.live, required this.touchpad});
  final LiveController live;
  final bool touchpad;
  @override
  State<LiveCanvas> createState() => _LiveCanvasState();
}

enum _Gesture { none, drag, pad, pinch, scroll }

class _LiveCanvasState extends State<LiveCanvas> {
  double _zoom = 1;
  Offset _pan = Offset.zero;
  final _snapper = TapSnapper();
  final _scroll = ScrollAccumulator();
  _Gesture _g = _Gesture.none;
  Offset? _downAt;
  LiveView? _startView;
  Offset _startFocal = Offset.zero;

  LiveView? _view(Size viewport) {
    final img = widget.live.imageSize;
    if (img == null || viewport.isEmpty) return null;
    return LiveView(viewport: viewport, image: img, zoom: _zoom, pan: _pan);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      final view = _view(size);
      final live = widget.live;
      return Listener(
        onPointerDown: (e) => _downAt ??= e.localPosition,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tap(view, d.localPosition),
          onLongPressStart: (d) => _longPress(view, d.localPosition),
          onScaleStart: (d) => _start(view, d),
          onScaleUpdate: (d) => _update(view, d),
          onScaleEnd: (_) => _end(),
          child: Stack(children: [
            if (live.textureId != null && view != null) Positioned.fromRect(rect: view.rect, child: LiveVideoView(textureId: live.textureId!)),
            Semantics(
              label: AppLocalizations.of(context).liveTitle,
              image: true,
              child: CustomPaint(
                size: size,
                painter: _FramePainter(
                  image: live.textureId != null ? null : live.image,
                  rect: view?.rect,
                  cursor: widget.touchpad && view != null && live.cursor != null ? view.toScreen(live.cursor!) : null,
                ),
              ),
            ),
            if (_zoom > 1.01)
              Positioned(
                right: 10,
                bottom: 10,
                child: _GlassIcon(icon: LucideIcons.minimize2, tooltip: AppLocalizations.of(context).liveResetZoom, onTap: resetZoom),
              ),
          ]),
        ),
      );
    });
  }

  void _tap(LiveView? v, Offset p) {
    _downAt = null;
    if (v == null) return;
    final live = widget.live;
    if (widget.touchpad) return live.click(null);
    final img = v.toImage(p);
    if (img == null) return; // margin
    live.click(_snapper.snap(p, img, DateTime.now()));
  }

  void _longPress(LiveView? v, Offset p) {
    _downAt = null;
    if (v == null) return;
    HapticFeedback.mediumImpact();
    if (widget.touchpad) return widget.live.click(null, button: 'right');
    final img = v.toImage(p);
    if (img != null) widget.live.click(img, button: 'right');
  }

  void _start(LiveView? v, ScaleStartDetails d) {
    _startView = v;
    _startFocal = d.localFocalPoint;
    _scroll.reset();
    if (v == null) return;
    if (d.pointerCount >= 2) {
      _g = _Gesture.none; // pinch or pan is decided on the first move
    } else if (widget.touchpad) {
      _g = _Gesture.pad;
    } else {
      // Mouse drag: starts where the finger first touched.
      final at = v.toImage(_downAt ?? d.localFocalPoint, clamp: true)!;
      widget.live.move(at);
      widget.live.down();
      _g = _Gesture.drag;
    }
  }

  void _update(LiveView? v, ScaleUpdateDetails d) {
    if (v == null) return;
    final live = widget.live;
    if (d.pointerCount >= 2 && (_g == _Gesture.drag || _g == _Gesture.pad)) {
      // A second finger arrived while dragging: the drag ends, switching to a two-finger gesture.
      if (_g == _Gesture.drag) live.up();
      _g = _Gesture.none;
      _startView = v;
      _startFocal = d.localFocalPoint;
    }
    switch (_g) {
      case _Gesture.drag:
        live.move(v.toImage(d.localFocalPoint, clamp: true)!);
      case _Gesture.pad:
        final cur = live.cursor ?? v.image.center(Offset.zero);
        final next = cur + v.deltaToImage(d.focalPointDelta) * 1.6;
        live.move(Offset(next.dx.clamp(0, v.image.width - 1), next.dy.clamp(0, v.image.height - 1)));
      case _Gesture.none:
        if (d.pointerCount < 2) return;
        if ((d.scale - 1).abs() > 0.08) {
          _g = _Gesture.pinch;
        } else if ((d.localFocalPoint - _startFocal).distance > 10) {
          _g = _Gesture.scroll;
        }
      case _Gesture.pinch:
        final sv = _startView ?? v;
        final z = sv.zoomed(sv.zoom * d.scale, _startFocal, panBy: d.localFocalPoint - _startFocal);
        setState(() {
          _zoom = z.zoom;
          _pan = z.pan;
        });
      case _Gesture.scroll:
        final (dx, dy) = _scroll.add(d.focalPointDelta);
        live.scroll(dx, dy);
    }
  }

  void _end() {
    if (_g == _Gesture.drag) widget.live.up();
    _g = _Gesture.none;
    _downAt = null;
  }

  @override
  void didUpdateWidget(LiveCanvas old) {
    super.didUpdateWidget(old);
    // The canvas is rebuilt every frame: the drag start point is forgotten only when the mode/stream changes.
    if (old.touchpad != widget.touchpad || old.live != widget.live) _downAt = null;
  }

  void resetZoom() => setState(() {
        _zoom = 1;
        _pan = Offset.zero;
      });
}

/// H.264 image: the native decoder's texture, stretched to the given rectangle (fitted image area).
class LiveVideoView extends StatelessWidget {
  const LiveVideoView({super.key, required this.textureId});
  final int textureId;
  @override
  Widget build(BuildContext context) => Texture(textureId: textureId, filterQuality: FilterQuality.medium);
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.image, required this.rect, required this.cursor});
  final ui.Image? image;
  final Rect? rect;
  final Offset? cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    final r = rect;
    if (img != null && r != null) {
      paintImage(canvas: canvas, rect: r, image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium);
    }
    final c = cursor;
    if (c != null) {
      canvas.drawCircle(c, 9, Paint()..color = const Color(0x55FFFFFF));
      canvas.drawCircle(c, 9, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF0A84FF));
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.image != image || old.rect != rect || old.cursor != cursor;
}

// ---- top bar ----

class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({required this.title, required this.live, required this.session, required this.touchpad, required this.onMode, required this.onHide, required this.onStop, required this.onBack, required this.onMoonlight});
  final String title;
  final LiveController live;
  final ControlSession? session;
  final bool touchpad;
  final VoidCallback onMode;
  final VoidCallback onHide;
  final VoidCallback onStop;
  final VoidCallback onBack;

  /// "High quality (Moonlight)" at the end of the quality menu.
  final VoidCallback onMoonlight;
  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = widget.live;
    final s = widget.session;
    final left = s?.expiresAt.difference(ref.read(clockProvider)());
    final secs = left == null || left.isNegative ? 0 : left.inSeconds;
    final time = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    final stats = c.status == LiveStatus.live
        ? [
            c.codec == 'h264' ? 'H.264' : 'JPEG',
            c.rttMs == null ? l.liveStatsFps(c.fps.toStringAsFixed(0)) : l.liveStats(c.fps.toStringAsFixed(0), '${c.rttMs}'),
            if (c.bytesPerSec > 0) l.liveBitrate((c.bytesPerSec * 8 / 1e6).toStringAsFixed(1)),
          ].join(' · ')
        : (c.status == LiveStatus.reconnecting ? l.liveReconnectingShort : l.liveConnecting);
    final qLabel = switch (c.quality) {
      LiveQuality.auto => l.liveQualityAuto,
      LiveQuality.high => l.liveQualityHigh,
      LiveQuality.medium => l.liveQualityMedium,
      LiveQuality.low => l.liveQualityLow,
    };
    final back = _GlassIcon(icon: LucideIcons.chevronLeft, tooltip: MaterialLocalizations.of(context).backButtonTooltip, onTap: widget.onBack);
    final title = Semantics(
      liveRegion: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
        Text(stats, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFD1D1D6), fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
      ]),
    );
    final tools = <Widget>[
      PopupMenuButton<Object>(
        tooltip: '${l.liveQuality}: $qLabel',
        initialValue: c.quality,
        onSelected: (v) => switch (v) {
          LiveQuality q => c.setQuality(q),
          LiveCodec k => c.setCodec(k),
          _ => widget.onMoonlight(),
        },
        itemBuilder: (_) => [
          for (final (q, label) in [
            (LiveQuality.auto, l.liveQualityAuto),
            (LiveQuality.high, l.liveQualityHigh),
            (LiveQuality.medium, l.liveQualityMedium),
            (LiveQuality.low, l.liveQualityLow),
          ])
            CheckedPopupMenuItem<Object>(value: q, checked: q == c.quality, child: Text(label)),
          // Codec: H.264 only if the phone has a decoder (Auto requires a hardware decoder).
          if (c.video != null) ...[
            const PopupMenuDivider(),
            for (final (k, label) in [
              (LiveCodec.auto, l.liveCodecAuto),
              (LiveCodec.h264, l.liveCodecH264),
              (LiveCodec.jpeg, l.liveCodecJpeg),
            ])
              CheckedPopupMenuItem<Object>(
                value: k,
                checked: k == c.codecChooser.pref,
                enabled: k != LiveCodec.h264 || c.codecChooser.support.available,
                child: Text(label),
              ),
          ],
          const PopupMenuDivider(),
          // Sunshine + Moonlight: 60 fps NVENC (games, video); doesn't replace the in-app stream, sits alongside it.
          PopupMenuItem<Object>(
            value: 'moonlight',
            child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(LucideIcons.gamepad2), title: Text(l.moonlightEntry)),
          ),
        ],
        child: _GlassIcon(icon: LucideIcons.gauge, label: qLabel),
      ),
      const SizedBox(width: 6),
      _GlassIcon(
        icon: widget.touchpad ? LucideIcons.touchpad : LucideIcons.pointer,
        tooltip: widget.touchpad ? l.liveModeTouchpad : l.liveModeDirect,
        selected: widget.touchpad,
        onTap: widget.onMode,
      ),
      const SizedBox(width: 6),
      _GlassIcon(icon: LucideIcons.eyeOff, tooltip: l.liveHideBar, onTap: widget.onHide),
    ];
    final session = <Widget>[
      if (s != null)
        Tooltip(
          message: l.desktopControlExtend,
          child: Semantics(
            button: true,
            label: '${l.liveSessionLeft(time)}. ${l.desktopControlExtend}',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                try {
                  await ref.read(controlProvider.notifier).extend();
                } catch (e) {
                  if (context.mounted) toast(context, agentErrorText(l, e));
                }
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: const Color(0x66000000), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0x55FFFFFF))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.timerReset, size: 16, color: Colors.white),
                  const SizedBox(width: 5),
                  Text(time, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
                ]),
              ),
            ),
          ),
        ),
      const SizedBox(width: 6),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD70015), foregroundColor: Colors.white, minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 12)),
        onPressed: widget.onStop,
        child: Text(l.desktopControlStop, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
          child: LayoutBuilder(
            // Two rows on a narrow (portrait) screen: title + session, tools below; one row when wide.
            builder: (context, box) => box.maxWidth < 600
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [back, const SizedBox(width: 6), Expanded(child: title), ...session]),
                    const SizedBox(height: 6),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: tools),
                  ])
                : Row(children: [back, const SizedBox(width: 6), Expanded(child: title), ...tools, const SizedBox(width: 10), ...session]),
          ),
        ),
      ),
    );
  }
}

class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.icon, this.tooltip, this.onTap, this.selected = false, this.label});
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool selected;

  /// Short text next to the icon (e.g. the selected quality).
  final String? label;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      height: 40,
      constraints: const BoxConstraints(minWidth: 40),
      padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 12),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF0A84FF) : const Color(0x66000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x55FFFFFF)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 19, color: Colors.white),
        if (label != null) ...[
          const SizedBox(width: 6),
          Text(label!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ]),
    );
    if (onTap == null) return box; // PopupMenuButton handles its own tap and tooltip
    return Tooltip(
      message: tooltip ?? '',
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        excludeSemantics: true,
        child: InkResponse(onTap: onTap, radius: 24, child: box),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xE61C1C1E), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(icon, size: 18, color: const Color(0xFFFFD60A)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.3))),
          ]),
        ),
      );
}

class _Ended extends StatelessWidget {
  const _Ended({required this.text, required this.onRestart, required this.onClose});
  final String text;
  final VoidCallback onRestart;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ColoredBox(
      color: const Color(0xB3000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(18)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(LucideIcons.monitorOff, color: Color(0xFFD1D1D6), size: 28),
              const SizedBox(height: 10),
              Text(l.liveEnded, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(text, style: const TextStyle(color: Color(0xFFD1D1D6), height: 1.35)),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: onClose, style: TextButton.styleFrom(foregroundColor: Colors.white), child: Text(l.commonClose)),
                const SizedBox(width: 8),
                FilledButton(onPressed: onRestart, child: Text(l.liveRestart)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---- keyboard bar ----

/// On-screen keyboard (hidden text field), Esc/Tab/modifiers/arrows, F keys page and preset shortcuts.
/// Ctrl/Alt/Shift/Super are one-shot: once pressed they go along with the next key or typed letter.
class LiveKeyboardBar extends StatefulWidget {
  const LiveKeyboardBar({super.key, required this.live, this.leading = const []});
  final LiveController live;

  /// Items prepended to the key row (e.g. the button that reopens a hidden toolbar).
  final List<Widget> leading;
  @override
  State<LiveKeyboardBar> createState() => _LiveKeyboardBarState();
}

class _LiveKeyboardBarState extends State<LiveKeyboardBar> {
  /// Fixed content of the hidden field: shrinking means backspace, growing means typed text.
  static const _base = '  ';
  final _text = TextEditingController(text: _base);
  final _focus = FocusNode();
  final _mods = <String>{};

  @override
  void initState() {
    super.initState();
    _reset();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reset() {
    _text.value = const TextEditingValue(text: _base, selection: TextSelection.collapsed(offset: _base.length));
  }

  void _key(String key) {
    widget.live.key(key, _mods);
    if (_mods.isNotEmpty) setState(_mods.clear);
  }

  void _onChanged(String v) {
    if (v.length < _base.length) {
      for (var i = 0; i < _base.length - v.length; i++) {
        _key('Backspace');
      }
    } else if (v.startsWith(_base) && v.length > _base.length) {
      final typed = v.substring(_base.length);
      final chord = typed.length == 1 ? chordKey(typed, _mods) : null;
      if (chord != null) {
        _key(chord);
      } else {
        widget.live.text(typed);
        if (_mods.isNotEmpty) setState(_mods.clear);
      }
    }
    _reset();
  }

  void _toggleKeyboard() {
    if (_focus.hasFocus) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  Future<void> _moreKeys() async {
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.liveMoreKeys, style: Theme.of(c).textTheme.titleMedium),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in [...liveFKeys, 'Home', 'End', 'PageUp', 'PageDown', 'Insert', 'Delete', 'Backspace', 'Enter', 'Space', 'PrintScreen'])
                ActionChip(label: Text(_keyLabel(l, k)), onPressed: () => Navigator.pop(c, k)),
            ]),
          ]),
        ),
      ),
    );
    if (picked != null) _key(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final keys = <Widget>[
      ...widget.leading,
      _KeyButton(icon: _focus.hasFocus ? LucideIcons.keyboardOff : LucideIcons.keyboard, label: l.liveKeyboard, selected: _focus.hasFocus, onTap: _toggleKeyboard),
      _KeyButton(text: 'Esc', label: 'Esc', onTap: () => _key('Esc')),
      _KeyButton(text: 'Tab', label: 'Tab', onTap: () => _key('Tab')),
      for (final m in liveModifiers)
        _KeyButton(
          text: _modLabel(m),
          label: _modLabel(m),
          selected: _mods.contains(m),
          onTap: () => setState(() => _mods.contains(m) ? _mods.remove(m) : _mods.add(m)),
        ),
      _KeyButton(icon: LucideIcons.arrowLeft, label: l.liveKeyLeft, onTap: () => _key('Left')),
      _KeyButton(icon: LucideIcons.arrowUp, label: l.liveKeyUp, onTap: () => _key('Up')),
      _KeyButton(icon: LucideIcons.arrowDown, label: l.liveKeyDown, onTap: () => _key('Down')),
      _KeyButton(icon: LucideIcons.arrowRight, label: l.liveKeyRight, onTap: () => _key('Right')),
      _KeyButton(text: 'F1–12', label: l.liveMoreKeys, onTap: _moreKeys),
    ];
    final combos = <Widget>[
      _ComboButton(icon: LucideIcons.copy, label: l.liveCopy, onTap: () => widget.live.key('C', const ['ctrl'])),
      _ComboButton(icon: LucideIcons.clipboardPaste, label: l.livePaste, onTap: () => widget.live.key('V', const ['ctrl'])),
      _ComboButton(icon: LucideIcons.undo2, label: l.liveUndo, onTap: () => widget.live.key('Z', const ['ctrl'])),
      _ComboButton(icon: LucideIcons.appWindow, label: l.liveSwitchWindow, onTap: () => widget.live.key('Tab', const ['alt'])),
    ];
    Widget row(List<Widget> items) => SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            children: [for (final k in items) Padding(padding: const EdgeInsets.only(right: 6), child: k)],
          ),
        );
    // In portrait keys and shortcuts are on separate rows; in landscape (little height) a single scrollable row.
    final tall = MediaQuery.sizeOf(context).height > 500;
    return ColoredBox(
      color: const Color(0xFF111114),
      child: SafeArea(
        top: false,
        child: Stack(children: [
          // Target of the on-screen keyboard: invisible but focusable.
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0,
              child: ExcludeSemantics(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.send,
                  onChanged: _onChanged,
                  onEditingComplete: () => _key('Enter'), // the keyboard stays open
                ),
              ),
            ),
          ),
          if (tall)
            Column(mainAxisSize: MainAxisSize.min, children: [row(keys), row(combos)])
          else
            row([...keys, const SizedBox(width: 6), ...combos]),
        ]),
      ),
    );
  }
}

String _modLabel(String m) => switch (m) {
      'ctrl' => 'Ctrl',
      'alt' => 'Alt',
      'shift' => 'Shift',
      _ => 'Super',
    };

String _keyLabel(AppLocalizations l, String k) => switch (k) {
      'PageUp' => 'PgUp',
      'PageDown' => 'PgDn',
      'Space' => l.liveKeySpace,
      'PrintScreen' => 'PrtSc',
      _ => k,
    };

class _KeyButton extends StatelessWidget {
  const _KeyButton({this.text, this.icon, required this.label, required this.onTap, this.selected = false});
  final String? text;
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Semantics(
          button: true,
          toggled: selected ? true : null,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: selected ? const Color(0xFF0A84FF) : const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Center(
                    child: icon != null
                        ? Icon(icon, size: 18, color: Colors.white)
                        : Text(text!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _ComboButton extends StatelessWidget {
  const _ComboButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF1C2A3D),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 16, color: const Color(0xFF64D2FF)),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
          ),
        ),
      );
}

/// Home screen shortcut / route: live screen on the Claude host (the session closes on exit).
void openLiveScreenRoute(BuildContext context, String hostId) => context.push('/system/desktop/live?host=${Uri.encodeQueryComponent(hostId)}');
