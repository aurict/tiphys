// What the PC's desktop backend can do (P1): GET /v1/desktop/capabilities. On Hyprland the agent drives the desktop
// itself and has everything; on other desktops (Sway, X11, GNOME/KDE portal, Windows, macOS) the native helper lists
// what really works there. The app hides or disables the rest with a short "not available on <backend>" note instead
// of letting the request fail. Older agents have no such route: they are Hyprland-only, so they get everything.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../system/agent_providers.dart';

class DesktopCaps {
  const DesktopCaps({required this.backend, required this.caps, this.platform, this.error});

  /// "hyprland" or "helper".
  final String backend;
  final Set<String> caps;

  /// Helper backend's platform: sway, x11, portal, windows, macos, none.
  final String? platform;

  /// Why the helper couldn't start (an agent error code), if it couldn't.
  final String? error;

  static const _hyprland = {
    'windows', 'windowActions', 'workspaces', 'monitors', 'thumbnails', 'screenshot', 'stream', 'input', 'text', 'apps', 'launch', 'dpms', //
    'clipboard', 'clipboardSync', 'h264', 'mobileView', 'sunshine', 'pcTools', 'browserFocus',
  };

  /// What an agent without the capabilities route has (it only knew Hyprland).
  static const legacy = DesktopCaps(backend: 'hyprland', caps: _hyprland);

  factory DesktopCaps.fromJson(Map j) => DesktopCaps(
        backend: '${j['backend'] ?? 'hyprland'}',
        caps: {for (final c in (j['capabilities'] as List? ?? const [])) '$c'},
        platform: j['platform'] as String?,
        error: j['error'] as String?,
      );

  bool has(String c) => caps.contains(c);
  bool get isHyprland => backend == 'hyprland';
}

/// The backend's name for "not available on …" notes.
String desktopBackendName(AppLocalizations l, DesktopCaps c) => c.isHyprland
    ? 'Hyprland'
    : switch (c.platform) {
        'sway' => 'Sway',
        'x11' => 'X11',
        'portal' => 'GNOME / KDE',
        'windows' => 'Windows',
        'macos' => 'macOS',
        _ => l.desktopBackendUnknown,
      };

/// Labels of the capabilities the app shows a "not available" note for, in display order.
List<String> missingDesktopFeatures(AppLocalizations l, DesktopCaps c) => [
      for (final (cap, label) in [
        ('windows', l.desktopCapWindows),
        ('thumbnails', l.desktopCapThumbnails),
        ('workspaces', l.desktopCapWorkspaces),
        ('stream', l.liveTitle),
        ('h264', 'H.264'),
        ('mobileView', l.uiTitle),
        ('sunshine', 'Sunshine'),
        ('pcTools', l.desktopCapPcTools),
        ('apps', l.desktopApps),
        ('clipboardSync', l.desktopCapClipboardSync),
        ('dpms', l.desktopCapDpms),
      ])
        if (!c.has(cap)) label,
    ];

final desktopCapsProvider = FutureProvider.autoDispose.family<DesktopCaps, String>((ref, hostId) async {
  try {
    return DesktopCaps.fromJson(await withAgent(ref, hostId, (c) => c.get('/v1/desktop/capabilities')));
  } on AgentError catch (e) {
    if (e.code == 'agent.route.notFound') return DesktopCaps.legacy;
    rethrow;
  }
});

/// Capabilities to lay the screen out with: while loading or after an error, the legacy set (the screen then shows
/// what it always showed; a missing capability still answers with a readable error).
DesktopCaps desktopCapsOf(WidgetRef ref, String hostId) => ref.watch(desktopCapsProvider(hostId)).value ?? DesktopCaps.legacy;
