// High quality mode (10.2 Stage B): Sunshine on the PC (NVENC, 60 fps) → Moonlight on the phone. The page,
// opened from the live screen's quality menu and from Desktop › Tools, shows the first blocker:
//   Sunshine not installed → copyable install commands for this PC;
//   installed but stopped → start (control session, lock asked again);
//   Moonlight not on the phone → Google Play / F-Droid;
//   ready → open Moonlight (straight to that PC's app list if there's a paired PC, ShortcutTrampoline) and
//   "Enter Moonlight PIN": the PIN goes to the Sunshine API via the agent, no Sunshine web UI needed.
// The Sunshine web username/password stay only on the agent (Agent settings › Sunshine).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys_native/tiphys_native.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../system/agent_providers.dart';
import 'desktop_data.dart';

const moonlightPackage = 'com.limelight';
const moonlightPlayUrl = 'https://play.google.com/store/apps/details?id=com.limelight';
const moonlightFdroidUrl = 'https://f-droid.org/packages/com.limelight/';

/// Install for Debian sid/trixie (latest SunshineStream/Sunshine release, trixie package). The package's postinst
/// script sets up the udev rules, uinput/uhid and setcap (cap_sys_admin for KMS capture) by itself.
const sunshineInstallCommands = '''cd /tmp
wget -O sunshine.deb https://github.com/SunshineStream/Sunshine/releases/download/v2026.914.233613/sunshine_2026.914.233613-1%2Bdebiantrixie_amd64.deb
sudo apt install ./sunshine.deb
sunshine --creds KULLANICI SIFRE
mkdir -p ~/.config/sunshine
printf 'capture = wlr\\nencoder = nvenc\\n' >> ~/.config/sunshine/sunshine.conf
systemctl --user start app-dev.lizardbyte.app.Sunshine''';

class SunshineStatus {
  SunshineStatus(Map j)
      : installed = j['installed'] == true,
        version = j['version'] as String?,
        running = j['running'] == true,
        capture = j['capture'] as String?,
        encoder = j['encoder'] as String?,
        credentials = j['credentials'] == true,
        api = '${j['api'] ?? 'stopped'}',
        pairedClients = (j['pairedClients'] as num?)?.toInt(),
        uniqueId = j['uniqueId'] as String?,
        hostName = j['hostName'] as String?;
  final bool installed;
  final String? version;
  final bool running;
  final String? capture;
  final String? encoder;
  final bool credentials;

  /// ok | noCredentials | unauthorized | setupRequired | unreachable | stopped
  final String api;
  final int? pairedClients;
  final String? uniqueId;
  final String? hostName;
}

final sunshineStatusProvider = FutureProvider.autoDispose.family<SunshineStatus, String>((ref, hostId) async {
  return SunshineStatus(await withAgent(ref, hostId, (c) => c.get('/v1/desktop/sunshine')));
});

/// Moonlight on the phone (a fake is given in tests).
abstract class MoonlightApp {
  Future<bool> installed();

  /// If [uuid]/[name] are given, that PC's app list (must be paired in Moonlight); otherwise the Moonlight home screen.
  Future<bool> open({String? uuid, String? name});
}

class NativeMoonlight implements MoonlightApp {
  @override
  Future<bool> installed() async {
    try {
      return await TiphysNative.isPackageInstalled(moonlightPackage);
    } on Exception {
      return false; // PlatformException / MissingPluginException (non-Android)
    }
  }

  @override
  Future<bool> open({String? uuid, String? name}) async {
    try {
      // ShortcutTrampoline is exported; finds the PC by "UUID" (server uniqueid) or "Name". If it's missing in an old
      // version or the PC is unknown, Moonlight shows its own error; with no activity at all, fall back to the launcher.
      if (uuid != null || name != null) {
        final ok = await TiphysNative.startActivity(moonlightPackage, component: 'com.limelight.ShortcutTrampoline', extras: {
          'UUID': ?uuid,
          'Name': ?name,
        });
        if (ok) return true;
      }
      return await TiphysNative.startActivity(moonlightPackage);
    } on Exception {
      return false; // PlatformException / MissingPluginException (non-Android)
    }
  }
}

final moonlightProvider = Provider<MoonlightApp>((ref) => NativeMoonlight());
final moonlightInstalledProvider = FutureProvider.autoDispose<bool>((ref) => ref.watch(moonlightProvider).installed());

enum MoonlightStage { notInstalled, stopped, noMoonlight, ready }

MoonlightStage moonlightStage(SunshineStatus s, bool moonlight) => !s.installed
    ? MoonlightStage.notInstalled
    : !s.running
        ? MoonlightStage.stopped
        : !moonlight
            ? MoonlightStage.noMoonlight
            : MoonlightStage.ready;

Future<void> showMoonlightSheet(BuildContext context, String hostId) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MoonlightSheet(hostId: hostId),
    );

class MoonlightSheet extends ConsumerStatefulWidget {
  const MoonlightSheet({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<MoonlightSheet> createState() => _MoonlightSheetState();
}

class _MoonlightSheetState extends ConsumerState<MoonlightSheet> {
  late final AppLifecycleListener _life;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The status is re-read on return from the Play Store / the terminal on the PC.
    _life = AppLifecycleListener(onResume: _refresh);
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(sunshineStatusProvider(widget.hostId));
    ref.invalidate(moonlightInstalledProvider);
  }

  bool get _controlOff {
    final f = ref.read(healthProvider(widget.hostId)).value?['features'] as Map?;
    return f != null && f['control'] != true;
  }

  Future<void> _service(bool start) async {
    final l = AppLocalizations.of(context);
    if (_controlOff) return toast(context, l.desktopControlOffHint);
    setState(() => _busy = true);
    await desktopAction(context, ref, widget.hostId, '/v1/desktop/sunshine/${start ? 'start' : 'stop'}', done: start ? l.sunshineStarted : l.sunshineStoppedDone);
    if (!mounted) return;
    setState(() => _busy = false);
    ref.invalidate(sunshineStatusProvider(widget.hostId));
  }

  Future<void> _open(SunshineStatus s) async {
    final l = AppLocalizations.of(context);
    final paired = (s.pairedClients ?? 0) > 0;
    final ok = await ref.read(moonlightProvider).open(uuid: paired ? s.uniqueId : null, name: paired ? s.hostName : null);
    if (!ok && mounted) toast(context, l.moonlightOpenFailed);
  }

  Future<void> _pin() async {
    final l = AppLocalizations.of(context);
    if (_controlOff) return toast(context, l.desktopControlOffHint);
    final paired = await showMoonlightPinSheet(context, widget.hostId);
    if (paired && mounted) ref.invalidate(sunshineStatusProvider(widget.hostId));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    final hostName = host?.name ?? widget.hostId;
    final status = ref.watch(sunshineStatusProvider(widget.hostId));
    final moonlight = ref.watch(moonlightInstalledProvider);

    Widget body;
    if (status.hasError) {
      body = _StateCard(
        icon: LucideIcons.circleAlert,
        color: t.danger,
        title: agentErrorText(l, status.error!),
        children: [TextButton(onPressed: _refresh, child: Text(l.commonRetry))],
      );
    } else if (!status.hasValue || !moonlight.hasValue) {
      body = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    } else {
      final s = status.value!;
      body = switch (moonlightStage(s, moonlight.value!)) {
        MoonlightStage.notInstalled => _StateCard(
            icon: LucideIcons.packageX,
            color: t.warning,
            title: l.sunshineNotInstalledTitle,
            text: l.sunshineNotInstalledBody(hostName),
            children: [
              const _Commands(code: sunshineInstallCommands),
              Text(l.sunshineInstallNote, style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.35)),
            ],
          ),
        MoonlightStage.stopped => _StateCard(
            icon: LucideIcons.circlePause,
            color: t.warning,
            title: l.sunshineStoppedTitle,
            text: l.sunshineStoppedBody(hostName),
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _service(true),
                icon: const Icon(LucideIcons.play, size: 18),
                label: Text(l.sunshineStart),
              ),
            ],
          ),
        MoonlightStage.noMoonlight => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _RunningLine(s: s),
            const SizedBox(height: 12),
            _StateCard(
              icon: LucideIcons.smartphone,
              color: t.warning,
              title: l.moonlightMissingTitle,
              text: l.moonlightMissingBody,
              children: [
                FilledButton.icon(
                  onPressed: () => launchUrl(Uri.parse(moonlightPlayUrl), mode: LaunchMode.externalApplication),
                  icon: const Icon(LucideIcons.store, size: 18),
                  label: const Text('Google Play'),
                ),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(moonlightFdroidUrl), mode: LaunchMode.externalApplication),
                  icon: const Icon(LucideIcons.externalLink, size: 18),
                  label: const Text('F-Droid'),
                ),
              ],
            ),
          ]),
        MoonlightStage.ready => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _RunningLine(s: s),
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: () => _open(s), icon: const Icon(LucideIcons.gamepad2, size: 18), label: Text(l.moonlightOpen)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: s.api == 'ok' ? _pin : null,
              icon: const Icon(LucideIcons.keyRound, size: 18),
              label: Text(l.moonlightEnterPin),
            ),
            if (s.api != 'ok') ...[
              const SizedBox(height: 12),
              _ApiNote(api: s.api, hostId: widget.hostId),
            ],
            const SizedBox(height: 12),
            Text(l.moonlightFirstTime(host?.address ?? hostName), style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.35)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : () => _service(false),
                icon: Icon(LucideIcons.power, size: 16, color: t.danger),
                label: Text(l.sunshineStop, style: TextStyle(color: t.danger)),
              ),
            ),
          ]),
      };
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: const Color(0xFF5E5CE6), borderRadius: BorderRadius.circular(12)),
              child: const Icon(LucideIcons.gamepad2, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(header: true, child: Text(l.moonlightEntry, style: Theme.of(context).textTheme.titleMedium)),
                Text(l.moonlightSubtitle, style: TextStyle(color: t.textSecondary, fontSize: 13)),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          body,
        ]),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.icon, required this.color, required this.title, this.text, this.children = const []});
  final IconData icon;
  final Color color;
  final String title;
  final String? text;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.isDark ? t.chipBackground : t.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.separator),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5))),
        ]),
        if (text != null) ...[
          const SizedBox(height: 8),
          Text(text!, style: TextStyle(color: t.textSecondary, height: 1.35)),
        ],
        for (final c in children) ...[const SizedBox(height: 12), c],
      ]),
    );
  }
}

/// Sunshine is running: version, capture, encoder, number of paired devices.
class _RunningLine extends StatelessWidget {
  const _RunningLine({required this.s});
  final SunshineStatus s;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(LucideIcons.circleCheck, color: t.success, size: 20)),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.sunshineRunning, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            [
              ?s.version,
              l.sunshineInfo(s.capture ?? l.sunshineDefault, s.encoder ?? l.sunshineDefault, s.pairedClients == null ? '–' : '${s.pairedClients}'),
            ].join(' · '),
            style: TextStyle(color: t.textSecondary, fontSize: 13),
          ),
        ]),
      ),
    ]);
  }
}

/// Web API unavailable: reason + (if needed) go to Agent settings.
class _ApiNote extends StatelessWidget {
  const _ApiNote({required this.api, required this.hostId});
  final String api;
  final String hostId;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final text = switch (api) {
      'noCredentials' => l.sunshineNoCredentials,
      'unauthorized' => l.sunshineUnauthorized,
      'setupRequired' => l.sunshineSetupRequired,
      _ => l.sunshineUnreachable,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.triangleAlert, color: t.warning, size: 18)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(height: 1.35, fontSize: 13.5))),
      ]),
      if (api == 'noCredentials' || api == 'unauthorized')
        TextButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            GoRouter.of(context).push('/settings/hosts/agent?id=$hostId');
          },
          icon: const Icon(LucideIcons.slidersHorizontal, size: 16),
          label: Text(l.agentSettings),
        ),
    ]);
  }
}

class _Commands extends StatelessWidget {
  const _Commands({required this.code});
  final String code;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: BoxDecoration(color: t.isDark ? const Color(0x33000000) : t.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: t.separator)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            code,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.45, fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')]),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: sunshineInstallCommands));
            toast(context, l.commonCopied);
          },
          icon: const Icon(LucideIcons.copy, size: 16),
          label: Text(l.sunshineCopyAll),
        ),
      ),
    ]);
  }
}

// ---- PIN ----

/// Sends the PIN shown by Moonlight to Sunshine via the agent; true if paired.
Future<bool> showMoonlightPinSheet(BuildContext context, String hostId) async =>
    await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MoonlightPinSheet(hostId: hostId),
    ) ??
    false;

class MoonlightPinSheet extends ConsumerStatefulWidget {
  const MoonlightPinSheet({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<MoonlightPinSheet> createState() => _MoonlightPinSheetState();
}

class _MoonlightPinSheetState extends ConsumerState<MoonlightPinSheet> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context);
    final pin = _pin.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) return setState(() => _error = l.sunshineBadPin);
    setState(() {
      _busy = true;
      _error = null;
    });
    final ctrl = ref.read(controlProvider.notifier);
    try {
      final s = await ctrl.ensure(context, widget.hostId);
      if (s == null) return;
      final host = ref.read(profileProvider).host(widget.hostId);
      if (host == null) throw const AgentError('agent.notConfigured');
      final c = await ref.read(agentClientFactoryProvider)(host);
      try {
        // Sunshine doesn't respond until Moonlight finishes the handshake (40 s limit on the agent).
        await c.request('POST', '/v1/desktop/sunshine/pair', body: {'pin': pin}, headers: {controlHeader: s.token}, timeout: const Duration(seconds: 50));
      } finally {
        c.close();
      }
      if (!mounted) return;
      toast(context, l.moonlightPaired);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (e is AgentError && e.code == 'agent.control.sessionRequired') ctrl.forget();
      if (mounted) setState(() => _error = agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Semantics(header: true, child: Text(l.moonlightPinTitle, style: Theme.of(context).textTheme.titleMedium)),
            const SizedBox(height: 6),
            Text(l.moonlightPinHint, style: TextStyle(color: t.textSecondary, height: 1.35)),
            const SizedBox(height: 16),
            TextField(
              controller: _pin,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              textAlign: TextAlign.center,
              autofillHints: const [AutofillHints.oneTimeCode],
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 12, fontFeatures: [FontFeature.tabularFigures()]),
              decoration: InputDecoration(labelText: 'PIN', hintText: '0000', errorText: _error, errorMaxLines: 4),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(LucideIcons.link, size: 18),
              label: Text(_busy ? l.moonlightPairing : l.moonlightPair),
            ),
          ]),
        ),
      ),
    );
  }
}
