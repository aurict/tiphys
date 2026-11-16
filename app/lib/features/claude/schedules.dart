// Claude › Scheduled tasks: tasks on the agent (claude feature) (/v1/claude/schedules). List: time,
// next run, on/off, last run (tap for the session), "Run now". Editing happens in a subpage.
// Times are in the agent's (PC's) time zone; a missed run is not made up later (agent: schedules.ts).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'claude_screen.dart' show claudeHostProvider, ClaudeFolderPicker;

final claudeSchedulesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(retry: (_, _) => null, (ref) async {
  final host = ref.watch(claudeHostProvider);
  if (host == null) return const [];
  autoRefresh(ref, const Duration(seconds: 30));
  final j = await withAgent(ref, host.id, (c) => c.get('/v1/claude/schedules'));
  return (j['schedules'] as List).cast<Map<String, dynamic>>();
});

/// Editable fields the agent expects (excluding id/lastRun/nextRun added by the server).
Map<String, dynamic> scheduleInput(Map<String, dynamic> s, {bool? enabled}) => {
      'name': s['name'],
      'cwd': s['cwd'],
      'prompt': s['prompt'],
      'when': s['when'],
      'permissionMode': s['permissionMode'] ?? 'default',
      if (s['model'] != null && '${s['model']}'.isNotEmpty) 'model': s['model'],
      if (s['effort'] != null) 'effort': s['effort'],
      if (s['profileId'] != null) 'profileId': s['profileId'],
      'enabled': enabled ?? s['enabled'] ?? true,
    };

/// Short name of an ISO weekday (1 = Monday) in the selected language (16 November 2026 is a Monday).
String weekdayShort(String locale, int isoDay) => DateFormat.E(locale).format(DateTime(2026, 11, 15 + isoDay));

String scheduleWhenText(AppLocalizations l, String locale, Map when) => switch (when['kind']) {
      'daily' => l.claudeScheduleDailyAt('${when['time']}'),
      'weekly' => (when['days'] as List).length == 7
          ? l.claudeScheduleDailyAt('${when['time']}')
          : '${[for (final d in (when['days'] as List).cast<num>()..sort()) weekdayShort(locale, d.toInt())].join(', ')} · ${when['time']}',
      _ => (when['everyMinutes'] as num) % 60 == 0
          ? l.claudeScheduleEveryHours(((when['everyMinutes'] as num) ~/ 60).toInt())
          : l.claudeScheduleEveryMinutes((when['everyMinutes'] as num).toInt()),
    };

/// "today 03:00", "tomorrow 03:00", "yesterday 03:00" or a date.
String scheduleTimeText(AppLocalizations l, String locale, DateTime t, DateTime now) {
  final hm = DateFormat.Hm(locale).format(t);
  final days = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  return switch (days) {
    0 => l.claudeScheduleToday(hm),
    1 => l.claudeScheduleTomorrow(hm),
    -1 => l.claudeScheduleYesterday(hm),
    _ => DateFormat('d MMM EEE HH:mm', locale).format(t),
  };
}

class ClaudeSchedulesScreen extends ConsumerStatefulWidget {
  const ClaudeSchedulesScreen({super.key});
  @override
  ConsumerState<ClaudeSchedulesScreen> createState() => _ClaudeSchedulesScreenState();
}

class _ClaudeSchedulesScreenState extends ConsumerState<ClaudeSchedulesScreen> {
  final _busy = <String>{};

  Future<void> _call(String id, Future<void> Function(String hostId) body) async {
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    setState(() => _busy.add(id));
    try {
      await body(host.id);
      ref.invalidate(claudeSchedulesProvider);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _toggle(Map<String, dynamic> s, bool v) =>
      _call('${s['id']}', (h) async => agentCall(ref, h, 'PUT', '/v1/claude/schedules/${s['id']}', scheduleInput(s, enabled: v)));

  void _runNow(Map<String, dynamic> s) => _call('${s['id']}', (h) async {
        final r = await agentCall(ref, h, 'POST', '/v1/claude/schedules/${s['id']}/run') as Map;
        if (mounted && r['sessionId'] != null) context.push('/claude/session/${r['sessionId']}');
      });

  void _openLast(Map<String, dynamic> s) {
    final last = (s['lastRun'] as Map?)?.cast<String, dynamic>();
    if (last == null) return;
    if (last['live'] == true) {
      context.push('/claude/session/${last['sessionId']}');
    } else if (last['sdkSessionId'] != null) {
      context.push('/claude/history/${last['sdkSessionId']}?cwd=${Uri.encodeComponent('${s['cwd']}')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final host = ref.watch(claudeHostProvider);
    final data = ref.watch(claudeSchedulesProvider);
    return SettingsPage(
      title: l.claudeSchedules,
      actions: [
        if (host != null) IconButton(tooltip: l.claudeScheduleAdd, icon: const Icon(LucideIcons.plus), onPressed: () => showScheduleEditor(context)),
      ],
      children: [
        if (host == null)
          Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.integrationNeedsAgentHost)))
        else
          ...data.when(
            skipLoadingOnRefresh: true,
            loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(agentErrorText(l, e))))],
            data: (list) => [
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.claudeSchedulesEmpty, style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 10),
                      FilledButton.icon(onPressed: () => showScheduleEditor(context), icon: const Icon(LucideIcons.plus), label: Text(l.claudeScheduleAdd)),
                    ]),
                  ),
                ),
              for (final s in list)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ScheduleCard(
                    s: s,
                    busy: _busy.contains('${s['id']}'),
                    onToggle: (v) => _toggle(s, v),
                    onRun: () => _runNow(s),
                    onEdit: () => showScheduleEditor(context, existing: s),
                    onOpenLast: () => _openLast(s),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text(l.claudeSchedulesHint(host.name), style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
      ],
    );
  }
}

class _ScheduleCard extends ConsumerWidget {
  const _ScheduleCard({required this.s, required this.busy, required this.onToggle, required this.onRun, required this.onEdit, required this.onOpenLast});
  final Map<String, dynamic> s;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onOpenLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = ref.watch(clockProvider)();
    final enabled = s['enabled'] == true;
    final running = s['running'] == true;
    final last = (s['lastRun'] as Map?)?.cast<String, dynamic>();
    final next = s['nextRun'] == null ? null : DateTime.parse('${s['nextRun']}').toLocal();
    final (lastText, lastColor) = switch (last) {
      null => (l.claudeScheduleNever, t.textSecondary),
      _ when running => (l.claudeScheduleRunning, t.accent),
      _ when last['ok'] == true => (l.claudeScheduleOk, t.success),
      _ when last['ok'] == false => (l.claudeScheduleFailed, t.danger),
      _ => (l.claudeScheduleNoResult, t.textSecondary),
    };
    final canOpen = last != null && (last['live'] == true || last['sdkSessionId'] != null);
    final cwd = '${s['cwd']}';
    return TCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: enabled ? const Color(0xFF5E5CE6) : const Color(0xFF8E8E93), borderRadius: BorderRadius.circular(9)),
            child: const Icon(LucideIcons.alarmClock, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name']}', style: tt.titleMedium),
              Text(scheduleWhenText(l, locale, s['when'] as Map), style: tt.bodySmall),
            ]),
          ),
          Semantics(
            label: '${s['name']}: ${l.claudeScheduleEnabled}',
            child: Switch.adaptive(value: enabled, onChanged: busy ? null : onToggle),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          '${cwd.split('/').where((p) => p.isNotEmpty).lastOrNull ?? cwd} · ${enabled && next != null ? l.claudeScheduleNext(scheduleTimeText(l, locale, next, now)) : l.claudeScheduleOff}',
          style: tt.bodyMedium?.copyWith(color: t.textSecondary),
        ),
        InkWell(
          onTap: canOpen ? onOpenLast : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              StatusDot(color: lastColor, size: 8),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  last == null ? lastText : '${l.claudeScheduleLast(scheduleTimeText(l, locale, DateTime.parse('${last['at']}').toLocal(), now))} · $lastText',
                  style: tt.bodyMedium?.copyWith(color: canOpen ? t.accent : t.textSecondary),
                ),
              ),
              if (canOpen) Icon(LucideIcons.chevronRight, size: 16, color: t.accent),
            ]),
          ),
        ),
        Row(children: [
          TextButton.icon(
            onPressed: busy || running ? null : onRun,
            icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.play, size: 18),
            label: Text(l.claudeScheduleRunNow),
          ),
          const Spacer(),
          TextButton.icon(onPressed: onEdit, icon: const Icon(LucideIcons.pencil, size: 18), label: Text(l.commonEdit)),
        ]),
      ]),
    );
  }
}

Future<void> showScheduleEditor(BuildContext context, {Map<String, dynamic>? existing}) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: ScheduleEditSheet(existing: existing),
      ),
    );

class ScheduleEditSheet extends ConsumerStatefulWidget {
  const ScheduleEditSheet({super.key, this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<ScheduleEditSheet> createState() => _ScheduleEditSheetState();
}

class _ScheduleEditSheetState extends ConsumerState<ScheduleEditSheet> {
  static const _intervals = [15, 30, 60, 120, 180, 360, 720, 1440];
  late final _name = TextEditingController(text: widget.existing?['name'] as String?);
  late final _prompt = TextEditingController(text: widget.existing?['prompt'] as String?);
  late String _cwd;
  late String _kind;
  late String _time;
  late Set<int> _days;
  late int _every;
  late String _mode;
  late String _effort;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = ref.read(profileProvider).claude;
    final e = widget.existing;
    final when = (e?['when'] as Map?) ?? const {'kind': 'daily', 'time': '09:00'};
    _cwd = e?['cwd'] as String? ?? c.favoriteFolders.firstOrNull ?? '~';
    _kind = '${when['kind']}';
    _time = when['time'] as String? ?? '09:00';
    _days = {...((when['days'] as List?) ?? const [1, 2, 3, 4, 5]).cast<num>().map((d) => d.toInt())};
    _every = (when['everyMinutes'] as num?)?.toInt() ?? 60;
    _mode = e?['permissionMode'] as String? ?? c.permissionMode;
    _effort = e?['effort'] as String? ?? c.effort;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ClaudeFolderPicker(hostId: host.id, start: _cwd)));
    if (picked != null) setState(() => _cwd = picked);
  }

  Future<void> _pickTime() async {
    final p = _time.split(':').map(int.parse).toList();
    final r = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: p[0], minute: p[1]),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (r != null) setState(() => _time = '${'${r.hour}'.padLeft(2, '0')}:${'${r.minute}'.padLeft(2, '0')}');
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    final error = _name.text.trim().isEmpty || _prompt.text.trim().isEmpty
        ? l.claudeScheduleNeedsNameAndPrompt
        : _kind == 'weekly' && _days.isEmpty
            ? l.claudeScheduleNeedsDays
            : null;
    if (error != null) return setState(() => _error = error);
    final model = widget.existing?['model'] as String? ?? ref.read(profileProvider).claude.model;
    final body = {
      'name': _name.text.trim(),
      'cwd': _cwd,
      'prompt': _prompt.text.trim(),
      'when': switch (_kind) {
        'interval' => {'kind': 'interval', 'everyMinutes': _every},
        'weekly' => {'kind': 'weekly', 'time': _time, 'days': (_days.toList()..sort())},
        _ => {'kind': 'daily', 'time': _time},
      },
      'permissionMode': _mode,
      'effort': _effort,
      if (model.isNotEmpty) 'model': model,
      if (widget.existing?['profileId'] != null) 'profileId': widget.existing!['profileId'],
      'enabled': widget.existing?['enabled'] ?? true,
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = widget.existing?['id'];
      await agentCall(ref, host.id, id == null ? 'POST' : 'PUT', id == null ? '/v1/claude/schedules' : '/v1/claude/schedules/$id', body);
      ref.invalidate(claudeSchedulesProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = agentErrorText(l, e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    final e = widget.existing;
    if (host == null || e == null) return;
    if (!await confirmDialog(context, message: l.claudeScheduleDeleteConfirm('${e['name']}'), confirmLabel: l.commonDelete, destructive: true)) return;
    try {
      await agentCall(ref, host.id, 'DELETE', '/v1/claude/schedules/${e['id']}');
      ref.invalidate(claudeSchedulesProvider);
      if (mounted) Navigator.pop(context);
    } catch (err) {
      if (mounted) setState(() => _error = agentErrorText(l, err));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final favorites = ref.watch(profileProvider.select((p) => p.claude.favoriteFolders));
    Widget label(String s) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 6), child: Text(s, style: Theme.of(context).textTheme.labelMedium));
    Widget chip(String text, bool selected, VoidCallback onTap) => ChoiceChip(
          label: Text(text),
          selected: selected,
          onSelected: (_) => onTap(),
          showCheckmark: false,
          selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
          labelStyle: TextStyle(color: selected ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
        );
    final intervals = {..._intervals, _every}.toList()..sort();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.existing == null ? l.claudeScheduleAdd : l.claudeScheduleEdit, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: InputDecoration(labelText: l.claudeScheduleName, hintText: l.claudeScheduleNameHint), textCapitalization: TextCapitalization.sentences),
          const SizedBox(height: 10),
          TCard(
            onTap: _pickFolder,
            semanticLabel: l.claudeFolder,
            child: Row(children: [
              Icon(LucideIcons.folder, color: t.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(_cwd, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13))),
              Icon(LucideIcons.chevronRight, color: t.textSecondary),
            ]),
          ),
          if (favorites.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in favorites) ActionChip(label: Text(f.split('/').last, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _cwd = f)),
              ]),
            ),
          const SizedBox(height: 10),
          TextField(controller: _prompt, minLines: 3, maxLines: 8, decoration: InputDecoration(labelText: l.claudeSchedulePrompt, hintText: l.claudeSchedulePromptHint)),
          label(l.claudeScheduleWhen),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'daily', label: Text(l.claudeScheduleDaily)),
              ButtonSegment(value: 'weekly', label: Text(l.claudeScheduleWeekly)),
              ButtonSegment(value: 'interval', label: Text(l.claudeScheduleInterval)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          if (_kind != 'interval') ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _pickTime,
                icon: const Icon(LucideIcons.clock, size: 18),
                label: Text('${l.claudeScheduleTime}: $_time'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
              ),
            ),
          ],
          if (_kind == 'weekly') ...[
            label(l.claudeScheduleDays),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (var d = 1; d <= 7; d++)
                chip(weekdayShort(locale, d), _days.contains(d), () => setState(() => _days.contains(d) ? _days.remove(d) : _days.add(d))),
            ]),
          ],
          if (_kind == 'interval') ...[
            label(l.claudeScheduleEveryLabel),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in intervals)
                chip(m % 60 == 0 ? l.claudeScheduleEveryHours(m ~/ 60) : l.claudeScheduleEveryMinutes(m), m == _every, () => setState(() => _every = m)),
            ]),
          ],
          label(l.claudePermissionMode),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (v, name) in [
              ('bypassPermissions', l.claudeModeBypassShort),
              ('acceptEdits', l.claudeModeAcceptShort),
              ('default', l.claudeModeDefaultShort),
              ('plan', l.claudeModePlan),
            ])
              chip(name, v == _mode, () => setState(() => _mode = v)),
          ]),
          if (_mode == 'default')
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.claudeScheduleAskHint, style: Theme.of(context).textTheme.bodySmall)),
          label(l.claudeEffort),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final e in claudeEfforts) chip(e, e == _effort, () => setState(() => _effort = e))]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: t.danger))),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.check),
            label: Text(l.commonSave),
          ),
          if (widget.existing != null)
            TextButton(onPressed: _busy ? null : _delete, style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.commonDelete)),
        ]),
      ),
    );
  }
}
