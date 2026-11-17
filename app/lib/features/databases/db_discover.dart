// "Discover" wizard, step 1 (PLAN.md §13.2): the running database containers the agent found (image name heuristic;
// only environment variable names are known, never values). Picking a supported one opens the connection form
// prefilled; Redis is listed but not supported.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'db_data.dart';
import 'db_form.dart';
import 'db_texts.dart';

class DbDiscoverScreen extends ConsumerWidget {
  const DbDiscoverScreen({super.key, required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(dbDiscoverProvider(hostId));
    return SettingsPage(
      title: l.dbDiscoverTitle,
      onRefresh: () async => ref.invalidate(dbDiscoverProvider(hostId)),
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(dbDiscoverProvider(hostId)))],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(l.dbDiscoverHint, style: Theme.of(context).textTheme.bodySmall),
        ),
        ...async.when(
          skipLoadingOnRefresh: true,
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [
            TCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.circleAlert, color: t.danger, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(agentErrorText(l, e))),
                    ],
                  ),
                  TextButton(onPressed: () => ref.invalidate(dbDiscoverProvider(hostId)), child: Text(l.commonRetry)),
                ],
              ),
            ),
          ],
          data: (list) => list.isEmpty
              ? [TCard(child: Text(l.dbDiscoverNone))]
              : [
                  GroupedSection(
                    children: [
                      for (final c in list)
                        GroupedRow(
                          title: c.container,
                          subtitle: [
                            '${dbEngineName(c.engine)}${c.version.isEmpty ? '' : ' ${c.version}'}',
                            if (c.project != null) c.project!,
                            if (!c.supported) l.dbDiscoverUnsupported else if (c.connections.isNotEmpty) l.dbDiscoverConnected(c.connections.length),
                          ].join(' · '),
                          icon: LucideIcons.database,
                          iconBackground: c.supported ? t.accent : t.textSecondary,
                          onTap: c.supported
                              ? () => context.push(
                                  '/db/form',
                                  extra: DbFormArgs(hostId: hostId, container: c),
                                )
                              : null,
                          showChevron: c.supported,
                        ),
                    ],
                  ),
                ],
        ),
      ],
    );
  }
}
