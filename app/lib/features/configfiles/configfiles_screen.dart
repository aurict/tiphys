// System › Config and secrets (PLAN.md §13.3, C-1): every agent with the `configfiles` feature → its stacks → the .env
// files the agent offers. Files it found but skipped are collapsed at the end with the reason.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import '../system/agent_providers.dart';
import 'configfiles_data.dart';
import 'configfiles_texts.dart';

/// "/configfiles/file?host=argo&id=cf-…"
String configFileRoute(String hostId, String fileId) => '/configfiles/file?host=${Uri.encodeQueryComponent(hostId)}&id=${Uri.encodeQueryComponent(fileId)}';

class ConfigFilesScreen extends ConsumerWidget {
  const ConfigFilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(configHostsProvider);
    Future<void> refresh() async {
      for (final h in hosts.value ?? const <Host>[]) {
        ref.invalidate(configFilesProvider(h.id));
      }
      ref.invalidate(configHostsProvider);
    }

    return SettingsPage(
      title: l.cfTitle,
      onRefresh: refresh,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: refresh)],
      children: hosts.when(
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (list) => list.isEmpty
            ? [TCard(child: Text(l.cfNoHosts))]
            : [
                for (final h in list) _HostFiles(host: h, showName: list.length > 1),
              ],
      ),
    );
  }
}

class _HostFiles extends ConsumerWidget {
  const _HostFiles({required this.host, required this.showName});
  final Host host;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(configFilesProvider(host.id));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (showName) SectionLabel(host.name),
      async.when(
        skipLoadingOnRefresh: true,
        loading: () => const TCard(child: Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))),
        error: (e, _) => TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.circleAlert, color: t.danger, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(agentErrorText(l, e))),
            ]),
            TextButton(onPressed: () => ref.invalidate(configFilesProvider(host.id)), child: Text(l.commonRetry)),
          ]),
        ),
        data: (f) => _Stacks(data: f),
      ),
    ]);
  }
}

class _Stacks extends StatelessWidget {
  const _Stacks({required this.data});
  final ConfigHostFiles data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = DateFormat('d MMM HH:mm', locale);
    if (data.files.isEmpty && data.skipped.isEmpty) return TCard(child: Text(l.cfNoFiles));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (data.files.isEmpty) TCard(child: Text(l.cfNoFiles)),
      for (final (stack, files) in groupFilesByStack(data.files))
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: GroupedSection(
            title: stack ?? l.cfOtherFiles,
            children: [
              for (final f in files)
                GroupedRow(
                  title: f.file,
                  subtitle: [
                    l.cfKeysCount(f.keys, f.secrets),
                    formatSize(f.size, locale),
                    if (f.modifiedAt != null) day.format(f.modifiedAt!),
                  ].join(' · '),
                  icon: f.secrets > 0 ? LucideIcons.fileLock : LucideIcons.fileText,
                  iconBackground: f.worldReadable ? t.warning : t.accent,
                  badge: f.worldReadable ? l.cfWorldReadableShort : null,
                  onTap: () => context.push(configFileRoute(data.host.id, f.fileId)),
                ),
            ],
          ),
        ),
      if (data.skipped.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TCard(
            padding: EdgeInsets.zero,
            radius: TiphysTokens.radiusList,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(LucideIcons.fileX, size: 20, color: t.textSecondary),
                title: Text(l.cfSkippedTitle(data.skipped.length), style: Theme.of(context).textTheme.titleMedium),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in data.skipped)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.file, style: Theme.of(context).textTheme.bodyMedium),
                        Text(skipReasonText(l, s.reason), style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}
