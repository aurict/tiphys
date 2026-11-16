// System › Compose stacks: stacks in the compose roots on every SSH host (no agent needed), container
// statuses; per stack: update check, update, restart, stop/start, recent logs. Output of long
// operations streams live. The update result is recorded as an event (if the host has no agent, to the first
// agent host in the profile, params.host = target host).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/compose.dart';
import '../../core/ssh/connection.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../terminal/sessions.dart' show sshOpenerProvider;
import '../terminal/terminal_screen.dart' show sshFailureText;
import 'agent_providers.dart';
import 'events.dart' show ChipRow, filterChip;

/// Shell that runs compose commands (a fake is given in tests). Each operation opens and closes its own connection.
final composeShellOpenerProvider = Provider<Future<RemoteShell> Function(Host)>((ref) => (h) => ref.read(sshOpenerProvider)(h));

/// Not retried automatically (each attempt is a new SSH connection); the error is shown with "Try again".
final composeListProvider = FutureProvider.autoDispose.family<ComposeListing, String>(retry: (_, _) => null, (ref, hostId) async {
  final host = ref.watch(profileProvider).host(hostId);
  if (host == null) throw const SshFailure('noSsh');
  final shell = await ref.read(composeShellOpenerProvider)(host);
  try {
    return await listComposeStacks(shell, host.composeRoots);
  } finally {
    shell.close();
  }
});

/// Writes the update result to the event feed. Silently skipped if there's no agent host; errors go to the caller.
Future<void> recordComposeEvent(WidgetRef ref, Host target, String key, Map<String, Object> params) async {
  final p = ref.read(profileProvider);
  final via = target.agent != null ? target : p.hosts.where((h) => h.agent != null).firstOrNull;
  if (via == null) return;
  await agentCall(ref, via.id, 'POST', '/v1/events', {
    'key': key,
    'params': {'host': target.name, ...params},
    'link': 'tiphys://system/compose',
  });
}

Color composeStateColor(TiphysTokens t, String state) => switch (state) {
      'running' => t.success,
      'partial' || 'restarting' || 'paused' => t.warning,
      'error' || 'dead' => t.danger,
      _ => const Color(0xFF6C6C70),
    };

String composeStackSubtitle(AppLocalizations l, ComposeStack s) => switch (s.state) {
      'error' => l.composeError,
      'down' => l.composeNotCreated,
      'stopped' => l.composeStopped,
      _ => [
          l.composeRunningCount(s.running, s.containers.length),
          if (s.containers.any((c) => c.health == 'unhealthy')) l.composeUnhealthy,
        ].join(' · '),
    };

String composeErrorText(AppLocalizations l, Object e) => switch (e) {
      SshFailure() => sshFailureText(l, e),
      ComposeFailure(:final step, :final code, :final detail) => [l.composeFailed(step, '${code ?? '-'}'), if (detail.isNotEmpty) detail].join('\n'),
      TimeoutException() => l.sshTimeout,
      _ => '${l.commonError}: $e',
    };

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key});
  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  String? _hostId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hosts = ref.watch(profileProvider).hosts.where((h) => h.ssh != null).toList();
    final host = hosts.where((h) => h.id == _hostId).firstOrNull ?? hosts.firstOrNull;
    final list = host == null ? null : ref.watch(composeListProvider(host.id));
    return SettingsPage(
      title: l.composeTitle,
      actions: [
        if (host != null) IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(composeListProvider(host.id))),
      ],
      children: [
        if (host == null)
          Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.composeNoSshHosts)))
        else ...[
          if (hosts.length > 1)
            ChipRow(children: [
              for (final h in hosts) filterChip(context, h.name, h.id == host.id, () => setState(() => _hostId = h.id), dot: t.hostColor(hexColor(h.color))),
            ]),
          ...list!.when(
            skipLoadingOnRefresh: true,
            loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TCard(
                  child: Row(children: [
                    Icon(LucideIcons.circleAlert, color: t.danger),
                    const SizedBox(width: 10),
                    Expanded(child: Text(composeErrorText(l, e))),
                    TextButton(onPressed: () => ref.invalidate(composeListProvider(host.id)), child: Text(l.commonRetry)),
                  ]),
                ),
              ),
            ],
            data: (d) => [
              if (d.stacks.isEmpty)
                Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.composeEmpty(host.composeRoots.join(', ')))))
              else
                GroupedSection(
                  title: host.name,
                  footer: l.composeRootsFooter(host.composeRoots.join(', ')),
                  children: [
                    for (final s in d.stacks)
                      GroupedRow(
                        title: s.name,
                        subtitle: '${composeStackSubtitle(l, s)} · ${d.pretty(s.dir)}',
                        icon: LucideIcons.layers,
                        iconBackground: composeStateColor(t, s.state),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ComposeStackPage(host: host, dir: s.dir))),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Stack details: containers + operations. Watches the list provider (refreshed after an operation).
class ComposeStackPage extends ConsumerWidget {
  const ComposeStackPage({super.key, required this.host, required this.dir});
  final Host host;
  final String dir;

  Future<void> _run(BuildContext context, WidgetRef ref, ComposeStack stack, String action) async {
    final l = AppLocalizations.of(context);
    bool force = false;
    switch (action) {
      case 'update':
        final r = await _confirmUpdate(context, stack.name);
        if (r == null) return;
        force = r;
      case 'restart':
        if (!await confirmDialog(context, message: l.composeRestartConfirm(stack.name), confirmLabel: l.composeRestart)) return;
      case 'stop':
        if (!await confirmDialog(context, message: l.composeStopConfirm(stack.name), confirmLabel: l.composeStop, destructive: true)) return;
    }
    if (!context.mounted) return;
    final opener = ref.read(composeShellOpenerProvider);
    final title = '${stack.name} · ${switch (action) {
      'check' => l.composeCheck,
      'update' => l.composeUpdate,
      'restart' => l.composeRestart,
      'stop' => l.composeStop,
      'start' => l.composeStart,
      _ => l.composeLogs,
    }}';
    await showComposeRun(context, title: title, body: (out) async {
      final shell = await opener(host);
      try {
        final ops = ComposeOps(shell, stack);
        switch (action) {
          case 'check':
            final (_, c) = await ops.check(out);
            return c.outdated.isEmpty ? l.composeNoUpdates : l.composeUpdatesAvailable(c.outdated.length, c.outdated.join(', '));
          case 'update':
            try {
              final r = await ops.update(out, force: force);
              final svcs = r.check.outdated;
              if (r.recreated) {
                await recordComposeEvent(ref, host, 'compose.updated', {
                  'stack': stack.name,
                  // The agent caps the event parameter at 500 characters; a long list would never get recorded.
                  'services': svcs.isEmpty ? '*' : _clip(svcs.join(', '), 400),
                  'count': svcs.length,
                  if (r.forced) 'forced': 1,
                }).catchError((Object _) => out('\n${l.composeEventFailed}\n'));
              }
              return !r.recreated
                  ? l.composeUpToDate
                  : svcs.isEmpty
                      ? l.composeRecreated
                      : l.composeUpdated(svcs.length, svcs.join(', '));
            } on ComposeFailure catch (f) {
              await recordComposeEvent(ref, host, 'compose.failed', {'stack': stack.name, 'step': f.step, 'code': f.code ?? -1})
                  .catchError((Object _) => out('\n${l.composeEventFailed}\n'));
              rethrow;
            }
          case 'logs':
            out(await ops.logs());
            return null;
          default:
            await ops.simple(action, out);
            return l.composeDone;
        }
      } finally {
        shell.close();
      }
    });
    // The page may have been left while the job runs: don't use the ref of a closed page.
    if (context.mounted) ref.invalidate(composeListProvider(host.id));
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final listing = ref.watch(composeListProvider(host.id)).value;
    final stack = listing?.stacks.where((s) => s.dir == dir).firstOrNull;
    final name = dir.substring(dir.lastIndexOf('/') + 1);
    if (stack == null) {
      return SettingsPage(title: name, children: [
        listing == null ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())) : TCard(child: Text(l.composeStackGone)),
      ]);
    }
    Widget action(String id, String title, IconData icon, Color color, {bool destructive = false}) =>
        GroupedRow(title: title, icon: icon, iconBackground: color, destructive: destructive, showChevron: false, onTap: () => _run(context, ref, stack, id));
    return SettingsPage(
      title: stack.name,
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(composeListProvider(host.id)))],
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text('${host.name} · ${listing!.pretty(stack.dir)}/${stack.file}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'JetBrainsMono')),
        ),
        if (stack.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TCard(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(LucideIcons.circleAlert, color: t.danger),
                const SizedBox(width: 10),
                Expanded(child: Text(stack.error!, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5))),
              ]),
            ),
          ),
        GroupedSection(title: l.composeContainers, children: [
          if (stack.containers.isEmpty)
            GroupedRow(title: l.composeNotCreated, icon: LucideIcons.box, iconBackground: const Color(0xFF6C6C70), showChevron: false),
          for (final c in stack.containers)
            GroupedRow(
              title: c.service.isEmpty ? c.name : c.service,
              // The status text already includes health ("Up 3 days (healthy)").
              subtitle: [c.status.isEmpty ? c.state : c.status, if (c.health.isNotEmpty && !c.status.contains(c.health)) c.health, c.image].join(' · '),
              icon: LucideIcons.box,
              iconBackground: composeStateColor(t, c.health == 'unhealthy' ? 'partial' : c.state),
              showChevron: false,
            ),
        ]),
        GroupedSection(title: l.composeActions, footer: l.composeActionsHint, children: [
          action('check', l.composeCheck, LucideIcons.searchCheck, t.accent),
          action('update', l.composeUpdate, LucideIcons.download, t.success),
          action('logs', l.composeLogs, LucideIcons.scrollText, const Color(0xFF2F9E6A)),
          if (stack.state != 'running') action('start', l.composeStart, LucideIcons.play, t.success),
          if (stack.running > 0) ...[
            action('restart', l.composeRestart, LucideIcons.rotateCcw, t.warning),
            action('stop', l.composeStop, LucideIcons.square, t.danger, destructive: true),
          ],
        ]),
      ],
    );
  }
}

/// Update confirmation; null = cancel, true = recreate even if the image didn't change.
Future<bool?> _confirmUpdate(BuildContext context, String stack) => showDialog<bool>(
      context: context,
      builder: (c) {
        final l = AppLocalizations.of(c);
        var force = false;
        return StatefulBuilder(
          builder: (c, set) => AlertDialog(
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.composeUpdateConfirm(stack), style: Theme.of(c).textTheme.bodyLarge),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: Text(l.composeForce), value: force, onChanged: (v) => set(() => force = v)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonCancel)),
              TextButton(onPressed: () => Navigator.pop(c, force), child: Text(l.composeUpdate)),
            ],
          ),
        );
      },
    );

/// Live output page: output streams while [body] runs; when done, the summary (returned text) or error is shown.
/// Doesn't close accidentally with the back gesture; if closed with "Hide" the job continues in the background (the
/// remote command isn't cut off, the result lands in the event feed) — so the user isn't stuck if the connection hangs.
Future<void> showComposeRun(BuildContext context, {required String title, required Future<String?> Function(void Function(String chunk) out) body}) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => ComposeRunSheet(title: title, body: body),
    );

class ComposeRunSheet extends StatefulWidget {
  const ComposeRunSheet({super.key, required this.title, required this.body});
  final String title;
  final Future<String?> Function(void Function(String chunk) out) body;
  @override
  State<ComposeRunSheet> createState() => _ComposeRunSheetState();
}

class _ComposeRunSheetState extends State<ComposeRunSheet> {
  static const _maxChars = 64 * 1024;
  final _scroll = ScrollController();
  String _out = '';
  bool _done = false;
  String? _summary;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _append(String chunk) {
    if (!mounted) return;
    setState(() {
      _out += chunk;
      if (_out.length > _maxChars) _out = _out.substring(_out.length - _maxChars);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _start() async {
    try {
      final s = await widget.body(_append);
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final h = MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: _done,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (!_done)
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(_error == null ? LucideIcons.circleCheck : LucideIcons.circleAlert, color: _error == null ? t.success : t.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
            ]),
            const SizedBox(height: 12),
            Semantics(
              label: l.composeOutput,
              liveRegion: true,
              child: Container(
                height: h * 0.42,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: t.isDark ? const Color(0xFF111114) : const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(14)),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SelectableText(
                    _out.isEmpty ? (_done ? '' : l.composeWorking) : _out,
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.35, color: t.text),
                  ),
                ),
              ),
            ),
            if (!_done)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.eyeOff, size: 18),
                  label: Text(l.composeHide),
                ),
              ),
            if (_done && (_summary != null || _error != null))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: TCard(
                  child: Text(_error != null ? composeErrorText(l, _error!) : _summary!,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: _error != null ? t.danger : t.text)),
                ),
              ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _done ? () => Navigator.pop(context) : null,
              child: Text(_done ? l.commonClose : l.composeWorking),
            ),
          ]),
        ),
      ),
    );
  }
}
