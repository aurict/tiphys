// SQL editor tab (PLAN.md §13.2, D-1..D-3): monospace editor with simple keyword highlighting, limit/timeout, results
// table, CSV share, save as saved query, the write mode (app lock each time it is turned on; preview → confirm →
// commit in a sheet) and the read-only role helper.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import '../vault/vault_state.dart' show sensitiveClipboardProvider, vaultAuthProvider;
import 'db_data.dart';
import 'db_form.dart' show DbFormArgs;
import 'db_queries.dart' show showQueryForm;
import 'db_result_view.dart';
import 'db_texts.dart';

final _sqlToken = RegExp(
  r"(--[^\n]*|/\*[\s\S]*?\*/)|('(?:[^']|'')*'?)|(\b\d+(?:\.\d+)?\b)|\b(select|from|where|group|by|order|having|limit|offset|join|left|right|inner|outer|full|cross|on|as|and|or|not|in|is|null|like|ilike|between|case|when|then|else|end|distinct|union|all|with|insert|into|values|update|set|delete|create|alter|drop|table|index|view|returning|explain|show|asc|desc|count|sum|avg|min|max|exists)\b",
  caseSensitive: false,
);

TextStyle sqlTextStyle(TiphysTokens t) => TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.4, color: t.text, fontFeatures: const [FontFeature.disable('calt'), FontFeature.disable('liga')]);

/// A text controller that colors comments, strings, numbers and the common keywords. Presentation only: the agent does
/// the real statement checking.
class SqlController extends TextEditingController {
  SqlController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = context.tokens;
    final base = (style ?? const TextStyle()).merge(sqlTextStyle(t));
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _sqlToken.allMatches(text)) {
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      final color = m.group(1) != null
          ? t.textSecondary
          : m.group(2) != null
          ? t.success
          : m.group(3) != null
          ? t.warning
          : t.accent;
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(color: color, fontWeight: m.group(4) != null ? FontWeight.w700 : null, fontStyle: m.group(1) != null ? FontStyle.italic : null),
        ),
      );
      pos = m.end;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(style: base, children: spans);
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// CSV button

Widget csvButton(BuildContext context, WidgetRef ref, {required String hostId, required String path, required Object body, required String name, bool enabled = true}) => CsvButton(hostId: hostId, path: path, body: body, name: name, enabled: enabled);

/// "Share CSV": streams the export to a temp file and hands it to the Android share sheet.
class CsvButton extends ConsumerStatefulWidget {
  const CsvButton({super.key, required this.hostId, required this.path, required this.body, required this.name, this.enabled = true});
  final String hostId;
  final String path;
  final Object body;
  final String name;
  final bool enabled;

  @override
  ConsumerState<CsvButton> createState() => _CsvButtonState();
}

class _CsvButtonState extends ConsumerState<CsvButton> {
  bool _busy = false;

  Future<void> _run() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final out = await shareCsv(ref, widget.hostId, widget.path, widget.body, name: csvFileName(widget.name, ref.read(clockProvider)()));
      if (mounted) toast(context, out.truncated ? '${l.dbCsvDone(out.rows)} ${l.dbCsvMaybeTruncated}' : l.dbCsvDone(out.rows));
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return OutlinedButton.icon(
      onPressed: _busy || !widget.enabled ? null : _run,
      icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.share2, size: 16),
      label: Text(_busy ? l.dbCsvBusy : l.dbCsvShare),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Editor tab

class DbEditorTab extends ConsumerStatefulWidget {
  const DbEditorTab({super.key, required this.hostId, required this.conn, required this.incoming, required this.roleRequest});
  final String hostId;
  final DbConnection conn;

  /// SQL pushed from elsewhere (a saved query, the role helper); taken once.
  final ValueNotifier<String?> incoming;

  /// Bumped to open the read-only role helper ("Use a read-only role").
  final ValueNotifier<int> roleRequest;

  @override
  ConsumerState<DbEditorTab> createState() => _DbEditorTabState();
}

class _DbEditorTabState extends ConsumerState<DbEditorTab> {
  final _sql = SqlController();
  final _limit = TextEditingController(text: '$dbDefaultLimit');
  final _timeout = TextEditingController(text: '$dbDefaultTimeoutSec');
  DbResult? _result;

  /// The SQL and timeout that produced [_result]: the CSV export repeats exactly that, not what the editor holds now.
  String _resultSql = '';
  int _resultTimeout = dbDefaultTimeoutSec;
  Object? _error;
  bool _running = false;
  String? _note;

  DbConnRef get _key => (widget.hostId, widget.conn.id);

  @override
  void initState() {
    super.initState();
    widget.incoming.addListener(_takeIncoming);
    _takeIncoming();
  }

  @override
  void dispose() {
    widget.incoming.removeListener(_takeIncoming);
    _sql.dispose();
    _limit.dispose();
    _timeout.dispose();
    super.dispose();
  }

  void _takeIncoming() {
    final s = widget.incoming.value;
    if (s == null) return;
    widget.incoming.value = null;
    _sql.text = s;
    setState(() {
      _result = null;
      _error = null;
    });
  }

  int get _limitValue => (int.tryParse(_limit.text.trim()) ?? dbDefaultLimit).clamp(1, dbMaxLimit);
  int get _timeoutValue => (int.tryParse(_timeout.text.trim()) ?? dbDefaultTimeoutSec).clamp(1, dbMaxTimeoutSec);

  Future<void> _run() async {
    if (_sql.text.trim().isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _note = null;
    });
    final sql = _sql.text, timeout = _timeoutValue;
    try {
      final r = await DbApi(ref, widget.hostId).query(widget.conn.id, sql, limit: _limitValue, timeoutSec: timeout);
      if (mounted) {
        setState(() {
          _result = r;
          _resultSql = sql;
          _resultTimeout = timeout;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _result = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The app lock is asked every time the write mode is turned on; without a lock it can't be.
  Future<void> _toggleWrite(bool on) async {
    final l = AppLocalizations.of(context);
    final mode = ref.read(dbWriteModeProvider(_key).notifier);
    if (!on) return mode.set(false);
    if (!widget.conn.canWrite) return toast(context, l.errDbWriteUnsupported);
    if (!await ref.read(dbWriteLockAvailableProvider.future)) {
      if (mounted) toast(context, l.dbWriteNeedsLock);
      return;
    }
    if (!mounted) return;
    if (await ref.read(vaultAuthProvider)(context) && mounted) mode.set(true);
  }

  Future<void> _preview() async {
    final sql = _sql.text.trim();
    if (sql.isEmpty) return;
    final l = AppLocalizations.of(context);
    final done = await showDbWriteSheet(context, hostId: widget.hostId, conn: widget.conn, sql: sql, timeoutSec: _timeoutValue);
    if (done == true && mounted) {
      ref.invalidate(dbSchemaProvider(_key));
      setState(() => _note = l.dbWriteDoneNote);
    }
  }

  Future<void> _saveQuery() async {
    if (_sql.text.trim().isEmpty) return;
    final saved = await showQueryForm(context, hostId: widget.hostId, conn: widget.conn, sql: _sql.text);
    if (saved == true && mounted) {
      ref.invalidate(dbQueriesProvider(_key));
      toast(context, AppLocalizations.of(context).dbSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final write = ref.watch(dbWriteModeProvider(_key));
    final r = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _sql,
          minLines: 6,
          maxLines: 12,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            hintText: l.dbEditorHint,
            filled: true,
            fillColor: t.card,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(TiphysTokens.radiusList)),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.dbLimit, helperText: '1–$dbMaxLimit'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _timeout,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.dbTimeout, helperText: '1–$dbMaxTimeoutSec'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.play, size: 16),
              label: Text(l.dbRun),
            ),
            if (write)
              FilledButton.icon(
                onPressed: _preview,
                style: FilledButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white),
                icon: const Icon(LucideIcons.scanEye, size: 16),
                label: Text(l.dbPreviewBtn),
              ),
            OutlinedButton.icon(onPressed: _saveQuery, icon: const Icon(LucideIcons.save, size: 16), label: Text(l.dbSaveAsQuery)),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.conn.canWrite)
          TCard(
            radius: TiphysTokens.radiusList,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            borderColor: write ? t.danger : null,
            child: SwitchListTile(value: write, onChanged: _toggleWrite, activeThumbColor: t.danger, title: Text(l.dbWriteMode), subtitle: Text(l.dbWriteModeHint), contentPadding: const EdgeInsets.symmetric(horizontal: 8)),
          )
        else
          Text(l.errDbWriteUnsupported, style: Theme.of(context).textTheme.bodySmall),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: DbNote(_note!, color: t.success, icon: LucideIcons.circleCheck),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: superuserReadsDisabled(_error!)
                ? SuperuserReadsNote(hostId: widget.hostId, conn: widget.conn, error: _error!, onUseRole: () => widget.roleRequest.value++)
                : DbNote(agentErrorText(l, _error!), color: t.danger),
          ),
        if (r != null) ...[
          const SizedBox(height: 14),
          DbResultView(
            result: r,
            actions: [
              CsvButton(hostId: widget.hostId, path: '/v1/db/connections/${widget.conn.id}/export', body: {'sql': _resultSql, 'timeoutMs': _resultTimeout * 1000}, name: widget.conn.id),
            ],
          ),
        ],
        if (widget.conn.canWrite) _RoleHelper(hostId: widget.hostId, conn: widget.conn, onRunInWriteMode: _runRoleInWriteMode, request: widget.roleRequest),
      ],
    );
  }

  Future<void> _runRoleInWriteMode(String sql) async {
    await _toggleWrite(true);
    if (!mounted || !ref.read(dbWriteModeProvider(_key))) return;
    _sql.text = sql;
    setState(() {
      _result = null;
      _error = null;
    });
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Read-only role helper

class _RoleHelper extends ConsumerStatefulWidget {
  const _RoleHelper({required this.hostId, required this.conn, required this.onRunInWriteMode, required this.request});
  final String hostId;
  final DbConnection conn;
  final Future<void> Function(String sql) onRunInWriteMode;
  final ValueNotifier<int> request;

  @override
  ConsumerState<_RoleHelper> createState() => _RoleHelperState();
}

class _RoleHelperState extends ConsumerState<_RoleHelper> {
  RoleSql? _role;
  Object? _error;
  bool _loading = false;
  final _box = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.request.addListener(_requested);
  }

  @override
  void dispose() {
    widget.request.removeListener(_requested);
    super.dispose();
  }

  /// "Use a read-only role": show the helper (and its SQL).
  Future<void> _requested() async {
    if (_role == null && !_loading) await _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _box.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final j = await DbApi(ref, widget.hostId).call('GET', '/v1/db/connections/${widget.conn.id}/readonly-role-sql');
      if (mounted) setState(() => _role = RoleSql(Map<String, dynamic>.from(j as Map)));
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
    final role = _role;
    return Padding(
      key: _box,
      padding: const EdgeInsets.only(top: 14),
      child: TCard(
        radius: TiphysTokens.radiusList,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.shieldCheck, size: 18, color: t.accent),
                const SizedBox(width: 8),
                Expanded(child: Text(l.dbRoleTitle, style: tt.titleMedium)),
              ],
            ),
            const SizedBox(height: 4),
            Text(l.dbRoleHint, style: tt.bodySmall),
            const SizedBox(height: 8),
            if (role == null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _loading ? null : _load,
                  child: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.dbRoleShow),
                ),
              )
            else ...[
              DbSecure(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: t.separator.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                  child: Text(role.text, style: sqlTextStyle(t).copyWith(fontSize: 12)),
                ),
              ),
              const SizedBox(height: 6),
              Text(l.dbRolePasswordNote, style: tt.bodySmall),
              if (!role.viaWriteMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(l.dbRoleClient, style: tt.bodySmall),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      await ref.read(sensitiveClipboardProvider).copy(role.text);
                      if (context.mounted) toast(context, l.commonCopied);
                    },
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: Text(l.commonCopy),
                  ),
                  if (role.viaWriteMode) FilledButton.icon(onPressed: () => widget.onRunInWriteMode(role.text), icon: const Icon(LucideIcons.pencilLine, size: 16), label: Text(l.dbRoleRunWrite)),
                  // PostgreSQL: once the role exists, reads can switch to it (the connection form, prefilled).
                  if (widget.conn.isPostgres && widget.conn.readRole != role.role)
                    OutlinedButton.icon(
                      onPressed: () => context.push('/db/form', extra: DbFormArgs(hostId: widget.hostId, existing: widget.conn, readRole: role.role)),
                      icon: const Icon(LucideIcons.userCheck, size: 16),
                      label: Text(l.dbRoleSetRead),
                    ),
                ],
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: DbNote(agentErrorText(l, _error!), color: t.danger),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Write preview sheet

/// Opens the write preview sheet; true when the statement was committed (also when the sheet is closed by the barrier
/// or back after the commit). [timeoutSec]: the editor's statement timeout, sent with the preview.
Future<bool?> showDbWriteSheet(BuildContext context, {required String hostId, required DbConnection conn, required String sql, int timeoutSec = dbDefaultTimeoutSec}) async {
  var committed = false;
  final r = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    // No drag-to-dismiss: a drag would close the sheet while the commit runs (PopScope only stops back and barrier).
    enableDrag: false,
    builder: (_) => DbWriteSheet(hostId: hostId, conn: conn, sql: sql, timeoutSec: timeoutSec, onCommitted: () => committed = true),
  );
  return r ?? (committed ? true : null);
}

class DbWriteSheet extends ConsumerStatefulWidget {
  const DbWriteSheet({super.key, required this.hostId, required this.conn, required this.sql, this.timeoutSec = dbDefaultTimeoutSec, this.onCommitted});
  final String hostId;
  final DbConnection conn;
  final String sql;
  final int timeoutSec;

  /// Called once the commit succeeded.
  final VoidCallback? onCommitted;

  @override
  ConsumerState<DbWriteSheet> createState() => _DbWriteSheetState();
}

/// Client timeout of a commit: the agent's longest statement timeout plus 15 s of slack (DbApi adds 10 to this), so a
/// slow commit isn't cut off on the phone while it still runs on the server.
const dbCommitTimeoutSec = dbMaxTimeoutSec + 5;

class _DbWriteSheetState extends ConsumerState<DbWriteSheet> {
  late final WriteFlow _flow;
  Timer? _tick;
  bool _confirming = false;

  /// "Outcome unknown": the user's read query to check what the commit did, and its answer.
  final _check = SqlController();
  DbResult? _checkResult;
  Object? _checkError;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final api = DbApi(ref, widget.hostId);
    final base = '/v1/db/connections/${widget.conn.id}/write';
    _flow =
        WriteFlow(
          previewFn: (sql) => api.call('POST', '$base/preview', body: {'sql': sql, 'timeoutMs': widget.timeoutSec * 1000}, timeoutSec: widget.timeoutSec),
          commitFn: (token) => api.call('POST', '$base/commit', body: {'previewToken': token, 'confirm': true}, timeoutSec: dbCommitTimeoutSec),
          clock: ref.read(clockProvider),
        )..addListener(() {
          if (_flow.stage == WriteStage.done) widget.onCommitted?.call();
          if (mounted) setState(() {});
        });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        _flow.tick();
        setState(() {});
      }
    });
    _flow.run(widget.sql);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _flow.dispose();
    _check.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    final p = _flow.preview;
    if (p == null || !_flow.canCommit || _confirming) return;
    _confirming = true;
    final bool ok;
    try {
      ok = await confirmDialog(context, message: l.dbCommitConfirm(p.statement.isEmpty ? 'SQL' : p.statement.toUpperCase()), confirmLabel: l.dbCommit, destructive: true);
    } finally {
      _confirming = false;
    }
    if (!ok || !mounted) return;
    await _flow.confirm();
  }

  /// Runs the user's read query (after an unknown commit outcome) with the read credential.
  Future<void> _runCheck() async {
    final sql = _check.text.trim();
    if (sql.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final r = await DbApi(ref, widget.hostId).query(widget.conn.id, sql, limit: 50, timeoutSec: dbDefaultTimeoutSec);
      if (mounted) setState(() => _checkResult = r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _checkError = e;
          _checkResult = null;
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final f = _flow;
    final p = f.preview;
    final err = f.error;
    final stage = f.stage;
    return PopScope(
      canPop: !f.busy,
      child: DbSecure(
        child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.dbPreviewTitle, style: tt.bodySmall),
                Text(widget.conn.name, style: tt.titleLarge),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: t.separator.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                  child: Text(widget.sql, maxLines: 6, overflow: TextOverflow.ellipsis, style: sqlTextStyle(t).copyWith(fontSize: 12)),
                ),
                if (p != null && stage == WriteStage.ready) ...[const SizedBox(height: 8), _Countdown(remaining: p.remaining(ref.read(clockProvider)()))],
                const SizedBox(height: 12),
                if (stage == WriteStage.previewing)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (p != null && (stage == WriteStage.ready || stage == WriteStage.committing)) ...[
                  TCard(
                    radius: TiphysTokens.radiusList,
                    child: Row(
                      children: [
                        Icon(p.isDdl ? LucideIcons.tableProperties : LucideIcons.rows3, size: 22, color: t.danger),
                        const SizedBox(width: 12),
                        Expanded(child: Text(p.isDdl ? l.dbPreviewDdl(p.statement) : l.dbPreviewAffected(p.count ?? 0), style: tt.titleMedium)),
                      ],
                    ),
                  ),
                  for (final w in p.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: DbNote(dbWarningText(l, w), icon: LucideIcons.shieldAlert),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(p.credential == 'write' ? l.dbPreviewCredWrite : l.dbPreviewCredRead, style: tt.bodySmall),
                  ),
                  if (!p.isDdl && p.sampleRows.isNotEmpty) ...[
                    SectionLabel(l.dbPreviewSample(p.sampleRows.length)),
                    DbResultTable(
                      result: DbResult({
                        'columns': [
                          for (final c in p.sampleColumns) {'name': c},
                        ],
                        'rows': p.sampleRows,
                      }),
                    ),
                  ] else if (!p.isDdl && (p.count ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(l.dbPreviewNoSample, style: tt.bodySmall),
                    ),
                  const SizedBox(height: 6),
                  Text(l.dbPreviewRolledBack, style: tt.bodySmall),
                ],
                if (stage == WriteStage.committing)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Row(
                      children: [
                        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Text(l.dbCommitting),
                      ],
                    ),
                  ),
                if (stage == WriteStage.done) DbNote(f.committed == null ? l.dbCommittedDdl : l.dbCommitted(f.committed!), color: t.success, icon: LucideIcons.circleCheck),
                if (stage == WriteStage.countChanged) DbNote(l.dbCountChangedBody(f.expected ?? 0, f.actual ?? 0), color: t.danger, icon: LucideIcons.triangleAlert),
                if (stage == WriteStage.expired) DbNote(l.incPreviewExpired, color: t.danger),
                if (stage == WriteStage.failed && err != null) DbNote(agentErrorText(l, err), color: t.danger),
                if (stage == WriteStage.unknown) ...[
                  DbNote(l.dbCommitUnknownBody, title: l.dbCommitUnknownTitle, color: t.danger, icon: LucideIcons.circleHelp),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _check,
                    minLines: 2,
                    maxLines: 5,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(hintText: l.dbCheckHint, border: OutlineInputBorder(borderRadius: BorderRadius.circular(TiphysTokens.radiusList))),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _checking ? null : _runCheck,
                    icon: _checking ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.listChecks, size: 16),
                    label: Text(l.dbCheckRows),
                  ),
                  if (_checkError != null) Padding(padding: const EdgeInsets.only(top: 8), child: DbNote(agentErrorText(l, _checkError!), color: t.danger)),
                  if (_checkResult != null) Padding(padding: const EdgeInsets.only(top: 8), child: DbResultView(result: _checkResult!)),
                ],
                if (stage == WriteStage.ready && err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: DbNote(agentErrorText(l, err), color: t.danger),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(onPressed: f.busy ? null : () => Navigator.pop(context, stage == WriteStage.done), child: Text(stage == WriteStage.done ? l.commonClose : l.commonCancel)),
                    const Spacer(),
                    if (stage == WriteStage.countChanged || stage == WriteStage.expired || stage == WriteStage.failed)
                      OutlinedButton.icon(onPressed: f.busy ? null : f.rePreview, icon: const Icon(LucideIcons.refreshCw, size: 16), label: Text(stage == WriteStage.countChanged ? l.dbRePreview : l.incPreviewRefresh))
                    else if (stage == WriteStage.ready || stage == WriteStage.committing)
                      FilledButton(
                        onPressed: f.canCommit ? _confirm : null,
                        style: FilledButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white),
                        child: Text(l.dbCommit),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.remaining});
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final low = remaining < const Duration(seconds: 20);
    final s = remaining.inSeconds;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.timer, size: 15, color: low ? t.danger : t.textSecondary),
        const SizedBox(width: 4),
        Text(l.incPreviewExpiresIn('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'), style: TextStyle(fontSize: 12.5, color: low ? t.danger : t.textSecondary)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Superuser reads (PostgreSQL)

/// The agent refused a read because the login is a superuser and the connection has neither a read role nor the
/// accepted risk (`agent.db.superuserReadsDisabled`).
bool superuserReadsDisabled(Object e) => e is AgentError && e.code == 'agent.db.superuserReadsDisabled';

/// Why reads are refused, with the two ways out: a read-only role (the role helper, then the connection form) or
/// accepting the risk. When the read role itself is a superuser only the explanation is shown.
class SuperuserReadsNote extends ConsumerWidget {
  const SuperuserReadsNote({super.key, required this.hostId, required this.conn, this.error, required this.onUseRole});
  final String hostId;
  final DbConnection conn;
  final Object? error;
  final VoidCallback onUseRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final e = error;
    final roleIsSuperuser = e is AgentError && e.params['readRole'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DbNote(roleIsSuperuser ? l.errDbReadRoleSuperuser : l.errDbSuperuserReadsDisabled, color: t.danger, icon: LucideIcons.shieldAlert),
        if (!roleIsSuperuser) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(onPressed: onUseRole, icon: const Icon(LucideIcons.shieldCheck, size: 16), label: Text(l.dbUseReadRole)),
              OutlinedButton.icon(
                onPressed: () => acceptSuperuserReads(context, ref, hostId, conn),
                style: OutlinedButton.styleFrom(foregroundColor: t.danger),
                icon: const Icon(LucideIcons.triangleAlert, size: 16),
                label: Text(l.dbAcceptRisk),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Accept the risk": a confirmation with a required "I understand" tick, then `allowSuperuserReads: true`.
Future<void> acceptSuperuserReads(BuildContext context, WidgetRef ref, String hostId, DbConnection conn) async {
  final l = AppLocalizations.of(context);
  if (!await confirmSuperuserReads(context, conn.name) || !context.mounted) return;
  try {
    await agentCall(ref, hostId, 'PATCH', '/v1/db/connections/${conn.id}', {'allowSuperuserReads': true});
    ref.invalidate(dbConnectionsProvider(hostId));
    if (context.mounted) toast(context, l.dbSaved);
  } catch (e) {
    if (context.mounted) toast(context, agentErrorText(l, e));
  }
}

/// The strong confirmation of superuser reads: the risk spelled out and a tick box before the button works.
Future<bool> confirmSuperuserReads(BuildContext context, String connName) async {
  final r = await showDialog<bool>(context: context, builder: (_) => _RiskDialog(connName: connName));
  return r ?? false;
}

class _RiskDialog extends StatefulWidget {
  const _RiskDialog({required this.connName});
  final String connName;

  @override
  State<_RiskDialog> createState() => _RiskDialogState();
}

class _RiskDialogState extends State<_RiskDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return AlertDialog(
      title: Text(l.dbAcceptRisk),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.dbAcceptRiskConfirm(widget.connName)),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l.dbAcceptRiskCheck),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.commonCancel)),
        FilledButton(
          onPressed: _understood ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(backgroundColor: t.danger, foregroundColor: Colors.white),
          child: Text(l.dbAcceptRiskBtn),
        ),
      ],
    );
  }
}
