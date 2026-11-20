// Agent self-update from the phone (K8): GET /v1/update says whether a newer signed release exists and whether this
// install can update itself (`managed`, an install.sh layout). "Update" asks for confirmation and the app lock, calls
// POST /v1/update/apply {version, confirm: true}, then polls the tokenless /v1/health until the new version answers.
// Unmanaged installs (git checkout, package, Docker) get the manual way instead.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../core/links.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../lock/lock_gate.dart';
import 'agent_providers.dart';
import 'doctor.dart' show CommandBox;

class UpdateInfo {
  const UpdateInfo({required this.current, this.latest, this.available = false, this.managed = false, this.notesUrl, this.error});
  final String current;
  final String? latest;
  final bool available;
  final bool managed;
  final String? notesUrl;
  final String? error;

  factory UpdateInfo.fromJson(Map j) => UpdateInfo(
        current: '${j['current'] ?? ''}',
        latest: j['latest'] as String?,
        available: j['available'] == true && j['latest'] is String,
        managed: j['managed'] == true,
        notesUrl: j['notesUrl'] as String?,
        error: j['error'] as String?,
      );
}

/// null: the agent is older than the update route.
final agentUpdateProvider = FutureProvider.autoDispose.family<UpdateInfo?, String>((ref, hostId) async {
  try {
    return UpdateInfo.fromJson(await withAgent(ref, hostId, (c) => c.get('/v1/update')));
  } on AgentError catch (e) {
    if (e.code == 'agent.route.notFound') return null;
    rethrow;
  }
});

/// Asks for the app lock again before an update. Without a lock set up, the confirmation dialog is the only gate:
/// the release is signed and checked by the agent, and a failed start rolls back by itself. Overridden in tests.
final updateAuthProvider = Provider<Future<bool> Function(BuildContext)>((ref) => (context) async {
      final l = AppLocalizations.of(context);
      if (!await ref.read(lockRequiredProvider.future)) return true;
      if (!context.mounted) return false;
      final ok = await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => PopScope(
          child: LockScreen(title: l.updateAuthTitle, onUnlocked: () => Navigator.of(c).pop(true), onCancel: () => Navigator.of(c).pop(false)),
        ),
      ));
      return ok ?? false;
    });

/// How often and how long to wait for the restarted agent. Overridden in tests.
final updateWaitProvider = Provider<({Duration every, int tries})>((ref) => (every: const Duration(seconds: 2), tries: 60));

/// Polls [health] until it reports [version]; false after [tries] attempts. Errors (agent restarting) are expected.
Future<bool> waitForAgentVersion(Future<Map<String, dynamic>> Function() health, String version, {Duration every = const Duration(seconds: 2), int tries = 60}) async {
  for (var i = 0; i < tries; i++) {
    try {
      if ((await health())['version'] == version) return true;
    } catch (_) {
      // Down while it restarts.
    }
    await Future<void>.delayed(every);
  }
  return false;
}

String updateErrorText(AppLocalizations l, String code, Map<String, dynamic> p) => switch (code) {
      'agent.update.disabled' => l.updateErrDisabled,
      'agent.update.notManaged' => l.updateErrNotManaged,
      'agent.update.notNewer' => l.updateErrNotNewer('${p['current'] ?? ''}'),
      'agent.update.unsupportedPlatform' => l.updateErrPlatform('${p['platform'] ?? ''}', '${p['arch'] ?? ''}'),
      'agent.update.noKey' => l.updateErrNoKey,
      'agent.update.busy' => l.updateErrBusy,
      'agent.update.unreachable' => l.updateErrUnreachable,
      'agent.update.badSignature' || 'agent.update.badChecksum' || 'agent.update.badBundle' || 'agent.update.missingAsset' => l.updateErrBadRelease,
      _ => l.updateErrFailed(code),
    };

/// System › Agent row: "Update available x.y.z" (shown only when the agent reports one).
class AgentUpdateRow extends ConsumerWidget {
  const AgentUpdateRow({super.key, required this.host, required this.info});
  final Host host;
  final UpdateInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return GroupedRow(
      title: l.updateAvailable(info.latest!),
      subtitle: info.managed ? l.updateRowHint(info.current) : l.updateRowManualHint(info.current),
      icon: LucideIcons.download,
      iconBackground: t.accent,
      onTap: () => info.managed ? startAgentUpdate(context, ref, host, info) : showManualUpdate(context, info),
    );
  }
}

/// How to update an install that can't update itself.
Future<void> showManualUpdate(BuildContext context, UpdateInfo info) {
  final l = AppLocalizations.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.updateManualTitle(info.latest ?? ''), style: Theme.of(c).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(l.updateManualBody, style: Theme.of(c).textTheme.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 12),
          CommandBox(command: kInstallCommands[InstallTarget.linux]!, label: l.updateManualInstaller),
          const SizedBox(height: 8),
          CommandBox(command: 'git pull && (cd agent && npm ci && npm run build) && systemctl --user restart tiphys-agent', label: l.updateManualCheckout),
          const SizedBox(height: 8),
          Text(l.updateManualPackages, style: Theme.of(c).textTheme.bodySmall),
        ]),
      ),
    ),
  );
}

/// Confirmation → app lock → apply → wait for the new version. Errors are shown in a dialog.
Future<void> startAgentUpdate(BuildContext context, WidgetRef ref, Host host, UpdateInfo info) async {
  final l = AppLocalizations.of(context);
  final version = info.latest!;
  if (!await confirmDialog(context, message: l.updateConfirm(host.name, info.current, version), confirmLabel: l.updateAction)) return;
  if (!context.mounted || !await ref.read(updateAuthProvider)(context) || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateProgressDialog(host: host, version: version),
  );
  ref.invalidate(agentUpdateProvider(host.id));
  ref.invalidate(healthProvider(host.id));
  ref.invalidate(agentStatusProvider(host.id));
  if (ok == true && context.mounted) toast(context, l.updateDone(host.name, version));
}

enum _Phase { applying, restarting, timeout, failed }

class _UpdateProgressDialog extends ConsumerStatefulWidget {
  const _UpdateProgressDialog({required this.host, required this.version});
  final Host host;
  final String version;
  @override
  ConsumerState<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends ConsumerState<_UpdateProgressDialog> {
  _Phase _phase = _Phase.applying;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      // Downloading and checking the bundle can take a while on a slow line.
      final c = await ref.read(agentClientFactoryProvider)(widget.host);
      try {
        await c.request('POST', '/v1/update/apply', body: {'version': widget.version, 'confirm': true}, timeout: const Duration(minutes: 3));
      } finally {
        c.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = agentErrorText(AppLocalizations.of(context), e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.restarting);
    final wait = ref.read(updateWaitProvider);
    final health = ref.read(agentHealthFnProvider);
    final up = await waitForAgentVersion(() => health(widget.host.agent!.url), widget.version, every: wait.every, tries: wait.tries);
    if (!mounted) return;
    if (up) return Navigator.of(context).pop(true);
    setState(() => _phase = _Phase.timeout);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final busy = _phase == _Phase.applying || _phase == _Phase.restarting;
    return AlertDialog(
      title: Text(l.updateTitle(widget.host.name)),
      content: Semantics(
        liveRegion: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (busy)
            const Padding(padding: EdgeInsets.only(top: 2), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)))
          else
            Icon(LucideIcons.circleAlert, color: t.danger),
          const SizedBox(width: 14),
          Expanded(
            child: Text(switch (_phase) {
              _Phase.applying => l.updateApplying(widget.version),
              _Phase.restarting => l.updateRestarting(widget.version),
              _Phase.timeout => l.updateTimeout(widget.version),
              _ => _error ?? l.commonError,
            }, style: const TextStyle(height: 1.35)),
          ),
        ]),
      ),
      actions: busy
          ? null
          : [
              if (_phase == _Phase.timeout)
                TextButton(
                  onPressed: () {
                    final router = GoRouter.of(context);
                    Navigator.of(context).pop(false);
                    router.push('/settings/hosts/health?id=${widget.host.id}');
                  },
                  child: Text(l.doctorTitle),
                ),
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l.commonClose)),
            ],
    );
  }
}
