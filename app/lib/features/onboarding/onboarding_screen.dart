// Setup wizard (K7): first launch without a host, or Settings › Set up a computer. Five steps: what Tiphys is and
// the Tailscale requirement → the one-command install for the computer's OS → pairing (QR scan or pasted code; adds
// the host) → the agent's health check → which features are on and what the risky ones would allow. Skippable at
// every step; once finished or skipped it doesn't open by itself again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/agent/agent_client.dart';
import '../../core/links.dart';
import '../../core/platform.dart';
import '../../core/profile/model.dart';
import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../settings/hosts_screens.dart' show hostPalette;
import '../settings/push_section.dart' show pushServiceProvider;
import '../system/agent_providers.dart';
import '../system/agent_settings_screen.dart' show agentFeatureName, agentFeatures;
import '../system/doctor.dart';
import '../system/pair_scanner.dart';
import 'onboarding_state.dart';

enum OnboardingStep { intro, install, pair, health, features }

/// Features that let the phone do something serious on the computer, with the plain-words risk shown in the last
/// step. All are off unless turned on (the installer never turns them on).
const riskyFeatures = ['claude', 'control', 'power', 'configfiles', 'securityFix', 'update'];

/// Adds (or refreshes) the host from a pairing code; returns its id. A host with the same agent URL gets the new token.
Future<String> addPairedHost(WidgetRef ref, PairPayload p) async {
  final profile = ref.read(profileProvider);
  final existing = profile.hosts.where((h) => h.agent?.url == p.url).firstOrNull;
  var id = existing?.id ?? slugify(p.agent);
  if (id.isEmpty) id = 'pc';
  if (existing == null) {
    final taken = {for (final h in profile.hosts) h.id};
    final base = id;
    for (var i = 2; taken.contains(id); i++) {
      id = '$base-$i';
    }
  }
  final tokenId = existing?.agent != null ? secretIdOf(existing!.agent!.tokenRef) : 'agent-$id';
  await ref.read(secretStoreProvider).write(tokenId, p.token);
  final agent = AgentRef(url: p.url, tokenRef: refOf(tokenId));
  final host = existing == null
      ? Host(id: id, name: p.agent, color: hostPalette[profile.hosts.length % hostPalette.length], address: Uri.parse(p.url).host, agent: agent)
      : Host(id: existing.id, name: existing.name, color: existing.color, address: existing.address, ssh: existing.ssh, agent: agent, wake: existing.wake, tags: existing.tags, composeRoots: existing.composeRoots);
  await ref.read(profileProvider.notifier).update((pr) => pr.copyWith(hosts: upsertBy(pr.hosts, host, (h) => h.id)));
  ref.invalidate(secretIdsProvider);
  // The new agent should get this phone's push endpoint too (if push is set up).
  unawaited(ref.read(pushServiceProvider)?.registerWithAgents());
  return id;
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.fromSettings = false, this.initialStep, this.hostId});
  final bool fromSettings;

  /// Deep link into a step (the paired host must be given for the last two).
  final String? initialStep;
  final String? hostId;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late OnboardingStep _step;
  InstallTarget _target = InstallTarget.linux;
  String? _hostId;
  String? _pairError;
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    _hostId = widget.hostId;
    _step = OnboardingStep.values.where((s) => s.name == widget.initialStep).firstOrNull ?? OnboardingStep.intro;
    if (_step.index > OnboardingStep.pair.index && _hostId == null) _step = OnboardingStep.pair;
  }

  Future<void> _exit() async {
    await ref.read(onboardingSeenProvider.notifier).markSeen();
    if (!mounted) return;
    if (widget.fromSettings && context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  void _go(int delta) => setState(() => _step = OnboardingStep.values[(_step.index + delta).clamp(0, OnboardingStep.values.length - 1)]);

  Future<void> _pair(Future<PairPayload?> Function(BuildContext) pick) async {
    final l = AppLocalizations.of(context);
    final p = await pick(context);
    if (p == null || !mounted) return;
    setState(() {
      _pairing = true;
      _pairError = null;
    });
    try {
      final id = await addPairedHost(ref, p);
      if (mounted) setState(() => _hostId = id);
    } catch (e) {
      if (mounted) setState(() => _pairError = agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final total = OnboardingStep.values.length;
    final (primary, onPrimary) = switch (_step) {
      OnboardingStep.intro => (l.onbTailscaleHave, () => _go(1)),
      OnboardingStep.pair => (l.commonContinue, _hostId == null ? null : () => _go(1)),
      OnboardingStep.features => (l.onbFinish, _exit),
      _ => (l.commonContinue, () => _go(1)),
    };
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 8, 8, 0),
              child: Row(children: [
                Expanded(child: Text(l.onbStepOf(_step.index + 1, total), style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600))),
                TextButton(onPressed: _exit, style: TextButton.styleFrom(minimumSize: const Size(48, 48)), child: Text(l.onbSkip)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: TiphysTokens.gutter),
              child: Semantics(
                label: l.onbStepOf(_step.index + 1, total),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: (_step.index + 1) / total, minHeight: 6, backgroundColor: t.ringTrack, color: t.accent),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 20, TiphysTokens.gutter, 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (_step) {
                        OnboardingStep.intro => _intro(l, t),
                        OnboardingStep.install => _install(l, t),
                        OnboardingStep.pair => _pairStep(l, t),
                        OnboardingStep.health => _health(l),
                        OnboardingStep.features => _features(l, t),
                      }),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 8, TiphysTokens.gutter, 14),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Row(children: [
                    if (_step.index > 0) ...[
                      OutlinedButton(onPressed: () => _go(-1), style: OutlinedButton.styleFrom(minimumSize: const Size(88, 52)), child: Text(l.onbBack)),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton(
                        onPressed: onPrimary,
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                        child: Text(primary, textAlign: TextAlign.center),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(header: true, child: Text(text, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
      );

  Widget _body(String text) => Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4, color: context.tokens.textSecondary));

  List<Widget> _intro(AppLocalizations l, TiphysTokens t) => [
        Align(alignment: Alignment.centerLeft, child: Image.asset('assets/brand/icon.png', width: 64, height: 64, excludeFromSemantics: true)),
        const SizedBox(height: 16),
        _title(l.onbWelcomeTitle),
        _body(l.onbWelcomeBody),
        const SizedBox(height: 18),
        TCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.network, color: t.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(l.onbTailscaleTitle, style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 8),
            Text(l.onbTailscaleBody, style: const TextStyle(height: 1.4)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => openExternal(kTailscaleDownloadUrl),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(LucideIcons.externalLink, size: 18),
              label: Text(l.onbTailscaleInstall),
            ),
          ]),
        ),
      ];

  List<Widget> _install(AppLocalizations l, TiphysTokens t) {
    final command = kInstallCommands[_target]!;
    return [
      _title(l.onbInstallTitle),
      _body(l.onbInstallBody),
      ChoiceSection<InstallTarget>(
        title: l.onbInstallOs,
        options: [
          (InstallTarget.linux, 'Linux'),
          (InstallTarget.macos, 'macOS'),
          (InstallTarget.windows, 'Windows'),
          (InstallTarget.docker, l.onbInstallDocker),
        ],
        value: _target,
        onChanged: (v) => setState(() => _target = v),
      ),
      SectionLabel(_target == InstallTarget.windows ? l.onbInstallRunWindows : l.onbInstallRun),
      CommandBox(
        command: command,
        extra: [
          TextButton.icon(
            onPressed: () => SharePlus.instance.share(ShareParams(text: command)),
            style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
            icon: const Icon(LucideIcons.share2, size: 16),
            label: Text(l.commonShare),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(switch (_target) {
        InstallTarget.docker => l.onbInstallHintDocker,
        InstallTarget.windows => l.onbInstallHintWindows,
        _ => l.onbInstallHint,
      }, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4)),
      if (_target == InstallTarget.docker)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => openExternal(kDocsDocker),
            style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
            icon: const Icon(LucideIcons.bookOpen, size: 16),
            label: Text(l.onbInstallDockerDocs),
          ),
        ),
    ];
  }

  List<Widget> _pairStep(AppLocalizations l, TiphysTokens t) {
    final host = ref.watch(profileProvider).host(_hostId);
    return [
      _title(l.onbPairTitle),
      _body(hasQrScanner ? l.onbPairBody : l.onbPairBodyPaste),
      const SizedBox(height: 18),
      if (host != null)
        Semantics(
          liveRegion: true,
          child: TCard(
            child: Row(children: [
              Icon(LucideIcons.circleCheck, color: t.success, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.onbPaired(host.name), style: Theme.of(context).textTheme.titleMedium),
                  Text(host.agent?.url ?? host.address, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ]),
          ),
        ),
      if (_pairError != null)
        TCard(
          child: Row(children: [
            Icon(LucideIcons.circleAlert, color: t.danger),
            const SizedBox(width: 10),
            Expanded(child: Text(_pairError!)),
          ]),
        ),
      const SizedBox(height: 12),
      if (_pairing)
        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
      else ...[
        if (hasQrScanner)
          FilledButton.tonalIcon(
            onPressed: () => _pair(PairScannerPage.open),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(LucideIcons.qrCode, size: 18),
            label: Text(host == null ? l.pairWithQr : l.onbPairAgain),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _pair(PairPasteDialog.open),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(LucideIcons.clipboardPaste, size: 18),
          label: Text(l.pairPasteTitle),
        ),
      ],
      const SizedBox(height: 12),
      Text(l.onbPairLater, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4)),
    ];
  }

  List<Widget> _health(AppLocalizations l) => [
        _title(l.onbHealthTitle),
        _body(l.onbHealthBody),
        const SizedBox(height: 14),
        DoctorPanel(hostId: _hostId!),
      ];

  List<Widget> _features(AppLocalizations l, TiphysTokens t) {
    final health = ref.watch(healthProvider(_hostId!));
    return [
      _title(l.onbFeaturesTitle),
      _body(l.onbFeaturesBody),
      health.when(
        loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: TCard(
            child: Row(children: [
              Icon(LucideIcons.circleAlert, color: t.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(agentErrorText(l, e))),
              TextButton(onPressed: () => ref.invalidate(healthProvider(_hostId!)), child: Text(l.commonRetry)),
            ]),
          ),
        ),
        data: (h) {
          final features = Map<String, dynamic>.from((h['features'] as Map?) ?? const {});
          final on = [for (final f in agentFeatures) if (features[f] == true && !riskyFeatures.contains(f)) agentFeatureName(l, f)];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel(l.onbFeaturesOn),
            if (on.isEmpty)
              Text(l.onbFeaturesNone, style: Theme.of(context).textTheme.bodyMedium)
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final name in on)
                  Chip(
                    avatar: Icon(LucideIcons.check, size: 16, color: t.success),
                    label: Text(name),
                    backgroundColor: t.chipBackground,
                    side: BorderSide(color: t.separator),
                    shape: const StadiumBorder(),
                  ),
              ]),
            GroupedSection(
              title: l.onbFeaturesRisky,
              footer: l.onbFeaturesRiskyHint,
              children: [for (final f in riskyFeatures) _RiskRow(name: _riskyName(l, f), on: features[f] == true, risk: _riskText(l, f))],
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: () => context.push('/settings/hosts/agent?id=$_hostId'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
              label: Text(l.agentSettings),
            ),
          ]);
        },
      ),
    ];
  }
}

String _riskyName(AppLocalizations l, String f) => switch (f) {
      'configfiles' => l.cfTitle,
      _ => agentFeatureName(l, f),
    };

String _riskText(AppLocalizations l, String f) => switch (f) {
      'claude' => l.onbRiskClaude,
      'control' => l.onbRiskControl,
      'power' => l.onbRiskPower,
      'configfiles' => l.onbRiskConfigfiles,
      'securityFix' => l.onbRiskSecurityFix,
      _ => l.onbRiskUpdate,
    };

class _RiskRow extends StatelessWidget {
  const _RiskRow({required this.name, required this.on, required this.risk});
  final String name;
  final bool on;
  final String risk;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(on ? LucideIcons.shieldAlert : LucideIcons.shieldCheck, size: 20, color: on ? t.warning : t.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(name, style: Theme.of(context).textTheme.titleMedium)),
                Text(on ? l.commonOn : l.commonOff, style: TextStyle(color: on ? t.warning : t.textSecondary, fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
              const SizedBox(height: 3),
              Text(risk, style: TextStyle(color: t.textSecondary, height: 1.35, fontSize: 13.5)),
            ]),
          ),
        ]),
      ),
    );
  }
}
