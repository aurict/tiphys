// Claude tab: open sessions + history; new session page (folder, mode, model, thinking, profile).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/util/refresh.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/floating_tab_bar.dart';
import '../../widgets/surfaces.dart';
import '../desktop/desktop_data.dart' show controlHeader, controlProvider;
import '../system/agent_providers.dart';

/// Host that runs Claude (Settings › Claude; otherwise the first agent host).
final claudeHostProvider = Provider<Host?>((ref) {
  final p = ref.watch(profileProvider);
  return p.host(p.claude.agentHostId) ?? p.hosts.where((h) => h.agent != null).firstOrNull;
});

/// Outbox folder (null in widget tests: the box is in memory only, no real disk I/O).
final outboxDirProvider = Provider<Future<String?> Function()>((ref) => () async => (await getApplicationDocumentsDirectory()).path);

final claudeSessionsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final host = ref.watch(claudeHostProvider);
  if (host == null) throw const _NoHost();
  autoRefresh(ref, const Duration(seconds: 10));
  return withAgent(ref, host.id, (c) => c.get('/v1/claude/sessions'));
});

class _NoHost implements Exception {
  const _NoHost();
}

String relativeTime(AppLocalizations l, DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return l.relativeNow;
  if (d.inHours < 1) return l.relativeMinutes(d.inMinutes);
  if (d.inDays < 1) return l.relativeHours(d.inHours);
  return l.relativeDays(d.inDays);
}

class ClaudeScreen extends ConsumerStatefulWidget {
  const ClaudeScreen({super.key, this.openNew = false, this.cwd});
  final bool openNew;
  final String? cwd;
  @override
  ConsumerState<ClaudeScreen> createState() => _ClaudeScreenState();
}

class _ClaudeScreenState extends ConsumerState<ClaudeScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.openNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showNewSession(context, ref, cwd: widget.cwd);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(claudeHostProvider);
    final data = ref.watch(claudeSessionsProvider);
    final now = ref.watch(clockProvider)();
    final top = MediaQuery.paddingOf(context).top;

    Color statusColor(String s) => switch (s) {
          'running' || 'starting' => t.accent,
          'waiting' => t.warning,
          'error' => t.danger,
          'idle' => t.success,
          _ => const Color(0xFF6C6C70),
        };

    return RefreshIndicator(
      onRefresh: () => ref.refresh(claudeSessionsProvider.future),
      child: ListView(
        padding: EdgeInsets.fromLTRB(TiphysTokens.gutter, top + 18, TiphysTokens.gutter, FloatingTabBar.height + FloatingTabBar.bottomGap + 24),
        children: [
          LargeTitleHeader(
            overline: host?.name,
            title: 'Claude',
            action: host == null
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    RoundIconButton(icon: LucideIcons.alarmClock, tooltip: l.claudeSchedules, onPressed: () => context.push('/claude/schedules')),
                    const SizedBox(width: 10),
                    RoundIconButton(icon: LucideIcons.plus, tooltip: l.homeNewClaudeSession, onPressed: () => showNewSession(context, ref)),
                  ]),
          ),
          const SizedBox(height: 12),
          if (host == null)
            TCard(child: Text(l.integrationNeedsAgentHost))
          else
            data.when(
              skipLoadingOnRefresh: true,
              loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
              data: (d) {
                final live = (d['live'] as List).cast<Map>();
                final terminal = ((d['terminal'] as List?) ?? const []).cast<Map>();
                final history = (d['history'] as List).cast<Map>();
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (live.isNotEmpty)
                    GroupedSection(title: l.claudeLive, children: [
                      for (final s in live)
                        GroupedRow(
                          title: '${s['title']}'.isEmpty ? l.claudeUntitled : '${s['title']}',
                          subtitle: '${s['kind'] == 'pc' ? l.claudePcUse : _folder('${s['cwd']}')} · '
                              '${(s['pendingPermissions'] as int) > 0 ? l.homeClaudeWaiting(s['pendingPermissions'] as int) : claudeStatusText(l, '${s['status']}')}',
                          icon: s['kind'] == 'pc' ? LucideIcons.monitor : LucideIcons.asterisk,
                          iconBackground: statusColor('${s['status']}'),
                          trailingText: '\$${(s['costUsd'] as num).toStringAsFixed(2)}',
                          onTap: () => context.push('/claude/session/${s['id']}'),
                        ),
                    ]),
                  if (terminal.isNotEmpty)
                    GroupedSection(title: l.claudeTerminalSessions, footer: l.claudeTerminalSessionsHint, children: [
                      for (final s in terminal)
                        GroupedRow(
                          title: '${s['title']}'.isEmpty ? l.claudeUntitled : '${s['title']}',
                          subtitle: '${_folder('${s['cwd'] ?? ''}')} · ${s['status'] == 'busy' ? l.claudeStatusRunning : l.claudeStatusIdle}',
                          icon: LucideIcons.squareTerminal,
                          iconBackground: s['status'] == 'busy' ? t.accent : const Color(0xFF6C6C70),
                          onTap: () => context.push('/claude/history/${s['sdkSessionId']}?terminal=1&cwd=${Uri.encodeComponent('${s['cwd'] ?? '~'}')}'),
                        ),
                    ]),
                  if (live.isEmpty)
                    TCard(
                      color: t.claudeTile,
                      borderColor: t.claudeTileBorder,
                      onTap: () => showNewSession(context, ref),
                      child: Row(children: [
                        Icon(LucideIcons.asterisk, color: t.claudeTileSubtext),
                        const SizedBox(width: 10),
                        Expanded(child: Text(l.homeNewClaudeSession, style: TextStyle(color: t.claudeTileText, fontWeight: FontWeight.w700, fontSize: 16))),
                        Icon(LucideIcons.plus, color: t.claudeTileText),
                      ]),
                    ),
                  if (history.isNotEmpty)
                    GroupedSection(title: l.claudeHistory, children: [
                      for (final h in history.take(25))
                        GroupedRow(
                          title: '${h['title']}'.isEmpty ? '—' : '${h['title']}',
                          subtitle: '${_folder('${h['cwd'] ?? ''}')} · ${relativeTime(l, DateTime.parse('${h['lastActivity']}'), now)}',
                          icon: LucideIcons.history,
                          iconBackground: const Color(0xFF6C6C70),
                          onTap: () => context.push('/claude/history/${h['sdkSessionId']}?cwd=${Uri.encodeComponent('${h['cwd'] ?? '~'}')}'),
                        ),
                    ]),
                ]);
              },
            ),
        ],
      ),
    );
  }
}

String _folder(String cwd) {
  final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? '/' : (parts.length == 1 ? parts.last : '${parts[parts.length - 2]}/${parts.last}');
}

String claudeStatusText(AppLocalizations l, String s) => switch (s) {
      'running' || 'starting' => l.claudeStatusRunning,
      'waiting' => l.claudeStatusWaiting,
      'idle' => l.claudeStatusIdle,
      'error' => l.claudeStatusError,
      _ => l.claudeStatusStopped,
    };

/// New session: folder + first message + settings. On success, switches to the chat screen.
Future<void> showNewSession(BuildContext context, WidgetRef ref, {String? cwd, String? resume, String? title, String? prompt}) async {
  await showModalBottomSheet<void>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: _NewSessionSheet(initialCwd: cwd, resume: resume, title: title, initialPrompt: prompt),
    ),
  );
}

class _NewSessionSheet extends ConsumerStatefulWidget {
  const _NewSessionSheet({this.initialCwd, this.resume, this.title, this.initialPrompt});
  final String? initialCwd;

  /// First message prepared from another screen (e.g. "Ask Claude" in Dozzle).
  final String? initialPrompt;
  final String? resume;
  final String? title;
  @override
  ConsumerState<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<_NewSessionSheet> {
  late final _prompt = TextEditingController(text: widget.initialPrompt);
  late String _cwd;
  late String _mode;
  late String _effort;
  late String _model;
  late String _profile;
  bool _worktree = false;
  bool _busy = false;
  String? _error;

  /// "Use the PC" mode: no folder/permission/worktree; a control session (lock again) opens at start.
  bool _pc = false;

  @override
  void initState() {
    super.initState();
    final c = ref.read(profileProvider).claude;
    _cwd = widget.initialCwd ?? c.favoriteFolders.firstOrNull ?? '~';
    _mode = c.permissionMode;
    _effort = c.effort;
    _model = c.model;
    _profile = c.profiles.any((p) => p.id == c.profileId) ? c.profileId : (c.profiles.firstOrNull?.id ?? 'personal');
  }

  Future<void> _pickFolder() async {
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ClaudeFolderPicker(hostId: host.id, start: _cwd)));
    if (picked != null) setState(() => _cwd = picked);
  }

  /// PC session: first the control session (app lock asked again), then the Claude session with the token.
  Future<void> _startPc() async {
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await ref.read(controlProvider.notifier).ensure(context, host.id, fresh: true);
      if (s == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final res = await agentCall(ref, host.id, 'POST', '/v1/claude/sessions', {
        'cwd': '~',
        'kind': 'pc',
        'prompt': _prompt.text.trim(),
        'effort': _effort,
        if (_model.isNotEmpty) 'model': _model,
        'profileId': _profile,
      }, {controlHeader: s.token}) as Map;
      if (!mounted) return;
      ref.invalidate(claudeSessionsProvider);
      Navigator.pop(context);
      context.push('/claude/session/${res['id']}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = agentErrorText(l, e);
      });
    }
  }

  Future<void> _start() async {
    if (_pc) return _startPc();
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await agentCall(ref, host.id, 'POST', '/v1/claude/sessions', {
        'cwd': _cwd,
        'prompt': _prompt.text.trim(),
        'permissionMode': _mode,
        'effort': _effort,
        if (_model.isNotEmpty) 'model': _model,
        'profileId': _profile,
        'resume': ?widget.resume,
        if (_worktree && widget.resume == null) 'worktree': true,
      }) as Map;
      if (!mounted) return;
      ref.invalidate(claudeSessionsProvider);
      Navigator.pop(context);
      context.push('/claude/session/${res['id']}');
    } catch (e) {
      setState(() {
        _busy = false;
        _error = agentErrorText(l, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = ref.watch(profileProvider.select((p) => p.claude));
    // Use the PC only if desktop + remote control are enabled on the Claude host.
    final host = ref.watch(claudeHostProvider);
    final features = host == null ? null : (ref.watch(healthProvider(host.id)).value?['features'] as Map?);
    final pcAvailable = widget.resume == null && features != null && features['desktop'] == true && features['control'] == true;
    final pc = _pc && pcAvailable;
    Widget chips<T>(String label, List<(T, String)> opts, T value, ValueChanged<T> set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 10, bottom: 6), child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (v, name) in opts)
              ChoiceChip(
                label: Text(name),
                selected: v == value,
                onSelected: (_) => set(v),
                showCheckmark: false,
                selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
                labelStyle: TextStyle(color: v == value ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
              ),
          ]),
        ]);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(pc ? l.claudePcUse : (widget.resume == null ? l.homeNewClaudeSession : l.claudeContinue), style: Theme.of(context).textTheme.titleLarge)),
            if (pcAvailable)
              FilterChip(
                avatar: Icon(LucideIcons.monitor, size: 16, color: pc ? (t.isDark ? Colors.black : Colors.white) : t.accent),
                label: Text(l.claudePcUse),
                selected: pc,
                showCheckmark: false,
                onSelected: _busy ? null : (v) => setState(() => _pc = v),
                selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
                labelStyle: TextStyle(color: pc ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
              ),
          ]),
          if (widget.title != null) Text(widget.title!, style: Theme.of(context).textTheme.bodySmall, maxLines: 2),
          const SizedBox(height: 12),
          if (pc)
            TCard(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(LucideIcons.monitor, color: t.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(l.claudePcHint, style: const TextStyle(fontSize: 13.5, height: 1.35))),
              ]),
            )
          else
          TCard(
            onTap: widget.resume == null ? _pickFolder : null,
            semanticLabel: l.claudeFolder,
            child: Row(children: [
              Icon(LucideIcons.folder, color: t.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(_cwd, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13))),
              if (widget.resume == null) Icon(LucideIcons.chevronRight, color: t.textSecondary),
            ]),
          ),
          if (c.favoriteFolders.isNotEmpty && widget.resume == null && !pc)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final f in c.favoriteFolders)
                  ActionChip(label: Text(f.split('/').last, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _cwd = f)),
              ]),
            ),
          const SizedBox(height: 12),
          // The first message is optional: a session started empty waits for the first message on the chat screen.
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 8,
            decoration: InputDecoration(hintText: pc ? l.claudePcPromptHint : l.claudePromptOptional, errorText: _error),
          ),
          if (!pc)
          chips<String>(l.claudePermissionMode, [
            ('bypassPermissions', l.claudeModeBypassShort),
            ('acceptEdits', l.claudeModeAcceptShort),
            ('default', l.claudeModeDefaultShort),
            ('plan', l.claudeModePlan),
          ], _mode, (v) => setState(() => _mode = v)),
          chips<String>(l.claudeEffort, [for (final e in claudeEfforts) (e, e)], _effort, (v) => setState(() => _effort = v)),
          if (c.profiles.length > 1) chips<String>(l.claudeProfiles, [for (final p in c.profiles) (p.id, p.name)], _profile, (v) => setState(() => _profile = v)),
          if (widget.resume == null && !pc)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(l.claudeWorktree),
                subtitle: Text(l.claudeWorktreeHint),
                value: _worktree,
                onChanged: (v) => setState(() => _worktree = v),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${l.claudeModel}: $_model', style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _start,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(pc ? LucideIcons.lockKeyhole : LucideIcons.arrowUp),
            label: Text(pc ? l.claudePcStart : (widget.resume == null ? l.claudeStart : l.claudeContinue)),
          ),
        ]),
      ),
    );
  }
}

/// Folder picker under the agent's allowed roots (new session and scheduled task).
class ClaudeFolderPicker extends ConsumerStatefulWidget {
  const ClaudeFolderPicker({super.key, required this.hostId, required this.start});
  final String hostId;
  final String start;
  @override
  ConsumerState<ClaudeFolderPicker> createState() => _ClaudeFolderPickerState();
}

class _ClaudeFolderPickerState extends ConsumerState<ClaudeFolderPicker> {
  Map<String, dynamic>? _d;
  Object? _err;

  @override
  void initState() {
    super.initState();
    _load(widget.start);
  }

  Future<void> _load(String path) async {
    try {
      final d = await agentCall(ref, widget.hostId, 'GET', '/v1/fs/dirs?path=${Uri.encodeQueryComponent(path)}');
      setState(() {
        _d = Map<String, dynamic>.from(d as Map);
        _err = null;
      });
    } catch (e) {
      if (path != '~') return _load('~');
      setState(() => _err = e);
    }
  }

  String _pretty(String p) {
    final home = _d?['home'] as String?;
    return home != null && p.startsWith(home) ? '~${p.substring(home.length)}' : p;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final path = _d?['path'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Text(path == null ? l.claudeFolder : _pretty(path), style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14)),
        actions: [
          if (path != null)
            TextButton(onPressed: () => Navigator.pop(context, _pretty(path)), child: Text(l.claudeChooseFolder)),
        ],
      ),
      body: _err != null
          ? Center(child: Text(agentErrorText(l, _err!)))
          : _d == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(children: [
                  if (path != _d!['home'])
                    ListTile(leading: const Icon(LucideIcons.arrowUp), title: const Text('..'), onTap: () => _load(path!.substring(0, path.lastIndexOf('/')).isEmpty ? '/' : path.substring(0, path.lastIndexOf('/')))),
                  for (final d in (_d!['dirs'] as List).cast<Map>())
                    ListTile(leading: const Icon(LucideIcons.folder), title: Text('${d['name']}'), onTap: () => _load('${d['path']}')),
                ]),
    );
  }
}

