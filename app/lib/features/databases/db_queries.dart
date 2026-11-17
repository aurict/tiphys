// Saved queries (PLAN.md §13.2, D-2): the list, the run sheet (table or chart per the chart config, CSV share) and the
// create/edit form with the chart pickers, which offer the columns the query returns (y: numeric columns only).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'db_data.dart';
import 'db_editor.dart' show SqlController, csvButton, sqlTextStyle;
import 'db_result_view.dart';
import 'db_texts.dart';

class DbQueriesTab extends ConsumerWidget {
  const DbQueriesTab({super.key, required this.hostId, required this.conn, required this.onOpenInEditor});
  final String hostId;
  final DbConnection conn;
  final void Function(String sql) onOpenInEditor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final key = (hostId, conn.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () async {
              if (await showQueryForm(context, hostId: hostId, conn: conn) == true) ref.invalidate(dbQueriesProvider(key));
            },
            icon: const Icon(LucideIcons.plus, size: 17),
            label: Text(l.dbQueryNew),
          ),
        ),
        const SizedBox(height: 8),
        ref
            .watch(dbQueriesProvider(key))
            .when(
              skipLoadingOnRefresh: true,
              loading: () => const Padding(
                padding: EdgeInsets.all(30),
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
                    TextButton(onPressed: () => ref.invalidate(dbQueriesProvider(key)), child: Text(l.commonRetry)),
                  ],
                ),
              ),
              data: (list) => list.isEmpty
                  ? TCard(child: Text(l.dbQueriesEmpty))
                  : GroupedSection(
                      children: [
                        for (final q in list)
                          GroupedRow(
                            title: q.name,
                            subtitle: q.sql.replaceAll(RegExp(r'\s+'), ' '),
                            icon: switch (q.chart.type) {
                              'line' => LucideIcons.chartLine,
                              'bar' => LucideIcons.chartColumn,
                              'stat' => LucideIcons.hash,
                              _ => LucideIcons.table,
                            },
                            onTap: () async {
                              final changed = await showQueryRunSheet(context, hostId: hostId, conn: conn, query: q, onOpenInEditor: onOpenInEditor);
                              if (changed == true) ref.invalidate(dbQueriesProvider(key));
                            },
                          ),
                      ],
                    ),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Run sheet

Future<bool?> showQueryRunSheet(BuildContext context, {required String hostId, required DbConnection conn, required DbSavedQuery query, required void Function(String sql) onOpenInEditor}) {
  return showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _RunSheet(hostId: hostId, conn: conn, query: query, onOpenInEditor: onOpenInEditor),
  );
}

class _RunSheet extends ConsumerStatefulWidget {
  const _RunSheet({required this.hostId, required this.conn, required this.query, required this.onOpenInEditor});
  final String hostId;
  final DbConnection conn;
  final DbSavedQuery query;
  final void Function(String sql) onOpenInEditor;

  @override
  ConsumerState<_RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends ConsumerState<_RunSheet> {
  DbResult? _result;
  Object? _error;
  bool _loading = true;
  late DbSavedQuery _query = widget.query;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await DbApi(ref, widget.hostId).runSaved(_query.id);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit() async {
    final saved = await showQueryForm(context, hostId: widget.hostId, conn: widget.conn, existing: _query);
    if (saved is DbSavedQuery && mounted) {
      _changed = true;
      setState(() => _query = saved);
      _run();
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.dbQueryDeleteConfirm(_query.name), confirmLabel: l.commonDelete, destructive: true) || !mounted) return;
    try {
      await agentCall(ref, widget.hostId, 'DELETE', '/v1/db/queries/${_query.id}');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final r = _result;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${l.dbQueryChart}: ${dbChartName(l, _query.chart.type)}', style: tt.bodySmall),
                Text(_query.name, style: tt.titleLarge),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  DbNote(agentErrorText(l, _error!), color: t.danger)
                else if (r != null) ...[
                  DbChartView(result: r, config: r.chart ?? _query.chart),
                  const SizedBox(height: 4),
                  Text(l.dbRowsSummary(r.rowCount, r.elapsedMs ?? 0), style: tt.bodySmall),
                  if (r.truncated) Padding(padding: const EdgeInsets.only(top: 8), child: DbNote(l.dbTruncatedBanner(r.rowCount))),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(onPressed: _loading ? null : _run, icon: const Icon(LucideIcons.refreshCw, size: 16), label: Text(l.dbQueryRun)),
                    csvButton(context, ref, hostId: widget.hostId, path: '/v1/db/queries/${_query.id}/export', body: const {}, name: _query.id),
                    OutlinedButton.icon(onPressed: _edit, icon: const Icon(LucideIcons.pencil, size: 16), label: Text(l.commonEdit)),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context, _changed);
                        widget.onOpenInEditor(_query.sql);
                      },
                      icon: const Icon(LucideIcons.squareTerminal, size: 16),
                      label: Text(l.dbOpenInEditor),
                    ),
                    TextButton.icon(
                      onPressed: _delete,
                      style: TextButton.styleFrom(foregroundColor: t.danger),
                      icon: const Icon(LucideIcons.trash2, size: 16),
                      label: Text(l.commonDelete),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => Navigator.pop(context, _changed), child: Text(l.commonClose)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Create / edit form

/// Result: true (created) / the saved query (edited) / null (cancelled).
Future<Object?> showQueryForm(BuildContext context, {required String hostId, required DbConnection conn, DbSavedQuery? existing, String? sql}) {
  return showModalBottomSheet<Object>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => QueryFormSheet(hostId: hostId, conn: conn, existing: existing, initialSql: sql),
  );
}

class QueryFormSheet extends ConsumerStatefulWidget {
  const QueryFormSheet({super.key, required this.hostId, required this.conn, this.existing, this.initialSql});
  final String hostId;
  final DbConnection conn;
  final DbSavedQuery? existing;
  final String? initialSql;

  @override
  ConsumerState<QueryFormSheet> createState() => _QueryFormSheetState();
}

class _QueryFormSheetState extends ConsumerState<QueryFormSheet> {
  final _name = TextEditingController();
  late final _sql = SqlController();
  String _type = 'table';
  String? _x;
  List<String> _y = [];

  /// Columns the query returns (from a run); the pickers offer these.
  List<DbResultColumn>? _columns;
  bool _loadingCols = false;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _sql.text = e?.sql ?? widget.initialSql ?? '';
    if (e != null) {
      _name.text = e.name;
      _type = e.chart.type;
      _x = e.chart.x;
      _y = [...e.chart.y];
      if (_type != 'table') _loadColumns();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _sql.dispose();
    super.dispose();
  }

  Future<void> _loadColumns() async {
    if (_sql.text.trim().isEmpty) return;
    setState(() {
      _loadingCols = true;
      _error = null;
    });
    try {
      final r = await DbApi(ref, widget.hostId).query(widget.conn.id, _sql.text, limit: 20);
      if (!mounted) return;
      setState(() {
        _columns = r.columns;
        if (_type != 'table' && (_y.isEmpty || (_x != null && !r.columns.any((c) => c.name == _x)))) {
          final s = suggestChart(_type, r.columns);
          _x = s.x;
          _y = [...s.y];
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loadingCols = false);
    }
  }

  void _pickType(String type) {
    setState(() {
      _type = type;
      final cols = _columns;
      if (cols != null) {
        final s = suggestChart(type, cols);
        _x = s.x;
        _y = [...s.y];
      }
    });
    if (type != 'table' && _columns == null) _loadColumns();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty || _sql.text.trim().isEmpty) {
      setState(() => _error = null);
      toast(context, l.commonRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final chart = DbChartConfig.of(_type, x: _x, y: _y).toJson();
      final body = {'name': _name.text.trim(), 'sql': _sql.text, 'chart': chart};
      final e = widget.existing;
      final Object? out;
      if (e == null) {
        await agentCall(ref, widget.hostId, 'POST', '/v1/db/queries', {'connectionId': widget.conn.id, ...body});
        out = true;
      } else {
        out = DbSavedQuery(Map<String, dynamic>.from(await agentCall(ref, widget.hostId, 'PATCH', '/v1/db/queries/${e.id}', body) as Map));
      }
      if (mounted) Navigator.pop(context, out);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final cols = _columns;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final yOptions = cols == null ? [for (final n in _y) DbResultColumn(n, null, 'number')] : chartYCandidates(cols);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16 + bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.existing == null ? l.dbQueryNew : l.dbQueryEdit, style: tt.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: l.dbQueryName),
                maxLength: 80,
              ),
              TextField(
                controller: _sql,
                minLines: 4,
                maxLines: 10,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                style: sqlTextStyle(t),
                decoration: InputDecoration(labelText: l.dbQuerySql, alignLabelWithHint: true),
                onChanged: (_) => _columns = null,
              ),
              SectionLabel(l.dbQueryChart),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [for (final c in chartTypes) ChoiceChip(label: Text(dbChartName(l, c)), selected: _type == c, onSelected: (_) => _pickType(c))],
              ),
              if (_type != 'table') ...[
                const SizedBox(height: 10),
                if (cols == null)
                  Row(
                    children: [
                      Expanded(child: Text(l.dbChartNoColumns, style: tt.bodySmall)),
                      OutlinedButton.icon(
                        onPressed: _loadingCols ? null : _loadColumns,
                        icon: _loadingCols ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.play, size: 16),
                        label: Text(l.dbChartLoadColumns),
                      ),
                    ],
                  )
                else ...[
                  if (_type != 'stat')
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: cols.any((c) => c.name == _x) ? _x : null,
                      decoration: InputDecoration(labelText: l.dbChartX),
                      items: [for (final c in chartXCandidates(cols)) DropdownMenuItem(value: c.name, child: Text('${c.name} (${c.kind})'))],
                      onChanged: (v) => setState(() => _x = v),
                    ),
                  const SizedBox(height: 8),
                  Text(_type == 'stat' ? l.dbChartStatColumn : l.dbChartY, style: tt.bodySmall),
                  if (yOptions.isEmpty)
                    Padding(padding: const EdgeInsets.only(top: 6), child: DbNote(l.dbChartNoNumeric))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final c in yOptions)
                          FilterChip(
                            label: Text(c.name),
                            selected: _y.contains(c.name),
                            onSelected: (on) => setState(() {
                              if (_type == 'stat') {
                                _y = [c.name];
                              } else if (on) {
                                if (_y.length < maxChartY) _y = [..._y, c.name];
                              } else {
                                _y = [..._y]..remove(c.name);
                              }
                            }),
                          ),
                      ],
                    ),
                ],
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DbNote(agentErrorText(l, _error!), color: t.danger),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(l.commonCancel)),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.commonSave),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
