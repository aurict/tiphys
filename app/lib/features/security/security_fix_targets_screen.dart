// Fix targets of the PC agent (PLAN.md §16 F4): which audited machines Claude may reach over SSH, and how. `host` is the
// audited host's id on the monitoring agent; no SSH destination means this PC. Opened from the agent settings and from the
// "Send to Claude" sheet ("set target").
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../system/agent_providers.dart';
import 'security_data.dart';
import 'security_fix.dart';
import 'security_section_widgets.dart' show SecNote;

class FixTargetsScreen extends ConsumerStatefulWidget {
  const FixTargetsScreen({super.key, this.hostId, this.addHost, this.addName});

  /// The PC agent; null = the Claude host.
  final String? hostId;

  /// Opens the add dialog with this security host (from the send sheet).
  final String? addHost, addName;
  @override
  ConsumerState<FixTargetsScreen> createState() => _FixTargetsScreenState();
}

class _FixTargetsScreenState extends ConsumerState<FixTargetsScreen> {
  List<FixTarget>? _targets;
  final _cache = TextEditingController(text: '15');
  bool _saving = false;
  bool _asked = false;

  String? get _hostId => widget.hostId ?? ref.read(claudeHostProvider)?.id;

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  void _fill(FixTargets t) {
    if (_targets != null) return;
    _targets = [...t.targets];
    _cache.text = '${t.sudoCacheMinutes}';
    final add = widget.addHost;
    if (add != null && !_asked && t.of(add) == null) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _edit(null, preset: FixTarget(host: add, name: widget.addName ?? add));
      });
    }
  }

  Future<void> _edit(FixTarget? existing, {FixTarget? preset}) async {
    final list = _targets;
    if (list == null) return;
    final r = await showModalBottomSheet<FixTarget>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: FixTargetSheet(initial: existing ?? preset, taken: {for (final t in list) if (t.host != existing?.host) t.host}),
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      final i = existing == null ? -1 : list.indexOf(existing);
      if (i >= 0) {
        list[i] = r;
      } else {
        list.add(r);
      }
    });
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final id = _hostId;
    final list = _targets;
    if (id == null || list == null) return;
    final value = FixTargets(targets: list, sudoCacheMinutes: int.tryParse(_cache.text.trim()) ?? 0);
    final problem = fixTargetsProblem(value);
    if (problem != null) return toast(context, fixTargetProblemText(l, problem));
    setState(() => _saving = true);
    try {
      await agentCall(ref, id, 'PUT', '/v1/claude/security/targets', value.toJson());
      ref.invalidate(fixTargetsProvider(id));
      if (!mounted) return;
      toast(context, l.systemDone);
      context.pop();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final id = _hostId;
    if (id == null) return SettingsPage(title: l.fixTargetsTitle, children: [TCard(child: Text(l.dozzleNoClaudeHost))]);
    final async = ref.watch(fixTargetsProvider(id));
    final list = _targets;
    return SettingsPage(
      title: l.fixTargetsTitle,
      onSave: list == null ? null : _save,
      saving: _saving,
      onRefresh: () async {
        ref.invalidate(fixTargetsProvider(id));
        await ref.read(fixTargetsProvider(id).future).then((_) {}, onError: (_) {});
      },
      children: [
        async.when(
          skipLoadingOnRefresh: true,
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(agentErrorText(l, e)),
              const SizedBox(height: 8),
              TextButton(onPressed: () => ref.invalidate(fixTargetsProvider(id)), child: Text(l.commonRetry)),
            ]),
          ),
          data: (data) {
            _fill(data);
            final targets = _targets!;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SecNote(l.fixTargetsIntro),
              const SizedBox(height: 12),
              if (targets.isEmpty) TCard(child: Text(l.fixTargetsEmpty)),
              if (targets.isNotEmpty)
                GroupedSection(children: [
                  for (final x in targets)
                    GroupedRow(
                      title: x.name,
                      subtitle: '${x.host} · ${x.destination ?? l.fixTargetThisPc}',
                      icon: x.ssh == null ? LucideIcons.monitor : LucideIcons.server,
                      iconBackground: t.accent,
                      onTap: () => _edit(x),
                      trailing: IconButton(
                        tooltip: l.commonDelete,
                        icon: Icon(LucideIcons.trash2, color: t.danger, size: 20),
                        onPressed: () async {
                          if (!await confirmDialog(context, message: l.fixTargetDeleteConfirm(x.name), confirmLabel: l.commonDelete, destructive: true)) return;
                          setState(() => targets.remove(x));
                        },
                      ),
                    ),
                ]),
              const SizedBox(height: 10),
              if (targets.length < fixMaxTargets)
                GroupedSection(children: [GroupedRow(title: l.fixTargetAdd, icon: LucideIcons.plus, iconBackground: t.accent, onTap: () => _edit(null))]),
              FieldCard(title: l.fixSudoCacheTitle, children: [
                TField(controller: _cache, label: l.fixSudoCacheLabel, keyboardType: TextInputType.number, helper: l.fixSudoCacheHint, validator: intV(1, 120)),
              ]),
            ]);
          },
        ),
      ],
    );
  }
}

/// One target: which audited machine (picked from the monitoring agents or typed), its name and how to reach it.
class FixTargetSheet extends ConsumerStatefulWidget {
  const FixTargetSheet({super.key, this.initial, this.taken = const {}});
  final FixTarget? initial;

  /// Host ids already used by other targets.
  final Set<String> taken;
  @override
  ConsumerState<FixTargetSheet> createState() => _FixTargetSheetState();
}

class _FixTargetSheetState extends ConsumerState<FixTargetSheet> {
  final _form = GlobalKey<FormState>();
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _ssh = TextEditingController(text: widget.initial?.ssh ?? '');
  late final _port = TextEditingController(text: widget.initial?.port?.toString() ?? '');
  late bool _local = widget.initial != null && widget.initial!.ssh == null;

  @override
  void dispose() {
    for (final c in [_host, _name, _ssh, _port]) {
      c.dispose();
    }
    super.dispose();
  }

  void _ok() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      FixTarget(host: _host.text.trim(), name: _name.text.trim(), ssh: _local ? null : _ssh.text.trim(), port: _local || _port.text.trim().isEmpty ? null : int.parse(_port.text.trim())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final known = [for (final h in ref.watch(securityFeedProvider).value?.hosts ?? const <SecurityHostSummary>[]) if (!widget.taken.contains(h.id)) h];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(header: true, child: Text(widget.initial == null ? l.fixTargetAdd : l.commonEdit, style: Theme.of(context).textTheme.titleLarge)),
            if (known.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(l.fixTargetPickHost, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final h in known)
                  ChoiceChip(
                    label: Text(h.name),
                    selected: _host.text == h.id,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _host.text = h.id;
                      if (_name.text.trim().isEmpty) _name.text = h.name;
                    }),
                  ),
              ]),
            ],
            const SizedBox(height: 6),
            TField(
              controller: _host,
              label: l.fixTargetHostLabel,
              hint: 'atlas',
              mono: true,
              helper: l.fixTargetHostHelper,
              validator: (v) => !validFixHost(v.trim()) ? l.fixTargetHostInvalid : (widget.taken.contains(v.trim()) ? l.fixTargetDuplicate : null),
            ),
            TField(controller: _name, label: l.fixTargetNameLabel, validator: requiredV(l)),
            SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: Text(l.fixTargetThisPc), subtitle: Text(l.fixTargetThisPcHint), value: _local, onChanged: (v) => setState(() => _local = v)),
            if (!_local) ...[
              TField(controller: _ssh, label: l.fixTargetSshLabel, hint: 'user@atlas', mono: true, helper: l.fixTargetSshHelper, validator: (v) => validFixSsh(v.trim()) ? null : l.fixTargetSshInvalid),
              TField(
                controller: _port,
                label: l.fixTargetPortLabel,
                hint: '22',
                keyboardType: TextInputType.number,
                validator: (v) => v.trim().isEmpty || (int.tryParse(v.trim()) != null && validFixPort(int.parse(v.trim()))) ? null : l.fixTargetPortInvalid,
              ),
            ],
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel))),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: _ok, style: FilledButton.styleFrom(backgroundColor: t.accent), child: Text(l.commonSave))),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Row on the agent settings screen (Claude host, feature on) that leads to the targets.
class FixTargetsLink extends StatelessWidget {
  const FixTargetsLink({super.key, required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GroupedSection(footer: l.fixTargetsLinkHint, children: [
      GroupedRow(
        title: l.fixTargetsTitle,
        icon: LucideIcons.shieldCheck,
        iconBackground: context.tokens.accent,
        onTap: () => context.push('/claude/security-targets?host=${Uri.encodeQueryComponent(hostId)}'),
      ),
    ]);
  }
}
