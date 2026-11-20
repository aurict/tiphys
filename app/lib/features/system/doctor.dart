// Health check of an agent's install (K6): GET /v1/doctor, the same checks as `tiphys-agent doctor`. The agent sends
// codes; the texts and the grouping (problems, warnings, OK) are here. A `fix` is a shell command suggestion the user
// can copy; the agent never runs it. Agents older than the route answer 404: the screen asks to update the agent.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'agent_providers.dart';

enum DoctorStatus { fail, warn, ok }

class DoctorCheck {
  const DoctorCheck({required this.id, required this.status, required this.code, this.params = const {}, this.fix});
  final String id;
  final DoctorStatus status;
  final String code;
  final Map<String, dynamic> params;
  final String? fix;

  factory DoctorCheck.fromJson(Map j) => DoctorCheck(
        id: '${j['id']}',
        // An unknown status from a newer agent counts as a warning: shown, not hidden.
        status: switch (j['status']) { 'ok' => DoctorStatus.ok, 'fail' => DoctorStatus.fail, _ => DoctorStatus.warn },
        code: '${j['code']}',
        params: Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
        fix: (j['fix'] as String?)?.trim().isEmpty ?? true ? null : (j['fix'] as String).trim(),
      );
}

class DoctorReport {
  const DoctorReport({required this.version, required this.checks});
  final String? version;
  final List<DoctorCheck> checks;

  factory DoctorReport.fromJson(Map j) =>
      DoctorReport(version: j['version'] as String?, checks: [for (final c in (j['checks'] as List? ?? const [])) if (c is Map) DoctorCheck.fromJson(c)]);

  List<DoctorCheck> withStatus(DoctorStatus s) => [for (final c in checks) if (c.status == s) c];
  int get problems => checks.where((c) => c.status != DoctorStatus.ok).length;
}

/// The checks take a few seconds on the agent (Tailscale CLI and the release check time out after 5 s). No automatic
/// retry: an old agent's 404 stays a 404, and "Run again" is one tap away.
final doctorProvider = FutureProvider.autoDispose.family<DoctorReport, String>(retry: (_, _) => null, (ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.request('GET', '/v1/doctor', timeout: const Duration(seconds: 30)));
  return DoctorReport.fromJson(j as Map);
});

/// Agent without GET /v1/doctor (older than the health check).
bool doctorMissing(Object e) => e is AgentError && e.code == 'agent.route.notFound';

String doctorText(AppLocalizations l, DoctorCheck c) {
  String s(String k) => '${c.params[k] ?? ''}';
  String list(String k) => c.params[k] is List ? (c.params[k] as List).join(', ') : s(k);
  return switch (c.code) {
    'doctor.tailscale.ok' => l.doctorTailscaleOk(s('dnsName')),
    'doctor.tailscale.missing' => l.doctorTailscaleMissing,
    'doctor.tailscale.loggedOut' => l.doctorTailscaleLoggedOut,
    'doctor.tailscale.stopped' => l.doctorTailscaleStopped,
    'doctor.tailscale.served' => l.doctorTailscaleServed(list('httpsPorts')),
    'doctor.tailscale.notServed' => l.doctorTailscaleNotServed(s('port')),
    'doctor.tailscale.serveUnknown' => l.doctorTailscaleServeUnknown,
    'doctor.agent.listening' => l.doctorAgentListening('${s('host')}:${s('port')}'),
    'doctor.agent.notListening' => l.doctorAgentNotListening('${s('host')}:${s('port')}'),
    'doctor.config.ok' => l.doctorConfigOk(s('path')),
    'doctor.config.missing' => l.doctorConfigMissing(s('path')),
    'doctor.config.permissions' => l.doctorConfigPermissions(s('path'), s('mode')),
    'doctor.config.wrongOwner' => l.doctorConfigWrongOwner(s('path')),
    'doctor.time.synced' => l.doctorTimeSynced,
    'doctor.time.notSynced' => l.doctorTimeNotSynced,
    'doctor.time.unchecked' => l.doctorTimeUnchecked,
    'doctor.disk.ok' => l.doctorDiskOk(s('freeMb')),
    'doctor.disk.low' => l.doctorDiskLow(s('freeMb')),
    'doctor.disk.full' => l.doctorDiskFull(s('freeMb')),
    'doctor.disk.unchecked' => l.doctorDiskUnchecked,
    'doctor.node.ok' => l.doctorNodeOk(s('node')),
    'doctor.node.old' => l.doctorNodeOld(s('node')),
    'doctor.node.tooOld' => l.doctorNodeTooOld(s('node')),
    'doctor.feature.toolsMissing' => l.doctorFeatureToolsMissing(s('feature'), list('tools')),
    'doctor.feature.dockerDenied' => l.doctorFeatureDockerDenied(s('socket')),
    'doctor.feature.transcribeMissing' => l.doctorFeatureTranscribeMissing(s('command')),
    'doctor.gamemode.pluginMissing' => s('status') == 'outdated' ? l.doctorGamemodePluginOutdated : l.doctorGamemodePluginMissing,
    'doctor.push.ok' => l.doctorPushOk(s('endpoints')),
    'doctor.push.notConfigured' => l.doctorPushNotConfigured,
    'doctor.version.latest' => l.doctorVersionLatest(s('current')),
    'doctor.version.outdated' => l.doctorVersionOutdated(s('current'), s('latest')),
    'doctor.version.unchecked' => l.doctorVersionUnchecked(s('current')),
    // A check added by a newer agent: its code is still more useful than nothing.
    _ => c.code,
  };
}

/// Grouped result list (problems, warnings, OK), shared by the health screen and the setup wizard.
class DoctorResults extends StatelessWidget {
  const DoctorResults({super.key, required this.report});
  final DoctorReport report;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fails = report.withStatus(DoctorStatus.fail);
    final warns = report.withStatus(DoctorStatus.warn);
    final oks = report.withStatus(DoctorStatus.ok);
    final good = fails.isEmpty && warns.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        liveRegion: true,
        child: TCard(
          child: Row(children: [
            Icon(good ? LucideIcons.circleCheck : (fails.isEmpty ? LucideIcons.triangleAlert : LucideIcons.circleX),
                color: good ? t.success : (fails.isEmpty ? t.warning : t.danger), size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(good ? l.doctorAllGood : l.doctorSummary(fails.length, warns.length), style: Theme.of(context).textTheme.titleMedium),
                if (report.version != null) Text(l.doctorAgentVersion(report.version!), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
      ),
      if (fails.isNotEmpty) _group(l.doctorProblems, fails),
      if (warns.isNotEmpty) _group(l.doctorWarnings, warns),
      if (oks.isNotEmpty) _group(l.doctorOk, oks),
    ]);
  }

  Widget _group(String title, List<DoctorCheck> checks) => GroupedSection(title: title, children: [for (final c in checks) DoctorCheckTile(check: c)]);
}

class DoctorCheckTile extends StatelessWidget {
  const DoctorCheckTile({super.key, required this.check});
  final DoctorCheck check;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final (icon, color, label) = switch (check.status) {
      DoctorStatus.fail => (LucideIcons.circleX, t.danger, l.doctorStatusFail),
      DoctorStatus.warn => (LucideIcons.triangleAlert, t.warning, l.doctorStatusWarn),
      DoctorStatus.ok => (LucideIcons.circleCheck, t.success, l.doctorStatusOk),
    };
    final text = doctorText(l, check);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, color: color, size: 20, semanticLabel: label)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.3)),
            if (check.fix != null) ...[
              const SizedBox(height: 8),
              CommandBox(command: check.fix!, label: l.doctorFixLabel),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A shell command in a mono box with a copy button (doctor fixes, install commands).
class CommandBox extends StatelessWidget {
  const CommandBox({super.key, required this.command, this.label, this.extra});
  final String command;
  final String? label;

  /// More buttons next to "Copy" (e.g. share).
  final List<Widget>? extra;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(color: t.isDark ? const Color(0xFF1C1C22) : const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(12), border: Border.all(color: t.separator)),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (label != null) Text(label!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.textSecondary)),
        SelectableText(
          command,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.4, fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')]),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          ...?extra,
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (context.mounted) toast(context, l.commonCopied);
            },
            style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
            icon: const Icon(LucideIcons.copy, size: 16),
            label: Text(l.commonCopy),
          ),
        ]),
      ]),
    );
  }
}

/// Settings › Hosts › (host) › Health check, also reached from System › Agent.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key, required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final host = ref.watch(profileProvider).host(hostId);
    final report = ref.watch(doctorProvider(hostId));
    return SettingsPage(
      title: '${l.doctorTitle} · ${host?.name ?? hostId}',
      actions: [
        IconButton(tooltip: l.doctorRerun, icon: const Icon(LucideIcons.refreshCw), onPressed: report.isLoading ? null : () => ref.invalidate(doctorProvider(hostId))),
      ],
      children: [DoctorPanel(hostId: hostId)],
    );
  }
}

/// Loading / error / old agent / results, with "Run again".
class DoctorPanel extends ConsumerWidget {
  const DoctorPanel({super.key, required this.hostId});
  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final report = ref.watch(doctorProvider(hostId));
    void rerun() => ref.invalidate(doctorProvider(hostId));
    return report.when(
      skipLoadingOnRefresh: false,
      loading: () => Padding(
        padding: const EdgeInsets.all(40),
        child: Column(children: [const CircularProgressIndicator(), const SizedBox(height: 14), Text(l.doctorRunning, textAlign: TextAlign.center)]),
      ),
      error: (e, _) => TCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(doctorMissing(e) ? LucideIcons.download : LucideIcons.circleAlert, color: doctorMissing(e) ? t.warning : t.danger),
            const SizedBox(width: 10),
            Expanded(child: Text(doctorMissing(e) ? l.doctorMissingTitle : agentErrorText(l, e), style: Theme.of(context).textTheme.titleMedium)),
          ]),
          if (doctorMissing(e)) ...[const SizedBox(height: 6), Text(l.doctorMissingHint, style: TextStyle(color: t.textSecondary, height: 1.35))],
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: rerun, child: Text(l.commonRetry))),
        ]),
      ),
      data: (r) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DoctorResults(report: r),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: rerun,
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(LucideIcons.refreshCw, size: 18),
          label: Text(l.doctorRerun),
        ),
      ]),
    );
  }
}

/// Row that opens the health check.
class HealthCheckRow extends StatelessWidget {
  const HealthCheckRow({super.key, required this.hostId});
  final String hostId;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GroupedRow(
      title: l.doctorTitle,
      subtitle: l.doctorRowHint,
      icon: LucideIcons.stethoscope,
      iconBackground: const Color(0xFF2F9E6A),
      onTap: () => context.push('/settings/hosts/health?id=$hostId'),
    );
  }
}
