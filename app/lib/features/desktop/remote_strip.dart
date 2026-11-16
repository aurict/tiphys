// The live screen's smart toolbar (11.1): the focused app's icon + name, horizontally scrolling remote buttons
// (the user's own buttons first, then the built-in profile) and an "all remotes" page. In portrait a strip above
// the keyboard bar, in landscape a column on the right. When hidden, a "show" button stays at the start of the
// keyboard bar; the state is stored on the device. Buttons send the existing WS input events (control session
// and the agent's rate limit apply as is);
// `confirm` buttons ask for confirmation on the phone, `prompt` buttons ask for text on the phone.
// 11.4: for the focused window the first button is "Mobile view" (a native button; also on the all remotes page).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../widgets/forms.dart';
import '../claude/claude_screen.dart' show outboxDirProvider;
import '../system/agent_providers.dart';
import '../system/media.dart';
import 'browser.dart';
import 'browser_screen.dart';
import 'desktop_data.dart';
import 'live_stream.dart';
import 'mobile_view_screen.dart';
import 'remote.dart';

/// Delay between events in a sequence: ydotool (uinput) and wtype (virtual keyboard) take separate paths; so the
/// order doesn't get mixed up when they come back to back.
const remoteStepGap = Duration(milliseconds: 80);

/// Longer delay if text follows right after a shortcut (command palette, Ctrl+L, Ctrl+F, Ctrl+P, F2 … open UI):
/// text typed before the opened field gets focus goes to the document. WS input has no ack; the agent runs
/// events in order but doesn't wait in between, so this relies on timing. If the network bunches events, the
/// delay on the phone is lost;
/// the real fix would be a "wait" event on the agent side.
const remoteUiGap = Duration(milliseconds: 300);

// ---- hidden/shown state (on the device) ----

class LiveRemoteCollapsed extends Notifier<bool> {
  @override
  bool build() {
    Future(() async {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      try {
        state = (jsonDecode(await f.readAsString()) as Map)['collapsed'] == true;
      } catch (_) {}
    });
    return false;
  }

  Future<File?> _file() async {
    final dir = await ref.read(outboxDirProvider)();
    return dir == null ? null : File('$dir/live-remote.json');
  }

  Future<void> set(bool v) async {
    state = v;
    final f = await _file();
    if (f != null) await f.writeAsString(jsonEncode({'collapsed': v}));
  }
}

final liveRemoteCollapsedProvider = NotifierProvider<LiveRemoteCollapsed, bool>(LiveRemoteCollapsed.new);

// ---- texts ----

String remoteLabel(AppLocalizations l, RemoteButton b) =>
    b.label ??
    switch (b.id) {
      'address' => l.remoteAddress,
      'back' => l.remoteBack,
      'forward' => l.remoteForward,
      'reload' => l.remoteReload,
      'newTab' => l.remoteNewTab,
      'closeTab' => l.remoteCloseTab,
      'reopenTab' => l.remoteReopenTab,
      'nextTab' => l.remoteNextTab,
      'prevTab' => l.remotePrevTab,
      'find' => l.remoteFind,
      'zoomIn' => l.remoteZoomIn,
      'zoomOut' => l.remoteZoomOut,
      'zoomReset' => l.remoteZoomReset,
      'fullscreen' => l.remoteFullscreen,
      'reader' => l.remoteReader,
      'scrollDown' => l.remoteScrollDown,
      'scrollUp' => l.remoteScrollUp,
      'top' => l.remoteTop,
      'palette' => l.remotePalette,
      'goToFile' => l.remoteGoToFile,
      'save' => l.remoteSave,
      'terminal' => l.remoteTerminal,
      'replace' => l.remoteReplace,
      'goToLine' => l.remoteGoToLine,
      'undo' => l.liveUndo,
      'redo' => l.remoteRedo,
      'comment' => l.remoteComment,
      'sidebar' => l.remoteSidebar,
      'interrupt' => l.remoteInterrupt,
      'eof' => l.remoteEof,
      'tab' => 'Tab',
      'history' => l.remoteHistory,
      'copy' => l.liveCopy,
      'paste' => l.livePaste,
      'cut' => l.remoteCut,
      'parent' => l.remoteParent,
      'path' => l.remotePath,
      'rename' => l.remoteRename,
      'newFolder' => l.remoteNewFolder,
      'delete' => l.commonDelete,
      'hidden' => l.remoteHidden,
      'playPause' => l.remotePlayPause,
      'seekBack' => l.remoteSeekBack,
      'seekForward' => l.remoteSeekForward,
      'volumeDown' => l.remoteVolumeDown,
      'volumeUp' => l.remoteVolumeUp,
      'mute' => l.remoteMute,
      'subtitles' => l.remoteSubtitles,
      'selectAll' => l.remoteSelectAll,
      'esc' => 'Esc',
      'enter' => 'Enter',
      'switchWindow' => l.liveSwitchWindow,
      'closeWindow' => l.remoteCloseWindow,
      'tabs' => l.browserTabs,
      'toPhone' => l.browserToPhone,
      'mobileView' => l.uiTitle,
      'mediaCard' => l.mediaTitle,
      _ => b.id,
    };

String _promptHint(AppLocalizations l, String? key) => switch (key) {
      'address' => l.remotePromptAddress,
      'find' => l.remotePromptFind,
      'command' => l.remotePromptCommand,
      'file' => l.remotePromptFile,
      'line' => l.remotePromptLine,
      'path' => l.remotePromptPath,
      _ => l.remotePromptText,
    };

// ---- execution ----

/// Sends the events in order to the live stream (waiting after each is sent); waits [uiGap] on a shortcut → text
/// transition, [gap] otherwise.
Future<void> sendRemoteEvents(LiveController live, List<Map<String, Object>> events, {Duration gap = remoteStepGap, Duration uiGap = remoteUiGap}) async {
  // The gaps are waited in the agent's input queue (`wait` event): even if the network bunches events, the UI
  // opened by the shortcut (command palette, address bar) is ready before the text.
  for (var i = 0; i < events.length; i++) {
    final wait = i == 0 ? Duration.zero : (events[i - 1]['type'] == 'key' && events[i]['type'] == 'text' ? uiGap : gap);
    if (wait > Duration.zero) live.wait(wait.inMilliseconds);
    final e = events[i];
    switch (e['type']) {
      case 'key':
        live.key(e['key'] as String, (e['mods'] as List).cast<String>());
      case 'text':
        live.text(e['text'] as String);
      case 'scroll':
        live.scroll(e['dx'] as int, e['dy'] as int);
    }
  }
}

/// Button: asks for confirmation or text if needed, then sends the events. Nothing is sent if cancelled.
/// If focus moved to another window while asking (input goes to the focused one), nothing is sent and a short
/// notification appears.
/// Native buttons ([RemoteButton.native]) send no events; [onNative] runs (if confirm is set, it asks first).
Future<void> runRemoteButton(BuildContext context, LiveController live, RemoteButton b, {Duration gap = remoteStepGap, Future<void> Function(RemoteNative n)? onNative}) async {
  final l = AppLocalizations.of(context);
  final label = remoteLabel(l, b);
  if (b.native != null) {
    if (b.confirm && !await confirmDialog(context, message: l.remoteConfirm(label), confirmLabel: label, destructive: true)) return;
    await onNative?.call(b.native!);
    return;
  }
  final at = live.focus?.address;
  String? text;
  if (b.action.kind == RemoteKind.prompt) {
    text = await _askText(context, label, _promptHint(l, b.prompt));
    if (text == null) return;
  }
  if (b.confirm) {
    if (!context.mounted) return;
    if (!await confirmDialog(context, message: l.remoteConfirm(label), confirmLabel: l.remoteSend, destructive: true)) return;
  }
  if ((text != null || b.confirm) && live.focus?.address != at) {
    if (context.mounted) toast(context, l.remoteFocusChanged);
    return;
  }
  final events = remoteEvents(b.action, text: text);
  if (events == null) {
    if (context.mounted) toast(context, l.liveErrBadKey);
    return;
  }
  await sendRemoteEvents(live, events, gap: gap);
}

Future<String?> _askText(BuildContext context, String title, String hint) =>
    showDialog<String>(context: context, builder: (_) => _PromptDialog(title: title, hint: hint));

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.title, required this.hint});
  final String title;
  final String hint;
  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _send() {
    final v = _c.text;
    if (v.trim().isNotEmpty) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        maxLength: 500,
        textInputAction: TextInputAction.send,
        decoration: InputDecoration(hintText: widget.hint, counterText: ''),
        onSubmitted: (_) => _send(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        FilledButton(onPressed: _send, child: Text(l.remoteSend)),
      ],
    );
  }
}

// ---- strip ----

/// 11.4: mobile view of the focused window (first button in every app; the same stream continues in the preview).
const mobileViewButton = RemoteButton('mobileView', LucideIcons.layoutList, RemoteAction.combo('Esc'), native: RemoteNative.mobileView);

/// Buttons for the focused app: mobile view (if the window address is known), the user's own, the built-in profile.
List<RemoteButton> remoteButtonsFor(Profile p, LiveFocus f) => [
      if ((f.address ?? '').isNotEmpty) mobileViewButton,
      for (final r in remotesFor(p.desktopRemotes, f.cls, f.initialClass)) ?userButton(r),
      ...remoteProfileFor(f.cls, f.initialClass).buttons,
    ];

class LiveRemoteStrip extends ConsumerWidget {
  const LiveRemoteStrip({super.key, required this.hostId, required this.live, required this.focus, this.vertical = false});
  final String hostId;
  final LiveController live;
  final LiveFocus focus;

  /// Column on the right in landscape.
  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profile = remoteProfileFor(focus.cls, focus.initialClass);
    final buttons = remoteButtonsFor(ref.watch(profileProvider), focus);
    final name = profile.name ?? (focus.cls.isEmpty ? l.remoteDesktop : focus.cls);
    final appIcon = _AppIcon(hostId: hostId, appId: focus.appId);
    final title = Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5));
    final more = _StripIcon(icon: LucideIcons.ellipsis, label: l.remoteMore, onTap: () => _more(context, ref, name, buttons));
    final hide = _StripIcon(
      icon: vertical ? LucideIcons.chevronRight : LucideIcons.chevronDown,
      label: l.remoteHide,
      onTap: () => ref.read(liveRemoteCollapsedProvider.notifier).set(true),
    );
    Widget chip(RemoteButton b) => _RemoteChip(button: b, label: remoteLabel(l, b), onTap: () => runRemoteButton(context, live, b, onNative: (n) => _native(context, ref, n)), expand: vertical);

    if (vertical) {
      return Semantics(
        container: true,
        label: l.remoteStripLabel(name),
        child: Container(
          width: 168,
          decoration: const BoxDecoration(color: Color(0xFF16161A), border: Border(left: BorderSide(color: Color(0x1FFFFFFF)))),
          child: SafeArea(
            left: false,
            bottom: false,
            child: LayoutBuilder(builder: (context, box) {
              final head = Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
                child: Row(children: [appIcon, const SizedBox(width: 8), Expanded(child: title), hide]),
              );
              final chips = [for (final b in buttons) Padding(padding: const EdgeInsets.only(bottom: 6), child: chip(b))];
              final tail = Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), child: SizedBox(width: double.infinity, child: more));
              // On a short screen (375 px landscape phone + keyboard bar + on-screen keyboard), a fixed title and "all"
              // leave no room for the buttons/they overflow: the whole column scrolls together.
              if (box.maxHeight < _stripCompactHeight) {
                return ListView(key: ValueKey('${profile.id}/${focus.cls}'), padding: EdgeInsets.zero, children: [
                  head,
                  Padding(padding: const EdgeInsets.fromLTRB(8, 2, 8, 0), child: Column(children: chips)),
                  tail,
                ]);
              }
              return Column(children: [
                head,
                Expanded(
                  child: ListView(key: ValueKey('${profile.id}/${focus.cls}'), padding: const EdgeInsets.fromLTRB(8, 2, 8, 6), children: chips),
                ),
                tail,
              ]);
            }),
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      label: l.remoteStripLabel(name),
      child: Container(
        height: 57,
        decoration: const BoxDecoration(color: Color(0xFF16161A), border: Border(top: BorderSide(color: Color(0x1FFFFFFF)))),
        child: Row(children: [
          const SizedBox(width: 10),
          appIcon,
          const SizedBox(width: 8),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 92), child: title),
          const SizedBox(width: 4),
          Expanded(
            child: ListView(
              key: ValueKey('${profile.id}/${focus.cls}'), // from the start when the app changes
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              children: [for (final b in buttons) Padding(padding: const EdgeInsets.only(right: 6), child: chip(b))],
            ),
          ),
          more,
          const SizedBox(width: 6),
          hide,
          const SizedBox(width: 6),
        ]),
      ),
    );
  }

  /// Native buttons: close the window via the agent, Firefox tabs / send the active tab to the phone, media card.
  Future<void> _native(BuildContext context, WidgetRef ref, RemoteNative n) async {
    final l = AppLocalizations.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    switch (n) {
      case RemoteNative.closeWindow:
        final a = focus.address;
        if (a == null) return toast(context, l.desktopWindowGone);
        await desktopAction(context, ref, hostId, '/v1/desktop/windows/$a/close');
      case RemoteNative.mobileView:
        final a = focus.address;
        if (a == null) return toast(context, l.desktopWindowGone);
        await openMobileView(context, hostId, address: a, title: focus.title, live: live);
      case RemoteNative.tabs:
        await nav.push(MaterialPageRoute<void>(builder: (_) => BrowserTabsScreen(hostId: hostId, fromLive: true)));
      case RemoteNative.media:
        await nav.push(MaterialPageRoute<void>(builder: (_) => MediaScreen(hostId: hostId)));
      case RemoteNative.toPhone:
        try {
          final r = await browserRequest(context, ref, hostId, 'GET', '/v1/desktop/browser/tabs');
          if (r == null || !context.mounted) return;
          final tab = activeTabFor(parseTabs((r as Map)['tabs']), focus.title);
          if (tab == null) return toast(context, l.browserNotWebUrl);
          await openTabOnPhone(context, ref, tab);
        } catch (e) {
          if (context.mounted) toast(context, agentErrorText(l, e));
        }
    }
  }

  Future<void> _more(BuildContext context, WidgetRef ref, String name, List<RemoteButton> buttons) async {
    final l = AppLocalizations.of(context);
    final user = buttons.where((b) => b.label != null).toList();
    final builtIn = buttons.where((b) => b.label == null).toList();
    final picked = await showModalBottomSheet<RemoteButton>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) {
        Widget tile(RemoteButton b) {
          final hint = b.native == null ? remoteHint(b.action) : null;
          return ListTile(
            leading: Icon(b.icon, size: 20),
            title: Text(remoteLabel(l, b)),
            trailing: hint == null
                ? null
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(c).textTheme.bodySmall),
                  ),
            minTileHeight: 48,
            onTap: () => Navigator.pop(c, b),
          );
        }

        Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 2), child: Text(t, style: Theme.of(c).textTheme.titleSmall));
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.72),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
              if (user.isNotEmpty) ...[head(l.remoteMine), for (final b in user) tile(b)],
              head(name),
              for (final b in builtIn) tile(b),
            ]),
          ),
        );
      },
    );
    if (picked != null && context.mounted) await runRemoteButton(context, live, picked, onNative: (n) => _native(context, ref, n));
  }
}

/// Height at which the side column fits the title + "all" + at least one and a half buttons; below it the
/// column scrolls as one piece.
const _stripCompactHeight = 190.0;

class _AppIcon extends ConsumerWidget {
  const _AppIcon({required this.hostId, required this.appId});
  final String hostId;
  final String? appId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = appId;
    final b = id == null ? null : ref.watch(desktopIconProvider((hostId, id))).value;
    if (b != null) return Image.memory(b, width: 26, height: 26, fit: BoxFit.contain, gaplessPlayback: true, excludeFromSemantics: true);
    return const Icon(LucideIcons.appWindow, size: 22, color: Color(0xFFD1D1D6));
  }
}

class _RemoteChip extends StatelessWidget {
  const _RemoteChip({required this.button, required this.label, required this.onTap, this.expand = false});
  final RemoteButton button;
  final String label;
  final VoidCallback onTap;
  final bool expand;
  @override
  Widget build(BuildContext context) {
    final hint = button.native == null ? remoteHint(button.action) : null;
    return Tooltip(
      message: hint == null ? label : '$label ($hint)',
      child: Semantics(
        button: true,
        label: label,
        hint: button.confirm ? AppLocalizations.of(context).remoteConfirmHint : null,
        excludeSemantics: true,
        child: Material(
          color: const Color(0xFF1C2A3D),
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            focusColor: const Color(0x663D8BFF),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: 44, minWidth: expand ? double.infinity : 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(button.icon, size: 16, color: button.confirm ? const Color(0xFFFF8A80) : const Color(0xFF64D2FF)),
                  const SizedBox(width: 6),
                  if (expand)
                    Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _chipText))
                  else
                    Text(label, style: _chipText),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _chipText = TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13);

class _StripIcon extends StatelessWidget {
  const _StripIcon({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              focusColor: const Color(0x663D8BFF),
              onTap: onTap,
              child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 18, color: Colors.white)),
            ),
          ),
        ),
      );
}
