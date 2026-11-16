// Settings › Desktop › Remotes (11.1): your own live screen buttons per window class (name, icon from a fixed set,
// action). Written to the profile's `desktopRemotes` section (carried by backup/sync). Shortcuts are validated with
// the agent's key table rules (remote.dart `parseCombo`); invalid ones aren't saved.
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
import '../desktop/remote.dart';

const _remoteColor = Color(0xFF0A84FF);

String remoteKindLabel(AppLocalizations l, RemoteKind k) => switch (k) {
      RemoteKind.combo => l.remoteKindCombo,
      RemoteKind.sequence => l.remoteKindSequence,
      RemoteKind.prompt => l.remoteKindPrompt,
      RemoteKind.scroll => l.remoteKindScroll,
    };

String remoteIconLabel(AppLocalizations l, String id) => switch (id) {
      'star' => l.remoteIconStar,
      'play' => l.remoteIconPlay,
      'search' => l.remoteIconSearch,
      'save' => l.remoteIconSave,
      'copy' => l.remoteIconCopy,
      'refresh' => l.remoteIconRefresh,
      'close' => l.remoteIconClose,
      'plus' => l.remoteIconPlus,
      'folder' => l.remoteIconFolder,
      'terminal' => l.remoteIconTerminal,
      'globe' => l.remoteIconGlobe,
      _ => l.remoteIconZap,
    };

class RemotesScreen extends ConsumerWidget {
  const RemotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final remotes = ref.watch(profileProvider.select((p) => p.desktopRemotes));
    final byClass = <String, List<DesktopRemote>>{};
    for (final r in remotes) {
      byClass.putIfAbsent(r.windowClass, () => []).add(r);
    }
    return SettingsPage(
      title: l.settingsRemotes,
      actions: [IconButton(tooltip: l.commonAdd, icon: const Icon(LucideIcons.plus), onPressed: () => context.push('/settings/remotes/edit'))],
      children: [
        if (remotes.isEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 24, 16, 24), child: Text(l.remotesEmpty, textAlign: TextAlign.center))
        else
          for (final e in byClass.entries) ...[
            GroupedSection(title: e.key, children: [
              for (final r in e.value)
                GroupedRow(
                  title: r.name,
                  subtitle: [remoteKindLabel(l, r.action.kind), ?remoteHint(r.action)].join(' · '),
                  icon: remoteIcon(r.icon),
                  iconBackground: _remoteColor,
                  onTap: () => context.push('/settings/remotes/edit?id=${r.id}'),
                ),
            ]),
            const SizedBox(height: 6),
          ],
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: () => context.push('/settings/remotes/edit'), icon: const Icon(LucideIcons.plus), label: Text(l.commonAdd)),
      ],
    );
  }
}

class RemoteEditScreen extends ConsumerStatefulWidget {
  const RemoteEditScreen({super.key, this.id, this.windowClass});
  final String? id;

  /// Suggested window class for a new button.
  final String? windowClass;
  @override
  ConsumerState<RemoteEditScreen> createState() => _RemoteEditState();
}

class _Step {
  _Step(this.text, String value) : value = TextEditingController(text: value);
  bool text;
  final TextEditingController value;
}

class _RemoteEditState extends ConsumerState<RemoteEditScreen> {
  final _form = GlobalKey<FormState>();
  final _class = TextEditingController();
  final _name = TextEditingController();
  final _combo = TextEditingController();
  final _dy = TextEditingController(text: '5');
  final _steps = <_Step>[];
  String _icon = 'zap';
  RemoteKind _kind = RemoteKind.combo;
  bool _submit = true;
  bool _confirm = false;
  DesktopRemote? _orig;

  @override
  void initState() {
    super.initState();
    _orig = ref.read(profileProvider).desktopRemotes.where((r) => r.id == widget.id).firstOrNull;
    final o = _orig;
    if (o != null) {
      _class.text = o.windowClass;
      _name.text = o.name;
      _icon = remoteIcons.contains(o.icon) ? o.icon : 'zap';
      _kind = o.action.kind;
      _combo.text = o.action.combo ?? '';
      _submit = o.action.submit;
      _confirm = o.confirm;
      if (o.action.kind == RemoteKind.scroll) _dy.text = '${o.action.dy}';
      for (final s in o.action.steps) {
        _steps.add(_Step(s.text != null, s.text ?? s.combo ?? ''));
      }
    } else {
      _class.text = widget.windowClass ?? '';
    }
    if (_steps.isEmpty) _steps.add(_Step(false, ''));
  }

  @override
  void dispose() {
    for (final c in [_class, _name, _combo, _dy, ..._steps.map((s) => s.value)]) {
      c.dispose();
    }
    super.dispose();
  }

  String? Function(String) _comboV(AppLocalizations l, {bool optional = false}) => (v) {
        if (v.trim().isEmpty) return optional ? null : l.commonRequired;
        // The schema's upper limit (remoteCombo ≤ 40): exceeding it would make saving fail schema validation.
        if (v.trim().length > 40) return '≤ 40';
        return parseCombo(v) == null ? l.remoteComboInvalid : null;
      };

  RemoteAction _action() => switch (_kind) {
        RemoteKind.combo => RemoteAction.combo(_combo.text.trim()),
        RemoteKind.prompt => RemoteAction.prompt(combo: _combo.text.trim().isEmpty ? null : _combo.text.trim(), submit: _submit),
        RemoteKind.scroll => RemoteAction.scroll(int.parse(_dy.text.trim())),
        RemoteKind.sequence => RemoteAction.sequence([
            for (final s in _steps) s.text ? RemoteStep.text(s.value.text) : RemoteStep.combo(s.value.text.trim()),
          ]),
      };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final action = _action();
    if (remoteEvents(action, text: 'x') == null) return; // something the validators missed (shouldn't happen)
    final existing = ref.read(profileProvider).desktopRemotes.map((r) => r.id).toSet();
    var id = _orig?.id ?? slugify(_name.text);
    if (_orig == null) {
      final base = id.isEmpty ? 'kumanda' : id;
      id = base;
      for (var i = 2; existing.contains(id); i++) {
        id = '$base-$i';
      }
    }
    final r = DesktopRemote(id: id, windowClass: _class.text.trim(), name: _name.text.trim(), icon: _icon, action: action, confirm: _confirm);
    await ref.read(profileProvider.notifier).update((p) => p.copyWith(desktopRemotes: upsertBy(p.desktopRemotes, r, (e) => e.id)));
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    String? maxLen(String v, int n) => v.trim().isEmpty ? l.commonRequired : (v.trim().length > n ? '≤ $n' : null);
    return Form(
      key: _form,
      child: SettingsPage(
        title: l.settingsRemotes,
        onSave: _save,
        children: [
          FieldCard(children: [
            TField(controller: _class, label: l.remoteClass, helper: l.remoteClassHelper, mono: true, validator: (v) => maxLen(v, 200)),
            TField(controller: _name, label: l.remoteName, validator: (v) => maxLen(v, 40)),
          ]),
          SectionLabel(l.remoteIconTitle),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final id in remoteIcons)
              Tooltip(
                message: remoteIconLabel(l, id),
                child: Semantics(
                  button: true,
                  selected: id == _icon,
                  label: remoteIconLabel(l, id),
                  excludeSemantics: true,
                  child: Material(
                    color: id == _icon ? _remoteColor : t.chipBackground,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _icon = id),
                      child: SizedBox(width: 48, height: 48, child: Icon(remoteIcon(id), size: 20, color: id == _icon ? Colors.white : t.text)),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          ChoiceSection<RemoteKind>(
            title: l.remoteActionTitle,
            options: [for (final k in RemoteKind.values) (k, remoteKindLabel(l, k))],
            value: _kind,
            onChanged: (k) => setState(() => _kind = k),
          ),
          const SizedBox(height: 14),
          ..._kindFields(l),
          const SizedBox(height: 14),
          GroupedSection(children: [SwitchRow(title: l.remoteConfirmSetting, value: _confirm, onChanged: (v) => setState(() => _confirm = v))]),
          if (_orig != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: GroupedSection(children: [
                GroupedRow(
                  title: l.commonDelete,
                  destructive: true,
                  showChevron: false,
                  onTap: () async {
                    await ref.read(profileProvider.notifier).update((p) => p.copyWith(desktopRemotes: p.desktopRemotes.where((r) => r.id != _orig!.id).toList()));
                    if (context.mounted) context.pop();
                  },
                ),
              ]),
            ),
        ],
      ),
    );
  }

  List<Widget> _kindFields(AppLocalizations l) => switch (_kind) {
        RemoteKind.combo => [
            FieldCard(children: [TField(controller: _combo, label: l.remoteKindCombo, helper: l.remoteComboHelper, mono: true, validator: _comboV(l))]),
          ],
        RemoteKind.prompt => [
            FieldCard(children: [TField(controller: _combo, label: l.remotePromptBefore, helper: l.remoteComboHelper, mono: true, validator: _comboV(l, optional: true))]),
            GroupedSection(children: [SwitchRow(title: l.remoteSubmit, value: _submit, onChanged: (v) => setState(() => _submit = v))]),
          ],
        RemoteKind.scroll => [
            FieldCard(children: [
              TField(
                controller: _dy,
                label: l.remoteScrollAmount,
                keyboardType: const TextInputType.numberWithOptions(signed: true),
                validator: (v) {
                  final n = int.tryParse(v.trim());
                  return n == null || n == 0 || n.abs() > 20 ? l.remoteScrollInvalid : null;
                },
              ),
            ]),
          ],
        RemoteKind.sequence => [
            FieldCard(children: [
              for (final (i, s) in _steps.indexed)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: DropdownButton<bool>(
                      value: s.text,
                      underline: const SizedBox(),
                      items: [
                        DropdownMenuItem(value: false, child: Text(l.remoteKindCombo)),
                        DropdownMenuItem(value: true, child: Text(l.remotePromptText)),
                      ],
                      onChanged: (v) => setState(() => s.text = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TField(
                      key: ObjectKey(s),
                      controller: s.value,
                      label: '${i + 1}',
                      mono: !s.text,
                      validator: s.text
                          ? (v) => v.isEmpty ? l.commonRequired : (v.length > 500 ? '≤ 500' : null)
                          : _comboV(l),
                    ),
                  ),
                  if (_steps.length > 1)
                    IconButton(
                      tooltip: l.remoteRemoveStep,
                      icon: const Icon(LucideIcons.x),
                      onPressed: () {
                        final c = _steps[i].value;
                        setState(() => _steps.removeAt(i));
                        WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose()); // after the field is gone
                      },
                    ),
                ]),
              if (_steps.length < 10)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _steps.add(_Step(false, ''))),
                    icon: const Icon(LucideIcons.plus, size: 18),
                    label: Text(l.remoteAddStep),
                  ),
                ),
            ]),
          ],
      };
}
