import 'package:go_router/go_router.dart';

import '../system/agent_settings_screen.dart';
import '../system/doctor.dart';
import 'claude_terminal_files.dart';
import 'general_settings.dart';
import 'hosts_screens.dart';
import 'integrations_screens.dart';
import 'profile_screen.dart';
import 'remotes_screens.dart';
import 'secrets_screen.dart';
import 'settings_home.dart';

final settingsRoute = GoRoute(
  path: '/settings',
  builder: (c, s) => const SettingsHome(),
  routes: [
    GoRoute(path: 'hosts', builder: (c, s) => const HostsScreen(), routes: [
      GoRoute(path: 'edit', builder: (c, s) => HostEditScreen(hostId: s.uri.queryParameters['id'])),
      GoRoute(path: 'agent', builder: (c, s) => AgentSettingsScreen(hostId: s.uri.queryParameters['id']!)),
      GoRoute(path: 'health', builder: (c, s) => HealthScreen(hostId: s.uri.queryParameters['id'] ?? '')),
    ]),
    GoRoute(path: 'secrets', builder: (c, s) => const SecretsScreen()),
    GoRoute(path: 'claude', builder: (c, s) => const ClaudeSettingsScreen()),
    GoRoute(path: 'integrations', builder: (c, s) => const IntegrationsScreen(), routes: [
      GoRoute(path: 'grafana', builder: (c, s) => GrafanaEditScreen(id: s.uri.queryParameters['id'])),
      GoRoute(path: 'dozzle', builder: (c, s) => DozzleEditScreen(id: s.uri.queryParameters['id'])),
      GoRoute(path: 'homepage', builder: (c, s) => const HomepageEditScreen()),
      GoRoute(path: 'uptime', builder: (c, s) => const UptimeEditScreen()),
      GoRoute(path: 'ntfy', builder: (c, s) => const NtfyEditScreen()),
      GoRoute(path: 'scriberr', builder: (c, s) => const ScriberrEditScreen()),
      GoRoute(path: 'obsidian', builder: (c, s) => const ObsidianEditScreen()),
    ]),
    GoRoute(path: 'terminal', builder: (c, s) => const TerminalSettingsScreen()),
    GoRoute(path: 'files', builder: (c, s) => const FilesSettingsScreen()),
    GoRoute(path: 'actions', builder: (c, s) => const QuickActionsScreen(), routes: [
      GoRoute(path: 'edit', builder: (c, s) => QuickActionEditScreen(id: s.uri.queryParameters['id'])),
    ]),
    GoRoute(path: 'remotes', builder: (c, s) => const RemotesScreen(), routes: [
      GoRoute(path: 'edit', builder: (c, s) => RemoteEditScreen(id: s.uri.queryParameters['id'], windowClass: s.uri.queryParameters['class'])),
    ]),
    GoRoute(path: 'home', builder: (c, s) => const HomeCardsScreen()),
    GoRoute(path: 'appearance', builder: (c, s) => const AppearanceScreen()),
    GoRoute(path: 'security', builder: (c, s) => const SecurityScreen()),
    GoRoute(path: 'notifications', builder: (c, s) => const NotificationsScreen()),
    GoRoute(path: 'profile', builder: (c, s) => const ProfileScreen()),
  ],
);
