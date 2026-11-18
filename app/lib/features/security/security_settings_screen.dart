// Audit settings (PLAN.md §15, S-1): this machine's role, expected open ports and sudo switch, and the other machines
// an agent audits over SSH or through their own agent. Tokens are only ever sent, never shown.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'security_data.dart';
import 'security_texts.dart';

class SecuritySettingsScreen extends ConsumerWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final agents = ref.watch(securityHostsProvider);
    Future<void> refresh() async {
      ref.invalidate(securityHostsProvider);
      for (final a in agents.value ?? const <Host>[]) {
        ref.invalidate(securitySettingsProvider(a.id));
      }
    }

    return SettingsPage(
      title: l.secSettingsTitle,
      onRefresh: refresh,
      children: agents.when(
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(agentErrorText(l, e)))],
        data: (list) => list.isEmpty ? [TCard(child: Text(l.secNoAgents))] : [for (final a in list) _AgentSettings(agent: a, showName: list.length > 1)],
      ),
    );
  }
}

void _changed(WidgetRef ref, String agentId) {
  ref.invalidate(securitySettingsProvider(agentId));
  ref.invalidate(securityFeedProvider);
  ref.invalidate(securityDetailProvider);
}

class _AgentSettings extends ConsumerWidget {
  const _AgentSettings({required this.agent, required this.showName});
  final Host agent;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final async = ref.watch(securitySettingsProvider(agent.id));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (showName) SectionLabel(agent.name),
      async.when(
        skipLoadingOnRefresh: true,
        loading: () => const TCard(child: Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))),
        error: (e, _) => TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.circleAlert, color: t.danger, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(agentErrorText(l, e))),
            ]),
            TextButton(onPressed: () => ref.invalidate(securitySettingsProvider(agent.id)), child: Text(l.commonRetry)),
          ]),
        ),
        data: (s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _SelfCard(settings: s),
          SectionLabel(l.secHostsTitle),
          if (s.hosts.isEmpty) TCard(child: Text(l.secHostsEmpty)),
          if (s.hosts.isNotEmpty)
            GroupedSection(children: [
              for (final h in s.hosts)
                GroupedRow(
                  title: h.name,
                  subtitle: '${securityRoleName(l, h.role)} · ${h.isSsh ? '${h.sshUser}@${h.sshHost}' : (h.url ?? '')}',
                  icon: h.isSsh ? LucideIcons.terminal : LucideIcons.server,
                  onTap: () => showSecurityHostForm(context, agent: agent, existing: h),
                ),
            ]),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: () => showSecurityHostForm(context, agent: agent), icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secAddHost)),
        ]),
      ),
    ]);
  }
}

class _SelfCard extends ConsumerStatefulWidget {
  const _SelfCard({required this.settings});
  final SecuritySettings settings;
  @override
  ConsumerState<_SelfCard> createState() => _SelfCardState();
}

class _SelfCardState extends ConsumerState<_SelfCard> {
  bool _busy = false;

  Future<void> _patch(Map<String, dynamic> body) async {
    final l = AppLocalizations.of(context);
    final agentId = widget.settings.agent.id;
    setState(() => _busy = true);
    try {
      await securityCall(ref, agentId, 'PATCH', securityHostPath('self'), body: body);
      if (mounted) toast(context, l.secSaved);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
      _changed(ref, agentId);
    }
  }

  Future<void> _sudo(bool on) async {
    final l = AppLocalizations.of(context);
    if (on && !await confirmDialog(context, message: l.secSudoConfirm)) return;
    await _patch({'sudo': on});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = widget.settings.self;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.secSelfTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Text(l.secRoleTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          _RoleChoice(value: s.role, onChanged: _busy ? null : (v) => _patch({'role': v})),
          const SizedBox(height: 4),
          Text(l.secRoleHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          Text(l.secAllowedPorts, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(l.secAllowedPortsHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          PortsEditor(ports: s.allowedPorts, enabled: !_busy, onChanged: (v) => _patch({'allowedPorts': v})),
        ]),
      ),
      const SizedBox(height: 10),
      GroupedSection(footer: l.secSudoWarn, children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        SwitchRow(title: l.secSudoTitle, value: s.sudo, icon: LucideIcons.shieldAlert, iconBackground: context.tokens.warning, onChanged: _busy ? (_) {} : _sudo),
      ]),
    ]);
  }
}

class _RoleChoice extends StatelessWidget {
  const _RoleChoice({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 'server', label: Text(l.secRoleServer)),
          ButtonSegment(value: 'desktop', label: Text(l.secRoleDesktop)),
        ],
        selected: {value},
        onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.single),
      ),
    );
  }
}

/// "tcp/22" chips with a remove button and an "Add port" chip (validated like the agent: ^(tcp|udp)/\d{1,5}$).
class PortsEditor extends StatelessWidget {
  const PortsEditor({super.key, required this.ports, required this.onChanged, this.enabled = true});
  final List<String> ports;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  Future<void> _add(BuildContext context) async {
    final v = await showDialog<String>(context: context, builder: (_) => const _PortDialog());
    if (v == null || ports.contains(v)) return;
    onChanged([...ports, v]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final p in ports)
        InputChip(
          label: Text(p, style: const TextStyle(fontFamily: monoFamily, fontSize: 13)),
          deleteButtonTooltipMessage: l.secPortRemove(p),
          onDeleted: enabled ? () => onChanged([...ports]..remove(p)) : null,
        ),
      ActionChip(avatar: const Icon(LucideIcons.plus, size: 16), label: Text(l.secAddPort), onPressed: enabled ? () => _add(context) : null),
    ]);
  }
}

class _PortDialog extends StatefulWidget {
  const _PortDialog();
  @override
  State<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends State<_PortDialog> {
  final _c = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim().toLowerCase();
    if (!validPortSpec(v)) {
      setState(() => _error = AppLocalizations.of(context).secPortInvalid);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secAddPort),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(labelText: l.secPortLabel, hintText: 'tcp/22', errorText: _error, errorMaxLines: 3),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(onPressed: _ok, child: Text(l.commonAdd)),
      ],
    );
  }
}

/// Add ([existing] == null) or edit a host in a bottom sheet.
Future<void> showSecurityHostForm(BuildContext context, {required Host agent, SecurityHostConfig? existing}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _HostForm(agent: agent, existing: existing),
    );

class _HostForm extends ConsumerStatefulWidget {
  const _HostForm({required this.agent, this.existing});
  final Host agent;
  final SecurityHostConfig? existing;
  @override
  ConsumerState<_HostForm> createState() => _HostFormState();
}

class _HostFormState extends ConsumerState<_HostForm> {
  final _form = GlobalKey<FormState>();
  late final SecurityHostConfig? _e = widget.existing;
  late final _id = TextEditingController(text: _e?.id ?? '');
  late final _name = TextEditingController(text: _e?.name ?? '');
  late final _sshHost = TextEditingController(text: _e?.sshHost ?? '');
  late final _sshUser = TextEditingController(text: _e?.sshUser ?? '');
  late final _sshPort = TextEditingController(text: '${_e?.sshPort ?? 22}');
  late final _keyPath = TextEditingController(text: _e?.keyPath ?? '');
  late final _url = TextEditingController(text: _e?.url ?? '');
  final _token = TextEditingController();
  late String _role = _e?.role ?? 'server';
  late bool _ssh = _e?.isSsh ?? true;
  late List<String> _ports = [...?_e?.allowedPorts];
  bool _busy = false;
  String? _tokenError;

  @override
  void dispose() {
    for (final c in [_id, _name, _sshHost, _sshUser, _sshPort, _keyPath, _url, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (_busy || !_form.currentState!.validate()) return;
    final token = _token.text.trim();
    // The agent keeps the stored token only while the URL stays the same.
    final needsToken = !_ssh && (_e == null || !(_e.hasToken) || _e.url != _url.text.trim());
    setState(() => _tokenError = null);
    if (!_ssh && token.isNotEmpty && !RegExp(r'^tps_[A-Za-z0-9_-]{20,}$').hasMatch(token)) {
      setState(() => _tokenError = l.secInvalid);
      return;
    }
    if (needsToken && token.isEmpty) {
      setState(() => _tokenError = l.secErrTokenRequired);
      return;
    }
    final source = securitySourceBody(ssh: _ssh, host: _sshHost.text, user: _sshUser.text, port: int.tryParse(_sshPort.text.trim()) ?? 22, keyPath: _keyPath.text, url: _url.text, token: token);
    final body = {if (_e == null) 'id': _id.text.trim(), 'name': _name.text.trim(), 'role': _role, 'allowedPorts': _ports, 'source': source};
    setState(() => _busy = true);
    try {
      if (_e == null) {
        await securityCall(ref, widget.agent.id, 'POST', '/v1/security/hosts', body: body);
      } else {
        await securityCall(ref, widget.agent.id, 'PATCH', securityHostPath(_e.id), body: body);
      }
      if (!mounted) return;
      _changed(ref, widget.agent.id);
      toast(context, l.secSaved);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, agentErrorText(l, e));
      }
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    if (_busy || !await confirmDialog(context, message: l.secDeleteHostConfirm(_e!.name), confirmLabel: l.commonDelete, destructive: true)) return;
    setState(() => _busy = true);
    try {
      await securityCall(ref, widget.agent.id, 'DELETE', securityHostPath(_e.id));
      if (!mounted) return;
      _changed(ref, widget.agent.id);
      toast(context, l.secDeleted);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, agentErrorText(l, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    String? required(String v) => v.trim().isEmpty ? l.commonRequired : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 8, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(header: true, child: Text(_e == null ? l.secAddHost : l.secEditHost, style: Theme.of(context).textTheme.titleLarge)),
            const SizedBox(height: 12),
            if (_e == null) ...[TField(controller: _id, label: l.secFieldId, hint: 'orion', mono: true, validator: idV(l)), const SizedBox(height: 10)],
            TField(controller: _name, label: l.secFieldName, validator: (v) => v.trim().isEmpty || v.trim().length > 80 ? l.secInvalid : null),
            const SizedBox(height: 12),
            _RoleChoice(value: _role, onChanged: (v) => setState(() => _role = v)),
            const SizedBox(height: 12),
            Text(l.secAllowedPorts, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            PortsEditor(ports: _ports, onChanged: (v) => setState(() => _ports = v)),
            const SizedBox(height: 14),
            Text(l.secFieldSource, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: true, label: Text(l.secSourceSsh)), ButtonSegment(value: false, label: Text(l.secSourceAgent))],
              selected: {_ssh},
              onSelectionChanged: (s) => setState(() => _ssh = s.single),
            ),
            const SizedBox(height: 12),
            if (_ssh) ...[
              TField(controller: _sshHost, label: l.secFieldSshHost, mono: true, validator: (v) => RegExp(r'^(?!-)[A-Za-z0-9.:_-]{1,253}$').hasMatch(v.trim()) ? null : l.secInvalid),
              const SizedBox(height: 10),
              TField(controller: _sshUser, label: l.secFieldSshUser, mono: true, validator: (v) => RegExp(r'^[a-z_][a-z0-9_-]{0,31}$').hasMatch(v.trim()) ? null : l.secInvalid),
              const SizedBox(height: 10),
              TField(
                controller: _sshPort,
                label: l.secFieldSshPort,
                keyboardType: TextInputType.number,
                validator: (v) => (int.tryParse(v.trim()) ?? 0) >= 1 && int.parse(v.trim()) <= 65535 ? null : l.secInvalid,
              ),
              const SizedBox(height: 10),
              TField(controller: _keyPath, label: l.secFieldKeyPath, mono: true, validator: required),
            ] else ...[
              TField(controller: _url, label: l.secFieldUrl, mono: true, keyboardType: TextInputType.url, validator: (v) => v.trim().startsWith('https://') && Uri.tryParse(v.trim())?.host.isNotEmpty == true ? null : l.secInvalid),
              const SizedBox(height: 10),
              TField(
                controller: _token,
                label: l.secFieldToken,
                obscure: true,
                mono: true,
                hint: _e?.hasToken == true ? l.secTokenKeep : null,
                helper: _tokenError ?? l.secTokenHint,
              ),
              if (_tokenError != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_tokenError!, style: TextStyle(color: context.tokens.danger, fontSize: 13))),
            ],
            const SizedBox(height: 16),
            Row(children: [
              if (_e != null) TextButton(onPressed: _busy ? null : _delete, style: TextButton.styleFrom(foregroundColor: context.tokens.danger), child: Text(l.secDeleteHost)),
              const Spacer(),
              TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l.commonCancel)),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.commonSave),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
