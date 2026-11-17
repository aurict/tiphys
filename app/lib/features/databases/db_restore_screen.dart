// Backup restore tests (PLAN.md §13.2, D-4): the list per agent (status, last run, next run, run now with polling), the
// results history of a test with the failure reason, and the create/edit form. The restore itself happens on the
// agent in a throwaway container; nothing here touches a real database.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/schedules.dart' show ScheduleWhenPicker, scheduleTimeText, scheduleWhenText, scheduleWhenValid;
import '../files/files_screen.dart' show formatSize;
import '../incidents/incidents_data.dart' show exactHostFor;
import '../system/agent_providers.dart';
import 'db_data.dart';
import 'db_restore_data.dart';
import 'db_result_view.dart';
import 'db_texts.dart';

/// "/db/restore?host=argo&test=Nightly" (host: id or the agent's name; test: the test's name, highlighted).
String dbRestoreRoute({String? host, String? test}) {
  final q = [if (host != null) 'host=${Uri.encodeQueryComponent(host)}', if (test != null) 'test=${Uri.encodeQueryComponent(test)}'];
  return '/db/restore${q.isEmpty ? '' : '?${q.join('&')}'}';
}

class DbRestoreArgs {
  const DbRestoreArgs({required this.hostId, this.existing});
  final String hostId;
  final RestoreTest? existing;
}

class DbRestoreScreen extends ConsumerWidget {
  const DbRestoreScreen({super.key, this.hostHint, this.testName});
  final String? hostHint;
  final String? testName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(dbHostsProvider);
    Future<void> refresh() async {
      for (final h in hosts.value ?? const <Host>[]) {
        ref.invalidate(dbRestoreProvider(h.id));
      }
    }

    return SettingsPage(
      title: l.dbRestoreTitle,
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
        data: (all) {
          // A link names one host exactly or not at all: then every host is listed, each under its name.
          final hit = exactHostFor(all, hostHint);
          final list = hit == null ? all : [hit];
          if (list.isEmpty) return [TCard(child: Text(l.dbNoHosts))];
          return [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Text(l.dbRestoreHint, style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final h in list) _HostTests(host: h, highlight: testName),
          ];
        },
      ),
    );
  }
}

class _HostTests extends ConsumerWidget {
  const _HostTests({required this.host, required this.highlight});
  final Host host;
  final String? highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(dbRestoreProvider(host.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Always named: the run buttons below act on this host.
        SectionLabel(host.name),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => context.push('/db/restore/form', extra: DbRestoreArgs(hostId: host.id)),
              icon: const Icon(LucideIcons.plus, size: 17),
              label: Text(l.dbRestoreAdd),
            ),
          ),
        ),
        async.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
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
                TextButton(onPressed: () => ref.invalidate(dbRestoreProvider(host.id)), child: Text(l.commonRetry)),
              ],
            ),
          ),
          data: (d) => d.tests.isEmpty
              ? TCard(child: Text(l.dbRestoreEmpty))
              : Column(
                  children: [
                    for (final test in d.tests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _TestCard(host: host, test: test, busy: d.anyRunning, highlighted: test.name == highlight),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TestCard extends ConsumerWidget {
  const _TestCard({required this.host, required this.test, required this.busy, required this.highlighted});
  final Host host;
  final RestoreTest test;

  /// Some test is running (one at a time).
  final bool busy;
  final bool highlighted;

  Future<void> _run(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    try {
      await agentCall(ref, host.id, 'POST', '/v1/db/restore-tests/${test.id}/run');
      ref.invalidate(dbRestoreProvider(host.id));
      ref.invalidate(dbRestoreResultsProvider((host.id, test.id)));
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
      ref.invalidate(dbRestoreProvider(host.id));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.dbRestoreDeleteConfirm(test.name), confirmLabel: l.commonDelete, destructive: true) || !context.mounted) return;
    try {
      await agentCall(ref, host.id, 'DELETE', '/v1/db/restore-tests/${test.id}');
      ref.invalidate(dbRestoreProvider(host.id));
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = ref.read(clockProvider)();
    final last = test.last;
    final (icon, color, status) = test.running
        ? (LucideIcons.loader, t.accent, l.dbRestoreRunning)
        : last == null
        ? (LucideIcons.circleDashed, t.textSecondary, l.dbRestoreNever)
        : last.ok
        ? (LucideIcons.circleCheck, t.success, l.dbRestoreOk)
        : (LucideIcons.circleX, t.danger, l.dbRestoreFailed);
    return TCard(
      radius: TiphysTokens.radiusList,
      borderColor: highlighted ? t.accent : null,
      onTap: () => showRestoreResultsSheet(context, host: host, test: test),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              test.running ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: color)) : Icon(icon, size: 22, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(test.name, style: tt.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              PopupMenuButton<String>(
                tooltip: l.dbConnectionMenu,
                icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
                onSelected: (v) {
                  switch (v) {
                    case 'history':
                      showRestoreResultsSheet(context, host: host, test: test);
                    case 'edit':
                      context.push(
                        '/db/restore/form',
                        extra: DbRestoreArgs(hostId: host.id, existing: test),
                      );
                    case 'delete':
                      _delete(context, ref);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'history', child: Text(l.dbRestoreHistory)),
                  PopupMenuItem(value: 'edit', enabled: !test.running, child: Text(l.commonEdit)),
                  PopupMenuItem(value: 'delete', enabled: !test.running, child: Text(l.commonDelete)),
                ],
              ),
            ],
          ),
          Text(
            '$status${last?.finishedAt != null && !test.running ? ' · ${scheduleTimeText(l, locale, last!.finishedAt!, now)}' : ''}',
            style: tt.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
          if (!test.running && last != null && !last.ok)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(restoreReasonText(l, last.reason, last.detail), style: tt.bodySmall),
            ),
          const SizedBox(height: 4),
          Text(
            '${test.image} · ${test.format} · ${test.dumpGlob}',
            style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: t.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            test.schedule == null
                ? l.dbRestoreManualOnly
                : !test.enabled
                ? l.dbRestoreDisabled
                : '${scheduleWhenText(l, locale, test.schedule!)}${test.nextRunAt != null ? ' · ${l.dbRestoreNext(scheduleTimeText(l, locale, test.nextRunAt!, now))}' : ''}',
            style: tt.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(onPressed: busy ? null : () => _run(context, ref), icon: const Icon(LucideIcons.play, size: 16), label: Text(l.dbRestoreRunNow)),
              if (test.running)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(l.dbRestoreRunningHint, style: tt.bodySmall),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Results

Future<void> showRestoreResultsSheet(BuildContext context, {required Host host, required RestoreTest test}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ResultsSheet(host: host, test: test),
  );
}

class _ResultsSheet extends ConsumerWidget {
  const _ResultsSheet({required this.host, required this.test});
  final Host host;
  final RestoreTest test;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = ref.read(clockProvider)();
    final async = ref.watch(dbRestoreResultsProvider((host.id, test.id)));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.dbRestoreHistory, style: tt.bodySmall),
              Text(test.name, style: tt.titleLarge),
              const SizedBox(height: 12),
              ...async.when(
                loading: () => [
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                error: (e, _) => [DbNote(agentErrorText(l, e), color: t.danger)],
                data: (list) => list.isEmpty
                    ? [TCard(child: Text(l.dbRestoreNoResults))]
                    : [
                        for (final r in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TCard(
                              radius: TiphysTokens.radiusList,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(r.ok ? LucideIcons.circleCheck : LucideIcons.circleX, size: 20, color: r.ok ? t.success : t.danger),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(r.startedAt == null ? '' : scheduleTimeText(l, locale, r.startedAt!, now), style: tt.titleSmall)),
                                      Text(r.trigger == 'schedule' ? l.dbRestoreTriggerSchedule : l.dbRestoreTriggerManual, style: tt.bodySmall),
                                    ],
                                  ),
                                  if (!r.ok)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(restoreReasonText(l, r.reason, r.detail), style: tt.bodyMedium),
                                    ),
                                  for (final f in r.failures)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text('#${f.index + 1}: ${restoreFailureText(l, f.reason)}${f.reason == 'expectation' ? ' (${l.dbRfActual('${f.actual}', f.expected ?? '')})' : ''}', style: tt.bodySmall?.copyWith(color: t.danger)),
                                    ),
                                  const SizedBox(height: 6),
                                  Text(
                                    [
                                      if (r.dumpFile != null) '${r.dumpFile}${r.dumpBytes != null ? ' (${formatSize(r.dumpBytes!, locale)})' : ''}',
                                      if (r.image != null) r.image!,
                                      l.dbRestoreChecked(r.rowsChecked),
                                      if (r.totalMs != null) l.dbRestoreDuration((r.totalMs! / 1000).round()),
                                    ].join(' · '),
                                    style: tt.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
              ),
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

// ---------------------------------------------------------------------------------------------------------------------
// Form

class _SanityRow {
  _SanityRow(SanityCheck? s) : sql = TextEditingController(text: s?.sql ?? ''), value = TextEditingController(text: s == null ? '0' : '${s.value}'), op = s?.op ?? '>';
  final TextEditingController sql;
  final TextEditingController value;
  String op;
  void dispose() {
    sql.dispose();
    value.dispose();
  }
}

class DbRestoreFormScreen extends ConsumerStatefulWidget {
  const DbRestoreFormScreen({super.key, required this.args});
  final DbRestoreArgs args;

  @override
  ConsumerState<DbRestoreFormScreen> createState() => _DbRestoreFormScreenState();
}

class _DbRestoreFormScreenState extends ConsumerState<DbRestoreFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _image = TextEditingController();
  final _glob = TextEditingController();
  String _engine = 'postgres';
  String _format = 'gz';
  String? _connectionId;
  bool _scheduled = false;
  bool _enabled = true;
  Map<String, dynamic> _when = ScheduleWhenPicker.normalize(const {'kind': 'daily', 'time': '03:30'});
  final _sanity = <_SanityRow>[];
  bool _saving = false;
  Object? _error;

  RestoreTest? get _existing => widget.args.existing;

  @override
  void initState() {
    super.initState();
    final e = _existing;
    if (e != null) {
      _name.text = e.name;
      _image.text = e.image;
      _glob.text = e.dumpGlob;
      _engine = e.engine;
      _format = e.format;
      _connectionId = e.connectionId;
      _scheduled = e.schedule != null;
      _enabled = e.enabled;
      if (e.schedule != null) _when = ScheduleWhenPicker.normalize(e.schedule);
      for (final s in e.sanity) {
        _sanity.add(_SanityRow(s));
      }
    } else {
      _image.text = 'postgres:16';
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _image, _glob]) {
      c.dispose();
    }
    for (final s in _sanity) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (!(_form.currentState?.validate() ?? false) || _saving) return;
    if (_scheduled && !scheduleWhenValid(_when)) {
      setState(() => _error = null);
      toast(context, l.claudeScheduleNeedsDays);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final editing = _existing != null;
      final body = restoreTestBody(
        id: editing ? null : slugify(_name.text),
        name: _name.text.trim(),
        connectionId: _connectionId,
        engine: _engine,
        image: _image.text.trim(),
        dumpGlob: _glob.text.trim(),
        format: _format,
        sanity: [for (final s in _sanity) SanityCheck(s.sql.text.trim(), s.op, num.parse(s.value.text.trim()))],
        schedule: _scheduled ? _when : null,
        enabled: _enabled,
        editing: editing,
      );
      if (editing) {
        await agentCall(ref, widget.args.hostId, 'PATCH', '/v1/db/restore-tests/${_existing!.id}', body);
      } else {
        await agentCall(ref, widget.args.hostId, 'POST', '/v1/db/restore-tests', body);
      }
      ref.invalidate(dbRestoreProvider(widget.args.hostId));
      if (!mounted) return;
      toast(context, l.dbSaved);
      GoRouter.of(context).pop();
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
    final locale = Localizations.localeOf(context).toLanguageTag();
    final conns = ref.watch(dbConnectionsProvider(widget.args.hostId)).value?.connections.where((c) => !c.isSqlite && c.engine == _engine).toList() ?? const <DbConnection>[];
    final formats = restoreFormatsFor(_engine);
    return SettingsPage(
      title: _existing == null ? l.dbRestoreFormNew : l.dbRestoreFormEdit,
      onSave: _save,
      saving: _saving,
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldCard(
                children: [
                  TField(controller: _name, label: l.dbFieldName, validator: (v) => v.trim().isEmpty ? l.commonRequired : (slugify(v).isEmpty && _existing == null ? l.hostIdHint : null)),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _engine,
                    decoration: InputDecoration(labelText: l.dbFieldEngine),
                    items: [
                      for (final e in const ['postgres', 'mysql', 'mariadb']) DropdownMenuItem(value: e, child: Text(dbEngineName(e))),
                    ],
                    onChanged: (v) => setState(() {
                      _engine = v ?? 'postgres';
                      if (!_image.text.startsWith('$_engine:')) _image.text = '$_engine:';
                      if (!restoreFormatsFor(_engine).contains(_format)) _format = 'gz';
                      if (_connectionId != null && !conns.any((c) => c.id == _connectionId)) _connectionId = null;
                    }),
                  ),
                  TField(controller: _image, label: l.dbRestoreImage, mono: true, helper: l.dbRestoreImageHint, validator: (v) => validRestoreImage(_engine, v.trim()) ? null : l.dbRestoreImageInvalid(_engine)),
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: conns.any((c) => c.id == _connectionId) ? _connectionId : null,
                    decoration: InputDecoration(labelText: l.dbRestoreConnection, helperText: l.dbRestoreConnectionHint, helperMaxLines: 3),
                    items: [
                      DropdownMenuItem(value: null, child: Text(l.commonNone)),
                      for (final c in conns) DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _connectionId = v),
                  ),
                ],
              ),
              SectionLabel(l.dbRestoreDump),
              FieldCard(
                children: [
                  TField(controller: _glob, label: l.dbRestoreGlob, mono: true, hint: '~/backups/app/*.sql.gz', helper: l.dbRestoreGlobHint, validator: (v) => v.trim().isEmpty ? l.commonRequired : null),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: formats.contains(_format) ? _format : 'gz',
                    decoration: InputDecoration(labelText: l.dbRestoreFormat),
                    items: [
                      for (final f in formats)
                        DropdownMenuItem(
                          value: f,
                          child: Text(switch (f) {
                            'custom' => l.dbRestoreFormatCustom,
                            'gz' => l.dbRestoreFormatGz,
                            _ => l.dbRestoreFormatSql,
                          }),
                        ),
                    ],
                    onChanged: (v) => setState(() => _format = v ?? 'gz'),
                  ),
                ],
              ),
              SectionLabel(l.dbRestoreSanity),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(l.dbRestoreSanityHint, style: tt.bodySmall),
              ),
              for (var i = 0; i < _sanity.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TCard(
                    radius: TiphysTokens.radiusList,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          controller: _sanity[i].sql,
                          minLines: 2,
                          maxLines: 5,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: t.text),
                          decoration: InputDecoration(labelText: l.dbRestoreSanitySql, hintText: 'SELECT count(*) FROM orders'),
                          validator: (v) => (v ?? '').trim().isEmpty ? l.commonRequired : null,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 90,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue: _sanity[i].op,
                                decoration: InputDecoration(labelText: l.dbRestoreExpect),
                                items: [for (final o in restoreOps) DropdownMenuItem(value: o, child: Text(o))],
                                onChanged: (v) => setState(() => _sanity[i].op = v ?? '>'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _sanity[i].value,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                                decoration: InputDecoration(labelText: l.dbRestoreValue),
                                validator: (v) => num.tryParse((v ?? '').trim()) == null ? l.commonRequired : null,
                              ),
                            ),
                            IconButton(
                              tooltip: l.commonDelete,
                              onPressed: () => setState(() => _sanity.removeAt(i).dispose()),
                              icon: Icon(LucideIcons.trash2, size: 18, color: t.danger),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_sanity.length < maxSanity)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(onPressed: () => setState(() => _sanity.add(_SanityRow(null))), icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.dbRestoreSanityAdd)),
                ),
              SectionLabel(l.dbRestoreSchedule),
              TCard(
                radius: TiphysTokens.radiusList,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SwitchListTile(
                  value: _scheduled,
                  onChanged: (v) => setState(() => _scheduled = v),
                  title: Text(l.dbRestoreScheduleSwitch),
                  subtitle: Text(_scheduled ? scheduleWhenText(l, locale, _when) : l.dbRestoreManualOnly),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              if (_scheduled) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TCard(
                    radius: TiphysTokens.radiusList,
                    child: ScheduleWhenPicker(initial: _when, onChanged: (w) => setState(() => _when = w)),
                  ),
                ),
                const SizedBox(height: 8),
                TCard(
                  radius: TiphysTokens.radiusList,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SwitchListTile(value: _enabled, onChanged: (v) => setState(() => _enabled = v), title: Text(l.dbRestoreEnabled), contentPadding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DbNote(agentErrorText(l, _error!), color: t.danger),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
