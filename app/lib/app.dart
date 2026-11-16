import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart' show SharedMediaFile;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'features/files/share_to_pc.dart';
import 'features/notes/obsidian.dart';
import 'features/notes/quick_note_screen.dart';
import 'features/git/git_screen.dart';
import 'features/claude/claude_chat_screen.dart';
import 'features/claude/claude_screen.dart';
import 'features/files/files_screen.dart';
import 'features/home/home_screen.dart';
import 'features/monitoring/dozzle_screen.dart';
import 'features/monitoring/grafana_screen.dart';
import 'features/monitoring/homepage_screen.dart';
import 'features/monitoring/sites_screen.dart';
import 'features/claude/schedules.dart';
import 'features/system/backups.dart';
import 'features/system/clipboard_sync.dart';
import 'features/system/compose.dart';
import 'features/system/events.dart';
import 'features/system/log_search.dart';
import 'features/system/media.dart';
import 'features/desktop/desktop_screen.dart';
import 'features/desktop/live_screen.dart';
import 'features/system/system_screen.dart';
import 'features/terminal/terminal_screen.dart';
import 'features/lock/lock_gate.dart';
import 'features/vault/vault_screen.dart';
import 'features/settings/settings_routes.dart';
import 'l10n/gen/app_localizations.dart';
import 'state/providers.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'widgets/floating_tab_bar.dart';
import 'widgets/surfaces.dart';

/// Tab id → (route, icon, label)
const tabRoutes = {
  'home': '/',
  'claude': '/claude',
  'terminal': '/terminal',
  'files': '/files',
  'system': '/system',
};

IconData tabIcon(String id) => switch (id) {
      'home' => LucideIcons.layoutGrid,
      'claude' => LucideIcons.asterisk,
      'terminal' => LucideIcons.terminal,
      'files' => LucideIcons.folder,
      _ => LucideIcons.chartLine,
    };

String tabLabel(AppLocalizations l, String id) => switch (id) {
      'home' => l.tabHome,
      'claude' => l.tabClaude,
      'terminal' => l.tabTerminal,
      'files' => l.tabFiles,
      _ => l.tabSystem,
    };

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/', pageBuilder: (c, s) => const NoTransitionPage(child: HomeScreen())),
          GoRoute(
            path: '/claude',
            pageBuilder: (c, s) => NoTransitionPage(
              child: ClaudeScreen(openNew: s.uri.queryParameters['new'] == '1', cwd: s.uri.queryParameters['cwd']),
            ),
          ),
          GoRoute(
            path: '/terminal',
            pageBuilder: (c, s) => NoTransitionPage(
              child: TerminalScreen(hostId: s.uri.queryParameters['host'], startDir: s.uri.queryParameters['cwd']),
            ),
          ),
          GoRoute(path: '/files', pageBuilder: (c, s) => const NoTransitionPage(child: FilesScreen())),
          GoRoute(
            path: '/system',
            pageBuilder: (c, s) => const NoTransitionPage(child: SystemScreen()),
          ),
        ],
      ),
      GoRoute(path: '/monitor/grafana', builder: (c, s) => const GrafanaScreen()),
      GoRoute(path: '/monitor/dozzle', builder: (c, s) => const DozzleScreen()),
      GoRoute(path: '/monitor/sites', builder: (c, s) => const SitesScreen()),
      GoRoute(path: '/monitor/homepage', builder: (c, s) => const HomepageScreen()),
      GoRoute(path: '/system/events', builder: (c, s) => const EventsScreen()),
      GoRoute(path: '/system/backups', builder: (c, s) => const BackupsScreen()),
      GoRoute(path: '/system/compose', builder: (c, s) => const ComposeScreen()),
      GoRoute(path: '/system/logs', builder: (c, s) => LogSearchScreen(initialPattern: s.uri.queryParameters['q'])),
      GoRoute(path: '/vault', builder: (c, s) => const VaultScreen()),
      GoRoute(path: '/system/media', builder: (c, s) => MediaScreen(hostId: s.uri.queryParameters['host'] ?? '')),
      GoRoute(path: '/system/desktop', builder: (c, s) => DesktopScreen(hostId: s.uri.queryParameters['host'] ?? '')),
      GoRoute(
        path: '/system/desktop/live',
        builder: (c, s) => LiveScreen(hostId: s.uri.queryParameters['host'] ?? '', window: s.uri.queryParameters['window']),
      ),
      GoRoute(path: '/note', builder: (c, s) => QuickNoteScreen(args: s.extra is QuickNoteArgs ? s.extra as QuickNoteArgs : const QuickNoteArgs())),
      GoRoute(path: '/claude/schedules', builder: (c, s) => const ClaudeSchedulesScreen()),
      GoRoute(path: '/share', builder: (c, s) => ShareToPcScreen(items: (s.extra as List?)?.cast<SharedMediaFile>() ?? const [])),
      GoRoute(path: '/git', builder: (c, s) => GitScreen(hostId: s.uri.queryParameters['host'] ?? '', path: s.uri.queryParameters['path'] ?? '~')),
      GoRoute(path: '/claude/session/:id', builder: (c, s) => ClaudeChatScreen(sessionId: s.pathParameters['id'])),
      GoRoute(
        path: '/claude/history/:id',
        builder: (c, s) => ClaudeChatScreen(
          historyId: s.pathParameters['id'],
          historyCwd: s.uri.queryParameters['cwd'],
          inTerminal: s.uri.queryParameters['terminal'] == '1',
        ),
      ),
      settingsRoute,
    ],
  );
});

class TiphysApp extends ConsumerWidget {
  const TiphysApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (c) => AppLocalizations.of(c).appName,
      theme: buildTheme(TiphysTokens.light),
      darkTheme: buildTheme(TiphysTokens.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: ref.watch(localeProvider),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (device, supported) {
        // English unless the system language is Turkish.
        if (device?.languageCode == 'tr') return const Locale('tr');
        return const Locale('en');
      },
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => LockGate(child: ClipboardSyncGate(child: child!)),
    );
  }
}

/// Tabs + floating bottom bar. Color blobs in the background in the dark theme.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profile = ref.watch(profileProvider);
    final tabs = profile.app.tabs;
    final current = tabs.lastIndexWhere((id) {
      final r = tabRoutes[id]!;
      return r == '/' ? location == '/' : location.startsWith(r);
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        colors: [for (final h in profile.hosts.take(3)) hexColor(h.color)],
        child: Stack(children: [
          Positioned.fill(child: child),
          Positioned(
            left: 0,
            right: 0,
            bottom: FloatingTabBar.bottomGap + MediaQuery.paddingOf(context).bottom,
            child: Center(
              child: FloatingTabBar(
                items: [for (final id in tabs) TabItem(icon: tabIcon(id), label: tabLabel(l, id))],
                index: current < 0 ? 0 : current,
                onSelect: (i) => context.go(tabRoutes[tabs[i]]!),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
