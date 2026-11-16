// System › Backups: backup checks (/v1/backups) on agents with the "backups" feature on: status, last backup
// time/size, "check now". Checks are added/removed from the agent settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/profile/model.dart';
import '../../core/push/push_service.dart' show backupReasonText;
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show formatSize;
import 'agent_providers.dart';

class HostBackups {
  const HostBackups(this.host, this.checks, this.intervalMinutes);
  final Host host;
  final List<Map<String, dynamic>> checks;
  final int intervalMinutes;
}

class BackupsFeed {
  const BackupsFeed(this.hosts, this.errors);
  final List<HostBackups> hosts;
  final Map<Host, Object> errors;
}

/// In parallel from agent hosts. Hosts with the feature off (no endpoint) aren't listed; other errors are shown per host.
final backupsFeedProvider = FutureProvider.autoDispose<BackupsFeed>((ref) async {
  autoRefresh(ref, const Duration(minutes: 2));
  final hosts = ref.watch(profileProvider).hosts.where((h) => h.agent != null).toList();
  final results = await Future.wait(hosts.map((h) async {
    try {
      final j = await withAgent(ref, h.id, (c) => c.get('/v1/backups')).timeout(const Duration(seconds: 30));
      return (h, HostBackups(h, (j['checks'] as List).cast<Map<String, dynamic>>(), (j['intervalMinutes'] as num?)?.toInt() ?? 15), null);
    } on AgentError catch (e) {
      return (h, null, e.code == 'agent.route.notFound' ? null : e);
    } catch (e) {
      return (h, null, e);
    }
  }));
  return BackupsFeed(
    [for (final r in results) if (r.$2 != null) r.$2!],
    {for (final r in results) if (r.$3 != null) r.$1: r.$3!},
  );
});

String backupStatusText(AppLocalizations l, String? status) => switch (status) {
      'ok' => l.backupsStatusOk,
      'stale' => l.backupsStatusStale,
      'failed' => l.backupsStatusFailed,
      'missing' => l.backupsStatusMissing,
      _ => l.backupsStatusUnknown,
    };

Color backupStatusColor(TiphysTokens t, String? status) => switch (status) {
      'ok' => t.success,
      'stale' => t.warning,
      'failed' || 'missing' => t.danger,
      _ => const Color(0xFF6C6C70),
    };

class BackupsScreen extends ConsumerStatefulWidget {
  const BackupsScreen({super.key});
  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  final _checking = <String>{};

  Future<void> _checkNow(Host host, Map<String, dynamic> c) async {
    final l = AppLocalizations.of(context);
    final key = '${host.id}/${c['id']}';
    setState(() => _checking.add(key));
    try {
      final r = await agentCall(ref, host.id, 'POST', '/v1/backups/${Uri.encodeComponent('${c['id']}')}/check') as Map;
      ref.invalidate(backupsFeedProvider);
      final st = ((r['check'] as Map)['state'] as Map?)?['status'] as String?;
      if (mounted) toast(context, l.backupsChecked(backupStatusText(l, st)));
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _checking.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final fmt = DateFormat('d MMM HH:mm', locale);
    final feed = ref.watch(backupsFeedProvider);

    String subtitle(Map<String, dynamic> c) {
      final s = (c['state'] as Map?)?.cast<String, dynamic>();
      final status = s?['status'] as String?;
      final lastAt = s?['lastAt'] as String?;
      return [
        backupStatusText(l, status),
        if (s != null) lastAt == null ? l.backupsNever : l.backupsLast(fmt.format(DateTime.parse(lastAt).toLocal())),
        if (s?['sizeBytes'] != null) formatSize((s!['sizeBytes'] as num).toInt(), locale),
        if (s?['running'] == true) l.backupsRunning,
        if (status == 'failed' || status == 'missing') backupReasonText(l, s?['detail'] as String?),
        if (status == 'stale') l.backupsMaxAge(NumberFormat.decimalPattern(locale).format(c['maxAgeHours'] as num)),
      ].join(' · ');
    }

    return SettingsPage(
      title: l.backupsTitle,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(backupsFeedProvider))],
      children: feed.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (f) => [
          for (final MapEntry(key: host, value: err) in f.errors.entries)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TCard(
                child: Row(children: [
                  Icon(LucideIcons.circleAlert, color: t.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${host.name}: ${agentErrorText(l, err)}')),
                ]),
              ),
            ),
          if (f.hosts.isEmpty && f.errors.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.backupsEmpty))),
          for (final hb in f.hosts)
            GroupedSection(
              title: hb.host.name,
              footer: hb.checks.isEmpty ? null : l.backupsEveryMinutes(hb.intervalMinutes),
              children: [
                if (hb.checks.isEmpty) GroupedRow(title: l.backupsHostNoChecks, icon: LucideIcons.archive, iconBackground: const Color(0xFF6C6C70), showChevron: false),
                for (final c in hb.checks)
                  GroupedRow(
                    title: '${c['name']}',
                    subtitle: subtitle(c),
                    icon: c['kind'] == 'unit' ? LucideIcons.timer : LucideIcons.archive,
                    iconBackground: backupStatusColor(t, (c['state'] as Map?)?['status'] as String?),
                    showChevron: false,
                    trailing: _checking.contains('${hb.host.id}/${c['id']}')
                        ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : IconButton(
                            tooltip: l.backupsCheckNow,
                            icon: Icon(LucideIcons.refreshCw, size: 20, color: t.accent),
                            onPressed: () => _checkNow(hb.host, c),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A wildcard (* ?) may only be in the last segment (the agent rejects it by the same rule).
bool backupPathValid(String p) {
  final dir = p.substring(0, p.lastIndexOf('/') + 1);
  return p.trim().isNotEmpty && !dir.contains(RegExp(r'[*?\[]'));
}

/// Kebab-case id from the name that doesn't collide with existing ids.
String backupCheckId(String name, Iterable<String> taken) {
  final base = slugify(name).isEmpty ? 'yedek' : slugify(name);
  var id = base;
  for (var i = 2; taken.contains(id); i++) {
    id = '${base.length > 58 ? base.substring(0, 58) : base}-$i';
  }
  return id;
}

/// Agent settings › Backup checks › Add check. On save, returns the check (in agent format);
/// writing to the agent happens via the settings screen's Save.
class BackupCheckEditPage extends StatefulWidget {
  const BackupCheckEditPage({super.key, required this.takenIds});
  final List<String> takenIds;
  @override
  State<BackupCheckEditPage> createState() => _BackupCheckEditPageState();
}

class _BackupCheckEditPageState extends State<BackupCheckEditPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _path = TextEditingController();
  final _unit = TextEditingController();
  final _maxAge = TextEditingController(text: '26');
  final _minBytes = TextEditingController(text: '0');
  String _kind = 'file';

  @override
  void dispose() {
    for (final c in [_name, _path, _unit, _maxAge, _minBytes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(<String, dynamic>{
      'id': backupCheckId(_name.text.trim(), widget.takenIds),
      'name': _name.text.trim(),
      'kind': _kind,
      if (_kind == 'file') 'path': _path.text.trim() else 'unit': _unit.text.trim(),
      'maxAgeHours': num.parse(_maxAge.text.trim().replaceAll(',', '.')),
      'minBytes': _kind == 'file' ? int.parse(_minBytes.text.trim()) : 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Form(
      key: _form,
      child: SettingsPage(title: l.agentBackupAdd, onSave: _save, children: [
        FieldCard(children: [
          TField(controller: _name, label: l.agentBackupName, hint: 'Obsidian', validator: requiredV(l), autofocus: true),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'file', label: Text(l.agentBackupKindFile), icon: const Icon(LucideIcons.archive, size: 16)),
                ButtonSegment(value: 'unit', label: Text(l.agentBackupKindUnit), icon: const Icon(LucideIcons.timer, size: 16)),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          ),
          if (_kind == 'file')
            TField(
              controller: _path,
              label: l.agentBackupPath,
              hint: '~/backups/obsidian/*.json.gz',
              helper: l.agentBackupPathHint,
              mono: true,
              validator: (v) => v.trim().isEmpty ? l.commonRequired : (backupPathValid(v) ? null : l.agentBackupInvalidPath),
            )
          else
            TField(
              controller: _unit,
              label: l.agentBackupUnit,
              hint: 'obsidian-backup.service',
              helper: l.agentBackupUnitHint,
              mono: true,
              validator: (v) => RegExp(r'^[A-Za-z0-9@_.:][A-Za-z0-9@_.:\\-]{0,199}$').hasMatch(v.trim()) ? null : l.commonRequired,
            ),
          TField(
            controller: _maxAge,
            label: l.agentBackupMaxAge,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (v) {
              final n = num.tryParse(v.trim().replaceAll(',', '.'));
              return n != null && n > 0 && n <= 24 * 366 ? null : '> 0';
            },
          ),
          if (_kind == 'file') TField(controller: _minBytes, label: l.agentBackupMinBytes, keyboardType: TextInputType.number, validator: intV(0, 1 << 40)),
        ]),
      ]),
    );
  }
}
