// Smart toolbar (11.1): a built-in remote profile by the focused window's class (single table), the user's
// remotes (profile `desktopRemotes`), shortcut text parsing (same rules as the agent's key table:
// agent/src/desktop_input.ts KEYS + keyArgs) and action → the live stream's existing WS input events (key/text/scroll).
// Shortcuts were chosen to be as layout-independent as possible (the dev PC uses a Turkish Q layout): no punctuation keys (e.g. in VS Code
// a command palette sequence instead of Ctrl+`), letters/digits only with Ctrl/Alt/Super; where a plain letter is
// needed (mpv/vlc "m", "f")
// a text event (wtype) is used. Firefox zoom uses the numeric keypad +/−.
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';

// ---- shortcut text ----

/// The agent's allowed key names (agent/src/desktop_input.ts KEYS).
const liveKeyNames = {
  'Esc', 'Tab', 'Enter', 'Backspace', 'Delete', 'Insert', 'Space', 'Up', 'Down', 'Left', 'Right', 'Home', 'End', //
  'PageUp', 'PageDown', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12', 'Super', 'PrintScreen',
  'KPPlus', 'KPMinus',
};

const _keyAliases = {
  'esc': 'Esc', 'escape': 'Esc', 'tab': 'Tab', 'enter': 'Enter', 'return': 'Enter', 'backspace': 'Backspace', //
  'delete': 'Delete', 'del': 'Delete', 'insert': 'Insert', 'ins': 'Insert', 'space': 'Space', 'up': 'Up', 'down': 'Down',
  'left': 'Left', 'right': 'Right', 'home': 'Home', 'end': 'End', 'pageup': 'PageUp', 'pgup': 'PageUp',
  'pagedown': 'PageDown', 'pgdn': 'PageDown', 'printscreen': 'PrintScreen', 'prtsc': 'PrintScreen', 'super': 'Super',
  'kpplus': 'KPPlus', 'kpminus': 'KPMinus',
};

const _modAliases = {'ctrl': 'ctrl', 'control': 'ctrl', 'alt': 'alt', 'shift': 'shift', 'super': 'super', 'meta': 'super', 'win': 'super'};
const _modOrder = ['ctrl', 'alt', 'shift', 'super'];

class KeyCombo {
  const KeyCombo(this.key, this.mods);
  final String key;
  final List<String> mods;

  /// Display format ("Ctrl+Shift+T", "Num +").
  String get label => [
        for (final m in mods) const {'ctrl': 'Ctrl', 'alt': 'Alt', 'shift': 'Shift', 'super': 'Super'}[m]!,
        switch (key) {
          'KPPlus' => 'Num +',
          'KPMinus' => 'Num −',
          'PageUp' => 'PgUp',
          'PageDown' => 'PgDn',
          _ => key,
        },
      ].join('+');

  Map<String, Object> get event => {'type': 'key', 'key': key, 'mods': mods};
}

/// "ctrl+shift+t", "Alt+Left", "F5" → key + modifiers; null for what the agent won't accept (unknown key, no
/// modifier,
/// or a letter/digit with Shift only).
KeyCombo? parseCombo(String s) {
  final parts = s.split('+').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty || parts.length > 5 || s.trim().endsWith('+')) return null;
  final mods = <String>{};
  String? key;
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    final last = i == parts.length - 1;
    final m = _modAliases[p.toLowerCase()];
    // "super" alone is a key; with a modifier (super+e) it's a modifier.
    if (m != null && !(last && mods.isEmpty && m == 'super')) {
      if (last) return null;
      mods.add(m);
      continue;
    }
    if (!last) return null;
    if (RegExp(r'^[a-z0-9]$', caseSensitive: false).hasMatch(p)) {
      key = p.toUpperCase();
    } else if (RegExp(r'^f([1-9]|1[0-2])$', caseSensitive: false).hasMatch(p)) {
      key = p.toUpperCase();
    } else {
      key = _keyAliases[p.toLowerCase()];
    }
    if (key == null) return null;
  }
  if (key == null) return null;
  final ordered = [for (final m in _modOrder) if (mods.contains(m)) m];
  if (RegExp(r'^[A-Z0-9]$').hasMatch(key) && !ordered.any((m) => m != 'shift')) return null;
  return KeyCombo(key, ordered);
}

// ---- action → input events ----

/// The action's WS input events (live stream: key/text/scroll). [text]: text typed on the phone for a prompt.
/// null if there's an invalid shortcut/text (a user remote may come from a hand-edited profile).
List<Map<String, Object>>? remoteEvents(RemoteAction a, {String? text}) {
  bool textOk(String t) => t.isNotEmpty && t.length <= 2000 && !RegExp(r'[\u0000-\u0008\u000b-\u001f\u007f-\u009f]').hasMatch(t);
  Map<String, Object>? key(String c) => parseCombo(c)?.event;
  final out = <Map<String, Object>>[];
  switch (a.kind) {
    case RemoteKind.combo:
      final k = key(a.combo ?? '');
      if (k == null) return null;
      out.add(k);
    case RemoteKind.sequence:
      if (a.steps.isEmpty) return null;
      for (final s in a.steps) {
        if (s.combo != null) {
          final k = key(s.combo!);
          if (k == null) return null;
          out.add(k);
        } else {
          if (!textOk(s.text ?? '')) return null;
          out.add({'type': 'text', 'text': s.text!});
        }
      }
    case RemoteKind.prompt:
      if (a.combo != null) {
        final k = key(a.combo!);
        if (k == null) return null;
        out.add(k);
      }
      final t = text ?? '';
      if (t.isNotEmpty) {
        if (!textOk(t)) return null;
        out.add({'type': 'text', 'text': t});
      }
      if (a.submit) out.add(const {'type': 'key', 'key': 'Enter', 'mods': <String>[]});
    case RemoteKind.scroll:
      if (a.dy == 0 || a.dy.abs() > 20) return null;
      out.add({'type': 'scroll', 'dx': 0, 'dy': a.dy});
  }
  return out;
}

/// Short description: the shortcut ("Ctrl+L"), the sequence's shortcuts ("Ctrl+Shift+P → …"); null if nothing to show.
String? remoteHint(RemoteAction a) => switch (a.kind) {
      RemoteKind.combo => parseCombo(a.combo ?? '')?.label,
      RemoteKind.prompt => a.combo == null ? null : '${parseCombo(a.combo!)?.label ?? a.combo} → …',
      RemoteKind.sequence => a.steps.length == 1 && a.steps.single.text != null
          ? a.steps.single.text
          : [for (final s in a.steps) s.combo != null ? (parseCombo(s.combo!)?.label ?? s.combo!) : '…'].join(' → '),
      RemoteKind.scroll => null,
    };

// ---- built-in profiles ----

/// Remote button. For a built-in button [id] is the translation key (see remote_strip.dart `remoteLabel`), for the
/// user's own [label] is its name. [prompt]: hint key shown when asking for text.
class RemoteButton {
  const RemoteButton(this.id, this.icon, this.action, {this.confirm = false, this.label, this.prompt, this.native});
  final String id;
  final IconData icon;
  final RemoteAction action;
  final bool confirm;
  final String? label;
  final String? prompt;

  /// Not a shortcut but an agent endpoint or a phone screen ([action] is unused).
  final RemoteNative? native;
}

/// Buttons that can't/shouldn't be done with a shortcut: close window (Alt+F4 isn't bound by default in Hyprland →
/// the agent's window close endpoint), Firefox tabs page and "Send to phone" (11.2), media card from the player
/// (9.8), mobile view
/// of the focused window (11.4).
enum RemoteNative { closeWindow, tabs, toPhone, media, mobileView }

/// Placeholder action for native buttons (not sent).
const _none = RemoteAction.combo('Esc');

class RemoteProfile {
  const RemoteProfile(this.id, this.name, this.classes, this.buttons);
  final String id;

  /// App name (brand; not translated). null in the generic profile: the window class is shown.
  final String? name;

  /// Lowercase window classes (Hyprland class/initialClass); the last segment of reverse-domain (flatpak) classes also
  /// matches (com.visualstudio.code → code).
  final List<String> classes;
  final List<RemoteButton> buttons;
}

RemoteAction _seq(List<RemoteStep> s) => RemoteAction.sequence(s);

// Common buttons.
const _copy = RemoteButton('copy', LucideIcons.copy, RemoteAction.combo('ctrl+c'));
const _cut = RemoteButton('cut', LucideIcons.scissors, RemoteAction.combo('ctrl+x'));
const _paste = RemoteButton('paste', LucideIcons.clipboardPaste, RemoteAction.combo('ctrl+v'));
const _undo = RemoteButton('undo', LucideIcons.undo2, RemoteAction.combo('ctrl+z'));
const _redo = RemoteButton('redo', LucideIcons.redo2, RemoteAction.combo('ctrl+shift+z'));
const _save = RemoteButton('save', LucideIcons.save, RemoteAction.combo('ctrl+s'));
const _selectAll = RemoteButton('selectAll', LucideIcons.textSelect, RemoteAction.combo('ctrl+a'));

/// Sequence that runs a command from the command palette (a path that needs no punctuation shortcut).
RemoteAction _palette(String command) => _seq([const RemoteStep.combo('ctrl+shift+p'), RemoteStep.text(command), const RemoteStep.combo('Enter')]);

/// Plain letter/digit key (players): typed as text.
RemoteAction _char(String c) => _seq([RemoteStep.text(c)]);

List<RemoteButton> _editor({required RemoteAction terminal, RemoteAction? comment}) => [
      const RemoteButton('palette', LucideIcons.command, RemoteAction.prompt(combo: 'ctrl+shift+p'), prompt: 'command'),
      const RemoteButton('goToFile', LucideIcons.fileSearch, RemoteAction.prompt(combo: 'ctrl+p'), prompt: 'file'),
      _save,
      RemoteButton('terminal', LucideIcons.squareTerminal, terminal),
      const RemoteButton('find', LucideIcons.search, RemoteAction.prompt(combo: 'ctrl+f'), prompt: 'find'),
      const RemoteButton('replace', LucideIcons.replace, RemoteAction.combo('ctrl+h')),
      const RemoteButton('goToLine', LucideIcons.listOrdered, RemoteAction.prompt(combo: 'ctrl+g'), prompt: 'line'),
      _undo,
      _redo,
      if (comment != null) RemoteButton('comment', LucideIcons.messageSquareCode, comment),
      const RemoteButton('sidebar', LucideIcons.panelLeft, RemoteAction.combo('ctrl+b')),
    ];

List<RemoteButton> _files({required String newFolder}) => [
      const RemoteButton('parent', LucideIcons.folderUp, RemoteAction.combo('alt+Up')),
      const RemoteButton('back', LucideIcons.arrowLeft, RemoteAction.combo('alt+Left')),
      const RemoteButton('path', LucideIcons.folderInput, RemoteAction.prompt(combo: 'ctrl+l'), prompt: 'path'),
      const RemoteButton('rename', LucideIcons.pencil, RemoteAction.combo('F2')),
      _copy,
      _cut,
      _paste,
      RemoteButton('newFolder', LucideIcons.folderPlus, RemoteAction.combo(newFolder)),
      const RemoteButton('delete', LucideIcons.trash2, RemoteAction.combo('Delete'), confirm: true),
      const RemoteButton('hidden', LucideIcons.eye, RemoteAction.combo('ctrl+h')),
    ];

List<RemoteButton> _player({required RemoteAction back, required RemoteAction forward, required RemoteAction volDown, required RemoteAction volUp}) => [
      const RemoteButton('mediaCard', LucideIcons.music, _none, native: RemoteNative.media),
      const RemoteButton('playPause', LucideIcons.play, RemoteAction.combo('Space')),
      RemoteButton('seekBack', LucideIcons.rewind, back),
      RemoteButton('seekForward', LucideIcons.fastForward, forward),
      RemoteButton('volumeDown', LucideIcons.volume1, volDown),
      RemoteButton('volumeUp', LucideIcons.volume2, volUp),
      RemoteButton('mute', LucideIcons.volumeX, _char('m')),
      RemoteButton('fullscreen', LucideIcons.maximize, _char('f')),
      RemoteButton('subtitles', LucideIcons.captions, _char('v')),
    ];

/// Unrecognized app.
const genericRemote = RemoteProfile('generic', null, [], [
  _copy,
  _paste,
  _cut,
  _undo,
  _selectAll,
  RemoteButton('esc', LucideIcons.circleX, RemoteAction.combo('Esc')),
  RemoteButton('enter', LucideIcons.cornerDownLeft, RemoteAction.combo('Enter')),
  RemoteButton('switchWindow', LucideIcons.appWindow, RemoteAction.combo('alt+Tab')),
  RemoteButton('closeWindow', LucideIcons.x, _none, confirm: true, native: RemoteNative.closeWindow),
]);

/// Built-in profiles (single table; order is match priority).
final remoteProfiles = <RemoteProfile>[
  const RemoteProfile('firefox', 'Firefox', ['firefox', 'firefox-esr', 'org.mozilla.firefox', 'firefox-developer-edition', 'librewolf'], [
    RemoteButton('address', LucideIcons.globe, RemoteAction.prompt(combo: 'ctrl+l'), prompt: 'address'),
    RemoteButton('tabs', LucideIcons.layers, _none, native: RemoteNative.tabs),
    RemoteButton('toPhone', LucideIcons.smartphone, _none, native: RemoteNative.toPhone),
    RemoteButton('back', LucideIcons.arrowLeft, RemoteAction.combo('alt+Left')),
    RemoteButton('forward', LucideIcons.arrowRight, RemoteAction.combo('alt+Right')),
    RemoteButton('reload', LucideIcons.rotateCw, RemoteAction.combo('F5')),
    RemoteButton('newTab', LucideIcons.plus, RemoteAction.combo('ctrl+t')),
    RemoteButton('closeTab', LucideIcons.x, RemoteAction.combo('ctrl+w'), confirm: true),
    RemoteButton('reopenTab', LucideIcons.history, RemoteAction.combo('ctrl+shift+t')),
    RemoteButton('nextTab', LucideIcons.chevronsRight, RemoteAction.combo('ctrl+PageDown')),
    RemoteButton('prevTab', LucideIcons.chevronsLeft, RemoteAction.combo('ctrl+PageUp')),
    RemoteButton('find', LucideIcons.search, RemoteAction.prompt(combo: 'ctrl+f'), prompt: 'find'),
    RemoteButton('zoomIn', LucideIcons.zoomIn, RemoteAction.combo('ctrl+KPPlus')),
    RemoteButton('zoomOut', LucideIcons.zoomOut, RemoteAction.combo('ctrl+KPMinus')),
    RemoteButton('zoomReset', LucideIcons.scan, RemoteAction.combo('ctrl+0')),
    RemoteButton('fullscreen', LucideIcons.maximize, RemoteAction.combo('F11')),
    RemoteButton('reader', LucideIcons.bookOpen, RemoteAction.combo('ctrl+alt+r')),
    RemoteButton('scrollDown', LucideIcons.arrowDown, RemoteAction.scroll(5)),
    RemoteButton('scrollUp', LucideIcons.arrowUp, RemoteAction.scroll(-5)),
    RemoteButton('top', LucideIcons.arrowUpToLine, RemoteAction.combo('ctrl+Home')),
  ]),
  RemoteProfile('vscode', 'VS Code', const ['code', 'code-oss', 'code-url-handler', 'codium', 'vscodium', 'com.visualstudio.code'],
      _editor(terminal: _palette('View: Toggle Terminal'), comment: _palette('Toggle Line Comment'))),
  RemoteProfile('zed', 'Zed', const ['dev.zed.zed', 'zed', 'dev.zed.zed-preview'],
      _editor(terminal: _palette('terminal panel: toggle'), comment: _palette('editor: toggle comments'))),
  const RemoteProfile('kitty', 'kitty', ['kitty'], [
    RemoteButton('interrupt', LucideIcons.octagonX, RemoteAction.combo('ctrl+c')),
    RemoteButton('eof', LucideIcons.logOut, RemoteAction.combo('ctrl+d')),
    RemoteButton('tab', LucideIcons.arrowRightToLine, RemoteAction.combo('Tab')),
    RemoteButton('history', LucideIcons.arrowUp, RemoteAction.combo('Up')),
    RemoteButton('newTab', LucideIcons.plus, RemoteAction.combo('ctrl+shift+t')),
    RemoteButton('nextTab', LucideIcons.chevronsRight, RemoteAction.combo('ctrl+shift+Right')),
    RemoteButton('prevTab', LucideIcons.chevronsLeft, RemoteAction.combo('ctrl+shift+Left')),
    RemoteButton('copy', LucideIcons.copy, RemoteAction.combo('ctrl+shift+c')),
    RemoteButton('paste', LucideIcons.clipboardPaste, RemoteAction.combo('ctrl+shift+v')),
  ]),
  RemoteProfile('nautilus', 'Nautilus', const ['org.gnome.nautilus', 'nautilus'], _files(newFolder: 'ctrl+shift+n')),
  RemoteProfile('dolphin', 'Dolphin', const ['org.kde.dolphin', 'dolphin'], _files(newFolder: 'F10')),
  RemoteProfile('mpv', 'mpv', const ['mpv', 'io.mpv.mpv'],
      _player(back: RemoteAction.combo('Left'), forward: RemoteAction.combo('Right'), volDown: _char('9'), volUp: _char('0'))),
  RemoteProfile('vlc', 'VLC', const ['vlc', 'org.videolan.vlc'],
      _player(back: RemoteAction.combo('alt+Left'), forward: RemoteAction.combo('alt+Right'), volDown: RemoteAction.combo('ctrl+Down'), volUp: RemoteAction.combo('ctrl+Up'))),
  RemoteProfile('mousepad', 'Mousepad', const ['org.xfce.mousepad', 'mousepad'], [
    _save,
    const RemoteButton('find', LucideIcons.search, RemoteAction.prompt(combo: 'ctrl+f'), prompt: 'find'),
    const RemoteButton('replace', LucideIcons.replace, RemoteAction.combo('ctrl+r')),
    const RemoteButton('goToLine', LucideIcons.listOrdered, RemoteAction.prompt(combo: 'ctrl+l'), prompt: 'line'),
    _undo,
    const RemoteButton('redo', LucideIcons.redo2, RemoteAction.combo('ctrl+y')),
    _selectAll,
    _copy,
    _paste,
  ]),
];

/// Window class → built-in profile: first an exact match (case-insensitive; class, then initialClass), then the
/// last segment of a reverse-domain class; otherwise [genericRemote].
RemoteProfile remoteProfileFor(String cls, [String initialClass = '']) {
  final keys = [for (final c in [cls, initialClass]) c.trim().toLowerCase()].where((c) => c.isNotEmpty).toList();
  for (final k in keys) {
    for (final p in remoteProfiles) {
      if (p.classes.contains(k)) return p;
    }
  }
  for (final k in keys) {
    final last = k.split('.').last;
    if (last == k || last.isEmpty) continue;
    for (final p in remoteProfiles) {
      if (p.classes.contains(last)) return p;
    }
  }
  return genericRemote;
}

/// User remotes matching this window: if the class is the same or both fall into the same built-in profile (e.g. a
/// button added for "firefox" also shows in firefox-esr).
List<DesktopRemote> remotesFor(List<DesktopRemote> all, String cls, [String initialClass = '']) {
  final here = {for (final c in [cls, initialClass]) c.trim().toLowerCase()}..remove('');
  if (here.isEmpty) return const [];
  final profile = remoteProfileFor(cls, initialClass);
  return [
    for (final r in all)
      if (here.contains(r.windowClass.trim().toLowerCase()) || (profile != genericRemote && remoteProfileFor(r.windowClass) == profile)) r,
  ];
}

/// Icon of a user remote (fixed set in the schema).
IconData remoteIcon(String id) => switch (id) {
      'star' => LucideIcons.star,
      'play' => LucideIcons.play,
      'search' => LucideIcons.search,
      'save' => LucideIcons.save,
      'copy' => LucideIcons.copy,
      'refresh' => LucideIcons.refreshCw,
      'close' => LucideIcons.x,
      'plus' => LucideIcons.plus,
      'folder' => LucideIcons.folder,
      'terminal' => LucideIcons.terminal,
      'globe' => LucideIcons.globe,
      _ => LucideIcons.zap,
    };

/// User remote → button (invalid action null: not shown).
RemoteButton? userButton(DesktopRemote r) => remoteEvents(r.action, text: r.action.kind == RemoteKind.prompt ? 'x' : null) == null
    ? null
    : RemoteButton('user:${r.id}', remoteIcon(r.icon), r.action, confirm: r.confirm, label: r.name);
