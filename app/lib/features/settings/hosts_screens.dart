// Hosts: list + editing (address, SSH, agent, wake, color).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/platform.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/secret_field.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_settings_screen.dart';
import '../system/pair_scanner.dart';

const hostPalette = ['#8F88EE', '#6CCB9F', '#EE9C77', '#64B5F6', '#F06292', '#FFD54F', '#90A4AE'];

class HostsScreen extends ConsumerWidget {
  const HostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final hosts = ref.watch(profileProvider.select((p) => p.hosts));
    return SettingsPage(
      title: l.settingsHosts,
      actions: [
        IconButton(tooltip: l.hostAdd, icon: const Icon(LucideIcons.plus), onPressed: () => context.push('/settings/hosts/edit')),
      ],
      children: [
        if (hosts.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text(l.hostsEmpty, textAlign: TextAlign.center))
        else
          GroupedSection(children: [
            for (final h in hosts)
              GroupedRow(
                title: h.name,
                subtitle: [h.address, if (h.ssh != null) 'SSH ${h.ssh!.user}', if (h.agent != null) l.hostAgent].join(' · '),
                icon: LucideIcons.server,
                iconBackground: hexColor(h.color),
                onTap: () => context.push('/settings/hosts/edit?id=${h.id}'),
              ),
          ]),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: () => context.push('/settings/hosts/edit'), icon: const Icon(LucideIcons.plus), label: Text(l.hostAdd)),
      ],
    );
  }
}

class HostEditScreen extends ConsumerStatefulWidget {
  const HostEditScreen({super.key, this.hostId});
  final String? hostId;
  @override
  ConsumerState<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends ConsumerState<HostEditScreen> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _tmux = TextEditingController(text: 'tiphys');
  final _agentUrl = TextEditingController();
  final _mac = TextEditingController();
  final _tags = TextEditingController();
  final _composeRoots = TextEditingController(text: '~/stack');
  late SecretInput _sshSecret;
  late SecretInput _agentToken;
  String _color = hostPalette.first;
  bool _ssh = true;
  bool _useKey = true;
  String? _keyId;
  bool _agent = false;
  bool _wake = false;
  String? _wakeVia;
  bool _saving = false;
  Host? _original;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    final h = p.host(widget.hostId);
    _original = h;
    _sshSecret = SecretInput('');
    _agentToken = SecretInput('');
    if (h != null) {
      _id.text = h.id;
      _name.text = h.name;
      _address.text = h.address;
      _color = h.color;
      _tags.text = h.tags.join(', ');
      _composeRoots.text = h.composeRoots.join(', ');
      _ssh = h.ssh != null;
      if (h.ssh != null) {
        _port.text = '${h.ssh!.port}';
        _user.text = h.ssh!.user;
        _tmux.text = h.ssh!.tmuxSession;
        _useKey = h.ssh!.auth is SshKeyAuth;
        if (_useKey) _keyId = secretIdOf(h.ssh!.auth.ref);
        if (!_useKey) _sshSecret.secretId = secretIdOf(h.ssh!.auth.ref);
      }
      _agent = h.agent != null;
      if (h.agent != null) {
        _agentUrl.text = h.agent!.url;
        _agentToken.secretId = secretIdOf(h.agent!.tokenRef);
      }
      _wake = h.wake != null;
      _mac.text = h.wake?.mac ?? '';
      _wakeVia = h.wake?.viaHostId;
    } else {
      _color = hostPalette[p.hosts.length % hostPalette.length];
      _keyId = p.keys.firstOrNull?.id;
    }
    _name.addListener(() {
      if (_original == null) _id.text = slugify(_name.text);
    });
  }

  @override
  void dispose() {
    for (final c in [_id, _name, _address, _port, _user, _tmux, _agentUrl, _mac, _tags, _composeRoots]) {
      c.dispose();
    }
    _sshSecret.dispose();
    _agentToken.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final id = _id.text.trim();
    if (_sshSecret.secretId.isEmpty) _sshSecret.secretId = 'ssh-pass-$id';
    if (_agentToken.secretId.isEmpty) _agentToken.secretId = 'agent-$id';
    final store = ref.read(secretStoreProvider);
    if (_ssh && !_useKey) await _sshSecret.commit(store);
    if (_agent) await _agentToken.commit(store);
    final host = Host(
      id: id,
      name: _name.text.trim(),
      color: _color,
      address: _address.text.trim(),
      ssh: !_ssh
          ? null
          : SshConfig(
              port: int.parse(_port.text),
              user: _user.text.trim(),
              auth: _useKey ? SshKeyAuth(refOf(_keyId!)) : SshPasswordAuth(_sshSecret.ref),
              tmuxSession: _tmux.text.trim().isEmpty ? 'tiphys' : _tmux.text.trim(),
            ),
      agent: _agent ? AgentRef(url: _agentUrl.text.trim(), tokenRef: _agentToken.ref) : null,
      wake: _wake ? WakeConfig(mac: _mac.text.trim().toUpperCase(), viaHostId: _wakeVia) : null,
      tags: _tags.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      composeRoots: _composeRoots.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).take(10).toList(),
    );
    await ref.read(profileProvider.notifier).update((p) {
      return p.copyWith(hosts: upsertBy(p.hosts, host, (h) => h.id));
    });
    ref.invalidate(secretIdsProvider);
    if (mounted) context.pop();
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.hostDeleteConfirm(_original!.name), confirmLabel: l.commonDelete, destructive: true)) return;
    await ref.read(profileProvider.notifier).update((p) => p.copyWith(hosts: p.hosts.where((h) => h.id != _original!.id).toList()));
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    final otherIds = p.hosts.map((h) => h.id).where((i) => i != _original?.id).toSet();
    return Form(
      key: _form,
      child: SettingsPage(
        title: _original == null ? l.hostAdd : l.hostEdit,
        onSave: _save,
        saving: _saving,
        children: [
          FieldCard(children: [
            TField(controller: _name, label: l.hostName, validator: requiredV(l)),
            TField(
              controller: _id,
              label: l.hostId,
              hint: l.hostIdHint,
              mono: true,
              enabled: _original == null, // changing the id breaks references; editable only on a new host
              validator: (v) => idV(l)(v) ?? (otherIds.contains(v) ? '"$v" ✕' : null),
            ),
            TField(controller: _address, label: l.hostAddress, hint: l.hostAddressHint, keyboardType: TextInputType.url, validator: requiredV(l)),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 10, runSpacing: 10, children: [
                for (final c in hostPalette)
                  Semantics(
                    button: true,
                    selected: c == _color,
                    label: '${l.hostColor} $c',
                    child: GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: hexColor(c),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(color: c == _color ? t.text : Colors.transparent, width: 2.5),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ]),
          GroupedSection(title: l.hostSsh, children: [SwitchRow(title: l.hostSsh, value: _ssh, onChanged: (v) => setState(() => _ssh = v))]),
          if (_ssh) ...[
            const SizedBox(height: 10),
            FieldCard(children: [
              Row(children: [
                Expanded(flex: 3, child: TField(controller: _user, label: l.hostSshUser, mono: true, validator: requiredV(l))),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: TField(controller: _port, label: l.hostSshPort, keyboardType: TextInputType.number, validator: intV(1, 65535))),
              ]),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(l.hostSshAuthKey), icon: const Icon(LucideIcons.keyRound, size: 16)),
                  ButtonSegment(value: false, label: Text(l.hostSshAuthPassword), icon: const Icon(LucideIcons.lock, size: 16)),
                ],
                selected: {_useKey},
                onSelectionChanged: (s) => setState(() => _useKey = s.first),
              ),
              if (_useKey)
                DropdownButtonFormField<String>(
                  initialValue: p.keys.any((k) => k.id == _keyId) ? _keyId : null,
                  decoration: InputDecoration(labelText: l.hostSshKey, helperText: p.keys.isEmpty ? l.keysEmpty : null),
                  items: [for (final k in p.keys) DropdownMenuItem(value: k.id, child: Text(k.label))],
                  onChanged: (v) => setState(() => _keyId = v),
                  validator: (v) => v == null ? l.commonRequired : null,
                )
              else
                SecretFieldView(input: _sshSecret, label: l.hostSshPassword),
              TField(controller: _tmux, label: l.hostTmux, mono: true),
              TField(controller: _composeRoots, label: l.hostComposeRoots, hint: '~/stack, /srv/compose', helper: l.hostComposeRootsHint, mono: true),
            ]),
          ],
          GroupedSection(title: l.hostAgent, children: [SwitchRow(title: l.hostAgent, value: _agent, onChanged: (v) => setState(() => _agent = v))]),
          if (_agent) ...[
            const SizedBox(height: 10),
            FieldCard(children: [
              TField(controller: _agentUrl, label: l.hostAgentUrl, hint: 'https://host.tailnet.ts.net:7443', keyboardType: TextInputType.url, validator: urlV(l)),
              SecretFieldView(input: _agentToken, label: l.hostAgentToken),
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await pickPairing(context);
                  if (p == null) return;
                  setState(() {
                    _agentUrl.text = p.url;
                    _agentToken.controller.text = p.token;
                    if (_name.text.isEmpty) _name.text = p.agent;
                  });
                },
                icon: Icon(hasQrScanner ? LucideIcons.qrCode : LucideIcons.clipboardPaste, size: 18),
                label: Text(hasQrScanner ? l.pairWithQr : l.pairPasteTitle),
                style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
              ),
            ]),
            if (_original?.agent != null) GroupedSection(children: [AgentSettingsLink(host: _original!)]),
          ],
          GroupedSection(title: l.hostWake, children: [SwitchRow(title: l.hostWake, value: _wake, onChanged: (v) => setState(() => _wake = v))]),
          if (_wake) ...[
            const SizedBox(height: 10),
            FieldCard(children: [
              TField(
                controller: _mac,
                label: l.hostWakeMac,
                hint: 'AA:BB:CC:DD:EE:FF',
                mono: true,
                validator: (v) => RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$').hasMatch(v.trim()) ? null : 'AA:BB:CC:DD:EE:FF',
              ),
              DropdownButtonFormField<String?>(
                initialValue: p.hosts.any((h) => h.id == _wakeVia) ? _wakeVia : null,
                decoration: InputDecoration(labelText: l.hostWakeVia, helperText: l.hostWakeViaHint, helperMaxLines: 3),
                items: [
                  DropdownMenuItem(value: null, child: Text(l.hostWakeViaPhone)),
                  for (final h in p.hosts.where((h) => h.id != _original?.id && h.agent != null)) DropdownMenuItem(value: h.id, child: Text(h.name)),
                ],
                onChanged: (v) => setState(() => _wakeVia = v),
              ),
            ]),
          ],
          FieldCard(children: [TField(controller: _tags, label: l.hostTags, hint: 'pc, oracle')]),
          if (_original != null) ...[
            const SizedBox(height: 18),
            GroupedSection(children: [GroupedRow(title: l.commonDelete, destructive: true, showChevron: false, onTap: _delete)]),
          ],
        ],
      ),
    );
  }
}
