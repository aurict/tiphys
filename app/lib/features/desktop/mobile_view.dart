// Mobile view (11.4), app-side data: the agent's AT-SPI snapshot (flat node list, tree via `parent`), grouping
// into sections to draw on the phone (tool/menu bars, open menus, tabs, web content, plain
// groups), search by name and the live view controller: `GET /v1/desktop/ui?address=` → sections; SSE
// `GET /v1/desktop/ui/events` "changed" → coalesced re-read; re-read after an action; stale generation
// (agent.ui.stale) → silently refresh + retry once with the same node. The stream is closed in the background; on
// exit `DELETE /v1/desktop/ui` (the agent closes the helper). Every endpoint needs a control session token (except
// DELETE).
// PRIVACY: the tree is kept only in memory; a password field's text never comes from the agent.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/agent/agent_client.dart';
import 'browser.dart' show browserBackoff, foldText;
import 'desktop_data.dart' show controlHeader;

class UiValue {
  const UiValue({required this.now, required this.min, required this.max, required this.step});
  final double now;
  final double min;
  final double max;
  final double step;
}

class UiNode {
  UiNode(Map j, {this.gen = 0, this.address = ''})
      : id = '${j['id']}',
        parent = j['parent'] as String?,
        depth = (j['depth'] as num?)?.toInt() ?? 0,
        role = '${j['role'] ?? ''}',
        name = '${j['name'] ?? ''}'.trim(),
        desc = '${j['desc'] ?? ''}'.trim(),
        states = {for (final s in (j['states'] as List? ?? const [])) '$s'},
        value = _value(j['value']),
        text = j['text'] as String?,
        password = j['password'] == true || j['role'] == 'password text',
        actions = [for (final a in (j['actions'] as List? ?? const [])) '$a'];
  final String id;

  /// Generation and window of the snapshot the node came from: actions are sent with this generation (not the
  /// generation of a later refreshed tree; otherwise a different node on a shifted path could be pressed).
  final int gen;
  final String address;
  final String? parent;
  final int depth;
  final String role;
  final String name;
  final String desc;
  final Set<String> states;
  final UiValue? value;

  /// Text of an editable field (≤ 200); always null for a password field.
  final String? text;
  final bool password;
  final List<String> actions;

  bool get enabled => states.contains('enabled');
  bool get checked => states.contains('checked');
  bool get selected => states.contains('selected');
  bool get expanded => states.contains('expanded');
  bool get focused => states.contains('focused');

  /// Display name: name, otherwise description (may be empty; the renderer puts fallback text).
  String get label => name.isNotEmpty ? name : desc;

  bool get isText => textRoles.contains(role);

  /// Rows selected on tap (Selection.select_child if they have no action).
  bool get selectable => const {'list item', 'tree item', 'table cell', 'page tab'}.contains(role);
}

UiValue? _value(Object? v) {
  if (v is! Map) return null;
  double d(String k) => (v[k] as num?)?.toDouble() ?? 0;
  return UiValue(now: d('now'), min: d('min'), max: d('max'), step: d('step'));
}

const textRoles = {'entry', 'text', 'password text'};

/// Roles drawn as chips in a bar (pressable widgets).
const _chipRoles = {
  'button', 'push button', 'push button menu', 'toggle button', 'check box', 'radio button', 'switch', 'menu', 'menu item',
  'check menu item', 'radio menu item', 'link', 'combo box', 'page tab',
};

class UiSnapshot {
  /// [address]: requested window (if not given, the one in the agent's response).
  UiSnapshot(Map j, {String? address}) : this._(j, address ?? '${j['address'] ?? ''}', (j['gen'] as num?)?.toInt() ?? 0);

  UiSnapshot._(Map j, this.address, this.gen)
      : cls = '${j['class'] ?? ''}',
        title = '${j['title'] ?? ''}',
        partial = j['partial'] == true,
        nodes = [for (final n in (j['nodes'] as List? ?? const []).whereType<Map>()) if (n['id'] is String) UiNode(n, gen: gen, address: address)];
  final String address;
  final String cls;
  final int gen;
  final String title;
  final bool partial;
  final List<UiNode> nodes;

  UiNode? byId(String id) => nodes.where((n) => n.id == id).firstOrNull;

  /// Text field of a combo box (like an address bar; the combo box draws the field).
  UiNode? entryOf(UiNode combo) => nodes.where((c) => c.parent == combo.id && c.isText).firstOrNull;
}

enum UiSectionKind {
  /// Tool/menu bar: horizontal chips ([UiSection.chips]) + fields that don't fit in a chip ([UiSection.items]).
  bar,

  /// Open menu (children visible): heading [UiSection.node], items indented.
  menu,

  /// Multiple tabs: segmented control ([UiSection.chips]).
  tabs,

  /// Web page content (document web): headings, links, buttons, fields.
  document,

  /// Plain group: controls and context labels under a heading.
  group,
}

class UiSection {
  UiSection(this.kind, {this.title = '', this.node, List<UiNode>? chips, List<UiNode>? items})
      : chips = chips ?? [],
        items = items ?? [];
  final UiSectionKind kind;
  final String title;
  final UiNode? node;
  final List<UiNode> chips;
  final List<UiNode> items;
}

/// Snapshot → sections to draw on the phone (document order). If [query] is given only items whose name matches remain
/// (insensitive to Turkish letters), emptied sections are dropped; if an open menu's heading matches, all of it stays.
List<UiSection> uiSections(UiSnapshot s, {String query = ''}) {
  final kids = <String?, List<UiNode>>{};
  final byId = {for (final n in s.nodes) n.id: n};
  for (final n in s.nodes) {
    (kids[n.parent] ??= []).add(n);
  }
  List<UiNode> childrenOf(String? id) => kids[id] ?? const [];
  UiNode? entryOf(UiNode combo) => childrenOf(combo.id).where((c) => c.isText).firstOrNull;
  // A label repeating the field's own name (form label) is skipped: the field already shows its name.
  final fieldNames = {for (final n in s.nodes) if (n.isText && n.name.isNotEmpty) (n.parent, n.name)};
  bool hidden(UiNode n) {
    final p = byId[n.parent];
    return (p != null && p.role == 'combo box' && n.isText) || (n.role == 'label' && fieldNames.contains((n.parent, n.name)));
  }

  /// Subtree as a flat list (excluding the text field of a combo box that draws the field).
  List<UiNode> flat(String id) => [
        for (final c in childrenOf(id))
          if (!hidden(c)) ...[c, ...flat(c.id)],
      ];

  final out = <UiSection>[];
  UiSection? group;
  void flush() {
    if (group != null && group!.items.isNotEmpty) out.add(group!);
    group = null;
  }

  void add(UiNode n) => (group ??= UiSection(UiSectionKind.group)).items.add(n);
  void menu(UiNode m) => out.add(UiSection(UiSectionKind.menu, title: m.label, node: m, items: flat(m.id)));

  void visit(String? id) {
    final list = childrenOf(id);
    for (var i = 0; i < list.length; i++) {
      final n = list[i];
      if (hidden(n)) continue;
      switch (n.role) {
        case 'tool bar' || 'menu bar':
          flush();
          final bar = UiSection(UiSectionKind.bar, title: n.label, node: n);
          final menus = <UiNode>[];
          void walk(String pid) {
            for (final c in childrenOf(pid)) {
              if (hidden(c)) continue;
              if (c.role == 'menu') {
                bar.chips.add(c);
                if (childrenOf(c.id).isNotEmpty) menus.add(c);
                continue;
              }
              if (c.role == 'combo box' && entryOf(c) != null) {
                bar.items.add(c);
                continue;
              }
              if (_chipRoles.contains(c.role)) {
                bar.chips.add(c);
              } else if (c.role != 'label' && c.role != 'heading' && c.role != 'tool bar' && c.role != 'menu bar') {
                bar.items.add(c);
              }
              walk(c.id);
            }
          }

          walk(n.id);
          if (bar.chips.isNotEmpty || bar.items.isNotEmpty) out.add(bar);
          menus.forEach(menu);
        case 'menu':
          if (childrenOf(n.id).isEmpty) {
            add(n);
          } else {
            flush();
            menu(n);
          }
        case 'page tab':
          final tabs = [n];
          while (i + 1 < list.length && list[i + 1].role == 'page tab') {
            tabs.add(list[++i]);
          }
          flush();
          if (tabs.length > 1) out.add(UiSection(UiSectionKind.tabs, chips: tabs));
          for (final t in tabs) {
            visit(t.id);
          }
        case 'document web':
          flush();
          final items = flat(n.id).where((c) => c.role != 'document web').toList();
          if (items.isNotEmpty) out.add(UiSection(UiSectionKind.document, title: n.label, node: n, items: items));
        case 'heading':
          flush();
          group = UiSection(UiSectionKind.group, title: n.label);
        default:
          add(n);
          visit(n.id);
      }
    }
  }

  visit(null);
  flush();
  final q = foldText(query.trim());
  if (q.isEmpty) return out;
  bool m(UiNode n) => n.role != 'label' && foldText(n.label).contains(q);
  final found = <UiSection>[];
  for (final sec in out) {
    if (sec.kind == UiSectionKind.menu && m(sec.node!)) {
      found.add(sec);
      continue;
    }
    final f = UiSection(sec.kind, title: sec.title, node: sec.node, chips: sec.chips.where(m).toList(), items: sec.items.where(m).toList());
    if (f.chips.isNotEmpty || f.items.isNotEmpty) found.add(f);
  }
  return found;
}

// ---- live view ----

class UiViewController extends ChangeNotifier {
  UiViewController({required this.client, required this.token, required this.address, this.backoff = browserBackoff, this.debounce = const Duration(milliseconds: 250), this.followDelay = const Duration(milliseconds: 300)});

  /// Agent client (a new one per call; closing it is the controller's job).
  final Future<AgentClient> Function() client;

  /// Control session token (opened after asking for the lock if needed); null if cancelled.
  final Future<String?> Function() token;
  final Duration Function(int attempt) backoff;

  /// Coalescing window for SSE "changed" events.
  final Duration debounce;

  /// How long the window must stay unchanged while following focus ([follow]).
  final Duration followDelay;

  /// Shown window (updated when focus changes if opened from the live screen).
  String address;

  UiSnapshot? snap;

  /// Error to show (AgentError); null = none.
  Object? error;

  /// The user cancelled opening a session.
  bool cancelled = false;

  String? _token;
  AgentClient? _sse;
  StreamSubscription<(String, String)>? _sub;
  Timer? _retry;
  Timer? _debounce;
  Timer? _follow;
  Future<void>? _inflight;
  bool _again = false;
  int _attempt = 0;
  bool _paused = false;
  bool _disposed = false;

  bool get loading => snap == null && error == null && !cancelled;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<dynamic> _call(String method, String path, [Object? body]) async {
    final c = await client();
    try {
      return await c.request(method, path, body: body, headers: {controlHeader: ?_token});
    } finally {
      c.close();
    }
  }

  /// Opens the session, reads the tree, subscribes to events. "Try again" calls this too.
  Future<void> start() async {
    _stopStream();
    error = null;
    cancelled = false;
    _notify();
    _token = await token();
    if (_disposed) return;
    if (_token == null) {
      cancelled = true;
      return _notify();
    }
    await refresh();
    if (error == null) _connect();
  }

  /// Re-reads the tree; requests arriving during a read are coalesced into a single extra read.
  Future<void> refresh() {
    if (_inflight case final f?) {
      _again = true;
      return f;
    }
    final f = _inflight = () async {
      do {
        _again = false;
        try {
          final a = address;
          final r = await _call('GET', '/v1/desktop/ui?address=$a') as Map;
          // If the window changed during the read, the old window's tree isn't shown.
          if (a != address) continue;
          snap = UiSnapshot(r, address: a);
          error = null;
        } catch (e) {
          error = e;
        }
        _notify();
      } while (_again && !_disposed);
    }();
    return f.whenComplete(() => _inflight = null);
  }

  /// Widget action ([kind]: act | text | value). Sent with the node's own generation and window. Stale generation →
  /// silently refreshed; if the same role + name sits at the same path in the new tree, retried once with the new
  /// generation, otherwise agent.ui.stale ("view changed, try again") is thrown. Not tried at all if the window (focus)
  /// changed meanwhile.
  /// On success the tree is re-read. Errors are thrown (AgentError).
  Future<dynamic> send(UiNode n, String kind, Map<String, Object?> body) async {
    const stale = AgentError('agent.ui.stale', {}, 409);
    final addr = n.address;
    // Window changed: setAddress is already reading the new tree.
    if (addr != address) throw stale;
    Future<dynamic> once(int gen) => _call('POST', '/v1/desktop/ui/$kind', {'address': addr, 'gen': gen, 'id': n.id, ...body});
    dynamic r;
    try {
      r = await once(n.gen);
    } on AgentError catch (e) {
      if (e.code != 'agent.ui.stale') rethrow;
      await refresh();
      final again = snap?.byId(n.id);
      if (address != addr || again == null || again.address != addr || again.role != n.role || again.name != n.name) throw stale;
      r = await once(again.gen);
    }
    await refresh();
    return r;
  }

  /// Live screen focus: if it stays on the same window for [followDelay], the view switches to it (the tree isn't read
  /// for every window quickly passed with Alt+Tab; if focus comes back, the pending switch is cancelled).
  void follow(String a) {
    _follow?.cancel();
    _follow = a == address
        ? null
        : Timer(followDelay, () {
            _follow = null;
            setAddress(a);
          });
  }

  /// Changes the shown window immediately.
  void setAddress(String a) {
    if (a == address) return;
    address = a;
    snap = null;
    error = null;
    _stopStream();
    _notify();
    if (_token == null || _paused) return;
    unawaited(refresh().then((_) {
      if (error == null) _connect();
    }));
  }

  void _connect() {
    if (_disposed || _paused || _token == null || _sub != null) return;
    _retry?.cancel();
    _retry = null;
    final t = _token!;
    client().then((c) {
      if (_disposed || _paused || _sub != null) {
        c.close();
        return;
      }
      _sse = c;
      _sub = c.sse('/v1/desktop/ui/events?address=$address', headers: {controlHeader: t}).listen(_onEvent, onError: _onDrop, onDone: () => _onDrop(null));
    }, onError: _onDrop);
  }

  void _onEvent((String, String) e) {
    if (e.$1 != 'changed') return;
    _attempt = 0;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(refresh()));
  }

  void _onDrop(Object? e) {
    _stopStream();
    if (_disposed || _paused) return;
    if (e is AgentError && e.code == 'agent.control.sessionRequired') {
      error = e;
      return _notify();
    }
    // The agent closed the view ("closed") or the connection dropped: the tree is re-read for changes missed meanwhile.
    _retry = Timer(backoff(_attempt++), () async {
      _retry = null;
      await refresh();
      if (error == null) _connect();
    });
  }

  void _stopStream() {
    _retry?.cancel();
    _retry = null;
    _debounce?.cancel();
    _debounce = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _sse?.close();
    _sse = null;
  }

  /// The app went to the background: the stream closes.
  void pause() {
    _paused = true;
    _stopStream();
  }

  /// Came to the foreground: the tree is re-read, the stream reopens.
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_token == null) return;
    _attempt = 0;
    unawaited(refresh().then((_) {
      if (error == null) _connect();
    }));
  }

  /// Left the screen: the stream closes, the agent is told to close the view (needs no token; errors don't matter).
  @override
  void dispose() {
    _disposed = true;
    _follow?.cancel();
    _stopStream();
    unawaited(() async {
      try {
        await _call('DELETE', '/v1/desktop/ui');
      } catch (_) {}
    }());
    super.dispose();
  }
}
