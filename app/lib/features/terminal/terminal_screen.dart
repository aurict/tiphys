// Terminal tab: host picker, session tabs, xterm view, extra key bar, command snippets.
// Two-finger font sizing; landscape use in the full-screen view.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/floating_tab_bar.dart';
import '../../widgets/surfaces.dart';
import '../notes/obsidian.dart';
import 'sessions.dart';

TerminalTheme terminalTheme(TiphysTokens t) => TerminalTheme(
      cursor: t.isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4338CA),
      selection: (t.isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4338CA)).withValues(alpha: 0.3),
      foreground: t.isDark ? const Color(0xFFE5E5EA) : const Color(0xFF1C1C1E),
      background: Colors.transparent,
      black: const Color(0xFF1C1C1E),
      red: t.isDark ? const Color(0xFFFF6961) : const Color(0xFFC62828),
      green: t.isDark ? const Color(0xFF30D158) : const Color(0xFF15803D),
      yellow: t.isDark ? const Color(0xFFFFD60A) : const Color(0xFFB45309),
      blue: t.isDark ? const Color(0xFF64B5F6) : const Color(0xFF1D4ED8),
      magenta: t.isDark ? const Color(0xFFA39DF5) : const Color(0xFF6D28D9),
      cyan: t.isDark ? const Color(0xFF7AD9AE) : const Color(0xFF0F766E),
      white: const Color(0xFFD1D1D6),
      brightBlack: const Color(0xFF8E8E93),
      brightRed: const Color(0xFFFF8A80),
      brightGreen: const Color(0xFF69F0AE),
      brightYellow: const Color(0xFFFFE57F),
      brightBlue: const Color(0xFF82B1FF),
      brightMagenta: const Color(0xFFD1C4E9),
      brightCyan: const Color(0xFFA7FFEB),
      brightWhite: const Color(0xFFFFFFFF),
      searchHitBackground: const Color(0xFFFFE082),
      searchHitBackgroundCurrent: const Color(0xFFFFB300),
      searchHitForeground: const Color(0xFF000000),
    );

String sshFailureText(AppLocalizations l, SshFailure? f) => switch (f?.code) {
      'noSsh' => l.sshNoSsh,
      'missingSecret' => l.secretMissing(f!.detail ?? ''),
      'unreachable' => l.sshUnreachable,
      'auth' => l.sshAuthFailed,
      'timeout' => l.sshTimeout,
      'hostKeyChanged' => l.sshHostKeyChanged,
      _ => '${l.commonError}${f?.detail == null ? '' : ': ${f!.detail}'}',
    };

class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key, this.hostId, this.startDir});
  final String? hostId;
  final String? startDir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final profile = ref.watch(profileProvider);
    final sessions = ref.watch(terminalSessionsProvider);
    final activeId = ref.watch(activeTerminalProvider);
    final active = sessions.where((s) => s.id == activeId).firstOrNull ?? sessions.lastOrNull;
    final hosts = profile.hosts.where((h) => h.ssh != null).toList();

    void open(Host h, {String? dir}) {
      final s = ref.read(terminalSessionsProvider.notifier).open(h, startDir: dir);
      ref.read(activeTerminalProvider.notifier).select(s.id);
    }

    // If we came from Files via "open terminal here", open it once.
    if (hostId != null && startDir != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final h = profile.host(hostId);
        final already = sessions.any((s) => s.host.id == hostId && s.startDir == startDir);
        if (h != null && !already) open(h, dir: startDir);
      });
    }

    final top = MediaQuery.paddingOf(context).top;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Padding(
      padding: EdgeInsets.only(top: top + 12, bottom: keyboardOpen ? 0 : FloatingTabBar.height + FloatingTabBar.bottomGap + 12),
      child: Column(children: [
        // Host and session chips; full screen on the right
        SizedBox(
          height: 44,
          child: Row(children: [
            Expanded(
              child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter),
            children: [
              for (final s in sessions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _SessionChip(session: s, selected: s == active, onTap: () => ref.read(activeTerminalProvider.notifier).select(s.id)),
                ),
              for (final h in hosts)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: Icon(LucideIcons.plus, size: 16, color: hexColor(h.color)),
                    label: Text(h.name),
                    tooltip: l.terminalOpenOn(h.name),
                    onPressed: () => open(h),
                    backgroundColor: t.chipBackground,
                    side: BorderSide(color: t.separator),
                    shape: const StadiumBorder(),
                  ),
                ),
            ],
              ),
            ),
            // If Obsidian is configured: save the selected text (otherwise the visible screen) as a quick note.
            if (active != null && profile.integrations.obsidian != null)
              IconButton(
                tooltip: l.noteSave,
                icon: const Icon(LucideIcons.notebookPen, size: 20),
                onPressed: () => openQuickNote(context, text: terminalNoteText(active.terminal, active.view.selection), title: 'Terminal · ${active.host.name}'),
              ),
            if (active != null)
              Padding(
                padding: const EdgeInsets.only(right: TiphysTokens.gutter - 8),
                child: IconButton(
                  tooltip: l.terminalFullscreen,
                  icon: const Icon(LucideIcons.maximize2, size: 20),
                  onPressed: () => openTerminalFullscreen(context, ref, active),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: active == null
                ? _Empty(hasHosts: hosts.isNotEmpty)
                : TCard(padding: const EdgeInsets.fromLTRB(8, 8, 4, 4), radius: 22, child: _SessionView(key: ValueKey(active.id), session: active)),
          ),
        ),
        if (active != null) _ExtraKeys(session: active, keys: profile.terminal.extraKeys, snippets: profile.terminal.snippets),
      ]),
    );
  }
}

/// Note text from the terminal: the selection if any, otherwise the visible screen (trailing whitespace trimmed).
String terminalNoteText(Terminal t, BufferRange? selection) {
  if (selection != null && !selection.isCollapsed) return t.buffer.getText(selection).trimRight();
  final b = t.buffer;
  return [for (var i = b.scrollBack; i < b.height; i++) b.lines[i].getText().trimRight()].join('\n').trim();
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasHosts});
  final bool hasHosts;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(LucideIcons.terminal, size: 40, color: context.tokens.textSecondary),
        const SizedBox(height: 12),
        Text(hasHosts ? l.terminalPickHost : l.terminalNoSshHosts, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
      ]),
    );
  }
}

class _SessionChip extends StatelessWidget {
  const _SessionChip({required this.session, required this.selected, required this.onTap});
  final TermSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final color = switch (session.status) {
          TermStatus.connected => t.success,
          TermStatus.connecting => t.warning,
          _ => t.danger,
        };
        return ChoiceChip(
          selected: selected,
          onSelected: (_) => onTap(),
          showCheckmark: false,
          avatar: StatusDot(color: color, size: 8),
          label: Text(session.host.name),
          selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
          labelStyle: TextStyle(color: selected ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
          backgroundColor: t.chipBackground,
          side: BorderSide(color: selected ? Colors.transparent : t.separator),
          shape: const StadiumBorder(),
        );
      },
    );
  }
}

/// Full-screen (landscape-rotatable) terminal. On close, portrait lock and system bars come back.
Future<void> openTerminalFullscreen(BuildContext context, WidgetRef ref, TermSession session) async {
  final fullscreen = ref.read(fullscreenTerminalProvider.notifier);
  fullscreen.set(session.id);
  try {
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => TerminalFullscreenScreen(session: session)));
  } finally {
    fullscreen.set(null);
  }
}

class TerminalFullscreenScreen extends ConsumerStatefulWidget {
  const TerminalFullscreenScreen({super.key, required this.session});
  final TermSession session;
  @override
  ConsumerState<TerminalFullscreenScreen> createState() => _TerminalFullscreenState();
}

class _TerminalFullscreenState extends ConsumerState<TerminalFullscreenScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight, DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final profile = ref.watch(profileProvider);
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: Padding(padding: const EdgeInsets.fromLTRB(6, 4, 2, 0), child: _SessionView(session: widget.session, fullscreen: true)),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton.filledTonal(
                  tooltip: l.terminalExitFullscreen,
                  icon: const Icon(LucideIcons.minimize2, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ]),
          ),
          _ExtraKeys(session: widget.session, keys: profile.terminal.extraKeys, snippets: profile.terminal.snippets),
        ]),
      ),
    );
  }
}

/// New font size from the ratio of the distance between two fingers (8–32, in half-point steps).
double pinchFontSize(double startFont, double startDistance, double distance) {
  final f = (startFont * distance / startDistance).clamp(8.0, 32.0);
  return (f * 2).round() / 2;
}

class _SessionView extends ConsumerStatefulWidget {
  const _SessionView({super.key, required this.session, this.fullscreen = false});
  final TermSession session;

  /// Whether this is the full-screen view (the tab's view doesn't draw the terminal meanwhile).
  final bool fullscreen;
  @override
  ConsumerState<_SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends ConsumerState<_SessionView> {
  // Pinch zoom: raw pointers are tracked (so it doesn't compete with the terminal's scroll/selection gestures).
  final _pointers = <int, Offset>{};
  double? _startDistance;
  double? _startFont;
  double? _liveFont;

  double get _distance {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _startDistance = math.max(_distance, 1);
      _startFont = _liveFont ?? ref.read(profileProvider).terminal.fontSize;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length != 2 || _startDistance == null) return;
    final f = pinchFontSize(_startFont!, _startDistance!, _distance);
    if (f != _liveFont) setState(() => _liveFont = f);
  }

  Future<void> _up(PointerEvent e) async {
    _pointers.remove(e.pointer);
    if (_pointers.length >= 2 || _startDistance == null) return;
    _startDistance = null;
    final f = _liveFont;
    // The live size stays until saving finishes (otherwise the text briefly jumps back to the old size).
    if (f != null && f != ref.read(profileProvider).terminal.fontSize) {
      await ref.read(profileProvider.notifier).update((p) => p.copyWith(terminal: p.terminal.copyWith(fontSize: f)));
    }
    if (mounted && _startDistance == null) setState(() => _liveFont = null);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final session = widget.session;
    final double fontSize = _liveFont ?? ref.watch(profileProvider.select((p) => p.terminal.fontSize));
    if (!widget.fullscreen && ref.watch(fullscreenTerminalProvider) == session.id) {
      return Center(child: Text(l.terminalInFullscreen, style: Theme.of(context).textTheme.bodyMedium));
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Stack(children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: TerminalView(
              session.terminal,
              controller: session.view,
              theme: terminalTheme(t),
              textStyle: TerminalStyle(fontSize: fontSize, fontFamily: 'JetBrainsMono'),
              autofocus: true,
              keyboardAppearance: t.isDark ? Brightness.dark : Brightness.light,
              backgroundOpacity: 0,
              // While zooming, don't resize the SSH window on every step; once when the fingers lift.
              autoResize: _startDistance == null,
            ),
          ),
        ),
        if (_liveFont != null)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TCard(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: Text(l.terminalFontSizeValue(_liveFont! % 1 == 0 ? '${_liveFont!.round()}' : '$_liveFont'))),
            ),
          ),
        if (session.status != TermStatus.connected)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Semantics(
              liveRegion: true,
              child: TCard(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(children: [
                  if (session.status == TermStatus.connecting)
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(LucideIcons.circleAlert, color: t.danger, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      switch (session.status) {
                        TermStatus.connecting => l.sshConnecting(session.host.name),
                        TermStatus.disconnected => l.sshDisconnected,
                        _ => sshFailureText(l, session.failure),
                      },
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (session.status != TermStatus.connecting)
                    TextButton(onPressed: () => ref.read(terminalSessionsProvider.notifier).reconnect(session), child: Text(l.sshReconnect)),
                  IconButton(
                    tooltip: l.commonClose,
                    icon: const Icon(LucideIcons.x, size: 18),
                    onPressed: () => ref.read(terminalSessionsProvider.notifier).close(session),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ExtraKeys extends StatelessWidget {
  const _ExtraKeys({required this.session, required this.keys, required this.snippets});
  final TermSession session;
  final List<String> keys;
  final List<Snippet> snippets;

  static String label(String k) => switch (k) {
        'esc' => 'Esc',
        'tab' => 'Tab',
        'ctrl' => 'Ctrl',
        'alt' => 'Alt',
        'up' => '↑',
        'down' => '↓',
        'left' => '←',
        'right' => '→',
        'home' => 'Home',
        'end' => 'End',
        'pgup' => 'PgUp',
        'pgdn' => 'PgDn',
        _ => k,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          children: [
            if (snippets.isNotEmpty)
              _Key(
                label: '⌘',
                semantics: l.terminalSnippets,
                onTap: () => showModalBottomSheet<void>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
                  context: context,
                  builder: (c) => ListView(shrinkWrap: true, children: [
                    for (final s in snippets.where((s) => s.hostId == null || s.hostId == session.host.id))
                      ListTile(
                        title: Text(s.name),
                        subtitle: Text(s.command, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
                        onTap: () {
                          Navigator.pop(c);
                          session.runCommand(s.command);
                        },
                      ),
                  ]),
                ),
              ),
            for (final k in keys)
              _Key(
                label: label(k),
                active: (k == 'ctrl' && session.ctrl) || (k == 'alt' && session.alt),
                onTap: () => session.sendKey(k),
                activeColor: t.accent,
              ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap, this.active = false, this.semantics, this.activeColor});
  final String label;
  final VoidCallback onTap;
  final bool active;
  final String? semantics;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        toggled: active,
        label: semantics ?? label,
        child: Material(
          color: active ? (activeColor ?? t.accent) : t.chipBackground,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontWeight: FontWeight.w700, fontSize: 14, color: active ? t.onAccent : t.text)),
            ),
          ),
        ),
      ),
    );
  }
}
