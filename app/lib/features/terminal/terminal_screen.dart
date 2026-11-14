// Terminal sekmesi: host seçimi, oturum sekmeleri, xterm görünümü, ek tuş çubuğu, komut parçacıkları.
import 'package:flutter/material.dart';
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

    // Dosyalar'dan "burada terminal aç" ile gelindiyse bir kez aç.
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
        // Host ve oturum çipleri
        SizedBox(
          height: 44,
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

class _SessionView extends ConsumerWidget {
  const _SessionView({super.key, required this.session});
  final TermSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fontSize = ref.watch(profileProvider.select((p) => p.terminal.fontSize));
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Stack(children: [
        Positioned.fill(
          child: TerminalView(
            session.terminal,
            theme: terminalTheme(t),
            textStyle: TerminalStyle(fontSize: fontSize, fontFamily: 'JetBrainsMono'),
            autofocus: true,
            keyboardAppearance: t.isDark ? Brightness.dark : Brightness.light,
            backgroundOpacity: 0,
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
      useRootNavigator: true, // alt sekme barının üstünde açılsın; yoksa bar sayfanın altını örter
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
