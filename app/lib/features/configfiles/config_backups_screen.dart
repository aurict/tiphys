// Backups of a config file (PLAN.md §13.3): the last versions the agent kept before each write; restoring one goes
// through the same masked preview and confirmation as a save.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import '../system/agent_providers.dart';
import 'config_preview_sheet.dart';
import 'configfiles_data.dart';

class ConfigBackupsScreen extends ConsumerStatefulWidget {
  const ConfigBackupsScreen({super.key, required this.hostId, required this.fileId});
  final String hostId;
  final String fileId;
  @override
  ConsumerState<ConfigBackupsScreen> createState() => _ConfigBackupsScreenState();
}

class _ConfigBackupsScreenState extends ConsumerState<ConfigBackupsScreen> {
  ConfigFileRef get _key => (widget.hostId, widget.fileId);

  Future<void> _restore(ConfigBackup b) async {
    final l = AppLocalizations.of(context);
    final path = '/v1/config-files/${widget.fileId}/restore';
    final out = await showConfigPreviewSheet(
      context,
      file: ref.read(configFileProvider(_key)).value?.file ?? widget.fileId,
      restore: true,
      load: (restart) => agentCall(ref, widget.hostId, 'POST', path, {'backupId': b.id, 'restart': restart ? 'affected' : 'none'}),
      execute: (p, restart) => configRequest(ref, widget.hostId, 'POST', path, {'backupId': b.id, 'previewToken': p.token, 'confirm': true, 'restart': restart ? 'affected' : 'none'}, timeout: restart ? restartTimeout : null),
    );
    if (!mounted) return;
    if (out.saved) {
      ref.invalidate(configBackupsProvider(_key));
      ref.invalidate(configFilesProvider(widget.hostId));
      toast(context, l.cfRestored);
      context.pop(true);
    } else if (out.reload) {
      // The file changed since the preview; the backup list is still right, so just let the user retry.
      ref.invalidate(configBackupsProvider(_key));
      toast(context, l.errCfConflict);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = DateFormat('d MMM yyyy HH:mm', locale);
    final async = ref.watch(configBackupsProvider(_key));
    return SettingsPage(
      title: l.cfBackups,
      onRefresh: () async {
        ref.invalidate(configBackupsProvider(_key));
        await ref.read(configBackupsProvider(_key).future).then((_) {}, onError: (_) {});
      },
      children: async.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          TCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(agentErrorText(l, e)),
            TextButton(onPressed: () => ref.invalidate(configBackupsProvider(_key)), child: Text(l.commonRetry)),
          ])),
        ],
        data: (list) => [
          Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(l.cfBackupsHint, style: Theme.of(context).textTheme.bodySmall)),
          if (list.isEmpty)
            TCard(child: Text(l.cfBackupsEmpty))
          else
            GroupedSection(children: [
              for (final b in list)
                GroupedRow(
                  title: b.at == null ? b.id : day.format(b.at!),
                  subtitle: formatSize(b.size, locale),
                  icon: LucideIcons.archive,
                  iconBackground: t.accent,
                  onTap: () => _restore(b),
                  trailing: TextButton(onPressed: () => _restore(b), child: Text(l.cfRestore)),
                ),
            ]),
        ],
      ),
    );
  }
}
