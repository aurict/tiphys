// Integrations: Grafana (multiple), Dozzle (multiple), Homepage, Uptime Kuma, ntfy, Scriberr, Obsidian (quick note).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/net/connection_test.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/secret_field.dart';
import '../../widgets/surfaces.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final i = ref.watch(profileProvider.select((p) => p.integrations));
    void go(String path) => context.push('/settings/integrations/$path');
    return SettingsPage(title: l.settingsIntegrations, children: [
      GroupedSection(title: 'Grafana', children: [
        for (final g in i.grafana) GroupedRow(title: g.name, subtitle: g.url, icon: LucideIcons.chartLine, iconBackground: const Color(0xFFE5795A), onTap: () => go('grafana?id=${g.id}')),
        GroupedRow(title: l.integrationAdd('Grafana'), icon: LucideIcons.plus, iconBackground: const Color(0xFF6C6C70), onTap: () => go('grafana')),
      ]),
      GroupedSection(title: 'Dozzle', children: [
        for (final d in i.dozzle) GroupedRow(title: d.name, subtitle: d.url, icon: LucideIcons.scrollText, iconBackground: const Color(0xFF2F9E6A), onTap: () => go('dozzle?id=${d.id}')),
        GroupedRow(title: l.integrationAdd('Dozzle'), icon: LucideIcons.plus, iconBackground: const Color(0xFF6C6C70), onTap: () => go('dozzle')),
      ]),
      GroupedSection(title: l.integrationOthers, children: [
        GroupedRow(title: 'Homepage', subtitle: i.homepage?.browserUrl ?? l.integrationNotSet, icon: LucideIcons.house, iconBackground: const Color(0xFF6CCB9F), onTap: () => go('homepage')),
        GroupedRow(title: 'Uptime Kuma', subtitle: i.uptimeKuma?.url ?? l.integrationNotSet, icon: LucideIcons.activity, iconBackground: const Color(0xFF15803D), onTap: () => go('uptime')),
        GroupedRow(title: 'ntfy', subtitle: i.ntfy?.url ?? l.integrationNotSet, icon: LucideIcons.bell, iconBackground: const Color(0xFF317F6F), onTap: () => go('ntfy')),
        GroupedRow(title: 'Scriberr', subtitle: switch (i.scriberr) {
                null => l.integrationNotSet,
                final s => '${switch (s.language) { 'tr' => l.appearanceLanguageTr, 'en' => l.appearanceLanguageEn, _ => l.scriberrAutoDetect }} · ${s.model}',
              }, icon: LucideIcons.mic, iconBackground: const Color(0xFF5E5CE6), onTap: () => go('scriberr')),
        GroupedRow(
            title: 'Obsidian',
            subtitle: i.obsidian == null ? l.integrationNotSet : '${i.obsidian!.vault} · ${i.obsidian!.mode == 'dailyNote' ? l.noteModeDaily : i.obsidian!.folder}',
            icon: LucideIcons.notebookPen,
            iconBackground: const Color(0xFF7C3AED),
            onTap: () => go('obsidian')),
      ]),
    ]);
  }
}

/// Shared: connection test button and its result.
class TestButton extends StatefulWidget {
  const TestButton({super.key, required this.run});
  final Future<TestResult> Function() run;
  @override
  State<TestButton> createState() => _TestButtonState();
}

class _TestButtonState extends State<TestButton> {
  TestResult? _r;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                final r = await widget.run();
                if (mounted) {
                  setState(() {
                    _r = r;
                    _busy = false;
                  });
                }
              },
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.plug, size: 18),
        label: Text(_busy ? l.commonTesting : l.commonTest),
        style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
      ),
      if (_r != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _r!.ok ? l.commonTestOk : l.commonTestFailed(_r!.reason ?? ''),
              style: TextStyle(color: _r!.ok ? t.success : t.danger, fontWeight: FontWeight.w600),
            ),
          ),
        ),
    ]);
  }
}

mixin _Saving<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final form = GlobalKey<FormState>();
  bool saving = false;
  Future<void> runSave(Future<void> Function() body) async {
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    await body();
    ref.invalidate(secretIdsProvider);
    if (mounted) context.pop();
  }
}

// ───────── Grafana ─────────

class GrafanaEditScreen extends ConsumerStatefulWidget {
  const GrafanaEditScreen({super.key, this.id});
  final String? id;
  @override
  ConsumerState<GrafanaEditScreen> createState() => _GrafanaEditState();
}

class _GrafanaEditState extends ConsumerState<GrafanaEditScreen> with _Saving {
  final _name = TextEditingController(text: 'Grafana');
  final _url = TextEditingController();
  final _dash = TextEditingController();
  final _refresh = TextEditingController(text: '30');
  final _range = TextEditingController(text: 'now-1h');
  late final SecretInput _token;
  bool _auth = true;
  GrafanaConfig? _orig;

  @override
  void initState() {
    super.initState();
    _orig = ref.read(profileProvider).integrations.grafana.where((g) => g.id == widget.id).firstOrNull;
    _token = SecretInput(_orig?.tokenRef != null ? secretIdOf(_orig!.tokenRef!) : '');
    if (_orig != null) {
      _name.text = _orig!.name;
      _url.text = _orig!.url;
      _dash.text = _orig!.defaultDashboardUid ?? '';
      _refresh.text = '${_orig!.refreshSeconds}';
      _range.text = _orig!.defaultRange;
      _auth = _orig!.tokenRef != null;
    }
  }

  String get _id => _orig?.id ?? slugify('grafana-${Uri.tryParse(_url.text)?.host.split('.').first ?? _name.text}');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Grafana',
        saving: saving,
        onSave: () => runSave(() async {
          if (_token.secretId.isEmpty) _token.secretId = _id;
          if (_auth) await _token.commit(ref.read(secretStoreProvider));
          final g = GrafanaConfig(
            id: _id,
            name: _name.text.trim(),
            url: _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
            tokenRef: _auth ? _token.ref : null,
            defaultDashboardUid: _dash.text.trim().isEmpty ? null : _dash.text.trim(),
            favorites: _orig?.favorites ?? const [],
            refreshSeconds: int.parse(_refresh.text),
            defaultRange: _range.text.trim(),
          );
          await ref.read(profileProvider.notifier).update((p) =>
              p.copyWith(integrations: p.integrations.copyWith(grafana: upsertBy(p.integrations.grafana, g, (e) => e.id))));
        }),
        children: [
          FieldCard(children: [
            TField(controller: _name, label: l.hostName, validator: requiredV(l)),
            TField(controller: _url, label: 'URL', hint: 'https://atlas.tailnet.ts.net:3030', keyboardType: TextInputType.url, validator: urlV(l)),
          ]),
          GroupedSection(children: [SwitchRow(title: l.integrationToken, value: _auth, onChanged: (v) => setState(() => _auth = v))]),
          if (_auth) FieldCard(children: [SecretFieldView(input: _token, label: l.integrationServiceAccountToken)]),
          FieldCard(title: l.integrationDefaults, children: [
            TField(controller: _dash, label: l.integrationDefaultDashboard, hint: 'systems-overview', mono: true),
            Row(children: [
              Expanded(child: TField(controller: _refresh, label: l.integrationRefreshSeconds, keyboardType: TextInputType.number, validator: intV(0, 3600))),
              const SizedBox(width: 10),
              Expanded(child: TField(controller: _range, label: l.integrationRange, mono: true, validator: requiredV(l))),
            ]),
          ]),
          const SizedBox(height: 14),
          TestButton(
            run: () async => testHttp('${_url.text.trim()}/api/health',
                bearer: _auth ? (_token.controller.text.isNotEmpty ? _token.controller.text : await ref.read(secretStoreProvider).read(_token.secretId)) : null),
          ),
          if (_orig != null) _DeleteRow(onDelete: () async {
            await ref.read(profileProvider.notifier).update((p) => p.copyWith(
                integrations: p.integrations.copyWith(grafana: p.integrations.grafana.where((g) => g.id != _orig!.id).toList())));
          }),
        ],
      ),
    );
  }
}

// ───────── Dozzle ─────────

class DozzleEditScreen extends ConsumerStatefulWidget {
  const DozzleEditScreen({super.key, this.id});
  final String? id;
  @override
  ConsumerState<DozzleEditScreen> createState() => _DozzleEditState();
}

class _DozzleEditState extends ConsumerState<DozzleEditScreen> with _Saving {
  final _name = TextEditingController(text: 'Dozzle');
  final _url = TextEditingController();
  final _user = TextEditingController();
  late final SecretInput _pass;
  bool _auth = false;
  DozzleConfig? _orig;

  @override
  void initState() {
    super.initState();
    _orig = ref.read(profileProvider).integrations.dozzle.where((g) => g.id == widget.id).firstOrNull;
    _pass = SecretInput(_orig?.passwordRef != null ? secretIdOf(_orig!.passwordRef!) : '');
    if (_orig != null) {
      _name.text = _orig!.name;
      _url.text = _orig!.url;
      _user.text = _orig!.username ?? '';
      _auth = _orig!.passwordRef != null;
    }
  }

  String get _id => _orig?.id ?? slugify('dozzle-${_name.text}');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Dozzle',
        saving: saving,
        onSave: () => runSave(() async {
          if (_pass.secretId.isEmpty) _pass.secretId = _id;
          if (_auth) await _pass.commit(ref.read(secretStoreProvider));
          final d = DozzleConfig(
            id: _id,
            name: _name.text.trim(),
            url: _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
            username: _auth ? _user.text.trim() : null,
            passwordRef: _auth ? _pass.ref : null,
          );
          await ref.read(profileProvider.notifier).update((p) =>
              p.copyWith(integrations: p.integrations.copyWith(dozzle: upsertBy(p.integrations.dozzle, d, (e) => e.id))));
        }),
        children: [
          FieldCard(children: [
            TField(controller: _name, label: l.hostName, validator: requiredV(l)),
            TField(controller: _url, label: 'URL', hint: 'https://atlas.tailnet.ts.net:8888', keyboardType: TextInputType.url, validator: urlV(l)),
          ]),
          GroupedSection(children: [SwitchRow(title: l.integrationLogin, value: _auth, onChanged: (v) => setState(() => _auth = v))]),
          if (_auth)
            FieldCard(children: [
              TField(controller: _user, label: l.hostSshUser, validator: requiredV(l)),
              SecretFieldView(input: _pass, label: l.hostSshPassword),
            ]),
          const SizedBox(height: 14),
          TestButton(run: () => testHttp('${_url.text.trim()}/healthcheck')),
          if (_orig != null) _DeleteRow(onDelete: () async {
            await ref.read(profileProvider.notifier).update((p) => p.copyWith(
                integrations: p.integrations.copyWith(dozzle: p.integrations.dozzle.where((g) => g.id != _orig!.id).toList())));
          }),
        ],
      ),
    );
  }
}

// ───────── Homepage ─────────

class HomepageEditScreen extends ConsumerStatefulWidget {
  const HomepageEditScreen({super.key});
  @override
  ConsumerState<HomepageEditScreen> createState() => _HomepageEditState();
}

class _HomepageEditState extends ConsumerState<HomepageEditScreen> with _Saving {
  final _url = TextEditingController();
  final _path = TextEditingController(text: '~/homepage/homepage/services.yaml');
  String? _hostId;
  bool _inApp = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    final h = p.integrations.homepage;
    _hostId = h?.hostId ?? p.hosts.where((x) => x.agent != null).firstOrNull?.id;
    if (h != null) {
      _url.text = h.browserUrl;
      _path.text = h.path;
      _inApp = h.openInApp;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Homepage',
        saving: saving,
        onSave: () => runSave(() async {
          final h = HomepageConfig(browserUrl: _url.text.trim(), hostId: _hostId!, path: _path.text.trim(), openInApp: _inApp);
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(homepage: () => h)));
        }),
        children: [
          FieldCard(children: [
            TField(controller: _url, label: l.integrationBrowserUrl, hint: 'https://argo.tailnet.ts.net:8443', keyboardType: TextInputType.url, validator: urlV(l)),
            _HostDropdown(hosts: p.hosts.where((h) => h.agent != null).toList(), value: _hostId, label: l.integrationReadVia, onChanged: (v) => setState(() => _hostId = v)),
            TField(controller: _path, label: l.integrationServicesFile, mono: true, validator: requiredV(l)),
          ]),
          GroupedSection(children: [SwitchRow(title: l.integrationOpenInApp, value: _inApp, onChanged: (v) => setState(() => _inApp = v))]),
          const SizedBox(height: 14),
          TestButton(run: () => testHttp(_url.text.trim(), acceptRedirect: true)),
          if (p.integrations.homepage != null)
            _DeleteRow(onDelete: () => ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(homepage: () => null)))),
        ],
      ),
    );
  }
}

// ───────── Uptime Kuma ─────────

class UptimeEditScreen extends ConsumerStatefulWidget {
  const UptimeEditScreen({super.key});
  @override
  ConsumerState<UptimeEditScreen> createState() => _UptimeEditState();
}

class _UptimeEditState extends ConsumerState<UptimeEditScreen> with _Saving {
  final _url = TextEditingController();
  final _interval = TextEditingController(text: '60');
  final _alert = TextEditingController(text: '120');
  final _cert = TextEditingController(text: '14');
  String? _via;
  bool _recovery = true;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    final u = p.integrations.uptimeKuma;
    _via = u?.viaHostId ?? p.hosts.where((x) => x.agent != null).firstOrNull?.id;
    if (u != null) {
      _url.text = u.url;
      _interval.text = '${u.intervalSeconds}';
      _alert.text = '${u.alertAfterSeconds}';
      _cert.text = '${u.certExpiryDays}';
      _recovery = u.notifyOnRecovery;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Uptime Kuma',
        saving: saving,
        onSave: () => runSave(() async {
          final u = UptimeKumaConfig(
            viaHostId: _via!,
            url: _url.text.trim(),
            intervalSeconds: int.parse(_interval.text),
            alertAfterSeconds: int.parse(_alert.text),
            certExpiryDays: int.parse(_cert.text),
            notifyOnRecovery: _recovery,
          );
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(uptimeKuma: () => u)));
        }),
        children: [
          FieldCard(children: [
            TField(controller: _url, label: 'URL', hint: 'https://atlas.tailnet.ts.net:3001', keyboardType: TextInputType.url, validator: urlV(l)),
            _HostDropdown(hosts: p.hosts.where((h) => h.agent != null).toList(), value: _via, label: l.integrationReadVia, onChanged: (v) => setState(() => _via = v)),
            Text(l.uptimeCredentialsOnAgent, style: Theme.of(context).textTheme.bodySmall),
          ]),
          FieldCard(title: l.integrationDefaults, children: [
            TField(controller: _interval, label: l.uptimeInterval, keyboardType: TextInputType.number, validator: intV(20, 86400)),
            TField(controller: _alert, label: l.uptimeAlertAfter, keyboardType: TextInputType.number, validator: intV(0, 86400)),
            TField(controller: _cert, label: l.uptimeCertDays, keyboardType: TextInputType.number, validator: intV(0, 365)),
          ]),
          GroupedSection(children: [SwitchRow(title: l.uptimeNotifyRecovery, value: _recovery, onChanged: (v) => setState(() => _recovery = v))]),
          const SizedBox(height: 14),
          TestButton(run: () => testHttp('${_url.text.trim()}/api/entry-page')),
          if (p.integrations.uptimeKuma != null)
            _DeleteRow(onDelete: () => ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(uptimeKuma: () => null)))),
        ],
      ),
    );
  }
}

// ───────── ntfy ─────────

class NtfyEditScreen extends ConsumerStatefulWidget {
  const NtfyEditScreen({super.key});
  @override
  ConsumerState<NtfyEditScreen> createState() => _NtfyEditState();
}

class _NtfyEditState extends ConsumerState<NtfyEditScreen> with _Saving {
  final _url = TextEditingController();
  final _topics = TextEditingController(text: 'siteler');

  @override
  void initState() {
    super.initState();
    final n = ref.read(profileProvider).integrations.ntfy;
    if (n != null) {
      _url.text = n.url;
      _topics.text = n.topics.join(', ');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'ntfy',
        saving: saving,
        onSave: () => runSave(() async {
          final n = NtfyConfig(
            url: _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
            topics: _topics.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
          );
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(ntfy: () => n)));
        }),
        children: [
          _Explain(l.ntfyExplain),
          FieldCard(children: [
            TField(controller: _url, label: 'URL', hint: 'https://atlas.tailnet.ts.net:2586', keyboardType: TextInputType.url, validator: urlV(l)),
            TField(controller: _topics, label: l.ntfyTopics, hint: 'siteler, alerts', helper: l.ntfyTopicsHint),
          ]),
          const SizedBox(height: 14),
          TestButton(run: () => testHttp('${_url.text.trim()}/v1/health')),
          if (p.integrations.ntfy != null)
            _DeleteRow(onDelete: () => ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(ntfy: () => null)))),
        ],
      ),
    );
  }
}

class _Explain extends StatelessWidget {
  const _Explain(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text(text, style: TextStyle(color: context.tokens.textSecondary, fontSize: 13)));
}

// ───────── Scriberr ─────────

class ScriberrEditScreen extends ConsumerStatefulWidget {
  const ScriberrEditScreen({super.key});
  @override
  ConsumerState<ScriberrEditScreen> createState() => _ScriberrEditState();
}

class _ScriberrEditState extends ConsumerState<ScriberrEditScreen> with _Saving {
  String _lang = 'tr';
  String _model = 'small';

  @override
  void initState() {
    super.initState();
    final s = ref.read(profileProvider).integrations.scriberr;
    if (s != null) {
      _lang = s.language;
      _model = s.model;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Scriberr',
        saving: saving,
        onSave: () => runSave(() async {
          final s = ScriberrConfig(language: _lang, model: _model);
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(scriberr: () => s)));
        }),
        children: [
          _Explain(l.scriberrExplain),
          ChoiceSection<String>(
            title: l.appearanceLanguage,
            value: _lang,
            options: [('tr', l.appearanceLanguageTr), ('en', l.appearanceLanguageEn), ('auto', l.scriberrAutoDetect)],
            onChanged: (v) => setState(() => _lang = v),
          ),
          ChoiceSection<String>(
            title: l.scriberrModel,
            value: _model,
            options: [('small', l.scriberrModelSmall), ('large-v3', l.scriberrModelLarge)],
            onChanged: (v) => setState(() => _model = v),
          ),
          if (p.integrations.scriberr != null)
            _DeleteRow(onDelete: () => ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(scriberr: () => null)))),
        ],
      ),
    );
  }
}

// ───────── Obsidian ─────────

class ObsidianEditScreen extends ConsumerStatefulWidget {
  const ObsidianEditScreen({super.key});
  @override
  ConsumerState<ObsidianEditScreen> createState() => _ObsidianEditState();
}

class _ObsidianEditState extends ConsumerState<ObsidianEditScreen> with _Saving {
  final _vault = TextEditingController();
  final _folder = TextEditingController(text: 'Gelen kutusu');
  final _daily = TextEditingController(text: 'Günlük/YYYY-MM-DD');
  String _mode = 'newNote';

  @override
  void initState() {
    super.initState();
    final o = ref.read(profileProvider).integrations.obsidian;
    if (o != null) {
      _vault.text = o.vault;
      _folder.text = o.folder;
      _daily.text = o.dailyNotePath;
      _mode = o.mode;
    }
  }

  @override
  void dispose() {
    _vault.dispose();
    _folder.dispose();
    _daily.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = ref.watch(profileProvider);
    return Form(
      key: form,
      child: SettingsPage(
        title: 'Obsidian',
        saving: saving,
        onSave: () => runSave(() async {
          final o = ObsidianConfig(
            vault: _vault.text.trim(),
            folder: _folder.text.trim(),
            mode: _mode,
            dailyNotePath: _daily.text.trim().isEmpty ? 'Günlük/YYYY-MM-DD' : _daily.text.trim(),
          );
          await ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(obsidian: () => o)));
        }),
        children: [
          _Explain(l.obsidianExplain),
          FieldCard(children: [
            TField(controller: _vault, label: l.obsidianVault, hint: 'Notlar', helper: l.obsidianVaultHelper, validator: requiredV(l), autofocus: p.integrations.obsidian == null),
            TField(controller: _folder, label: l.obsidianFolder, hint: 'Gelen kutusu'),
            TField(controller: _daily, label: l.obsidianDailyPath, hint: 'Günlük/YYYY-MM-DD', helper: l.obsidianDailyPathHelper),
          ]),
          ChoiceSection<String>(
            title: l.obsidianMode,
            value: _mode,
            options: [('newNote', l.noteModeNew), ('dailyNote', l.noteModeDaily)],
            onChanged: (v) => setState(() => _mode = v),
          ),
          if (p.integrations.obsidian != null)
            _DeleteRow(onDelete: () => ref.read(profileProvider.notifier).update((p) => p.copyWith(integrations: p.integrations.copyWith(obsidian: () => null)))),
        ],
      ),
    );
  }
}

// ───────── shared pieces ─────────

class _HostDropdown extends StatelessWidget {
  const _HostDropdown({required this.hosts, required this.value, required this.label, required this.onChanged});
  final List<Host> hosts;
  final String? value;
  final String label;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return DropdownButtonFormField<String>(
      initialValue: hosts.any((h) => h.id == value) ? value : null,
      decoration: InputDecoration(labelText: label, helperText: hosts.isEmpty ? l.integrationNeedsAgentHost : null, helperMaxLines: 2),
      items: [for (final h in hosts) DropdownMenuItem(value: h.id, child: Text(h.name))],
      onChanged: onChanged,
      validator: (v) => v == null ? l.commonRequired : null,
    );
  }
}

class _DeleteRow extends StatelessWidget {
  const _DeleteRow({required this.onDelete});
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: GroupedSection(children: [
        GroupedRow(
          title: l.commonDelete,
          destructive: true,
          showChevron: false,
          onTap: () async {
            if (!await confirmDialog(context, message: l.integrationDeleteConfirm, confirmLabel: l.commonDelete, destructive: true)) return;
            await onDelete();
            if (context.mounted) context.pop();
          },
        ),
      ]),
    );
  }
}
