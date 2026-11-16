// Firefox bridge (11.2, 11.3), app-side data: bridge status, tabs (grouping by window, search, the focused
// window's active tab), splitting reader text into blocks and the live tab list controller
// (SSE `GET /v1/desktop/browser/events`: `status` + `tabs`; reconnects with a 1→30 s growing interval on disconnect,
// stops while the app is in the background). The status endpoint needs no token; the tab list and every action need a
// control session.
// PRIVACY: URLs/titles are kept only in memory; never written to disk or logs.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/forms.dart';
import '../system/agent_providers.dart';
import 'desktop_data.dart';

class BrowserStatus {
  const BrowserStatus({required this.connected, this.version, this.ext, this.content = false});
  BrowserStatus.fromJson(Map j)
      : connected = j['connected'] == true,
        version = (j['version'] as num?)?.toInt(),
        ext = j['ext'] as String?,
        content = (j['permissions'] as Map?)?['content'] == true;
  final bool connected;
  final int? version;
  final String? ext;

  /// Whether page content (11.3) permission is granted.
  final bool content;
}

class BrowserTab {
  BrowserTab(Map j)
      : id = (j['id'] as num).toInt(),
        windowId = (j['windowId'] as num?)?.toInt() ?? 0,
        index = (j['index'] as num?)?.toInt() ?? 0,
        title = '${j['title'] ?? ''}',
        url = j['url'] as String?,
        pinned = j['pinned'] == true,
        audible = j['audible'] == true,
        muted = j['muted'] == true,
        active = j['active'] == true,
        lastAccessed = (j['lastAccessed'] as num?)?.toInt(),
        favicon = _decodeFavicon(j['favicon']);
  final int id;
  final int windowId;
  final int index;
  final String title;

  /// Only http/https/file/about; others (extension pages etc.) null.
  final String? url;
  final bool pinned;
  final bool audible;
  final bool muted;
  final bool active;
  final int? lastAccessed;

  /// Bytes of a `data:` favicon (the extension downscales it to a ≤ 32 px PNG); otherwise null → the domain's initial.
  final Uint8List? favicon;

  Uri? get _uri => url == null ? null : Uri.tryParse(url!);

  /// Domain without "www."; empty if none.
  String get domain => (_uri?.host ?? '').replaceFirst(RegExp(r'^www\.'), '');

  /// Can it be opened on the phone (http/https only).
  bool get webUrl => _uri != null && (_uri!.isScheme('http') || _uri!.isScheme('https')) && _uri!.host.isNotEmpty;

  /// Title; if empty, the URL or domain.
  String get label => title.trim().isNotEmpty ? title : (url ?? domain);

  /// The avatar's letter: the domain's first letter, otherwise the title's.
  String get letter {
    final s = domain.isNotEmpty ? domain : label.trim();
    return s.isEmpty ? '?' : s.characters.first.toUpperCase();
  }

  bool matches(String q) {
    final n = foldText(q.trim());
    if (n.isEmpty) return true;
    return foldText(title).contains(n) || foldText(url ?? '').contains(n);
  }
}

Uint8List? _decodeFavicon(Object? v) {
  if (v is! String || !v.startsWith('data:')) return null;
  final comma = v.indexOf(',');
  if (comma < 0 || !v.substring(0, comma).endsWith(';base64')) return null;
  try {
    final b = base64Decode(v.substring(comma + 1));
    return isRasterImage(b) ? b : null;
  } catch (_) {
    return null;
  }
}

/// For case-insensitive comparison that's also insensitive to Turkish i/ı.
String foldText(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase().replaceAll('ı', 'i');

List<BrowserTab> parseTabs(Object? list) => [for (final t in (list as List? ?? const []).whereType<Map>()) if (t['id'] is num) BrowserTab(t)];

/// Groups by window (window order by id, tab order by position); if [query] is given it's filtered and windows left
/// empty are dropped.
List<(int, List<BrowserTab>)> groupTabs(List<BrowserTab> tabs, [String query = '']) {
  final by = <int, List<BrowserTab>>{};
  for (final t in tabs) {
    if (t.matches(query)) (by[t.windowId] ??= []).add(t);
  }
  final ids = by.keys.toList()..sort();
  return [for (final id in ids) (id, by[id]!..sort((a, b) => a.index.compareTo(b.index)))];
}

/// Active tab of the focused Firefox window: the active tab whose title the window title ("Tab — Mozilla Firefox")
/// starts with; if not found, the most recently accessed active tab.
BrowserTab? activeTabFor(List<BrowserTab> tabs, String windowTitle) {
  final active = tabs.where((t) => t.active).toList();
  if (active.isEmpty) return null;
  final byTitle = active.where((t) => t.title.isNotEmpty && windowTitle.startsWith(t.title)).toList();
  final pool = byTitle.isNotEmpty ? byTitle : active;
  pool.sort((a, b) => (b.lastAccessed ?? 0).compareTo(a.lastAccessed ?? 0));
  return pool.first;
}

// ---- reader text ----

enum ReaderKind { heading, bullet, numbered, paragraph }

class ReaderBlock {
  const ReaderBlock(this.kind, this.text, {this.level = 0, this.marker = ''});
  final ReaderKind kind;
  final String text;

  /// Heading level (1–6).
  final int level;

  /// The "3." marker of a numbered item.
  final String marker;
}

/// The extension's plain text (headings "# ", list items "• " / "1. ", blocks separated by blank lines) → blocks.
/// Single
/// line breaks within a paragraph are kept.
List<ReaderBlock> readerBlocks(String text) {
  final out = <ReaderBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(ReaderBlock(ReaderKind.paragraph, para.join('\n')));
    para.clear();
  }

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    final h = RegExp(r'^(#{1,6}) (.+)$').firstMatch(line);
    final n = RegExp(r'^(\d{1,4}\.) (.+)$').firstMatch(line);
    if (h != null) {
      flush();
      out.add(ReaderBlock(ReaderKind.heading, h.group(2)!.trim(), level: h.group(1)!.length));
    } else if (line.startsWith('• ')) {
      flush();
      out.add(ReaderBlock(ReaderKind.bullet, line.substring(2).trim()));
    } else if (n != null) {
      flush();
      out.add(ReaderBlock(ReaderKind.numbered, n.group(2)!.trim(), marker: n.group(1)!));
    } else {
      para.add(line);
    }
  }
  flush();
  return out;
}

/// "Have Claude summarize" message: request + title/URL + text (stays under the agent's 200 000 character limit).
String browserSummaryPrompt(AppLocalizations l, {required String title, String? url, required String text}) {
  const max = 150000;
  final body = text.length > max ? '${text.substring(0, max)}\n…' : text;
  return [l.browserSummaryIntro, '', '# $title', ?url, '', body].join('\n');
}

// ---- calls ----

/// Opener on the phone (url_launcher; http/https only). Overridden in tests.
final phoneOpenerProvider = Provider<Future<bool> Function(String url)>((ref) => openExternal);

/// Status for the "Browser" row in the desktop panel; on an old agent (no endpoint) an error → the row is hidden.
final browserStatusProvider = FutureProvider.autoDispose.family<BrowserStatus, String>((ref, hostId) async =>
    BrowserStatus.fromJson(await withAgent(ref, hostId, (c) => c.get('/v1/desktop/browser'))));

/// Bridge status (needs no token).
Future<BrowserStatus> fetchBrowserStatus(WidgetRef ref, String hostId) async =>
    BrowserStatus.fromJson(await agentCall(ref, hostId, 'GET', '/v1/desktop/browser') as Map);

/// Bridge call with a control session: opens a session if needed (lock asked). Returns null if cancelled; agent
/// errors
/// are thrown (if the session ended on the agent, it's forgotten locally too).
Future<dynamic> browserRequest(BuildContext context, WidgetRef ref, String hostId, String method, String path, [Object? body]) async {
  final ctrl = ref.read(controlProvider.notifier);
  final s = await ctrl.ensure(context, hostId);
  if (s == null) return null;
  try {
    return await agentCall(ref, hostId, method, path, method == 'GET' ? null : (body ?? const {}), {controlHeader: s.token}) ?? const {};
  } on AgentError catch (e) {
    if (e.code == 'agent.control.sessionRequired') ctrl.forget();
    rethrow;
  }
}

/// Same, with errors shown in a short notification; the result on success, otherwise null.
Future<dynamic> browserAction(BuildContext context, WidgetRef ref, String hostId, String path, {Object? body, String? done}) async {
  final l = AppLocalizations.of(context);
  try {
    final r = await browserRequest(context, ref, hostId, 'POST', path, body);
    if (r != null && done != null && context.mounted) toast(context, done);
    return r;
  } catch (e) {
    if (context.mounted) toast(context, agentErrorText(l, e));
    return null;
  }
}

/// Opens the URL on the phone ("Send to phone"); http/https only.
Future<void> openTabOnPhone(BuildContext context, WidgetRef ref, BrowserTab tab) async {
  final l = AppLocalizations.of(context);
  if (!tab.webUrl || !await ref.read(phoneOpenerProvider)(tab.url!)) {
    if (context.mounted) toast(context, l.browserNotWebUrl);
  }
}

// ---- live tab list ----

/// Reconnect delay: 1, 2, 4 … 30 s.
Duration browserBackoff(int attempt) => Duration(seconds: attempt >= 5 ? 30 : 1 << attempt);

class BrowserTabsController extends ChangeNotifier {
  BrowserTabsController({required this.client, required this.token, this.backoff = browserBackoff, this.poll = const Duration(seconds: 10)});

  /// Agent client (a new one per connection; closing it is the controller's job).
  final Future<AgentClient> Function() client;

  /// Control session token (opened after asking for the lock if needed); null if cancelled.
  final Future<String?> Function() token;
  final Duration Function(int attempt) backoff;

  /// Status re-read interval while the bridge isn't connected (the stream only opens when connected; no news arrives
  /// on connect).
  final Duration poll;

  BrowserStatus? status;
  List<BrowserTab>? tabs;

  /// Error to show (AgentError); null = none.
  Object? error;

  /// The user cancelled opening a session.
  bool cancelled = false;

  AgentClient? _sse;
  StreamSubscription<(String, String)>? _sub;
  Timer? _retry;
  Timer? _poll;
  int _attempt = 0;
  bool _paused = false;
  bool _disposed = false;
  String? _token;

  bool get loading => status == null && error == null && !cancelled;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _once<T>(Future<T> Function(AgentClient c) body) async {
    final c = await client();
    try {
      return await body(c);
    } finally {
      c.close();
    }
  }

  /// Reads the status; if connected, opens a session and subscribes to the stream. "Try again" calls this too.
  Future<void> start() async {
    _stopStream();
    error = null;
    cancelled = false;
    _notify();
    try {
      status = BrowserStatus.fromJson(await _once((c) => c.get('/v1/desktop/browser')));
      if (status!.connected) {
        _token = await token();
        if (_token == null) {
          cancelled = true;
        } else {
          await _loadTabs();
          _connect();
        }
      }
    } catch (e) {
      error = e;
    }
    _notify();
    _schedulePoll();
  }

  /// Not connected (setup card): status is read every [poll] while the screen is in front; on connect [start]
  /// (session + stream).
  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (_disposed || _paused || cancelled || error != null || status == null || status!.connected) return;
    _poll = Timer(poll, () async {
      _poll = null;
      BrowserStatus? s;
      try {
        s = BrowserStatus.fromJson(await _once((c) => c.get('/v1/desktop/browser')));
      } catch (_) {
        // Transient network error: the setup card stays, checked again on the next round.
      }
      if (_disposed || _paused) return;
      if (s?.connected == true) return start();
      _schedulePoll();
    });
  }

  Future<void> _loadTabs() async {
    final t = _token;
    if (t == null) return;
    final j = await _once((c) => c.request('GET', '/v1/desktop/browser/tabs', headers: {controlHeader: t}));
    tabs = parseTabs((j as Map?)?['tabs']);
    _notify();
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
      _sub = c.sse('/v1/desktop/browser/events', headers: {controlHeader: t}).listen(_onEvent, onError: _onDrop, onDone: () => _onDrop(null));
    }, onError: _onDrop);
  }

  void _onEvent((String, String) e) {
    final (name, data) = e;
    Object? j;
    try {
      j = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (j is! Map) return;
    _attempt = 0;
    error = null;
    if (name == 'status') {
      final was = status?.connected ?? false;
      status = BrowserStatus.fromJson(j);
      if (!status!.connected) {
        tabs = null;
      } else if (!was || tabs == null) {
        unawaited(_loadTabs().catchError((Object e) {
          error = e;
          _notify();
        }));
      }
    } else if (name == 'tabs') {
      tabs = parseTabs(j['tabs']);
    }
    _notify();
  }

  void _onDrop(Object? e) {
    _stopStream();
    if (_disposed || _paused) return;
    if (e is AgentError && e.code == 'agent.control.sessionRequired') {
      // Session ended (timeout, "Stop"): no reconnect; the user reopens it with "Try again".
      error = e;
      _notify();
      return;
    }
    _retry = Timer(backoff(_attempt++), () async {
      _retry = null;
      // Events missed in between: the list is re-read.
      try {
        await _loadTabs();
      } catch (e) {
        if (e is AgentError && e.code == 'agent.control.sessionRequired') {
          error = e;
          _notify();
          return;
        }
      }
      _connect();
    });
  }

  void _stopStream() {
    _retry?.cancel();
    _retry = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _sse?.close();
    _sse = null;
  }

  /// The app went to the background: the stream closes.
  void pause() {
    _paused = true;
    _poll?.cancel();
    _poll = null;
    _stopStream();
  }

  /// Came to the foreground: the list is re-read, the stream reopens.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _schedulePoll();
    if (_token == null || error != null) return;
    _attempt = 0;
    unawaited(_loadTabs().catchError((Object e) {
      error = e;
      _notify();
    }));
    _connect();
  }

  /// So a swiped-away tab leaves the list before the event arrives (Dismissible).
  void removeLocal(Iterable<int> ids) {
    final s = ids.toSet();
    tabs = tabs?.where((t) => !s.contains(t.id)).toList();
    _notify();
  }

  /// Action failed: the list is re-read from the agent.
  Future<void> reload() => _loadTabs().catchError((Object _) {});

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _stopStream();
    super.dispose();
  }
}
