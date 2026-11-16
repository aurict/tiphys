// Home screen shortcuts: catalog (icon, color, name), availability and what a tap does.
// Drawn as a row in the "Quick access" card in the Cards layout, a square tile in the Shortcuts layout, and a list
// row in the Focus layout. A shortcut whose requirement isn't configured is hidden on home (Settings says missing).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../desktop/live_screen.dart' show openLiveScreenRoute;
import '../notes/obsidian.dart';
import '../system/agent_providers.dart';
import '../system/open_on_pc.dart';
import '../system/wake.dart';
import 'home_data.dart';

IconData shortcutIcon(String id) => switch (id) {
      'terminal' => LucideIcons.terminal,
      'files' => LucideIcons.folder,
      'quickNote' => LucideIcons.notebookPen,
      'homepage' => LucideIcons.house,
      'vault' => LucideIcons.keySquare,
      'desktop' => LucideIcons.appWindow,
      'liveScreen' => LucideIcons.monitorPlay,
      'media' => LucideIcons.music,
      'openOnPc' => LucideIcons.squareArrowOutUpRight,
      'newClaude' => LucideIcons.asterisk,
      'schedules' => LucideIcons.calendarClock,
      'events' => LucideIcons.history,
      'compose' => LucideIcons.layers,
      'logs' => LucideIcons.textSearch,
      'backups' => LucideIcons.archive,
      'dozzle' => LucideIcons.scrollText,
      'grafana' => LucideIcons.chartLine,
      'sites' => LucideIcons.activity,
      _ => LucideIcons.power,
    };

/// Icon background; the row colors of the same screens in the System tab.
Color shortcutColor(TiphysTokens t, String id) => switch (id) {
      'terminal' => t.rowIconTerminal,
      'files' => t.rowIconFiles,
      'quickNote' => const Color(0xFF7C3AED),
      'homepage' => t.rowIconHomepage,
      'vault' => const Color(0xFF5E5CE6),
      'desktop' => const Color(0xFF5856D6),
      'liveScreen' => const Color(0xFFD70015),
      'media' => const Color(0xFFFF375F),
      'openOnPc' => const Color(0xFF0A84FF),
      'newClaude' => const Color(0xFFC2410C),
      'schedules' => const Color(0xFFB45309),
      'events' => const Color(0xFF5E5CE6),
      'compose' => const Color(0xFF1D63ED),
      'logs' => const Color(0xFF30B0C7),
      'backups' => const Color(0xFF0A84FF),
      'dozzle' => const Color(0xFF2F9E6A),
      'grafana' => const Color(0xFFE5795A),
      'sites' => t.success,
      _ => const Color(0xFF6C6C70),
    };

String shortcutLabel(AppLocalizations l, String id) => switch (id) {
      'terminal' => l.tabTerminal,
      'files' => l.tabFiles,
      'quickNote' => l.noteTitle,
      'homepage' => 'Homepage',
      'vault' => l.vaultTitle,
      'desktop' => l.desktopTitle,
      'liveScreen' => l.liveTitle,
      'media' => l.mediaTitle,
      'openOnPc' => l.openOnPc,
      'newClaude' => l.homeNewClaudeSession,
      'schedules' => l.claudeSchedules,
      'events' => l.eventsTitle,
      'compose' => l.composeTitle,
      'logs' => l.logSearchTitle,
      'backups' => l.backupsTitle,
      'dozzle' => 'Dozzle',
      'grafana' => 'Grafana',
      'sites' => l.shortcutSites,
      _ => l.shortcutWake,
    };

/// Host with an agent for desktop tasks (desktop panel, media, open on PC): the Claude host. Ignored if the agent's
/// feature list is known and "desktop" is off (if unknown the shortcut is shown; the screen itself reports the error).
Host? _desktopHost(WidgetRef ref) {
  final h = ref.watch(claudeHostProvider);
  if (h == null) return null;
  final f = (ref.watch(healthProvider(h.id)).value?['features'] as Map?);
  return f != null && f['desktop'] != true ? null : h;
}

/// For the live screen: "control" must also be on for the desktop host (shown if the feature list is unknown).
Host? _controlHost(WidgetRef ref) {
  final h = _desktopHost(ref);
  if (h == null) return null;
  final f = (ref.watch(healthProvider(h.id)).value?['features'] as Map?);
  return f != null && f['control'] != true ? null : h;
}

/// Host to wake: the Claude host if it has WoL configured, otherwise the first host with WoL configured.
Host? _wakeHost(Profile p) {
  final c = p.host(p.claude.agentHostId);
  return c?.wake != null ? c : p.hosts.where((h) => h.wake != null).firstOrNull;
}

/// The shortcut's missing requirement; null: available.
String? shortcutMissing(WidgetRef ref, AppLocalizations l, String id) {
  final p = ref.watch(profileProvider);
  final agent = p.hosts.any((h) => h.agent != null);
  final ssh = p.hosts.any((h) => h.ssh != null);
  final i = p.integrations;
  return switch (id) {
    'quickNote' => i.obsidian == null ? l.shortcutNeedsObsidian : null,
    'homepage' => i.homepage == null ? l.shortcutNeedsIntegration : null,
    'dozzle' => i.dozzle.isEmpty ? l.shortcutNeedsIntegration : null,
    'grafana' => i.grafana.isEmpty ? l.shortcutNeedsIntegration : null,
    'sites' => i.uptimeKuma == null ? l.shortcutNeedsIntegration : null,
    'media' || 'openOnPc' || 'desktop' => !agent ? l.shortcutNeedsAgent : _desktopHost(ref) == null ? l.shortcutNeedsDesktop : null,
    'liveScreen' => !agent ? l.shortcutNeedsAgent : _controlHost(ref) == null ? l.shortcutNeedsControl : null,
    'newClaude' || 'schedules' || 'events' || 'backups' => agent ? null : l.shortcutNeedsAgent,
    'compose' || 'logs' => ssh ? null : l.shortcutNeedsSsh,
    'wake' => _wakeHost(p) == null ? l.shortcutNeedsWake : null,
    _ => null,
  };
}

/// Shortcuts to show on home: enabled, known and available ones, in the user's order.
List<String> visibleShortcuts(WidgetRef ref, AppLocalizations l) => [
      for (final id in ref.watch(profileProvider.select((p) => p.app.shortcuts)))
        if (allShortcuts.contains(id) && shortcutMissing(ref, l, id) == null) id,
    ];

/// Shortcuts that act immediately (open no new screen): no arrow is shown in the row.
bool shortcutIsAction(String id) => id == 'openOnPc' || id == 'wake';

void runShortcut(BuildContext context, WidgetRef ref, String id) {
  final p = ref.read(profileProvider);
  switch (id) {
    case 'terminal':
      context.go('/terminal');
    case 'files':
      context.go('/files');
    case 'quickNote':
      openQuickNote(context);
    case 'homepage':
      openExternal(p.integrations.homepage!.browserUrl);
    case 'vault':
      context.push('/vault');
    case 'desktop':
      context.push('/system/desktop?host=${Uri.encodeQueryComponent(ref.read(claudeHostProvider)!.id)}');
    case 'liveScreen':
      openLiveScreenRoute(context, ref.read(claudeHostProvider)!.id);
    case 'media':
      context.push('/system/media?host=${Uri.encodeQueryComponent(ref.read(claudeHostProvider)!.id)}');
    case 'openOnPc':
      openClipboardUrlOnPc(context, ref, ref.read(claudeHostProvider)!);
    case 'newClaude':
      context.go('/claude?new=1');
    case 'schedules':
      context.push('/claude/schedules');
    case 'events':
      context.push('/system/events');
    case 'compose':
      context.push('/system/compose');
    case 'logs':
      context.push('/system/logs');
    case 'backups':
      context.push('/system/backups');
    case 'dozzle':
      context.push('/monitor/dozzle');
    case 'grafana':
      context.push('/monitor/grafana');
    case 'sites':
      context.push('/monitor/sites');
    case 'wake':
      final l = AppLocalizations.of(context);
      wakeHost(ref, _wakeHost(p)!, l).then((msg) {
        if (context.mounted) toast(context, msg);
      });
  }
}

/// Row view (Quick access card and Focus layout). The first four shortcuts show the same right-hand text as the
/// old Quick access rows.
class ShortcutRow extends ConsumerWidget {
  const ShortcutRow({super.key, required this.id, required this.data});
  final String id;
  final HomeData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    return GroupedRow(
      title: shortcutLabel(l, id),
      icon: shortcutIcon(id),
      iconBackground: shortcutColor(t, id),
      trailingText: switch (id) {
        'terminal' => data.terminalTabs > 0 ? l.homeTabsCount(data.terminalTabs) : null,
        'files' => p.files.bookmarks.firstOrNull?.path,
        'quickNote' => 'Obsidian',
        'homepage' => l.homeOpenInBrowser,
        _ => null,
      },
      external: id == 'homepage',
      showChevron: !shortcutIsAction(id),
      onTap: () => runShortcut(context, ref, id),
    );
  }
}

/// Square tile view (Shortcuts layout). Name at most two lines, ellipsized if it doesn't fit.
class ShortcutTile extends ConsumerWidget {
  const ShortcutTile({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final label = shortcutLabel(l, id);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: TCard(
        radius: 22,
        padding: const EdgeInsets.all(12),
        semanticLabel: label,
        onTap: () => runShortcut(context, ref, id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ExcludeSemantics(
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: shortcutColor(t, id), borderRadius: BorderRadius.circular(10)),
              child: Icon(shortcutIcon(id), size: 18, color: Colors.white),
            ),
          ),
          const Spacer(),
          ExcludeSemantics(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.2),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    );
  }
}
