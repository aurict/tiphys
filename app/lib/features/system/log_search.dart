// System › Log search: parallel search on the selected hosts (SSH; no agent needed) — systemd journal (system + user)
// and logs of running containers. Results merged by time, matches highlighted; host and source filter.
// Long press a line: copy / Ask Claude / Save to Obsidian.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart';
import '../../core/ssh/log_search.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider, showNewSession;
import '../notes/obsidian.dart';
import '../terminal/sessions.dart' show sshOpenerProvider;
import '../terminal/terminal_screen.dart' show sshFailureText;
import 'events.dart' show ChipRow, filterChip;

/// Shell that runs the search command (a fake is given in tests). Each search opens and closes its own connection.
final logSearchShellOpenerProvider = Provider<Future<RemoteShell> Function(Host)>((ref) => (h) => ref.read(sshOpenerProvider)(h));

/// Time range options.
const logSearchRanges = [Duration(minutes: 15), Duration(hours: 1), Duration(hours: 6), Duration(hours: 24)];

/// Max number of lines drawn on screen at once (grows with "More").
const _page = 200;

String logRangeLabel(AppLocalizations l, Duration d) => d.inMinutes < 60 ? l.logSearchMinutes(d.inMinutes) : l.logSearchHours(d.inHours);

/// Ready message for "Ask Claude": the selected line and the preceding (at most 20) matches from the same host + source.
String logSearchClaudePrompt(AppLocalizations l, {required String pattern, required String hostName, required List<LogHit> newestFirst, required int index}) {
  String fmt(LogHit h) => '${h.time?.toIso8601String() ?? '-'} ${h.message}';
  final target = newestFirst[index];
  final before = <String>[];
  var budget = 6000; // keep the message a reasonable size
  for (var i = index + 1; i < newestFirst.length && before.length < 20; i++) {
    final h = newestFirst[i];
    if (h.hostId != target.hostId || h.source != target.source) continue;
    final s = fmt(h);
    budget -= s.length;
    if (budget < 0) break;
    before.insert(0, s);
  }
  return [
    l.logSearchClaudeIntro(hostName, target.source, pattern),
    '',
    '```',
    fmt(target),
    '```',
    if (before.isNotEmpty) ...['', l.logSearchClaudeBefore, '```', ...before, '```'],
  ].join('\n');
}

String logSearchErrorText(AppLocalizations l, Object e) => switch (e) {
      SshFailure() => sshFailureText(l, e),
      TimeoutException() => l.sshTimeout,
      _ => '${l.commonError}: $e',
    };

class LogSearchScreen extends ConsumerStatefulWidget {
  const LogSearchScreen({super.key, this.initialPattern});

  /// Preset pattern for tests and external opening (searched immediately if given).
  final String? initialPattern;
  @override
  ConsumerState<LogSearchScreen> createState() => _LogSearchScreenState();
}

class _LogSearchScreenState extends ConsumerState<LogSearchScreen> {
  final _q = TextEditingController();
  Duration _range = logSearchRanges.first;

  /// Hosts to search (empty = all; so new hosts are included if the profile changes).
  Set<String> _excluded = {};

  /// Last search's pattern and host → result (loading / error / data).
  String _searched = '';
  final _results = <String, AsyncValue<LogSearchResult>>{};
  int _generation = 0;

  String? _hostFilter;
  String? _sourceFilter;
  int _limit = _page;

  @override
  void initState() {
    super.initState();
    if (widget.initialPattern != null) {
      _q.text = widget.initialPattern!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<Host> get _sshHosts => ref.read(profileProvider).hosts.where((h) => h.ssh != null).toList();

  Future<void> _search() async {
    final pattern = normalizeLogPattern(_q.text);
    if (pattern.isEmpty) return;
    FocusScope.of(context).unfocus();
    final hosts = _sshHosts.where((h) => !_excluded.contains(h.id)).toList();
    if (hosts.isEmpty) return;
    final gen = ++_generation;
    final q = LogQuery(pattern: pattern, since: _range);
    final opener = ref.read(logSearchShellOpenerProvider);
    setState(() {
      _searched = pattern;
      _results
        ..clear()
        ..addAll({for (final h in hosts) h.id: const AsyncValue<LogSearchResult>.loading()});
      _hostFilter = null;
      _sourceFilter = null;
      _limit = _page;
    });
    await Future.wait([
      for (final h in hosts)
        () async {
          AsyncValue<LogSearchResult> v;
          try {
            final shell = await opener(h);
            try {
              v = AsyncValue.data(await searchHostLogs(shell, h.id, q));
            } finally {
              shell.close();
            }
          } catch (e, st) {
            v = AsyncValue.error(e, st);
          }
          if (mounted && gen == _generation) setState(() => _results[h.id] = v);
        }(),
    ]);
  }

  void _lineMenu(List<LogHit> newestFirst, int index) {
    final l = AppLocalizations.of(context);
    final hit = newestFirst[index];
    final hostName = ref.read(profileProvider).host(hit.hostId)?.name ?? hit.hostId;
    final stamp = hit.time?.toIso8601String() ?? '';
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(hit.message.split('\n').first, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
          ),
          ListTile(
            leading: const Icon(LucideIcons.copy),
            title: Text(l.commonCopy),
            onTap: () {
              Navigator.pop(c);
              Clipboard.setData(ClipboardData(text: hit.message));
              toast(context, l.commonCopied);
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.sparkles),
            title: Text(l.dozzleAskClaude),
            subtitle: Text(l.logSearchAskClaudeHint),
            onTap: () {
              Navigator.pop(c);
              if (ref.read(claudeHostProvider) == null) {
                toast(context, l.dozzleNoClaudeHost);
                return;
              }
              showNewSession(context, ref, prompt: logSearchClaudePrompt(l, pattern: _searched, hostName: hostName, newestFirst: newestFirst, index: index));
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.notebookPen),
            title: Text(l.noteSave),
            onTap: () {
              Navigator.pop(c);
              openQuickNote(context, text: '$stamp [$hostName · ${hit.source}] ${hit.message}', title: '${l.logSearchTitle} · $hostName · ${hit.source}');
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
    final p = ref.watch(profileProvider);
    final hosts = p.hosts.where((h) => h.ssh != null).toList();
    final done = [for (final v in _results.values) ?v.value];
    final all = mergeLogHits(done);
    final sources = <String, int>{};
    for (final h in all) {
      if (_hostFilter == null || h.hostId == _hostFilter) sources[h.source] = (sources[h.source] ?? 0) + 1;
    }
    final sourceList = sources.keys.toList()..sort((a, b) => sources[b]!.compareTo(sources[a]!));
    final shown = all.where((h) => (_hostFilter == null || h.hostId == _hostFilter) && (_sourceFilter == null || h.source == _sourceFilter)).toList();
    final hostsWithHits = {for (final h in all) h.hostId};
    final loading = _results.values.any((v) => v.isLoading);

    return SettingsPage(
      title: l.logSearchTitle,
      children: [
        if (hosts.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.composeNoSshHosts)))
        else ...[
          const SizedBox(height: 8),
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: l.logSearchHint,
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              suffixIcon: IconButton(tooltip: l.logSearchRun, icon: const Icon(LucideIcons.arrowRight), onPressed: loading ? null : _search),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<Duration>(
            segments: [for (final d in logSearchRanges) ButtonSegment(value: d, label: Text(logRangeLabel(l, d)))],
            selected: {_range},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _range = s.first),
          ),
          if (hosts.length > 1)
            ChipRow(children: [
              for (final h in hosts)
                Semantics(
                  checked: !_excluded.contains(h.id),
                  child: filterChip(context, h.name, !_excluded.contains(h.id), () {
                    setState(() {
                      final next = {..._excluded};
                      if (!next.remove(h.id)) next.add(h.id);
                      if (next.length < hosts.length) _excluded = next; // at least one host stays selected
                    });
                  }, dot: t.hostColor(hexColor(h.color))),
                ),
            ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(l.logSearchExplain, style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
          ),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 6),
            GroupedSection(children: [
              for (final MapEntry(key: id, value: v) in _results.entries) _HostStatusRow(host: p.host(id), hostId: id, value: v),
            ]),
          ],
          if (hostsWithHits.length > 1)
            ChipRow(children: [
              filterChip(context, l.eventsAllHosts, _hostFilter == null, () => setState(() => _hostFilter = _sourceFilter = null)),
              for (final id in hostsWithHits)
                filterChip(context, p.host(id)?.name ?? id, _hostFilter == id, () => setState(() {
                      _hostFilter = id;
                      _sourceFilter = null;
                    }), dot: t.hostColor(hexColor(p.host(id)?.color ?? '#8F88EE'))),
            ]),
          if (sourceList.length > 1)
            ChipRow(children: [
              filterChip(context, l.logSearchAllSources, _sourceFilter == null, () => setState(() => _sourceFilter = null)),
              for (final s in sourceList.take(30)) filterChip(context, '$s · ${sources[s]}', _sourceFilter == s, () => setState(() => _sourceFilter = s)),
            ]),
          if (_results.isNotEmpty && !loading && all.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.logSearchNoHits(_searched, logRangeLabel(l, _range))))),
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 12),
            TCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (var i = 0; i < shown.length && i < _limit; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 0.5, color: t.separator),
                  _HitRow(
                    hit: shown[i],
                    pattern: _searched,
                    host: p.host(shown[i].hostId),
                    showHost: hostsWithHits.length > 1,
                    onMenu: () => _lineMenu(shown, i),
                  ),
                ],
              ]),
            ),
            if (shown.length > _limit)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(child: TextButton(onPressed: () => setState(() => _limit += _page), child: Text(l.logSearchMore(shown.length - _limit)))),
              ),
          ],
        ],
      ],
    );
  }
}

/// Per-host status: searching / n matches (+ notes: user journal only, truncated, no docker…) / error.
class _HostStatusRow extends StatelessWidget {
  const _HostStatusRow({required this.host, required this.hostId, required this.value});
  final Host? host;
  final String hostId;
  final AsyncValue<LogSearchResult> value;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final name = host?.name ?? hostId;
    return value.when(
      loading: () => GroupedRow(
        title: name,
        subtitle: l.logSearchSearching,
        showChevron: false,
        trailing: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => GroupedRow(title: name, subtitle: logSearchErrorText(l, e), icon: LucideIcons.circleAlert, iconBackground: t.danger, showChevron: false),
      data: (r) => GroupedRow(
        title: name,
        subtitle: [
          l.logSearchHitCount(r.hits.length),
          if (r.userOnly) l.logSearchUserOnly,
          if (r.truncated) l.logSearchTruncated,
          if (r.dockerMissing) l.logSearchNoDocker,
          if (r.dockerError != null) '${l.logSearchDockerError}: ${r.dockerError}',
          ...r.journalErrors.map((e) => 'journalctl: $e'),
        ].join(' · '),
        icon: r.userOnly || r.truncated || r.dockerError != null || r.journalErrors.isNotEmpty ? LucideIcons.triangleAlert : LucideIcons.check,
        iconBackground: r.userOnly || r.truncated || r.dockerError != null || r.journalErrors.isNotEmpty ? t.warning : t.success,
        showChevron: false,
      ),
    );
  }
}

class _HitRow extends StatefulWidget {
  const _HitRow({required this.hit, required this.pattern, required this.host, required this.showHost, required this.onMenu});
  final LogHit hit;
  final String pattern;
  final Host? host;
  final bool showHost;
  final VoidCallback onMenu;
  @override
  State<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends State<_HitRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final h = widget.hit;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final time = h.time == null ? '—' : DateFormat('d MMM HH:mm:ss', locale).format(h.time!);
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.35, color: t.text);
    final mark = TextStyle(backgroundColor: t.warning.withValues(alpha: t.isDark ? 0.45 : 0.3), fontWeight: FontWeight.w700);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (s, e) in logMatchRanges(h.message, widget.pattern)) {
      if (s > at) spans.add(TextSpan(text: h.message.substring(at, s)));
      spans.add(TextSpan(text: h.message.substring(s, e), style: mark));
      at = e;
    }
    if (at < h.message.length) spans.add(TextSpan(text: h.message.substring(at)));
    final error = h.priority != null && h.priority! <= 3;
    return Semantics(
      onLongPressHint: l.logSearchLineActions,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        onLongPress: widget.onMenu,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (widget.showHost && widget.host != null) ...[
                StatusDot(color: t.hostColor(hexColor(widget.host!.color)), size: 8, square: true),
                const SizedBox(width: 6),
                Text(widget.host!.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.text)),
                Text('  ·  ', style: TextStyle(fontSize: 12, color: t.textSecondary)),
              ],
              Icon(h.kind == 'docker' ? LucideIcons.container : LucideIcons.scrollText, size: 13, color: t.textSecondary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(h.source, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: error ? t.danger : t.textSecondary)),
              ),
              const SizedBox(width: 8),
              Text(time, style: TextStyle(fontSize: 12, color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 3),
            Text.rich(TextSpan(style: mono, children: spans), maxLines: _open ? null : 4, overflow: _open ? null : TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}
