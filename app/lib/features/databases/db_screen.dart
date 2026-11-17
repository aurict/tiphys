// System › Databases (PLAN.md §13.2, D-1): every agent with the `databases` feature → its connections, the "Discover"
// wizard entry and manual add. A connection row opens the console (schema / queries / editor); its menu tests, edits
// and deletes it. Passwords never show: the agent only says whether one is stored.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'db_data.dart';
import 'db_form.dart';
import 'db_restore_screen.dart';
import 'db_result_view.dart';
import 'db_texts.dart';

/// "/db/conn?host=argo&id=db-…"
String dbConnRoute(String hostId, String connId) => '/db/conn?host=${Uri.encodeQueryComponent(hostId)}&id=${Uri.encodeQueryComponent(connId)}';

class DbScreen extends ConsumerWidget {
  const DbScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(dbHostsProvider);
    Future<void> refresh() async {
      for (final h in hosts.value ?? const <Host>[]) {
        ref.invalidate(dbConnectionsProvider(h.id));
      }
      ref.invalidate(dbHostsProvider);
    }

    return SettingsPage(
      title: l.dbTitle,
      onRefresh: refresh,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: refresh)],
      children: hosts.when(
        loading: () => [
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (list) => list.isEmpty ? [TCard(child: Text(l.dbNoHosts))] : [for (final h in list) _HostConnections(host: h, showName: list.length > 1)],
      ),
    );
  }
}

class _HostConnections extends ConsumerWidget {
  const _HostConnections({required this.host, required this.showName});
  final Host host;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(dbConnectionsProvider(host.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showName) SectionLabel(host.name),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => context.push(dbRestoreRoute(host: host.id)),
                icon: const Icon(LucideIcons.archiveRestore, size: 17),
                label: Text(l.dbRestoreTitle),
              ),
              FilledButton.icon(onPressed: () => context.push('/db/discover?host=${Uri.encodeQueryComponent(host.id)}'), icon: const Icon(LucideIcons.radar, size: 17), label: Text(l.dbDiscover)),
              OutlinedButton.icon(
                onPressed: () => context.push('/db/form', extra: DbFormArgs(hostId: host.id)),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: Text(l.dbAddManual),
              ),
            ],
          ),
        ),
        async.when(
          skipLoadingOnRefresh: true,
          loading: () => const TCard(
            child: Center(
              child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) => TCard(
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
                TextButton(onPressed: () => ref.invalidate(dbConnectionsProvider(host.id)), child: Text(l.commonRetry)),
              ],
            ),
          ),
          data: (d) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!d.sqlite)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DbNote(l.dbSqliteUnavailable, icon: LucideIcons.info),
                ),
              if (d.connections.isEmpty) TCard(child: Text(l.dbNoConnections)) else GroupedSection(children: [for (final c in d.connections) _ConnectionRow(conn: c)]),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectionRow extends ConsumerWidget {
  const _ConnectionRow({required this.conn});
  final DbConnection conn;

  Future<void> _test(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    try {
      final j = await DbApi(ref, conn.host.id).test(conn.id);
      if (!context.mounted) return;
      final warnings = [for (final w in (j['warnings'] as List? ?? const [])) dbWarningText(l, '$w')];
      final lines = [l.dbTestOk('${j['serverVersion'] ?? ''}', '${j['user'] ?? '-'}', '${j['latencyMs'] ?? 0}'), if (j['superuser'] == true && !warnings.contains(l.dbWarnSuperuser)) l.dbWarnSuperuser, ...warnings];
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(conn.name),
          content: Text(lines.join('\n\n')),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonClose))],
        ),
      );
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.dbDeleteConfirm(conn.name), confirmLabel: l.commonDelete, destructive: true) || !context.mounted) return;
    try {
      await agentCall(ref, conn.host.id, 'DELETE', '/v1/db/connections/${conn.id}');
      ref.invalidate(dbConnectionsProvider(conn.host.id));
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return GroupedRow(
      title: conn.name,
      subtitle: [dbEngineName(conn.engine), conn.targetLabel, if (conn.database != null) conn.database!].join(' · '),
      icon: LucideIcons.database,
      iconBackground: conn.superuser ? t.warning : t.accent,
      badge: conn.superuser ? l.dbSuperuserBadge : null,
      onTap: () => context.push(dbConnRoute(conn.host.id, conn.id)),
      trailing: PopupMenuButton<String>(
        tooltip: l.dbConnectionMenu,
        icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
        onSelected: (v) {
          switch (v) {
            case 'test':
              _test(context, ref);
            case 'edit':
              context.push(
                '/db/form',
                extra: DbFormArgs(hostId: conn.host.id, existing: conn),
              );
            case 'delete':
              _delete(context, ref);
          }
        },
        itemBuilder: (_) => [PopupMenuItem(value: 'test', child: Text(l.commonTest)), PopupMenuItem(value: 'edit', child: Text(l.commonEdit)), PopupMenuItem(value: 'delete', child: Text(l.commonDelete))],
      ),
    );
  }
}
