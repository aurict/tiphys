// "Use the PC" Claude session (10.3): a live screen strip above the chat (10.2 stream, small and low fps;
// tap = fullscreen viewer, usable by hand from there too), control time + extend and a prominent "Stop"
// (cuts Claude AND closes the control session). When control ends, a clear status card and "reopen" (lock asked
// again, the agent binds the session with a new token). Screenshots in tool results are thumbnails (tap = enlarge).
// Relaxed rule for the PC session: leaving the chat or sending the app to the background does NOT CLOSE control (a
// task can be given and the phone pocketed); instead a persistent notification (pc_ongoing.dart) stays for the
// control duration and "Stop" works without opening the app. Control's own duration, the PC border
// and notify-send carry on as before.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../desktop/desktop_data.dart';
import '../desktop/desktop_screen.dart' show ControlBanner;
import '../desktop/live_screen.dart' show openLiveScreen;
import '../desktop/live_stream.dart';
import '../system/agent_providers.dart';
import 'claude_controller.dart';
import 'claude_screen.dart' show claudeHostProvider;
import 'pc_ongoing.dart';

/// Stream quality of the strip in the chat: low fps and scale (little bandwidth and PC load).
const pcStripParams = LiveParams(4, 0.35, 45);

/// Screenshot taken by Claude (copy on the agent's disk; last 60). Kept while the app stays open.
final pcShotProvider = FutureProvider.family<Uint8List?, (String, String)>((ref, key) async {
  final (hostId, id) = key;
  try {
    final b = await withAgent(ref, hostId, (c) => c.requestBytes('/v1/claude/shots/$id', timeout: const Duration(seconds: 20)));
    return isRasterImage(b) ? b : null;
  } on AgentError {
    return null;
  }
});

class PcPanel extends ConsumerStatefulWidget {
  const PcPanel({super.key, required this.controller, required this.hostId});
  final ClaudeSessionController controller;
  final String hostId;
  @override
  ConsumerState<PcPanel> createState() => _PcPanelState();
}

class _PcPanelState extends ConsumerState<PcPanel> {
  LiveController? _live;
  late final ControlController _control;
  late final AppLifecycleListener _life;
  bool _busy = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _control = ref.read(controlProvider.notifier);
    _life = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  /// In the background only the strip's stream stops (bandwidth/PC load); control and Claude continue.
  void _onLifecycle(AppLifecycleState s) {
    if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
      unawaited(_live?.pause());
    } else if (s == AppLifecycleState.resumed) {
      if (!_expanded) unawaited(_live?.resume());
    }
  }

  /// Persistent notification + stored token: hold while the agent is bound, release when unbound (after build).
  void _syncHold(bool active, bool agentInactive) {
    final c = widget.controller;
    final ongoing = ref.read(pcOngoingProvider.notifier);
    final held = ref.read(pcOngoingProvider)?.sessionId == c.sessionId;
    if (active) {
      final title = '${c.summary?['title'] ?? ''}';
      unawaited(ongoing.hold(hostId: widget.hostId, sessionId: c.sessionId, title: title, l: AppLocalizations.of(context)));
    } else if (held && agentInactive) {
      ongoing.ended(c.sessionId);
    }
  }

  /// The strip's stream (on while there's a session; otherwise off).
  void _sync(ControlSession? s, bool active) {
    if (!active || s == null) {
      final l = _live;
      if (l != null) {
        _live = null;
        l.removeListener(_onLive);
        l.dispose();
      }
      return;
    }
    if (_live != null) return;
    final host = ref.read(profileProvider).host(widget.hostId);
    if (host == null) return;
    final c = LiveController(
      host: host,
      connector: ref.read(liveConnectorProvider),
      decoder: ref.read(liveDecoderProvider),
      token: s.token,
      clock: ref.read(clockProvider),
      fixed: pcStripParams,
    )..addListener(_onLive);
    _live = c;
    unawaited(c.start());
  }

  void _onLive() {
    final c = _live;
    if (c == null || !mounted) return;
    // If the token was refreshed on the same device, continue with the new token.
    final s = ref.read(controlProvider);
    if (c.status == LiveStatus.ended && s != null && s.hostId == widget.hostId && s.token != c.token) unawaited(c.reconnect(newToken: s.token));
  }

  @override
  void dispose() {
    _life.dispose();
    _live?.removeListener(_onLive);
    _live?.dispose();
    // Leaving the chat does NOT CLOSE control (PC session): the persistent notification stays, Claude keeps working.
    super.dispose();
  }

  /// Stop: cuts Claude and closes the control session (the indicator on the PC goes away).
  Future<void> _stop() async {
    final l = AppLocalizations.of(context);
    try {
      if (widget.controller.busy || widget.controller.status == 'waiting') await widget.controller.interrupt();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
    await _control.stop();
  }

  /// Reopen control: lock asked again, the agent binds this chat to a new session.
  Future<void> _reconnect() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final s = await _control.ensure(context, widget.hostId, fresh: true);
      if (s == null) return;
      await widget.controller.bindControl(s.token);
    } catch (e) {
      if (e is AgentError && e.code == 'agent.control.sessionRequired') _control.forget();
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fullscreen live viewer (usable by hand too); the strip resumes on return.
  Future<void> _expand() async {
    final c = _live;
    if (c == null) return;
    _expanded = true;
    await c.pause(); // one stream per session: the strip makes room
    if (!mounted) return;
    await openLiveScreen(context, widget.hostId);
    _expanded = false;
    if (mounted && identical(_live, c)) await c.resume();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = widget.controller;
    final s = ref.watch(controlProvider);
    final mine = s != null && s.hostId == widget.hostId ? s : null;
    final active = mine != null && c.pcControlActive;
    _sync(mine, active);
    final agentInactive = c.summary != null && !c.pcControlActive;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncHold(active, agentInactive);
    });
    final live = _live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: active && live != null
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Strip(live: live, onTap: _expand),
              const SizedBox(height: 8),
              ControlBanner(session: mine, onStop: _stop),
            ])
          : Semantics(
              liveRegion: true,
              container: true,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                decoration: BoxDecoration(
                  color: t.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: t.warning.withValues(alpha: 0.5)),
                ),
                child: Row(children: [
                  Icon(LucideIcons.monitorOff, color: t.warning, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.pcControlEndReason == 'expired' ? l.claudePcExpired : l.claudePcEnded,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _reconnect,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 14)),
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l.claudePcReconnect, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
    );
  }
}

/// Small live screen: frame is fitted; tap = enlarge.
class _Strip extends StatelessWidget {
  const _Strip({required this.live, required this.onTap});
  final LiveController live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: l.claudePcExpand,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 172,
            color: const Color(0xFF0B0B0E),
            child: ListenableBuilder(
              listenable: live,
              builder: (context, _) => Stack(fit: StackFit.expand, children: [
                if (live.image != null)
                  RawImage(image: live.image, fit: BoxFit.contain, filterQuality: FilterQuality.medium)
                else if (live.status != LiveStatus.ended)
                  const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
                else
                  Center(child: Text(liveErrorCode(l, live.errorCode), style: const TextStyle(color: Colors.white70, fontSize: 12.5), textAlign: TextAlign.center)),
                Positioned(
                  top: 8,
                  left: 8,
                  child: _Pill(children: [
                    Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFFFF3B30), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(l.liveTitle, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
                const Positioned(top: 8, right: 8, child: _Pill(children: [Icon(LucideIcons.maximize2, color: Colors.white, size: 15)])),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

String liveErrorCode(AppLocalizations l, String? code) => agentErrorText(l, AgentError(code ?? 'agent.control.sessionRequired'));

class _Pill extends StatelessWidget {
  const _Pill({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}

/// Thumbnail of the screenshot in a tool result; tap = enlarge (zoomable).
class PcShotThumb extends ConsumerWidget {
  const PcShotThumb({super.key, required this.shotId});
  final String shotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(claudeHostProvider);
    if (host == null) return const SizedBox.shrink();
    final img = ref.watch(pcShotProvider((host.id, shotId)));
    final bytes = img.value;
    Widget box(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(height: 112, width: 200, color: t.chipBackground, child: child),
        );
    if (bytes == null) {
      return box(img.isLoading ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))) : Icon(LucideIcons.imageOff, color: t.textSecondary));
    }
    return Semantics(
      button: true,
      label: l.claudePcShot,
      child: GestureDetector(
        onTap: () => showPcShot(context, bytes),
        child: box(Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, semanticLabel: l.claudePcShot)),
      ),
    );
  }
}

/// Fullscreen screenshot: pinch to zoom.
Future<void> showPcShot(BuildContext context, Uint8List bytes) => showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (c) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(children: [
          Positioned.fill(child: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes, semanticLabel: AppLocalizations.of(c).claudePcShot)))),
          Positioned(
            top: MediaQuery.paddingOf(c).top + 8,
            right: 8,
            child: IconButton(
              tooltip: MaterialLocalizations.of(c).closeButtonTooltip,
              style: IconButton.styleFrom(backgroundColor: const Color(0x66000000)),
              icon: const Icon(LucideIcons.x, color: Colors.white),
              onPressed: () => Navigator.of(c).pop(),
            ),
          ),
        ]),
      ),
    );
