// agy chat: messages (markdown), collapsible thoughts, tool calls, plan, permission cards with the options agy offers,
// mode/model chips, context usage, "continue on the PC". Events come from a long poll that runs while the screen is
// visible (see AgyController).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/chat_markdown.dart';
import '../claude/continue_on_pc.dart';
import '../system/agent_providers.dart';
import 'agy_data.dart';
import 'agy_screen.dart';
import 'agy_texts.dart';

class AgyChatScreen extends ConsumerStatefulWidget {
  const AgyChatScreen({super.key, required this.sessionId, this.hostHint});
  final String sessionId;
  final String? hostHint;
  @override
  ConsumerState<AgyChatScreen> createState() => _AgyChatScreenState();
}

class _AgyChatScreenState extends ConsumerState<AgyChatScreen> {
  AgyController? _c;
  Object? _error;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final host = await _host();
      if (host == null) throw const AgentErrorNoHost();
      final client = await ref.read(agentClientFactoryProvider)(host);
      final c = AgyController(
        client: client,
        sessionId: widget.sessionId,
        waitMs: ref.read(agyPollWaitProvider),
        poll: ref.read(agyPollEnabledProvider),
      );
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(_onUpdate);
      setState(() => _c = c);
      await c.start();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// The host the session lives on. An auto-dispose provider that is only read would be disposed while it is awaited, so
  /// it is held for the duration.
  Future<Host?> _host() async {
    final sub = ref.listenManual(agyHostProvider(widget.hostHint), (_, _) {});
    try {
      return await ref.read(agyHostProvider(widget.hostHint).future);
    } finally {
      sub.close();
    }
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_onUpdate);
    _c?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final c = _c;
    if (text.isEmpty || c == null || c.active) return;
    setState(() => _sending = true);
    try {
      await c.send(text);
      _input.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      // 409 agent.agy.busy: agy started something meanwhile; the text stays in the box and the status is re-read.
      if (mounted) toast(context, agentErrorText(AppLocalizations.of(context), e));
      await c.pollOnce(wait: 0);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(AppLocalizations.of(context), e));
    }
  }

  Future<void> _continueOnPc(AgyController c) {
    final cwd = c.summary?['cwd'] as String?;
    final conv = c.summary?['conversationId'] as String?;
    final command = c.resumeCommand ?? (cwd != null && conv != null && conv.isNotEmpty ? agyResumeCommand(cwd, conv) : null);
    return continueOnPc(
      context,
      command: command,
      active: c.status == 'running' || c.status == 'waiting',
      // Cancel the turn (answers open permission prompts as cancelled), then close agy's process.
      stop: () async {
        await c.cancel();
        await c.close();
        await c.pollOnce(wait: 0);
      },
    );
  }

  Future<void> _pickMode(AgyController c) async {
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Text(l.agyChooseMode, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final m in c.modes)
              ListTile(
                title: Text(agyModeLabel(l, '${m['id']}', m['name'] as String?)),
                subtitle: Text(agyModeHint(l, '${m['id']}') ?? '${m['description'] ?? ''}'),
                trailing: m['id'] == c.summary?['modeId'] ? const Icon(LucideIcons.check, size: 18) : null,
                onTap: () => Navigator.pop(ctx, '${m['id']}'),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != c.summary?['modeId']) await _guard(() => c.setMode(picked));
  }

  Future<void> _pickModel(AgyController c) async {
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Text(l.agyChooseModel, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final m in c.models)
              ListTile(
                title: Text('${m['name']}'.isEmpty ? '${m['value']}' : '${m['name']}'),
                trailing: m['value'] == c.summary?['model'] ? const Icon(LucideIcons.check, size: 18) : null,
                onTap: () => Navigator.pop(ctx, '${m['value']}'),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != c.summary?['model']) await _guard(() => c.setModel(picked));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = _c;
    final sm = c?.summary;
    final title = sm == null ? 'agy' : ((sm['title'] as String?)?.isEmpty ?? true ? l.claudeUntitled : sm['title'] as String);
    final status = c?.status ?? 'starting';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      icon: const Icon(LucideIcons.chevronLeft),
                      onPressed: () => context.canPop() ? context.pop() : context.go('/claude'),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                          if (c != null)
                            Row(
                              children: [
                                StatusDot(color: c.ended ? t.textSecondary : (c.active ? t.accent : t.success), size: 7),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    agyStatusText(l, status),
                                    style: Theme.of(context).textTheme.labelSmall,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (c != null && sm != null) _UsageRing(usage: sm['usage'] as Map?),
                    if (c != null && !c.gone)
                      PopupMenuButton<String>(
                        tooltip: l.filesMore,
                        icon: const Icon(LucideIcons.ellipsisVertical),
                        onSelected: (v) async {
                          if (v == 'pc') {
                            await _continueOnPc(c);
                          } else if (v == 'close') {
                            await _guard(() async {
                              await c.close();
                              if (context.mounted) context.pop();
                            });
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'pc', child: Text(l.continuePcMenu)),
                          if (!c.ended) PopupMenuItem(value: 'close', child: Text(l.claudeEndSession)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (c != null && sm != null) _Chips(controller: c, onMode: () => _pickMode(c), onModel: () => _pickModel(c)),
            if (c != null && c.gone) _Banner(text: l.agyErrSessionNotFound),
            if (c != null && !c.gone && c.error != null && sm != null) _Banner(text: agentErrorText(l, c.error!), warn: true),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error is AgentErrorNoHost ? l.agyNoHost : agentErrorText(l, _error!)),
                      ),
                    )
                  : c == null || (sm == null && c.error == null)
                  ? const Center(child: CircularProgressIndicator())
                  : sm == null
                  ? Center(
                      child: Padding(padding: const EdgeInsets.all(24), child: Text(agentErrorText(l, c.error!))),
                    )
                  : _Messages(controller: c, scroll: _scroll),
            ),
            if (c != null && sm != null && c.ended)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TCard(
                        child: Row(
                          children: [
                            Icon(
                              status == 'error' ? LucideIcons.circleAlert : LucideIcons.circleStop,
                              color: status == 'error' ? t.danger : t.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(status == 'error' ? l.agySessionFailed : l.agySessionEnded)),
                          ],
                        ),
                      ),
                      if ((sm['conversationId'] as String?)?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: () async {
                            final host = await _host();
                            if (host != null && context.mounted) {
                              await showAgyNewSession(
                                context,
                                ref,
                                host: host,
                                cwd: sm['cwd'] as String?,
                                resume: sm['conversationId'] as String?,
                                title: sm['title'] as String?,
                              );
                            }
                          },
                          icon: const Icon(LucideIcons.play),
                          label: Text(l.agyReopen),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (c != null && sm != null && !c.ended)
              _Composer(controller: c, input: _input, sending: _sending, onSend: _send, onCancel: () => _guard(c.cancel)),
          ],
        ),
      ),
    );
  }
}

/// No agent reports the feature (thrown inside [_AgyChatScreenState._open]).
class AgentErrorNoHost implements Exception {
  const AgentErrorNoHost();
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.warn = false});
  final String text;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final color = warn ? context.tokens.warning : context.tokens.danger;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// Context window usage as a small ring and a percentage.
class _UsageRing extends StatelessWidget {
  const _UsageRing({required this.usage});
  final Map? usage;
  @override
  Widget build(BuildContext context) {
    final used = (usage?['used'] as num?)?.toDouble();
    final size = (usage?['size'] as num?)?.toDouble();
    if (used == null || size == null || size <= 0) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final pct = (used / size).clamp(0.0, 1.0);
    final color = pct > 0.85 ? t.danger : (pct > 0.6 ? t.warning : t.accent);
    final text = '%${(pct * 100).round()}';
    return Semantics(
      label: l.agyUsageSemantics(text),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(value: pct, strokeWidth: 2.6, color: color, backgroundColor: t.separator),
              ),
              const SizedBox(width: 5),
              Text(
                text,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.controller, required this.onMode, required this.onModel});
  final AgyController controller;
  final VoidCallback onMode;
  final VoidCallback onModel;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sm = controller.summary!;
    final modeId = '${sm['modeId'] ?? 'default'}';
    final modeName = controller.modes.where((m) => m['id'] == modeId).map((m) => m['name'] as String?).firstOrNull;
    final model = sm['model'] as String?;
    final modelName = controller.models.where((m) => m['value'] == model).map((m) => '${m['name']}').firstOrNull;
    final enabled = !controller.ended;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ActionChip(
              avatar: const Icon(LucideIcons.shieldCheck, size: 16),
              label: Text('${l.agyMode}: ${agyModeLabel(l, modeId, modeName)}'),
              onPressed: enabled && controller.modes.isNotEmpty ? onMode : null,
            ),
            if (model != null && model.isNotEmpty) ...[
              const SizedBox(width: 8),
              ActionChip(
                avatar: const Icon(LucideIcons.cpu, size: 16),
                label: Text(modelName == null || modelName.isEmpty ? model : modelName),
                onPressed: enabled && controller.models.isNotEmpty ? onModel : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.controller, required this.scroll});
  final AgyController controller;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = controller;
    final tools = agyToolStates(c.events);
    final resolved = agyResolvedPermissions(c.events);
    final items = <Widget>[];
    var inReplay = false;
    Widget dim(AgyEvent e, Widget w) => e.replay ? Opacity(opacity: 0.6, child: w) : w;
    for (final e in c.events) {
      if (e.replay && !inReplay) items.add(_Notice(text: l.agyReplayLabel));
      inReplay = e.replay;
      switch (e.kind) {
        case 'user':
          items.add(dim(e, _UserBubble(text: e.text)));
        case 'agent':
          items.add(dim(e, Padding(padding: const EdgeInsets.only(top: 8, bottom: 4, right: 16), child: ChatMarkdown(e.text))));
        case 'thought':
          items.add(dim(e, _Thought(text: e.text)));
        case 'tool':
          final id = e.get<String>('toolCallId') ?? '';
          items.add(dim(e, _ToolCard(state: tools[id] ?? e.json)));
        case 'plan':
          items.add(dim(e, _PlanCard(entries: [for (final x in (e.get<List>('entries') ?? const [])) Map<String, dynamic>.from(x as Map)])));
        case 'permission':
          items.add(dim(e, _PermissionCard(event: e, controller: c, resolved: resolved[e.get<String>('requestId')])));
        case 'mode':
          final id = e.get<String>('modeId') ?? '';
          final name = c.modes.where((m) => m['id'] == id).map((m) => m['name'] as String?).firstOrNull;
          items.add(_Notice(text: l.agyModeChanged(agyModeLabel(l, id, name))));
        case 'error':
          items.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(agyEventErrorText(l, e.text), style: TextStyle(color: context.tokens.danger, fontSize: 13)),
            ),
          );
        case 'turnEnd':
          final r = e.get<String>('stopReason') ?? '';
          final cancelled = r == 'cancelled';
          items.add(
            _Notice(text: cancelled ? l.agyTurnCancelled : (r.isEmpty || r == 'end_turn' ? l.agyTurnDone : l.agyTurnStop(r)), warn: cancelled),
          );
      }
    }
    if (c.status == 'running') items.add(const _Typing());
    return ListView.builder(
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: items.length,
      itemBuilder: (_, i) => items[items.length - 1 - i],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 4, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: t.claudeTile,
          borderRadius: BorderRadius.circular(18),
          border: t.isDark ? Border.all(color: t.claudeTileBorder) : null,
        ),
        child: SelectableText(text, style: TextStyle(color: t.claudeTileText, fontSize: 15, height: 1.35)),
      ),
    );
  }
}

class _Thought extends StatelessWidget {
  const _Thought({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    // A transparent Material under the tile: the screen's background is a ColoredBox that would hide the tile's ink.
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(LucideIcons.brain, size: 16, color: t.textSecondary),
          title: Text(l.claudeThinking, style: Theme.of(context).textTheme.labelMedium),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                text,
                style: TextStyle(fontSize: 13, color: t.textSecondary, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _toolIcon(String? kind) => switch (kind) {
  'execute' => LucideIcons.terminal,
  'read' => LucideIcons.fileText,
  'edit' => LucideIcons.filePen,
  'delete' => LucideIcons.trash2,
  'move' => LucideIcons.folderInput,
  'search' => LucideIcons.search,
  'fetch' => LucideIcons.globe,
  'think' => LucideIcons.brain,
  _ => LucideIcons.wrench,
};

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.state});
  final Map<String, dynamic> state;
  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = widget.state;
    final status = '${s['status'] ?? ''}';
    final failed = status == 'failed';
    final done = status == 'completed';
    final paths = [for (final p in (s['paths'] as List? ?? const [])) '$p'];
    final command = s['command'] as String?;
    final title = '${s['title'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TCard(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        onTap: () => setState(() => _open = !_open),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_toolIcon(s['toolKind'] as String?), size: 16, color: failed ? t.danger : t.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: _open ? 4 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                if (done)
                  Icon(LucideIcons.check, size: 15, color: t.success)
                else if (failed)
                  Icon(LucideIcons.x, size: 15, color: t.danger)
                else
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
              ],
            ),
            if (command != null && command.isNotEmpty && command != title) ...[
              const SizedBox(height: 6),
              Text(
                command,
                maxLines: _open ? 12 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: t.textSecondary),
              ),
            ],
            for (final p in paths.take(_open ? paths.length : 2))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  p,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: t.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.entries});
  final List<Map<String, dynamic>> entries;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TCard(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.listChecks, size: 16, color: t.accent),
                const SizedBox(width: 8),
                Text(l.agyPlanTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ],
            ),
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch ('${e['status']}') {
                        'completed' => LucideIcons.circleCheck,
                        'in_progress' => LucideIcons.loaderCircle,
                        _ => LucideIcons.circle,
                      },
                      size: 15,
                      color: e['status'] == 'completed' ? t.success : t.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${e['content']}',
                        style: TextStyle(fontSize: 13.5, height: 1.3, decoration: e['status'] == 'completed' ? TextDecoration.lineThrough : null),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Button text of an offered option: Allow/Deny in the app's language for the "once" kinds, else the agent's own name.
String _optionLabel(AppLocalizations l, Map o) => switch ('${o['kind']}') {
  'allow_once' => l.claudeAllow,
  'reject_once' => l.claudeDeny,
  _ => '${o['name']}',
};

class _PermissionCard extends StatefulWidget {
  const _PermissionCard({required this.event, required this.controller, required this.resolved});
  final AgyEvent event;
  final AgyController controller;

  /// The chosen option id once answered ("cancelled" when the turn was cancelled).
  final String? resolved;
  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _busy = false;

  Future<void> _decide(String optionId) async {
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    try {
      await widget.controller.decide(widget.event.get<String>('requestId')!, optionId);
      // The answer shows as soon as the next poll reports it.
      await widget.controller.pollOnce(wait: 0);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(AppLocalizations.of(context), e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final e = widget.event;
    final options = [for (final o in (e.get<List>('options') ?? const [])) Map<String, dynamic>.from(o as Map)];
    final command = e.get<String>('command');
    final title = e.get<String>('title') ?? '';
    final resolved = widget.resolved;
    final chosen = options.where((o) => o['optionId'] == resolved).firstOrNull;
    final allowed = chosen != null && '${chosen['kind']}'.startsWith('allow');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        liveRegion: resolved == null,
        child: TCard(
          radius: 18,
          borderColor: t.warning,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.shieldQuestion, color: t.warning, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(l.agyPermissionTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              if (title.isNotEmpty) ...[const SizedBox(height: 6), Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5))],
              if (command != null && command.isNotEmpty && command != title) ...[
                const SizedBox(height: 4),
                Text(command, style: const TextStyle(fontFamily: monoFamily, fontSize: 12)),
              ],
              const SizedBox(height: 10),
              if (resolved == null && !widget.controller.ended)
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (final o in options)
                      '${o['kind']}'.startsWith('reject')
                          ? OutlinedButton(
                              onPressed: _busy ? null : () => _decide('${o['optionId']}'),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(110, 48), foregroundColor: t.danger),
                              child: Text(_optionLabel(l, o)),
                            )
                          : FilledButton(
                              onPressed: _busy ? null : () => _decide('${o['optionId']}'),
                              style: FilledButton.styleFrom(minimumSize: const Size(110, 48)),
                              child: Text(_optionLabel(l, o)),
                            ),
                  ],
                )
              else if (resolved != null)
                Text(
                  chosen == null ? l.agyPermissionCancelled : l.agyAnswered(_optionLabel(l, chosen)),
                  style: TextStyle(color: chosen == null ? t.warning : (allowed ? t.success : t.danger), fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warn = false});
  final String text;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: t.separator)),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: warn ? t.warning : t.textSecondary),
              ),
            ),
          ),
          Expanded(child: Divider(color: t.separator)),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: context.tokens.accent)),
        const SizedBox(width: 10),
        Text(AppLocalizations.of(context).agyWorking, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.input, required this.sending, required this.onSend, required this.onCancel});
  final AgyController controller;
  final TextEditingController input;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final active = controller.active;
    final hint = controller.status == 'waiting' ? l.agyWaitingHint : (active ? l.agyBusyHint : l.agyPromptHint);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: TCard(
          radius: 24,
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  enabled: !active,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: hint,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                  ),
                ),
              ),
              if (controller.status == 'running' || controller.status == 'waiting')
                IconButton(
                  tooltip: l.agyCancel,
                  icon: Icon(LucideIcons.square, color: t.danger),
                  onPressed: onCancel,
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Semantics(
                  button: true,
                  enabled: !active,
                  label: l.claudeSend,
                  child: Material(
                    color: active ? t.separator : (t.isDark ? t.tabActive : const Color(0xFF111114)),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: sending || active ? null : onSend,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: sending
                            ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(LucideIcons.arrowUp, color: t.isDark ? Colors.black : Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
