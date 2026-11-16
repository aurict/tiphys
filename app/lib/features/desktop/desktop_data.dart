// Desktop panel (10.1) data: Hyprland windows/workspaces, thumbnails, app list and
// icons (read-only, agent "desktop" feature) + control session (for every changing action; agent "control"
// feature). Opening a session asks for the app lock (PIN / fingerprint) again; the token stays only in memory.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/push/push_service.dart' show PcHold, pcControlSecretId;
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../widgets/forms.dart';
import '../claude/claude_screen.dart' show outboxDirProvider;
import '../lock/lock_gate.dart';
import '../system/agent_providers.dart';

class DesktopWindow {
  DesktopWindow(Map j)
      : address = '${j['address']}',
        cls = '${j['class'] ?? ''}',
        title = '${j['title'] ?? ''}',
        workspaceId = ((j['workspace'] as Map?)?['id'] as num?)?.toInt() ?? 0,
        workspaceName = '${(j['workspace'] as Map?)?['name'] ?? ''}',
        floating = j['floating'] == true,
        fullscreen = j['fullscreen'] == true,
        pinned = j['pinned'] == true,
        focused = j['focused'] == true,
        visible = j['visible'] == true,
        appId = j['appId'] as String?;
  final String address;
  final String cls;
  final String title;
  final int workspaceId;
  final String workspaceName;
  final bool floating;
  final bool fullscreen;
  final bool pinned;
  final bool focused;

  /// Currently on screen (its thumbnail can be fetched).
  final bool visible;

  /// App matching the window class (for the icon).
  final String? appId;

  /// Card title: window title, otherwise the class.
  String get label => title.trim().isNotEmpty ? title : cls;
}

class DesktopWorkspace {
  DesktopWorkspace(Map j)
      : id = (j['id'] as num).toInt(),
        name = '${j['name'] ?? j['id']}',
        windows = (j['windows'] as num?)?.toInt() ?? 0,
        visible = j['visible'] == true,
        focused = j['focused'] == true;
  final int id;
  final String name;
  final int windows;
  final bool visible;
  final bool focused;
}

class DesktopState {
  DesktopState(Map j)
      : activeWorkspace = (j['activeWorkspace'] as num?)?.toInt(),
        workspaces = [for (final w in (j['workspaces'] as List? ?? const []).cast<Map>()) DesktopWorkspace(w)],
        windows = [for (final w in (j['windows'] as List? ?? const []).cast<Map>()) DesktopWindow(w)],
        screenOn = (j['monitors'] as List? ?? const []).cast<Map>().every((m) => m['dpms'] != false);
  final int? activeWorkspace;
  final List<DesktopWorkspace> workspaces;
  final List<DesktopWindow> windows;

  /// Are all monitors on (DPMS)?
  final bool screenOn;

  /// For the "Move" menu: normal workspaces + the next free number.
  List<int> get moveTargets {
    final ids = [for (final w in workspaces) if (w.id > 0) w.id];
    final next = (ids.isEmpty ? 0 : ids.reduce((a, b) => a > b ? a : b)) + 1;
    return [...ids, if (next <= 100) next];
  }
}

/// On-screen group from the XDG main categories.
const desktopGroups = ['network', 'development', 'office', 'graphics', 'media', 'game', 'system', 'utility', 'other'];

class DesktopApp {
  DesktopApp(Map j)
      : id = '${j['id']}',
        name = '${j['name']}',
        genericName = j['genericName'] as String?,
        comment = j['comment'] as String?,
        categories = [for (final c in (j['categories'] as List? ?? const [])) '$c'],
        keywords = [for (final c in (j['keywords'] as List? ?? const [])) '$c'],
        hasIcon = j['hasIcon'] == true;
  final String id;
  final String name;
  final String? genericName;
  final String? comment;
  final List<String> categories;
  final List<String> keywords;
  final bool hasIcon;

  String get group {
    final c = categories.toSet();
    if (c.contains('Network')) return 'network';
    if (c.contains('Development')) return 'development';
    if (c.contains('Office')) return 'office';
    if (c.contains('Graphics')) return 'graphics';
    if (c.contains('AudioVideo') || c.contains('Audio') || c.contains('Video')) return 'media';
    if (c.contains('Game')) return 'game';
    if (c.contains('System') || c.contains('Settings')) return 'system';
    if (c.contains('Utility')) return 'utility';
    return 'other';
  }

  /// Does it appear in the name, generic name, description or keywords (case-insensitive and insensitive to Turkish i/ı)?
  bool matches(String q) {
    final n = _fold(q.trim());
    if (n.isEmpty) return true;
    return [name, genericName ?? '', comment ?? '', id, ...keywords].any((s) => _fold(s).contains(n));
  }
}

String _fold(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase().replaceAll('ı', 'i');

String desktopGroupLabel(AppLocalizations l, String g) => switch (g) {
      'network' => l.desktopCatNetwork,
      'development' => l.desktopCatDevelopment,
      'office' => l.desktopCatOffice,
      'graphics' => l.desktopCatGraphics,
      'media' => l.desktopCatMedia,
      'game' => l.desktopCatGame,
      'system' => l.desktopCatSystem,
      'utility' => l.desktopCatUtility,
      _ => l.desktopCatOther,
    };

/// PNG / WebP / JPEG? (SVG icons can't be drawn; the app shows a fallback icon.)
bool isRasterImage(Uint8List b) =>
    (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) ||
    (b.length > 12 && String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') ||
    (b.length > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff);

/// Windows + workspaces; every 4 s while the screen is open and the app is in the foreground.
final desktopStateProvider = FutureProvider.autoDispose.family<DesktopState, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 4));
  return DesktopState(await withAgent(ref, hostId, (c) => c.get('/v1/desktop/windows')));
});

/// Thumbnail of a visible window (host, address); null if unavailable (other workspace) → app icon.
final desktopThumbProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String)>((ref, key) async {
  autoRefresh(ref, const Duration(seconds: 5));
  final (hostId, address) = key;
  try {
    final b = await withAgent(ref, hostId, (c) => c.requestBytes('/v1/desktop/windows/$address/thumb', query: {'w': '360'}, timeout: const Duration(seconds: 15)));
    return isRasterImage(b) ? b : null;
  } on AgentError {
    return null;
  }
});

/// App list (host, language).
final desktopAppsProvider = FutureProvider.autoDispose.family<List<DesktopApp>, (String, String)>((ref, key) async {
  final (hostId, lang) = key;
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/desktop/apps', query: {'lang': lang}));
  return [for (final a in (j['apps'] as List).cast<Map>()) DesktopApp(a)];
});

/// App icon (host, id); kept while the app stays open so it isn't re-downloaded while scrolling.
final desktopIconProvider = FutureProvider.family<Uint8List?, (String, String)>((ref, key) async {
  final (hostId, id) = key;
  try {
    final b = await withAgent(ref, hostId, (c) => c.requestBytes('/v1/desktop/apps/${Uri.encodeComponent(id)}/icon', query: {'size': '128'}, timeout: const Duration(seconds: 20)));
    return isRasterImage(b) ? b : null;
  } on AgentError {
    return null;
  }
});

/// Recently launched apps (at most 8 per host), in a file on the device.
class DesktopRecent extends Notifier<Map<String, List<String>>> {
  static const max = 8;

  @override
  Map<String, List<String>> build() {
    Future(() async {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        state = {for (final e in j.entries) e.key: [for (final x in e.value as List) '$x']};
      } catch (_) {}
    });
    return {};
  }

  Future<File?> _file() async {
    final dir = await ref.read(outboxDirProvider)();
    return dir == null ? null : File('$dir/desktop-recent.json');
  }

  Future<void> add(String hostId, String appId) async {
    state = {...state, hostId: [appId, ...?state[hostId]?.where((x) => x != appId)].take(max).toList()};
    final f = await _file();
    if (f != null) await f.writeAsString(jsonEncode(state));
  }
}

final desktopRecentProvider = NotifierProvider<DesktopRecent, Map<String, List<String>>>(DesktopRecent.new);

// ---- control session ----

class ControlSession {
  const ControlSession({required this.hostId, required this.token, required this.expiresAt});
  final String hostId;
  final String token;
  final DateTime expiresAt;
}

/// Asks for the app lock again before opening a control session; doesn't open if no lock is set. Overridden in tests.
final controlAuthProvider = Provider<Future<bool> Function(BuildContext)>((ref) => (context) async {
      final l = AppLocalizations.of(context);
      if (!await ref.read(lockRequiredProvider.future)) {
        if (context.mounted) toast(context, l.desktopControlNeedsLock);
        return false;
      }
      if (!context.mounted) return false;
      final ok = await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => PopScope(
          child: LockScreen(title: l.desktopControlAuthTitle, onUnlocked: () => Navigator.of(c).pop(true), onCancel: () => Navigator.of(c).pop(false)),
        ),
      ));
      return ok ?? false;
    });

const controlHeader = 'X-Tiphys-Control';

class ControlController extends Notifier<ControlSession?> {
  @override
  ControlSession? build() => null;

  Future<T> _call<T>(String hostId, Future<T> Function(AgentClient c) body) async {
    final host = ref.read(profileProvider).host(hostId);
    if (host == null) throw const AgentError('agent.notConfigured');
    final c = await ref.read(agentClientFactoryProvider)(host);
    try {
      return await body(c);
    } finally {
      c.close();
    }
  }

  /// Valid session on this host; otherwise asks for the lock again and opens one. null if cancelled; AgentError if the
  /// agent refuses.
  /// [fresh]: asks for the lock again even if a session is open (Claude using the PC asks for approval at every start).
  Future<ControlSession?> ensure(BuildContext context, String hostId, {bool fresh = false}) async {
    await syncStored();
    final now = ref.read(clockProvider)();
    final s = state;
    final valid = s != null && s.hostId == hostId && s.expiresAt.isAfter(now.add(const Duration(seconds: 5)));
    if (valid && !fresh) return s;
    if (valid) {
      if (!context.mounted || !await ref.read(controlAuthProvider)(context)) return null;
      return state;
    }
    if (s != null) await stop();
    if (!context.mounted || !await ref.read(controlAuthProvider)(context)) return null;
    final j = await _call(hostId, (c) => c.post('/v1/desktop/control/session', const {'minutes': 15})) as Map;
    return state = ControlSession(hostId: hostId, token: '${j['token']}', expiresAt: DateTime.parse('${j['expiresAt']}').toLocal());
  }

  Future<void> extend() async {
    final s = state;
    if (s == null) return;
    final j = await _call(s.hostId, (c) => c.request('POST', '/v1/desktop/control/session/extend', body: const {'minutes': 15}, headers: {controlHeader: s.token})) as Map;
    if (state?.token == s.token) state = ControlSession(hostId: s.hostId, token: s.token, expiresAt: DateTime.parse('${j['expiresAt']}').toLocal());
  }

  /// Closes the session (the indicator on the PC goes away). Ends locally even if the agent is unreachable; the agent
  /// closes it when it expires.
  Future<void> stop() async {
    if (!ref.mounted) return; // while the app is closing (container disposed)
    final s = state;
    if (s == null) return;
    state = null;
    try {
      await _call(s.hostId, (c) => c.request('DELETE', '/v1/desktop/control/session', headers: {controlHeader: s.token}));
    } catch (_) {}
  }

  /// Strict rule (panel / live screen: on leaving the screen or after 60 s in the background): closes the session — but
  /// doesn't touch it if a Claude session using the PC holds it (so a task can be given and the phone pocketed; the
  /// timer still runs).
  Future<void> release() async {
    if (!ref.mounted || pcHold != null) return;
    await stop();
  }

  /// The PC Claude session holding the session (set/cleared by claude/pc_ongoing.dart); while set, the strict rule
  /// doesn't apply.
  String? pcHold;

  /// The agent doesn't recognize the session (expired / agent restarted): end it locally too.
  void forget() => state = null;

  /// "Extend" in the notification runs in a background isolate and writes the new end only to the stored record (PcHold):
  /// the local end is updated if it's older. Called when the app comes to the foreground and before acting on the local
  /// end.
  Future<void> syncStored() async {
    if (state == null || pcHold == null) return;
    final h = PcHold.fromJson(await ref.read(secretStoreProvider).read(pcControlSecretId));
    final s = ref.mounted ? state : null;
    if (h == null || s == null || h.hostId != s.hostId || h.token != s.token || !h.expiresAt.isAfter(s.expiresAt)) return;
    state = ControlSession(hostId: s.hostId, token: s.token, expiresAt: h.expiresAt);
  }

  /// Local time expired: check the stored record first (may have been extended in the background); forget if truly expired.
  Future<void> expireIfDue() async {
    await syncStored();
    final s = ref.mounted ? state : null;
    if (s != null && !s.expiresAt.isAfter(ref.read(clockProvider)())) forget();
  }
}

final controlProvider = NotifierProvider<ControlController, ControlSession?>(ControlController.new);

/// Changing desktop call: opens a session if needed (lock asked), sends with the token, then refreshes the state.
Future<bool> desktopAction(BuildContext context, WidgetRef ref, String hostId, String path, {Object? body, String? done}) async {
  final l = AppLocalizations.of(context);
  final ctrl = ref.read(controlProvider.notifier);
  try {
    final s = await ctrl.ensure(context, hostId);
    if (s == null) return false;
    await agentCall(ref, hostId, 'POST', path, body ?? const {}, {controlHeader: s.token});
    if (done != null && context.mounted) toast(context, done);
    return true;
  } catch (e) {
    if (e is AgentError && e.code == 'agent.control.sessionRequired') ctrl.forget();
    if (context.mounted) toast(context, agentErrorText(l, e));
    return false;
  } finally {
    if (context.mounted) ref.invalidate(desktopStateProvider(hostId));
  }
}
