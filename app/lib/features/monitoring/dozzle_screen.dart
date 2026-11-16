// Dozzle: container list and live log stream (pause, search, level colors, JSON folding).
// Multiple containers can be selected and watched in one stream; start/stop/restart on a single container
// (if enabled in Dozzle); long-press a log line for "Ask Claude".
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/integrations/dozzle_client.dart';
import '../../core/integrations/http_json.dart' show IntegrationError;
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider, showNewSession;
import '../notes/obsidian.dart';
import '../files/files_screen.dart' show formatSize;
import 'providers.dart';

final dozzleContainersProvider = FutureProvider.autoDispose.family<List<DozzleContainer>, String>((ref, id) async {
  final d = ref.watch(profileProvider).integrations.dozzle.firstWhere((x) => x.id == id);
  final c = await ref.read(dozzleFactoryProvider)(d);
  try {
    return await c.containers();
  } finally {
    c.close();
  }
});

/// At most this many containers in the merged stream (each is a separate live connection).
const dozzleMaxMerged = 8;

class DozzleScreen extends ConsumerStatefulWidget {
  const DozzleScreen({super.key});
  @override
  ConsumerState<DozzleScreen> createState() => _DozzleScreenState();
}

class _DozzleScreenState extends ConsumerState<DozzleScreen> {
  String? _id;
  String _q = '';

  /// null: normal list; otherwise the container IDs selected for the merged stream.
  Set<String>? _selected;

  void _open(DozzleConfig cfg, List<DozzleContainer> cs) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DozzleLogsScreen(config: cfg, containers: cs)));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final list = ref.watch(profileProvider.select((p) => p.integrations.dozzle));
    final cfg = list.where((d) => d.id == _id).firstOrNull ?? list.firstOrNull;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final selecting = _selected != null;
    final all = cfg == null ? null : ref.watch(dozzleContainersProvider(cfg.id)).value;
    final picked = [for (final c in all ?? const <DozzleContainer>[]) if (_selected?.contains(c.id) ?? false) c];
    return SettingsPage(
      title: selecting ? l.dozzleSelected(picked.length) : (cfg?.name ?? 'Dozzle'),
      actions: [
        if (cfg != null)
          IconButton(
            tooltip: selecting ? l.commonCancel : l.dozzleMerge,
            icon: Icon(selecting ? LucideIcons.x : LucideIcons.layers),
            onPressed: () => setState(() => _selected = selecting ? null : {}),
          ),
      ],
      children: [
        if (cfg == null)
          TCard(child: Text(l.integrationNotSet))
        else ...[
          if (list.length > 1)
            Wrap(spacing: 8, children: [
              for (final d in list)
                ChoiceChip(
                  label: Text(d.name),
                  selected: d.id == cfg.id,
                  onSelected: (_) => setState(() {
                    _id = d.id;
                    _selected = null;
                  }),
                ),
            ]),
          TextField(
            decoration: InputDecoration(hintText: l.homeSearch, prefixIcon: const Icon(LucideIcons.search, size: 18)),
            onChanged: (v) => setState(() => _q = v.toLowerCase()),
          ),
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(l.dozzleMergeHint(dozzleMaxMerged), style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 10),
          ref.watch(dozzleContainersProvider(cfg.id)).when(
                loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
                error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
                data: (cs) {
                  final f = cs.where((c) => _q.isEmpty || '${c.name} ${c.image} ${c.project}'.toLowerCase().contains(_q)).toList();
                  // Compose projects in selection mode: select all of a project's containers with one tap.
                  final projects = selecting ? {for (final c in cs) if (c.project != null) c.project!}.toList() : const <String>[];
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (projects.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final p in projects..sort())
                            ActionChip(
                              avatar: const Icon(LucideIcons.layers, size: 14),
                              label: Text(p),
                              tooltip: l.dozzleSelectProject(p),
                              onPressed: () => setState(() {
                                final ids = [for (final c in cs) if (c.project == p) c.id];
                                _selected = {..._selected!, ...ids.take(dozzleMaxMerged - _selected!.length)};
                              }),
                            ),
                        ]),
                      ),
                    GroupedSection(children: [
                      for (final c in f)
                        GroupedRow(
                          title: c.name,
                          subtitle: [
                            c.state,
                            if (c.health != null) c.health!,
                            if (c.cpu != null) '%${c.cpu!.toStringAsFixed(1)}',
                            if (c.memoryBytes != null) formatSize(c.memoryBytes!, locale),
                          ].join(' · '),
                          icon: LucideIcons.box,
                          iconBackground: !c.running ? const Color(0xFF6C6C70) : (c.health == 'unhealthy' ? t.danger : t.success),
                          showChevron: !selecting,
                          trailing: selecting
                              ? ExcludeSemantics(child: Checkbox(value: _selected!.contains(c.id), onChanged: (_) => _toggle(c)))
                              : null,
                          onTap: selecting ? () => _toggle(c) : () => _open(cfg, [c]),
                        ),
                    ]),
                  ]);
                },
              ),
          if (selecting) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: picked.isEmpty ? null : () => _open(cfg, picked),
              icon: const Icon(LucideIcons.scrollText),
              label: Text(l.dozzleWatchTogether(picked.length)),
            ),
          ],
        ],
      ],
    );
  }

  void _toggle(DozzleContainer c) {
    final s = _selected!;
    setState(() {
      if (s.contains(c.id)) {
        s.remove(c.id);
      } else if (s.length < dozzleMaxMerged) {
        s.add(c.id);
      } else {
        toast(context, AppLocalizations.of(context).dozzleMergeHint(dozzleMaxMerged));
      }
    });
  }
}

/// Line in the merged stream: which container it came from + the log.
class DozzleLine {
  const DozzleLine(this.source, this.log);
  final int source;
  final DozzleLog log;
}

/// Source container label colors (dark shades in light theme, light shades in dark theme: AA contrast).
Color dozzleSourceColor(TiphysTokens t, int i) {
  const dark = [0xFF1D4ED8, 0xFF15803D, 0xFFB45309, 0xFF6D28D9, 0xFFBE185D, 0xFF0F766E, 0xFF4D7C0F, 0xFFC2410C];
  const light = [0xFF82B1FF, 0xFF69F0AE, 0xFFFFB74D, 0xFFCE93D8, 0xFFF48FB1, 0xFF80DEEA, 0xFFC5E1A5, 0xFFFFAB91];
  return Color((t.isDark ? light : dark)[i % dark.length]);
}

/// Prepared message for "Ask Claude": container, the selected line and the (at most 30) lines before it.
String dozzleClaudePrompt(AppLocalizations l, List<DozzleContainer> containers, List<DozzleLine> lines, int index) {
  String fmt(DozzleLine x) => '${x.log.time.toIso8601String()}${containers.length > 1 ? ' [${containers[x.source].name}]' : ''} ${x.log.text}';
  final target = lines[index];
  final c = containers[target.source];
  final before = <String>[];
  var budget = 6000; // keep the message a reasonable size
  for (var i = index - 1; i >= 0 && before.length < 30; i--) {
    final s = fmt(lines[i]);
    budget -= s.length;
    if (budget < 0) break;
    before.insert(0, s);
  }
  return [
    l.dozzleClaudeIntro(c.name, c.image),
    '',
    '```',
    fmt(target),
    '```',
    if (before.isNotEmpty) ...['', l.dozzleClaudeBefore, '```', ...before, '```'],
  ].join('\n');
}

/// Merges container histories in time order. Lines with the same millisecond (stack traces, sudden bursts)
/// keep their server order: `List.sort` isn't stable, so ties fall back to container and arrival order.
List<DozzleLine> mergeDozzleHistory(List<List<DozzleLog>> hist) {
  final all = [
    for (var i = 0; i < hist.length; i++)
      for (var j = 0; j < hist[i].length; j++) (i, j, hist[i][j]),
  ]..sort((a, b) {
      final t = a.$3.time.compareTo(b.$3.time);
      if (t != 0) return t;
      final s = a.$1.compareTo(b.$1);
      return s != 0 ? s : a.$2.compareTo(b.$2);
    });
  return [for (final (i, _, e) in all) DozzleLine(i, e)];
}

class DozzleLogsScreen extends ConsumerStatefulWidget {
  const DozzleLogsScreen({super.key, required this.config, required this.containers});
  final DozzleConfig config;
  final List<DozzleContainer> containers;
  @override
  ConsumerState<DozzleLogsScreen> createState() => _DozzleLogsState();
}

class _DozzleLogsState extends ConsumerState<DozzleLogsScreen> {
  DozzleClient? _c;
  final _logs = <DozzleLine>[];
  final _subs = <StreamSubscription<DozzleLog>>[];
  bool _paused = false;
  final _buffer = <DozzleLine>[];
  String _q = '';
  final Set<String> _levels = {...dozzleLevels};
  Object? _error;
  bool _loading = true;
  final _scroll = ScrollController();

  /// Whether container actions are enabled in Dozzle (asked only in the single-container view).
  bool? _actions;
  bool _acting = false;

  /// Last known state after an action (the list snapshot goes stale).
  late String _state = widget.containers.first.state;

  bool get _merged => widget.containers.length > 1;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = await ref.read(dozzleFactoryProvider)(widget.config);
      _c = c;
      if (!_merged) unawaited(c.actionsEnabled().then((v) => v, onError: (_) => false).then((v) => mounted ? setState(() => _actions = v) : null));
      final hist = await Future.wait([for (final x in widget.containers) c.history(x)]);
      if (!mounted) return;
      setState(() {
        _logs.addAll(mergeDozzleHistory(hist));
        _loading = false;
      });
      for (var i = 0; i < widget.containers.length; i++) {
        _listen(c, i);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  /// Live stream. Dozzle closes the stream when the container stops; while the screen stays open it reconnects
  /// every few seconds (so logs keep coming if the container restarted). Repeated lines are filtered in `_add`.
  void _listen(DozzleClient c, int i) {
    late final StreamSubscription<DozzleLog> sub;
    void again() {
      _subs.remove(sub);
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted && identical(_c, c)) _listen(c, i);
      });
    }

    sub = c.stream(widget.containers[i]).listen(
      (e) {
        if (!mounted) return;
        final line = DozzleLine(i, e);
        if (_paused) {
          _buffer.add(line);
        } else {
          setState(() => _add(line));
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
      onDone: again,
    );
    _subs.add(sub);
  }

  void _add(DozzleLine e) {
    // When the stream reconnects the last line may arrive again: skip it if it equals the same container's last line.
    if (e.log.id != 0) {
      for (var i = _logs.length - 1; i >= 0; i--) {
        if (_logs[i].source != e.source) continue;
        if (_logs[i].log.id == e.log.id) return;
        break;
      }
    }
    _logs.add(e);
    if (_logs.length > 5000) _logs.removeRange(0, _logs.length - 5000);
  }

  @override
  void dispose() {
    for (final s in [..._subs]) {
      s.cancel();
    }
    final c = _c;
    _c = null; // stop the reconnect loop
    c?.close();
    _scroll.dispose();
    super.dispose();
  }

  Color _levelColor(TiphysTokens t, String level) => switch (level) {
        'error' || 'fatal' => t.danger,
        'warn' => t.warning,
        'debug' || 'trace' => t.textSecondary,
        _ => t.text,
      };

  Future<void> _runAction(String action) async {
    final l = AppLocalizations.of(context);
    final c = widget.containers.first;
    final client = _c;
    if (client == null) {
      toast(context, '${l.commonError}: ${integrationErrorText(l, _error ?? const IntegrationError('net.unreachable'))}');
      return;
    }
    _actions ??= await client.actionsEnabled().catchError((_) => false);
    if (!mounted) return;
    if (_actions != true) {
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(l.dozzleActionsOffTitle),
          content: Text(l.dozzleActionsOffBody),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(l.commonClose))],
        ),
      );
      return;
    }
    final label = _actionLabel(l, action);
    if (action != 'start' && !await confirmDialog(context, message: l.dozzleActionConfirm(label, c.name), confirmLabel: label, destructive: action == 'stop')) {
      return;
    }
    setState(() => _acting = true);
    try {
      await client.action(c, action);
      if (!mounted) return;
      setState(() => _state = action == 'stop' ? 'exited' : 'running');
      ref.invalidate(dozzleContainersProvider(widget.config.id));
      toast(context, l.dozzleActionDone(label));
    } catch (e) {
      if (mounted) toast(context, '${l.commonError}: ${integrationErrorText(l, e)}');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  String _actionLabel(AppLocalizations l, String a) => switch (a) {
        'start' => l.dozzleStart,
        'stop' => l.dozzleStop,
        _ => l.dozzleRestart,
      };

  void _lineMenu(List<DozzleLine> chronological, int index) {
    final l = AppLocalizations.of(context);
    final line = chronological[index];
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(line.log.text.split('\n').first, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
          ),
          ListTile(
            leading: const Icon(LucideIcons.sparkles),
            title: Text(l.dozzleAskClaude),
            subtitle: Text(l.dozzleAskClaudeHint),
            onTap: () {
              Navigator.pop(c);
              if (ref.read(claudeHostProvider) == null) {
                toast(context, l.dozzleNoClaudeHost);
                return;
              }
              showNewSession(context, ref, prompt: dozzleClaudePrompt(l, widget.containers, chronological, index));
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.copy),
            title: Text(l.commonCopy),
            onTap: () {
              Navigator.pop(c);
              Clipboard.setData(ClipboardData(text: line.log.text));
              toast(context, l.commonCopied);
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.notebookPen),
            title: Text(l.noteSave),
            onTap: () {
              Navigator.pop(c);
              final name = widget.containers[line.source].name;
              openQuickNote(context, text: '${line.log.time.toIso8601String()} [$name] ${line.log.text}', title: 'Dozzle · $name');
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fmt = DateFormat.Hms();
    bool visible(DozzleLine e) => _levels.contains(e.log.level) && (_q.isEmpty || e.log.text.toLowerCase().contains(_q));
    // Visible lines are in chronological order; the list is drawn reversed (newest at the bottom, scroll up).
    final chronological = _logs.where(visible).toList();
    final shown = chronological.length > 1500 ? chronological.sublist(chronological.length - 1500) : chronological;
    final single = widget.containers.first;
    final running = _state == 'running';
    return Scaffold(
      appBar: AppBar(
        title: _merged
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.dozzleMergedTitle(widget.containers.length)),
                Text(widget.containers.map((c) => c.name).join(', '), style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ])
            : Text(single.name),
        actions: [
          IconButton(
            tooltip: _paused ? l.dozzleResume : l.dozzlePause,
            icon: Icon(_paused ? LucideIcons.play : LucideIcons.pause),
            onPressed: () => setState(() {
              _paused = !_paused;
              if (!_paused) {
                _buffer.forEach(_add);
                _buffer.clear();
              }
            }),
          ),
          PopupMenuButton<String>(
            tooltip: l.dozzleLevels,
            icon: const Icon(LucideIcons.listFilter),
            onSelected: (lv) => setState(() => _levels.contains(lv) ? _levels.remove(lv) : _levels.add(lv)),
            itemBuilder: (_) => [
              for (final lv in dozzleLevels) CheckedPopupMenuItem(value: lv, checked: _levels.contains(lv), child: Text(lv)),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: l.filesMore,
            icon: _acting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.ellipsisVertical),
            enabled: !_acting,
            onSelected: (v) {
              switch (v) {
                case 'copy':
                  Clipboard.setData(ClipboardData(text: shown.map((e) => '${e.log.time.toIso8601String()} ${_merged ? '[${widget.containers[e.source].name}] ' : ''}${e.log.text}').join('\n')));
                  toast(context, l.commonCopied);
                case 'share':
                  // Not the filtered view but the whole buffer (at most 5000 lines) is shared as a .log file.
                  final text = _logs
                      .map((e) => '${e.log.time.toIso8601String()} ${_merged ? '[${widget.containers[e.source].name}] ' : ''}[${e.log.level}] ${e.log.text}')
                      .join('\n');
                  final base = _merged ? 'dozzle-${widget.containers.length}' : single.name;
                  final name = '$base-${DateFormat('yyyyMMdd-HHmm').format(DateTime.now())}.log';
                  SharePlus.instance.share(ShareParams(files: [XFile.fromData(utf8.encode(text), mimeType: 'text/plain', name: name)], fileNameOverrides: [name]));
                default:
                  _runAction(v);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'copy', child: ListTile(leading: const Icon(LucideIcons.copy), title: Text(l.commonCopy), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'share', child: ListTile(leading: const Icon(LucideIcons.share2), title: Text(l.dozzleShareLog), contentPadding: EdgeInsets.zero)),
              if (!_merged) ...[
                const PopupMenuDivider(),
                for (final a in running ? const ['restart', 'stop'] : const ['start'])
                  PopupMenuItem(
                    value: a,
                    child: ListTile(
                      leading: Icon(switch (a) { 'start' => LucideIcons.play, 'stop' => LucideIcons.square, _ => LucideIcons.rotateCw }),
                      title: Text(_actionLabel(l, a)),
                      subtitle: _actions == false ? Text(l.dozzleActionsOffShort) : null,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: InputDecoration(hintText: l.homeSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v.toLowerCase()),
          ),
        ),
        if (_merged)
          SizedBox(
            height: 30,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (var i = 0; i < widget.containers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: dozzleSourceColor(t, i), borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 5),
                    Text(widget.containers[i].name, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
            ]),
          ),
        if (_paused && _buffer.isNotEmpty)
          Padding(padding: const EdgeInsets.all(6), child: Text(l.dozzleBuffered(_buffer.length), style: TextStyle(color: t.warning, fontWeight: FontWeight.w600))),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(integrationErrorText(l, _error!), style: TextStyle(color: t.danger))),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : shown.isEmpty
                  ? Center(child: Text(l.dozzleNoLogs))
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final idx = shown.length - 1 - i;
                        final e = shown[idx];
                        final chronoIndex = chronological.length - shown.length + idx;
                        final line = Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${fmt.format(e.log.time)}  ', style: TextStyle(color: t.textSecondary)),
                            if (_merged) TextSpan(text: '${widget.containers[e.source].name}  ', style: TextStyle(color: dozzleSourceColor(t, e.source), fontWeight: FontWeight.w700)),
                            if (e.log.stream == 'stderr') TextSpan(text: '! ', style: TextStyle(color: t.warning)),
                            TextSpan(text: e.log.isJson ? e.log.text.split('\n').first : e.log.text, style: TextStyle(color: _levelColor(t, e.log.level))),
                          ]),
                          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.35),
                        );
                        if (!e.log.isJson) {
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _lineMenu(chronological, chronoIndex),
                            child: Padding(padding: const EdgeInsets.only(bottom: 3), child: line),
                          );
                        }
                        return GestureDetector(
                          onLongPress: () => _lineMenu(chronological, chronoIndex),
                          child: Theme(
                            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              dense: true,
                              tilePadding: EdgeInsets.zero,
                              title: line,
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: SelectableText(e.log.text, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
