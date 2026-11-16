// Terminal sessions: each tab is an SSH connection + a shell in tmux. Lives as long as the app stays open;
// if the connection drops the tmux session keeps running on the server, and "reconnect" resumes where it left off.
import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../core/util/refresh.dart';
import '../../state/providers.dart';

enum TermStatus { connecting, connected, disconnected, failed }

class TermSession extends ChangeNotifier {
  TermSession({required this.id, required this.host, this.startDir}) : terminal = Terminal(maxLines: 10000);
  final String id;
  final Host host;
  final String? startDir;
  final Terminal terminal;

  /// The view's selection (e.g. "Save to Obsidian" takes the selected text).
  final TerminalController view = TerminalController();

  TermStatus status = TermStatus.connecting;
  SshFailure? failure;
  SshConnection? _conn;
  SSHSession? _shell;
  StreamSubscription<String>? _out;

  /// Number of each connection: a late close of an old connection must not show the new one as "disconnected".
  int _gen = 0;
  Timer? _watchdog;

  /// Sticky Ctrl/Alt on the extra key bar.
  bool ctrl = false;
  bool alt = false;

  void _set(TermStatus s, [SshFailure? f]) {
    status = s;
    failure = f;
    notifyListeners();
  }

  Future<void> connect(Future<SshConnection> Function(Host) open) async {
    final gen = ++_gen;
    _set(TermStatus.connecting);
    void lost() {
      if (gen == _gen && status == TermStatus.connected) _set(TermStatus.disconnected);
    }

    try {
      final conn = await open(host);
      if (gen != _gen) {
        conn.close(); // meanwhile another connection started or the tab was closed
        return;
      }
      _conn = conn;
      final shell = await conn.shell(
        cols: terminal.viewWidth,
        rows: terminal.viewHeight,
        startDir: startDir,
      );
      _shell = shell;
      _out = shell.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
      shell.stderr.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
      terminal.onOutput = (data) => _send(_applyModifiers(data));
      terminal.onResize = (w, h, pw, ph) => _shell?.resizeTerminal(w, h, pw, ph);
      _set(TermStatus.connected);
      unawaited(shell.done.then((_) => lost(), onError: (_) => lost()));
      unawaited(conn.client.done.then((_) => lost(), onError: (_) => lost()));
      // dartssh2's keepalive waits forever if no reply comes; we detect dead connections ourselves.
      _watchdog?.cancel();
      _watchdog = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (gen == _gen && status == TermStatus.connected && !await isAlive()) lost();
      });
    } on SshFailure catch (f) {
      if (gen == _gen) _set(TermStatus.failed, f);
    } catch (e) {
      if (gen == _gen) _set(TermStatus.failed, SshFailure('other', e.toString()));
    }
  }

  /// Whether the connection really responds (TCP can silently die on mobile network changes / in Doze).
  Future<bool> isAlive() async {
    final c = _conn;
    if (c == null || c.client.isClosed) return false;
    try {
      await c.client.ping().timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _applyModifiers(String data) {
    var out = data;
    if (ctrl && out.length == 1) {
      final c = out.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) out = String.fromCharCode(c & 0x1f);
      if (out == ' ') out = '\x00';
    }
    if (alt) out = '\x1b$out';
    if (ctrl || alt) {
      ctrl = false;
      alt = false;
      notifyListeners();
    }
    return out;
  }

  void _send(String data) => _shell?.write(Uint8List.fromList(utf8.encode(data)));

  /// Special keys from the extra key bar.
  void sendKey(String key) {
    switch (key) {
      case 'ctrl':
        ctrl = !ctrl;
        notifyListeners();
      case 'alt':
        alt = !alt;
        notifyListeners();
      default:
        final seq = keySequence(key);
        _send(alt ? '\x1b$seq' : seq);
        if (alt || ctrl) {
          alt = false;
          ctrl = false;
          notifyListeners();
        }
    }
  }

  /// Command snippet: types the text and presses Enter.
  void runCommand(String command) => _send('$command\r');

  void dispose_() {
    _gen++;
    _watchdog?.cancel();
    _out?.cancel();
    _shell?.close();
    _conn?.close();
  }

  @override
  void dispose() {
    dispose_();
    view.dispose();
    super.dispose();
  }
}

String keySequence(String key) => switch (key) {
      'esc' => '\x1b',
      'tab' => '\t',
      'up' => '\x1b[A',
      'down' => '\x1b[B',
      'right' => '\x1b[C',
      'left' => '\x1b[D',
      'home' => '\x1b[H',
      'end' => '\x1b[F',
      'pgup' => '\x1b[5~',
      'pgdn' => '\x1b[6~',
      'enter' => '\r',
      _ => key,
    };

/// SSH connection opener (replaced in tests).
final sshOpenerProvider = Provider<Future<SshConnection> Function(Host)>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  final known = SecretKnownHosts(secrets);
  return (host) => SshConnection.open(host, secrets, knownHosts: known);
});

class TerminalSessions extends Notifier<List<TermSession>> {
  int _seq = 0;
  final _all = <TermSession>[];

  @override
  List<TermSession> build() {
    appVisible.addListener(_onVisible);
    ref.onDispose(() {
      appVisible.removeListener(_onVisible);
      for (final s in _all) {
        s.dispose();
      }
      _all.clear();
    });
    return [];
  }

  TermSession open(Host host, {String? startDir}) {
    final s = TermSession(id: '${host.id}-${++_seq}', host: host, startDir: startDir);
    _all.add(s);
    state = [...state, s];
    // On disconnect (if in foreground) reconnect automatically once after 2 s; if that fails it stays "failed"
    // and is left to the user (no endless retry loop).
    var last = s.status;
    s.addListener(() {
      if (s.status == TermStatus.disconnected && last == TermStatus.connected && appVisible.value) {
        Timer(const Duration(seconds: 2), () {
          if (_all.contains(s) && s.status == TermStatus.disconnected) unawaited(reconnect(s));
        });
      }
      last = s.status;
    });
    unawaited(s.connect(ref.read(sshOpenerProvider)));
    return s;
  }

  Future<void> reconnect(TermSession s) async {
    if (s.status == TermStatus.connecting) return; // a double tap must not open a second connection
    s.dispose_();
    await s.connect(ref.read(sshOpenerProvider));
  }

  /// When the app comes to the foreground: dropped or silently dead tabs reconnect automatically
  /// (the tmux session keeps running on the server, so you resume where you left off).
  Future<void> _onVisible() async {
    if (!appVisible.value) return;
    for (final s in [..._all]) {
      if (s.status == TermStatus.disconnected || (s.status == TermStatus.connected && !await s.isAlive())) {
        unawaited(reconnect(s));
      }
    }
  }

  void close(TermSession s) {
    _all.remove(s);
    s.dispose();
    state = state.where((x) => x != s).toList();
  }
}

final terminalSessionsProvider = NotifierProvider<TerminalSessions, List<TermSession>>(TerminalSessions.new);

/// Selected tab ID.
class ActiveTerminal extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final activeTerminalProvider = NotifierProvider<ActiveTerminal, String?>(ActiveTerminal.new);

/// Session open full screen (landscape-rotatable). Meanwhile the tab's view doesn't draw the terminal: two views
/// must not keep resizing the same terminal to different sizes and constantly resize the SSH window.
class FullscreenTerminal extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final fullscreenTerminalProvider = NotifierProvider<FullscreenTerminal, String?>(FullscreenTerminal.new);
