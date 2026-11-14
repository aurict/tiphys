// Claude, Terminal, Dosyalar ve Hızlı işlemler ayarları.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';

/// Virgül ya da satırla ayrılmış liste düzenleyici (favori klasörler, komutlar, tuşlar…)
class _ListField extends StatelessWidget {
  const _ListField({required this.controller, required this.label, this.hint, this.helper});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  @override
  Widget build(BuildContext context) => TField(controller: controller, label: label, hint: hint, helper: helper, mono: true, maxLines: 5);
}

List<String> _lines(String s) => s.split(RegExp(r'[\n,]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

class ClaudeSettingsScreen extends ConsumerStatefulWidget {
  const ClaudeSettingsScreen({super.key});
  @override
  ConsumerState<ClaudeSettingsScreen> createState() => _ClaudeSettingsState();
}

class _ClaudeSettingsState extends ConsumerState<ClaudeSettingsScreen> {
  final _form = GlobalKey<FormState>();
  late ClaudeSettings _c;
  final _model = TextEditingController();
  final _folders = TextEditingController();
  final _commands = TextEditingController();
  final _profiles = TextEditingController();

  @override
  void initState() {
    super.initState();
    _c = ref.read(profileProvider).claude;
    _model.text = _c.model;
    _folders.text = _c.favoriteFolders.join('\n');
    _commands.text = _c.pinnedCommands.join('\n');
    _profiles.text = _c.profiles.map((p) => '${p.id} = ${p.configDir}').join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(profileProvider.select((p) => p.hosts.where((h) => h.agent != null).toList()));
    return Form(
      key: _form,
      child: SettingsPage(
        title: l.settingsClaude,
        onSave: () async {
          if (!_form.currentState!.validate()) return;
          final profiles = _lines(_profiles.text).map((line) {
            final parts = line.split('=');
            final id = parts.first.trim();
            return ClaudeProfile(id: id, name: id, configDir: parts.length > 1 ? parts.sublist(1).join('=').trim() : '~/.claude');
          }).toList();
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(
                claude: _c.copyWith(
                  model: _model.text.trim(),
                  favoriteFolders: _lines(_folders.text),
                  pinnedCommands: _lines(_commands.text).map((c) => c.startsWith('/') ? c : '/$c').toList(),
                  profiles: profiles,
                  profileId: profiles.any((x) => x.id == _c.profileId) ? _c.profileId : (profiles.firstOrNull?.id ?? 'personal'),
                ),
              ));
          if (context.mounted) context.pop();
        },
        children: [
          FieldCard(children: [
            DropdownButtonFormField<String>(
              initialValue: hosts.any((h) => h.id == _c.agentHostId) ? _c.agentHostId : null,
              decoration: InputDecoration(labelText: l.claudeAgentHost, helperText: hosts.isEmpty ? l.integrationNeedsAgentHost : null, helperMaxLines: 2),
              items: [for (final h in hosts) DropdownMenuItem(value: h.id, child: Text(h.name))],
              onChanged: (v) => setState(() => _c = _c.copyWith(agentHostId: () => v)),
            ),
            TField(controller: _model, label: l.claudeModel, mono: true, validator: requiredV(l)),
          ]),
          ChoiceSection<String>(
            title: l.claudeEffort,
            value: _c.effort,
            options: [for (final e in claudeEfforts) (e, e)],
            onChanged: (v) => setState(() => _c = _c.copyWith(effort: v)),
          ),
          ChoiceSection<String>(
            title: l.claudePermissionMode,
            value: _c.permissionMode,
            options: [
              ('bypassPermissions', l.claudeModeBypass),
              ('acceptEdits', l.claudeModeAcceptEdits),
              ('default', l.claudeModeDefault),
              ('plan', l.claudeModePlan),
            ],
            onChanged: (v) => setState(() => _c = _c.copyWith(permissionMode: v)),
          ),
          FieldCard(children: [
            _ListField(controller: _profiles, label: l.claudeProfiles, hint: 'personal = ~/.claude\nwork = ~/.claude-work', helper: l.claudeProfilesHint),
            _ListField(controller: _folders, label: l.claudeFavoriteFolders, hint: '~/projects/web'),
            _ListField(controller: _commands, label: l.claudePinnedCommands, hint: '/review\n/init'),
          ]),
        ],
      ),
    );
  }
}

class TerminalSettingsScreen extends ConsumerStatefulWidget {
  const TerminalSettingsScreen({super.key});
  @override
  ConsumerState<TerminalSettingsScreen> createState() => _TerminalSettingsState();
}

class _TerminalSettingsState extends ConsumerState<TerminalSettingsScreen> {
  late TerminalSettings _t;
  final _keys = TextEditingController();
  final _snippets = TextEditingController();

  @override
  void initState() {
    super.initState();
    _t = ref.read(profileProvider).terminal;
    _keys.text = _t.extraKeys.join(' ');
    _snippets.text = _t.snippets.map((s) => '${s.name} | ${s.command}${s.hostId == null ? '' : ' | ${s.hostId}'}').join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    return SettingsPage(
      title: l.settingsTerminal,
      onSave: () async {
        final snippets = _snippets.text
            .split('\n')
            .map((line) => line.split('|').map((e) => e.trim()).toList())
            .where((p) => p.length >= 2 && p[0].isNotEmpty && p[1].isNotEmpty)
            .map((p) => Snippet(name: p[0], command: p[1], hostId: p.length > 2 && p[2].isNotEmpty ? p[2] : null))
            .toList();
        await ref.read(profileProvider.notifier).update((p) => p.copyWith(
              terminal: _t.copyWith(extraKeys: _keys.text.split(RegExp(r'\s+')).where((k) => k.isNotEmpty).toList(), snippets: snippets),
            ));
        if (context.mounted) context.pop();
      },
      children: [
        SectionLabel(l.terminalFontSize),
        TCard(
          child: Column(children: [
            Slider(
              value: _t.fontSize,
              min: 9,
              max: 22,
              divisions: 13,
              label: _t.fontSize.toStringAsFixed(0),
              onChanged: (v) => setState(() => _t = _t.copyWith(fontSize: v)),
            ),
            Text(r'~/Desktop $ ls -la', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: _t.fontSize)),
          ]),
        ),
        FieldCard(title: l.terminalExtraKeys, children: [
          TField(controller: _keys, label: l.terminalExtraKeys, helper: l.terminalExtraKeysHint, mono: true, maxLines: 2),
        ]),
        FieldCard(title: l.terminalSnippets, children: [
          TField(controller: _snippets, label: l.terminalSnippets, hint: 'Docker | docker ps | atlas', helper: l.terminalSnippetsHint, mono: true, maxLines: 6),
        ]),
        Padding(padding: const EdgeInsets.all(8), child: Text(l.terminalThemeNote, style: tt.bodySmall)),
      ],
    );
  }
}

class FilesSettingsScreen extends ConsumerStatefulWidget {
  const FilesSettingsScreen({super.key});
  @override
  ConsumerState<FilesSettingsScreen> createState() => _FilesSettingsState();
}

class _FilesSettingsState extends ConsumerState<FilesSettingsScreen> {
  late FileSettings _f;
  final _bookmarks = TextEditingController();

  @override
  void initState() {
    super.initState();
    _f = ref.read(profileProvider).files;
    _bookmarks.text = _f.bookmarks.map((b) => '${b.hostId}:${b.path}').join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hostIds = ref.watch(profileProvider.select((p) => p.hosts.map((h) => h.id).toSet()));
    return SettingsPage(
      title: l.settingsFiles,
      onSave: () async {
        final bm = _bookmarks.text
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.contains(':'))
            .map((line) => Bookmark(hostId: line.substring(0, line.indexOf(':')).trim(), path: line.substring(line.indexOf(':') + 1).trim()))
            .where((b) => hostIds.contains(b.hostId) && b.path.isNotEmpty)
            .toList();
        await ref.read(profileProvider.notifier).update((p) => p.copyWith(files: FileSettings(bookmarks: bm, showHidden: _f.showHidden)));
        if (context.mounted) context.pop();
      },
      children: [
        GroupedSection(children: [
          SwitchRow(title: l.filesShowHidden, value: _f.showHidden, onChanged: (v) => setState(() => _f = FileSettings(bookmarks: _f.bookmarks, showHidden: v))),
        ]),
        FieldCard(title: l.filesBookmarks, children: [
          TField(controller: _bookmarks, label: l.filesBookmarks, hint: 'argo:~/Desktop\natlas:~/stack', helper: l.filesBookmarksHint, mono: true, maxLines: 6),
        ]),
      ],
    );
  }
}

class QuickActionsScreen extends ConsumerWidget {
  const QuickActionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return SettingsPage(
      title: l.settingsQuickActions,
      actions: [IconButton(tooltip: l.commonAdd, icon: const Icon(LucideIcons.plus), onPressed: () => context.push('/settings/actions/edit'))],
      children: [
        if (p.quickActions.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text(l.commonEmpty, textAlign: TextAlign.center))
        else
          GroupedSection(children: [
            for (final a in p.quickActions)
              GroupedRow(
                title: a.name,
                subtitle: '${p.host(a.hostId)?.name ?? a.hostId} · ${a.command}',
                icon: LucideIcons.zap,
                iconBackground: const Color(0xFFE5795A),
                onTap: () => context.push('/settings/actions/edit?id=${a.id}'),
              ),
          ]),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: () => context.push('/settings/actions/edit'), icon: const Icon(LucideIcons.plus), label: Text(l.commonAdd)),
      ],
    );
  }
}

class QuickActionEditScreen extends ConsumerStatefulWidget {
  const QuickActionEditScreen({super.key, this.id});
  final String? id;
  @override
  ConsumerState<QuickActionEditScreen> createState() => _QuickActionEditState();
}

class _QuickActionEditState extends ConsumerState<QuickActionEditScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _command = TextEditingController();
  String? _host;
  bool _confirm = true;
  QuickAction? _orig;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    _orig = p.quickActions.where((a) => a.id == widget.id).firstOrNull;
    _host = _orig?.hostId ?? p.hosts.firstOrNull?.id;
    if (_orig != null) {
      _name.text = _orig!.name;
      _command.text = _orig!.command;
      _confirm = _orig!.confirm;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hosts = ref.watch(profileProvider.select((p) => p.hosts));
    return Form(
      key: _form,
      child: SettingsPage(
        title: l.settingsQuickActions,
        onSave: () async {
          if (!_form.currentState!.validate()) return;
          final existing = ref.read(profileProvider).quickActions.map((a) => a.id).toSet();
          var id = _orig?.id ?? slugify(_name.text);
          if (_orig == null) {
            final base = id.isEmpty ? 'islem' : id;
            id = base;
            for (var i = 2; existing.contains(id); i++) {
              id = '$base-$i';
            }
          }
          final a = QuickAction(id: id, name: _name.text.trim(), hostId: _host!, command: _command.text.trim(), confirm: _confirm, icon: _orig?.icon ?? 'zap');
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(quickActions: upsertBy(p.quickActions, a, (e) => e.id)));
          if (context.mounted) context.pop();
        },
        children: [
          FieldCard(children: [
            TField(controller: _name, label: l.hostName, validator: requiredV(l)),
            DropdownButtonFormField<String>(
              initialValue: hosts.any((h) => h.id == _host) ? _host : null,
              decoration: InputDecoration(labelText: l.settingsHosts),
              items: [for (final h in hosts) DropdownMenuItem(value: h.id, child: Text(h.name))],
              onChanged: (v) => setState(() => _host = v),
              validator: (v) => v == null ? l.commonRequired : null,
            ),
            TField(controller: _command, label: l.quickActionCommand, mono: true, maxLines: 4, validator: requiredV(l)),
          ]),
          GroupedSection(children: [SwitchRow(title: l.quickActionConfirm, value: _confirm, onChanged: (v) => setState(() => _confirm = v))]),
          if (_orig != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: GroupedSection(children: [
                GroupedRow(
                  title: l.commonDelete,
                  destructive: true,
                  showChevron: false,
                  onTap: () async {
                    await ref.read(profileProvider.notifier).update((p) => p.copyWith(quickActions: p.quickActions.where((a) => a.id != _orig!.id).toList()));
                    if (context.mounted) context.pop();
                  },
                ),
              ]),
            ),
          SizedBox(height: 1, child: ColoredBox(color: t.background)),
        ],
      ),
    );
  }
}
