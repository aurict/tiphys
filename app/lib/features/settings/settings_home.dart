import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';

class SettingsHome extends ConsumerWidget {
  const SettingsHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    final missing = ref.watch(secretIdsProvider).value;
    final missingCount = missing == null ? 0 : p.secretIds.difference(missing).length;
    GroupedRow row(String title, String hint, IconData icon, Color bg, String path, {String? trailing, String? badge}) => GroupedRow(
          title: title,
          subtitle: hint,
          icon: icon,
          iconBackground: bg,
          trailingText: trailing,
          badge: badge,
          onTap: () => context.push('/settings/$path'),
        );
    return SettingsPage(title: l.settingsTitle, children: [
      GroupedSection(children: [
        row(l.settingsHosts, l.settingsHostsHint, LucideIcons.server, const Color(0xFF4338CA), 'hosts', trailing: '${p.hosts.length}'),
        GroupedRow(
          title: l.onbSettingsRow,
          subtitle: l.onbSettingsRowHint,
          icon: LucideIcons.wand,
          iconBackground: const Color(0xFF2F9E6A),
          onTap: () => context.push('/welcome?from=settings'),
        ),
        row(l.settingsKeys, l.settingsKeysHint, LucideIcons.keyRound, const Color(0xFFB45309), 'secrets',
            badge: missingCount > 0 ? '$missingCount' : null),
        row(l.settingsClaude, l.settingsClaudeHint, LucideIcons.asterisk, const Color(0xFF1E1B4B), 'claude'),
        row(l.settingsIntegrations, l.settingsIntegrationsHint, LucideIcons.plug, const Color(0xFF2F9E6A), 'integrations'),
      ]),
      const SizedBox(height: 14),
      GroupedSection(children: [
        row(l.settingsTerminal, l.settingsTerminalHint, LucideIcons.terminal, context.tokens.rowIconTerminal, 'terminal'),
        row(l.settingsFiles, l.settingsFilesHint, LucideIcons.folder, const Color(0xFF5E5CE6), 'files'),
        row(l.settingsQuickActions, l.settingsQuickActionsHint, LucideIcons.zap, const Color(0xFFE5795A), 'actions',
            trailing: '${p.quickActions.length}'),
        row(l.settingsNotifications, l.settingsNotificationsHint, LucideIcons.bell, const Color(0xFFC62828), 'notifications'),
      ]),
      GroupedSection(title: l.settingsDesktop, children: [
        row(l.settingsRemotes, l.settingsRemotesHint, LucideIcons.squareMousePointer, const Color(0xFF0A84FF), 'remotes',
            trailing: p.desktopRemotes.isEmpty ? null : '${p.desktopRemotes.length}'),
      ]),
      const SizedBox(height: 14),
      GroupedSection(children: [
        row(l.settingsHome, l.settingsHomeHint, LucideIcons.layoutGrid, const Color(0xFF6C6C70), 'home'),
        row(l.settingsAppearance, l.settingsAppearanceHint, LucideIcons.palette, const Color(0xFF8F88EE), 'appearance'),
        row(l.settingsSecurity, l.settingsSecurityHint, LucideIcons.shield, const Color(0xFF15803D), 'security'),
        row(l.settingsProfile, l.settingsProfileHint, LucideIcons.fileJson, const Color(0xFF3A3A40), 'profile'),
      ]),
    ]);
  }
}
