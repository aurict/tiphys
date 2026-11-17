// One connection of the database console (PLAN.md §13.2): tabs Schema / Queries / Editor. While the write mode is on the
// whole screen gets a red frame and a banner. The tab bodies stay alive when switching (the editor keeps its text).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import '../incidents/host_picker.dart' show HostBadge;
import '../system/events.dart' show ChipRow, filterChip;
import 'db_data.dart';
import 'db_editor.dart';
import 'db_queries.dart';
import 'db_result_view.dart';
import 'db_texts.dart';

class DbConnectionScreen extends ConsumerStatefulWidget {
  const DbConnectionScreen({super.key, required this.hostId, required this.connId});
  final String hostId;
  final String connId;

  @override
  ConsumerState<DbConnectionScreen> createState() => _DbConnectionScreenState();
}

class _DbConnectionScreenState extends ConsumerState<DbConnectionScreen> {
  String _tab = 'schema';

  /// SQL sent to the editor from a saved query (or the role helper); the editor takes it and clears it.
  final _editorSql = ValueNotifier<String?>(null);

  /// Bumped by "Use a read-only role": the editor's role helper opens.
  final _roleRequest = ValueNotifier<int>(0);

  /// CSV exports happen on this screen: leaving it removes any copy left in the cache (db-export/, share_plus/).
  late final Future<void> Function() _clearCsv;

  @override
  void initState() {
    super.initState();
    _clearCsv = ref.read(dbClearCsvCopiesProvider);
  }

  @override
  void dispose() {
    _editorSql.dispose();
    _roleRequest.dispose();
    unawaited(_clearCsv());
    super.dispose();
  }

  void _toRoleHelper() {
    setState(() => _tab = 'editor');
    _roleRequest.value++;
  }

  void _toEditor(String sql) {
    _editorSql.value = sql;
    setState(() => _tab = 'editor');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final key = (widget.hostId, widget.connId);
    final conns = ref.watch(dbConnectionsProvider(widget.hostId));
    final conn = conns.value?.byId(widget.connId);
    final write = ref.watch(dbWriteModeProvider(key));
    Widget tabs(DbConnection c) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChipRow(
          children: [
            filterChip(context, l.dbTabSchema, _tab == 'schema', () => setState(() => _tab = 'schema')),
            filterChip(context, l.dbTabQueries, _tab == 'queries', () => setState(() => _tab = 'queries')),
            filterChip(context, l.dbTabEditor, _tab == 'editor', () => setState(() => _tab = 'editor')),
          ],
        ),
        const SizedBox(height: 6),
        Visibility(
          visible: _tab == 'schema',
          maintainState: true,
          child: DbSchemaTab(hostId: widget.hostId, conn: c),
        ),
        Visibility(
          visible: _tab == 'queries',
          maintainState: true,
          child: DbQueriesTab(hostId: widget.hostId, conn: c, onOpenInEditor: _toEditor),
        ),
        Visibility(
          visible: _tab == 'editor',
          maintainState: true,
          child: DbEditorTab(hostId: widget.hostId, conn: c, incoming: _editorSql, roleRequest: _roleRequest),
        ),
      ],
    );
    final page = SettingsPage(
      title: conn?.name ?? l.dbTitle,
      onRefresh: () async {
        ref.invalidate(dbConnectionsProvider(widget.hostId));
        ref.invalidate(dbSchemaProvider(key));
        ref.invalidate(dbQueriesProvider(key));
      },
      children: [
        // A fixed slot (not a conditional entry): the tab bodies below must keep their state when the banner appears.
        write
            ? Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DbNote(l.dbWriteBanner, color: t.danger, icon: LucideIcons.triangleAlert),
              )
            : const SizedBox.shrink(),
        ...conns.when(
          skipLoadingOnRefresh: true,
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
          data: (_) => conn == null
              ? [TCard(child: Text(l.errDbConnectionNotFound))]
              : [
                  TCard(
                    radius: TiphysTokens.radiusList,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HostBadge(conn.host),
                        const SizedBox(height: 6),
                        Text(
                          [dbEngineName(conn.engine), conn.targetLabel, if (conn.database != null) conn.database!].join(' · '),
                          style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: t.text),
                        ),
                        for (final w in conn.warnings)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: DbNote(dbWarningText(l, w), icon: LucideIcons.shieldAlert),
                          ),
                        // PostgreSQL read access: through a read role, superuser reads allowed, or refused for now.
                        if (conn.superuserReadsBlocked)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: SuperuserReadsNote(hostId: widget.hostId, conn: conn, onUseRole: _toRoleHelper),
                          )
                        else if (conn.isPostgres && (conn.readRole != null || conn.allowSuperuserReads))
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                Icon(conn.readRole != null ? LucideIcons.shieldCheck : LucideIcons.triangleAlert, size: 16, color: conn.readRole != null ? t.success : t.danger),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(conn.readRole != null ? l.dbReadsViaRole(conn.readRole!) : l.dbReadsSuperuserAllowed, style: Theme.of(context).textTheme.bodySmall),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  tabs(conn),
                ],
        ),
      ],
    );
    return Stack(
      children: [
        page,
        if (write)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: t.danger, width: 4)),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Schema tab

class DbSchemaTab extends ConsumerWidget {
  const DbSchemaTab({super.key, required this.hostId, required this.conn});
  final String hostId;
  final DbConnection conn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final key = (hostId, conn.id);
    return ref
        .watch(dbSchemaProvider(key))
        .when(
          skipLoadingOnRefresh: true,
          loading: () => const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
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
                TextButton(onPressed: () => ref.invalidate(dbSchemaProvider(key)), child: Text(l.commonRetry)),
              ],
            ),
          ),
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.truncated) Padding(padding: const EdgeInsets.only(bottom: 8), child: DbNote(l.dbSchemaTruncated)),
              if (s.schemas.isEmpty) TCard(child: Text(l.dbSchemaEmpty)),
              for (var i = 0; i < s.schemas.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TCard(
                    padding: EdgeInsets.zero,
                    radius: TiphysTokens.radiusList,
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        initiallyExpanded: i == 0,
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                        leading: Icon(LucideIcons.folderTree, size: 20, color: t.accent),
                        title: Text(s.schemas[i].name, style: tt.titleMedium),
                        subtitle: Text(l.dbTablesCount(s.schemas[i].tables.length), style: tt.bodySmall),
                        childrenPadding: const EdgeInsets.only(bottom: 6),
                        children: [
                          for (final tb in s.schemas[i].tables)
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                              leading: Icon(tb.kind == 'table' || tb.kind == 'partitionedTable' ? LucideIcons.table : LucideIcons.eye, size: 18, color: t.textSecondary),
                              title: Text(
                                tb.name,
                                style: TextStyle(fontFamily: monoFamily, fontSize: 13.5, color: t.text),
                              ),
                              subtitle: Text([dbKindName(l, tb.kind), if (tb.estimatedRows != null) l.dbEstRows(tb.estimatedRows!)].join(' · '), style: tt.bodySmall),
                              trailing: const Icon(LucideIcons.chevronRight, size: 18),
                              onTap: () => showTableSheet(context, ref, hostId, conn, tb),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
  }
}

/// Columns, indexes, estimated rows of a table and a preview of its first rows.
Future<void> showTableSheet(BuildContext context, WidgetRef ref, String hostId, DbConnection conn, DbTable table) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TableSheet(hostId: hostId, conn: conn, table: table),
  );
}

class _TableSheet extends ConsumerStatefulWidget {
  const _TableSheet({required this.hostId, required this.conn, required this.table});
  final String hostId;
  final DbConnection conn;
  final DbTable table;

  @override
  ConsumerState<_TableSheet> createState() => _TableSheetState();
}

class _TableSheetState extends ConsumerState<_TableSheet> {
  DbResult? _preview;
  Object? _error;
  bool _loading = false;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await DbApi(ref, widget.hostId).preview(widget.conn.id, widget.table);
      if (mounted) setState(() => _preview = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final tb = widget.table;
    final mono = TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: t.text);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${tb.schema} · ${dbKindName(l, tb.kind)}', style: tt.bodySmall),
              Text(tb.name, style: tt.titleLarge?.copyWith(fontFamily: monoFamily, fontSize: 18)),
              if (tb.estimatedRows != null) Text(l.dbEstRows(tb.estimatedRows!), style: tt.bodySmall),
              SectionLabel(l.dbColumns),
              TCard(
                radius: TiphysTokens.radiusList,
                child: Column(
                  children: [
                    for (final c in tb.columns)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: Text(c.name, style: mono.copyWith(fontWeight: c.primaryKey ? FontWeight.w700 : FontWeight.w400)),
                            ),
                            Expanded(
                              flex: 5,
                              child: Text([c.type, if (c.primaryKey) 'PK', if (!c.nullable) 'NOT NULL'].join(' · '), style: tt.bodySmall, textAlign: TextAlign.right),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (tb.indexes.isNotEmpty) ...[
                SectionLabel(l.dbIndexes),
                TCard(
                  radius: TiphysTokens.radiusList,
                  child: Column(
                    children: [
                      for (final i in tb.indexes)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 5, child: Text(i.name, style: mono)),
                              Expanded(
                                flex: 5,
                                child: Text([i.definition, if (i.primary) 'PK' else if (i.unique) l.dbUnique].join(' · '), style: tt.bodySmall, textAlign: TextAlign.right),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              SectionLabel(l.dbPreviewTable),
              if (_preview == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _load,
                    icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.eye, size: 16),
                    label: Text(l.dbPreviewLoad(dbPreviewRows)),
                  ),
                )
              else
                DbResultView(result: _preview!),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: DbNote(agentErrorText(l, _error!), color: t.danger),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonClose)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
