// Scanner settings (PLAN.md §15 S-2): Trivy / Gitleaks / Java DB switches, registry logins, GitHub owners and token,
// Loki, local repository roots and the night window. Tokens are write-only: the agent only says whether one exists,
// and an empty token field keeps the stored one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'security_data.dart' show securityCall;
import 'security_more_data.dart';
import 'security_section_widgets.dart';

class SecurityScannersScreen extends ConsumerWidget {
  const SecurityScannersScreen({super.key, this.agentHint});
  final String? agentHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: l.secScannersTitle,
      onRefresh: () async {
        ref.invalidate(securityAgentsProvider(agentHint));
        ref.invalidate(securityGetProvider);
      },
      children: [SecurityAgentBlocks(hint: agentHint, builder: (c, a) => _ScannersBlock(agent: a))],
    );
  }
}

class _ScannersBlock extends ConsumerStatefulWidget {
  const _ScannersBlock({required this.agent});
  final Host agent;
  @override
  ConsumerState<_ScannersBlock> createState() => _ScannersBlockState();
}

class _ScannersBlockState extends ConsumerState<_ScannersBlock> {
  bool _busy = false;
  final _ghToken = TextEditingController();
  final _lokiContainer = TextEditingController();
  final _lokiPort = TextEditingController();
  final _lokiUrl = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  String? _lokiMode;
  String? _loadedFor;
  late final _key = (widget.agent.id, secScannersPath);

  @override
  void dispose() {
    for (final c in [_ghToken, _lokiContainer, _lokiPort, _lokiUrl, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Form fields start from the agent's values once per response (after a save the fields keep what was typed).
  void _load(ScannersConfig c) {
    final sig = '${c.lokiContainer}|${c.lokiPort}|${c.lokiUrl}|${c.nightFrom}|${c.nightTo}';
    if (_loadedFor == sig) return;
    _loadedFor = sig;
    _lokiMode = c.lokiMode;
    _lokiContainer.text = c.lokiContainer ?? '';
    _lokiPort.text = '${c.lokiPort}';
    _lokiUrl.text = c.lokiUrl ?? '';
    _from.text = '${c.nightFrom}';
    _to.text = '${c.nightTo}';
  }

  Future<bool> _patch(Map<String, dynamic> body, {bool toastOk = true}) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    final ok = await secAct(context, () => securityCall(ref, widget.agent.id, 'PATCH', secScannersPath, body: body), ok: toastOk ? l.secSaved : null);
    if (mounted) setState(() => _busy = false);
    ref.invalidate(securityGetProvider(_key));
    ref.invalidate(securityGetProvider((widget.agent.id, secVulnsPath)));
    return ok;
  }

  Future<void> _editRegistry(ScannersConfig c, {RegistryAuthItem? existing}) async {
    final r = await showDialog<(String, String, String)>(context: context, builder: (_) => _RegistryDialog(existing: existing));
    if (r == null) return;
    final rows = <(String, String, String?)>[
      for (final x in c.registryAuth)
        if (x.registry != existing?.registry || x.username != existing?.username) (x.registry, x.username, null),
    ];
    rows.add((r.$1, r.$2, r.$3));
    await _patch({'registryAuth': registryAuthBody(rows)});
  }

  Future<void> _removeRegistry(ScannersConfig c, RegistryAuthItem item) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.secRegistryRemoveConfirm(item.registry), confirmLabel: l.commonDelete, destructive: true)) return;
    await _patch({
      'registryAuth': registryAuthBody([for (final x in c.registryAuth) if (x != item) (x.registry, x.username, null)]),
    });
  }

  Future<void> _addOwner(ScannersConfig c) async {
    final l = AppLocalizations.of(context);
    final v = await secAskText(context, title: l.secGhAddOwner, label: l.secGhOwner, hint: 'example-org', mono: true, validator: (v) => validGithubOwner(v) ? null : l.secInvalid);
    if (v == null || c.owners.contains(v)) return;
    await _patch({'github': {'owners': [...c.owners, v]}});
  }

  Future<void> _saveToken(ScannersConfig c) async {
    final v = _ghToken.text.trim();
    if (v.isEmpty) return;
    if (await _patch({'github': {'owners': c.owners, 'token': v}})) _ghToken.clear();
  }

  Future<void> _removeToken(ScannersConfig c) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.secGhTokenRemoveConfirm, confirmLabel: l.secTokenRemove, destructive: true)) return;
    await _patch({'github': {'owners': c.owners, 'token': null}});
  }

  Future<void> _saveLoki() async {
    final l = AppLocalizations.of(context);
    final mode = _lokiMode ?? 'off';
    final port = int.tryParse(_lokiPort.text.trim()) ?? 0;
    if (mode == 'container' && (!validContainerName(_lokiContainer.text.trim()) || port < 1 || port > 65535)) return toast(context, l.secInvalid);
    if (mode == 'url' && Uri.tryParse(_lokiUrl.text.trim())?.hasScheme != true) return toast(context, l.secInvalid);
    await _patch({'loki': lokiBody(mode, container: _lokiContainer.text, port: port, url: _lokiUrl.text)});
  }

  Future<void> _addRoot(ScannersConfig c) async {
    final l = AppLocalizations.of(context);
    final v = await secAskText(context, title: l.secRootAdd, label: l.secRootLabel, hint: '~/projects', mono: true, validator: (v) => v.isEmpty || v.length > 1024 ? l.secInvalid : null);
    if (v == null || c.localRoots.contains(v)) return;
    await _patch({'localRoots': [...c.localRoots, v]});
  }

  Future<void> _saveNight() async {
    final l = AppLocalizations.of(context);
    final a = int.tryParse(_from.text.trim()), b = int.tryParse(_to.text.trim());
    if (a == null || b == null || a < 0 || a > 23 || b < 0 || b > 24) return toast(context, l.secInvalid);
    await _patch({'nightHours': [a, b]});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return SecAsync<Map<String, dynamic>>(
      value: ref.watch(securityGetProvider(_key)),
      onRetry: () => ref.invalidate(securityGetProvider(_key)),
      data: (j) {
        final c = ScannersConfig(j['scanners'] is Map ? Map<String, dynamic>.from(j['scanners'] as Map) : <String, dynamic>{});
        _load(c);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          GroupedSection(footer: l.secScannersHint, children: [
            SwitchRow(title: l.secScanTrivy, subtitle: l.secScanTrivyHint, value: c.trivy, icon: LucideIcons.scanSearch, onChanged: _busy ? (_) {} : (v) => _patch({'trivy': v})),
            SwitchRow(title: l.secScanGitleaks, subtitle: l.secScanGitleaksHint, value: c.gitleaks, icon: LucideIcons.keyRound, onChanged: _busy ? (_) {} : (v) => _patch({'gitleaks': v})),
            SwitchRow(title: l.secScanJavaDb, subtitle: l.secScanJavaDbHint, value: c.javaDb, icon: LucideIcons.database, onChanged: _busy ? (_) {} : (v) => _patch({'javaDb': v})),
          ]),
          SectionLabel(l.secRegistryTitle),
          if (c.registryAuth.isEmpty) TCard(child: Text(l.secRegistryEmpty)),
          if (c.registryAuth.isNotEmpty)
            GroupedSection(children: [
              for (final r in c.registryAuth)
                GroupedRow(
                  title: r.registry,
                  subtitle: '${r.username} · ${r.hasToken ? l.secTokenSaved : l.secTokenMissing}',
                  icon: LucideIcons.packageOpen,
                  onTap: () => _editRegistry(c, existing: r),
                  trailing: IconButton(tooltip: l.secRegistryRemove(r.registry), icon: const Icon(LucideIcons.trash2, size: 18), onPressed: () => _removeRegistry(c, r)),
                ),
            ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _busy || c.registryAuth.length >= 10 ? null : () => _editRegistry(c), icon: const Icon(LucideIcons.plus, size: 16), label: Text(l.secRegistryAdd)),
          Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: Text(l.secRegistryHint, style: tt.bodySmall)),
          SectionLabel(l.secGhTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.secGhOwners, style: tt.titleSmall),
              const SizedBox(height: 6),
              SecChipList(items: c.owners, addLabel: l.secGhAddOwner, enabled: !_busy, removeLabel: l.secGhRemoveOwner, onAdd: () => _addOwner(c), onRemove: (o) => _patch({'github': {'owners': [for (final x in c.owners) if (x != o) x]}})),
              const SizedBox(height: 14),
              TField(controller: _ghToken, label: l.secGhToken, obscure: true, mono: true, hint: c.githubToken ? l.secTokenKeep : null, helper: l.secGhTokenHint),
              const SizedBox(height: 8),
              Row(children: [
                if (c.githubToken) TextButton(onPressed: _busy ? null : () => _removeToken(c), style: TextButton.styleFrom(foregroundColor: t.danger), child: Text(l.secTokenRemove)),
                const Spacer(),
                FilledButton(onPressed: _busy ? null : () => _saveToken(c), child: Text(l.commonSave)),
              ]),
            ]),
          ),
          SectionLabel(l.secLokiTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'off', label: Text(l.secLokiOff)),
                  ButtonSegment(value: 'container', label: Text(l.secLokiContainer)),
                  ButtonSegment(value: 'url', label: Text(l.secLokiUrl)),
                ],
                selected: {_lokiMode ?? 'off'},
                onSelectionChanged: (s) => setState(() => _lokiMode = s.single),
              ),
              const SizedBox(height: 12),
              if (_lokiMode == 'container') ...[
                TField(controller: _lokiContainer, label: l.secLokiContainerName, mono: true, hint: 'loki'),
                const SizedBox(height: 10),
                TField(controller: _lokiPort, label: l.secLokiPort, keyboardType: TextInputType.number),
              ],
              if (_lokiMode == 'url') TField(controller: _lokiUrl, label: l.secLokiUrlLabel, mono: true, keyboardType: TextInputType.url, hint: 'https://loki.example.org'),
              if (_lokiMode == 'off') Text(l.secLokiOffHint, style: tt.bodySmall),
              const SizedBox(height: 10),
              Align(alignment: AlignmentDirectional.centerEnd, child: FilledButton(onPressed: _busy ? null : _saveLoki, child: Text(l.commonSave))),
            ]),
          ),
          SectionLabel(l.secRootsTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.secRootsHint, style: tt.bodySmall),
              const SizedBox(height: 8),
              SecChipList(items: c.localRoots, addLabel: l.secRootAdd, enabled: !_busy, removeLabel: (_) => l.secRootRemove, onAdd: () => _addRoot(c), onRemove: (r) => _patch({'localRoots': [for (final x in c.localRoots) if (x != r) x]})),
            ]),
          ),
          SectionLabel(l.secNightTitle),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l.secNightHint, style: tt.bodySmall),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TField(controller: _from, label: l.secNightFrom, keyboardType: TextInputType.number)),
                const SizedBox(width: 12),
                Expanded(child: TField(controller: _to, label: l.secNightTo, keyboardType: TextInputType.number)),
              ]),
              const SizedBox(height: 10),
              Align(alignment: AlignmentDirectional.centerEnd, child: FilledButton(onPressed: _busy ? null : _saveNight, child: Text(l.commonSave))),
            ]),
          ),
        ]);
      },
    );
  }
}

/// Registry login: registry host, user name and a token that is only sent when typed.
class _RegistryDialog extends StatefulWidget {
  const _RegistryDialog({this.existing});
  final RegistryAuthItem? existing;
  @override
  State<_RegistryDialog> createState() => _RegistryDialogState();
}

class _RegistryDialogState extends State<_RegistryDialog> {
  final _form = GlobalKey<FormState>();
  late final _registry = TextEditingController(text: widget.existing?.registry ?? 'ghcr.io');
  late final _user = TextEditingController(text: widget.existing?.username ?? '');
  final _token = TextEditingController();

  @override
  void dispose() {
    for (final c in [_registry, _user, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final keep = widget.existing?.hasToken == true;
    return AlertDialog(
      title: Text(widget.existing == null ? l.secRegistryAdd : l.secRegistryEdit),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TField(controller: _registry, label: l.secRegistryHost, mono: true, enabled: widget.existing == null, validator: (v) => validRegistry(v.trim()) ? null : l.secInvalid),
            const SizedBox(height: 10),
            TField(controller: _user, label: l.secRegistryUser, mono: true, validator: (v) => v.trim().isEmpty || v.trim().length > 100 ? l.secInvalid : null),
            const SizedBox(height: 10),
            TField(
              controller: _token,
              label: l.secRegistryToken,
              obscure: true,
              mono: true,
              hint: keep ? l.secTokenKeep : null,
              helper: l.secRegistryTokenHint,
              // The agent keeps a stored token only for the same registry and user name.
              validator: (v) => (v.trim().isEmpty && !(keep && _user.text.trim() == widget.existing!.username)) || v.trim().length > 500 ? l.commonRequired : null,
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: () {
            if (_form.currentState!.validate()) Navigator.pop(context, (_registry.text.trim(), _user.text.trim(), _token.text.trim()));
          },
          child: Text(l.commonSave),
        ),
      ],
    );
  }
}
