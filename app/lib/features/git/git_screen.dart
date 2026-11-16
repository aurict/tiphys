// Git (via the agent): branch, ahead/behind, changes (stage/unstage/revert), diff, commit, push/pull/fetch,
// history and branch switching. Opened from a folder in Files.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';

typedef GitKey = (String hostId, String path);

final gitStatusProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, GitKey>((ref, k) async {
  return withAgent(ref, k.$1, (c) => c.get('/v1/git/status', query: {'path': k.$2}));
});

final gitLogProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, GitKey>((ref, k) async {
  final j = await withAgent(ref, k.$1, (c) => c.get('/v1/git/log', query: {'path': k.$2, 'limit': '80'}));
  return (j['commits'] as List).cast<Map<String, dynamic>>();
});

class GitScreen extends ConsumerStatefulWidget {
  const GitScreen({super.key, required this.hostId, required this.path});
  final String hostId;
  final String path;
  @override
  ConsumerState<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends ConsumerState<GitScreen> {
  final _message = TextEditingController();
  int _tab = 0;
  String? _busy; // running operation (push, pull, …)

  GitKey get _k => (widget.hostId, widget.path);

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(gitStatusProvider(_k));
    ref.invalidate(gitLogProvider(_k));
  }

  Future<void> _op(String name, String path, Map<String, dynamic> body, {String? done}) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = name);
    try {
      await agentCall(ref, widget.hostId, 'POST', path, body);
      _refresh();
      if (done != null && mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, gitErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _stage(List<String> files, bool stage) => _op('stage', '/v1/git/stage', {'path': widget.path, 'files': files, 'stage': stage});

  Future<void> _commit(bool hasStaged) async {
    final l = AppLocalizations.of(context);
    final msg = _message.text.trim();
    if (msg.isEmpty) {
      toast(context, l.gitMessageRequired);
      return;
    }
    await _op('commit', '/v1/git/commit', {'path': widget.path, 'message': msg, 'all': !hasStaged}, done: l.gitCommitted);
    if (mounted && _busy == null) _message.clear();
  }

  Future<void> _discard(String file) async {
    final l = AppLocalizations.of(context);
    if (!await confirmDialog(context, message: l.gitDiscardConfirm(file), confirmLabel: l.gitDiscard, destructive: true)) return;
    await _op('discard', '/v1/git/discard', {'path': widget.path, 'files': [file], 'confirm': true});
  }

  Future<void> _branches(String? current) async {
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<(String, bool)>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
      context: context,
      isScrollControlled: true,
      builder: (c) => _BranchSheet(hostId: widget.hostId, path: widget.path, current: current),
    );
    if (picked == null) return;
    await _op('checkout', '/v1/git/checkout', {'path': widget.path, 'branch': picked.$1, 'create': picked.$2}, done: l.gitSwitched(picked.$1));
  }

  void _openDiff({String? file, bool staged = false, String? commit, required String title}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GitDiffScreen(hostId: widget.hostId, path: widget.path, file: file, staged: staged, commit: commit, title: title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final status = ref.watch(gitStatusProvider(_k));
    final name = widget.path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? widget.path;
    return SettingsPage(
      title: name,
      actions: [IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: _refresh)],
      children: status.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [TCard(child: Text(gitErrorText(l, e)))],
        data: (s) {
          final files = (s['files'] as List).cast<Map<String, dynamic>>();
          final staged = files.where((f) => f['index'] != '.' && f['untracked'] != true && f['conflicted'] != true).toList();
          final unstaged = files.where((f) => f['worktree'] != '.' || f['conflicted'] == true).toList();
          final ahead = s['ahead'] as int? ?? 0, behind = s['behind'] as int? ?? 0;
          return [
            // Branch and remote operations
            TCard(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(LucideIcons.gitBranch, size: 20, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: _busy == null ? () => _branches(s['branch'] as String?) : null,
                      child: Row(children: [
                        Flexible(
                          child: Text('${s['branch'] ?? l.gitDetached}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16), overflow: TextOverflow.ellipsis),
                        ),
                        Icon(LucideIcons.chevronsUpDown, size: 16, color: t.textSecondary),
                      ]),
                    ),
                  ),
                  if (ahead > 0) _Badge(icon: LucideIcons.arrowUp, text: '$ahead', color: t.accent),
                  if (behind > 0) _Badge(icon: LucideIcons.arrowDown, text: '$behind', color: t.warning),
                ]),
                if (s['upstream'] != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 2),
                    child: Text('${s['upstream']}', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  for (final (op, icon, label) in [
                    ('fetch', LucideIcons.refreshCcw, l.gitFetch),
                    ('pull', LucideIcons.arrowDownToLine, l.gitPull),
                    ('push', LucideIcons.arrowUpFromLine, l.gitPush),
                  ]) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy != null ? null : () => _op(op, '/v1/git/$op', {'path': widget.path}, done: l.systemDone),
                        icon: _busy == op ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 16),
                        label: Text(label),
                      ),
                    ),
                    if (op != 'push') const SizedBox(width: 6),
                  ],
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(l.gitChanges(files.length))),
                ButtonSegment(value: 1, label: Text(l.gitHistory)),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() => _tab = v.first),
            ),
            const SizedBox(height: 4),
            if (_tab == 0) ...[
              if (files.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.gitClean))),
              if (staged.isNotEmpty)
                GroupedSection(
                  title: l.gitStaged,
                  children: [
                    for (final f in staged)
                      _FileRow(
                        file: f,
                        code: '${f['index']}',
                        onTap: () => _openDiff(file: '${f['path']}', staged: true, title: '${f['path']}'),
                        action: IconButton(tooltip: l.gitUnstage, icon: const Icon(LucideIcons.minus, size: 18), onPressed: _busy == null ? () => _stage(['${f['path']}'], false) : null),
                      ),
                  ],
                ),
              if (unstaged.isNotEmpty)
                GroupedSection(
                  title: l.gitUnstaged,
                  children: [
                    for (final f in unstaged)
                      _FileRow(
                        file: f,
                        code: f['untracked'] == true ? 'U' : (f['conflicted'] == true ? '!' : '${f['worktree']}'),
                        onTap: () => _openDiff(file: '${f['path']}', title: '${f['path']}'),
                        onLongPress: f['untracked'] == true ? null : () => _discard('${f['path']}'),
                        action: IconButton(tooltip: l.gitStage, icon: const Icon(LucideIcons.plus, size: 18), onPressed: _busy == null ? () => _stage(['${f['path']}'], true) : null),
                      ),
                  ],
                ),
              if (unstaged.length > 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: _busy == null ? () => _stage([for (final f in unstaged) '${f['path']}'], true) : null, child: Text(l.gitStageAll)),
                ),
              if (files.isNotEmpty) ...[
                const SizedBox(height: 8),
                TField(controller: _message, label: l.gitCommitMessage, maxLines: 4),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy == null ? () => _commit(staged.isNotEmpty) : null,
                  icon: _busy == 'commit' ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.gitCommitHorizontal, size: 18),
                  label: Text(staged.isNotEmpty ? l.gitCommitStaged(staged.length) : l.gitCommitAll),
                ),
              ],
            ] else
              _History(k: _k, onOpen: (c) => _openDiff(commit: '${c['hash']}', title: '${c['subject']}')),
          ];
        },
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 2),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      );
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.code, required this.onTap, required this.action, this.onLongPress});
  final Map<String, dynamic> file;
  final String code;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final path = '${file['path']}';
    final slash = path.lastIndexOf('/');
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(children: [
          GitCodeChip(code),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(slash < 0 ? path : path.substring(slash + 1), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (slash > 0) Text(path.substring(0, slash), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textSecondary, fontSize: 12)),
            ]),
          ),
          action,
        ]),
      ),
    );
  }
}

/// File status badge (M, A, D, U, R, !); shared by the Git screen and Claude session changes.
class GitCodeChip extends StatelessWidget {
  const GitCodeChip(this.code, {super.key});
  final String code;

  /// Badge letter from the status line: untracked U, conflict !, otherwise working tree first, then staged status.
  static String of(Map<String, dynamic> f) => f['untracked'] == true
      ? 'U'
      : f['conflicted'] == true
          ? '!'
          : '${f['worktree']}' != '.'
              ? '${f['worktree']}'
              : '${f['index']}';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = switch (code) {
      'A' || 'U' => t.success,
      'D' => t.danger,
      '!' => t.warning,
      'R' || 'C' => const Color(0xFF5E5CE6),
      _ => t.accent,
    };
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(7)),
      child: Text(code, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12, fontFamily: 'JetBrainsMono')),
    );
  }
}

class _History extends ConsumerWidget {
  const _History({required this.k, required this.onOpen});
  final GitKey k;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fmt = DateFormat('d MMM y HH:mm', Localizations.localeOf(context).toLanguageTag());
    return ref.watch(gitLogProvider(k)).when(
          loading: () => const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => TCard(child: Text(gitErrorText(l, e))),
          data: (list) => list.isEmpty
              ? Padding(padding: const EdgeInsets.only(top: 12), child: TCard(child: Text(l.gitNoCommits)))
              : GroupedSection(children: [
                  for (final c in list)
                    GroupedRow(
                      title: '${c['subject']}',
                      subtitle: '${'${c['hash']}'.substring(0, 7)} · ${c['author']} · ${fmt.format(DateTime.parse('${c['date']}').toLocal())}',
                      trailing: '${c['refs']}'.isEmpty
                          ? null
                          : ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 110),
                              child: Text('${c['refs']}'.replaceAll('HEAD -> ', ''),
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                      onTap: () => onOpen(c),
                    ),
                ]),
        );
  }
}

class _BranchSheet extends ConsumerStatefulWidget {
  const _BranchSheet({required this.hostId, required this.path, required this.current});
  final String hostId;
  final String path;
  final String? current;
  @override
  ConsumerState<_BranchSheet> createState() => _BranchSheetState();
}

class _BranchSheetState extends ConsumerState<_BranchSheet> {
  List<Map>? _list;
  Object? _error;
  final _new = TextEditingController();

  @override
  void initState() {
    super.initState();
    agentCall(ref, widget.hostId, 'GET', Uri(path: '/v1/git/branches', queryParameters: {'path': widget.path}).toString()).then(
      (j) => mounted ? setState(() => _list = ((j as Map)['branches'] as List).cast<Map>()) : null,
      onError: (Object e) => mounted ? setState(() => _error = e) : null,
    );
  }

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final local = _list?.where((b) => b['remote'] != true).toList() ?? [];
    final remote = _list?.where((b) => b['remote'] == true && !'${b['name']}'.endsWith('/HEAD')).toList() ?? [];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: ListView(shrinkWrap: true, padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom), children: [
          Text(l.gitBranches, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_error != null) Text(gitErrorText(l, _error!), style: TextStyle(color: t.danger)),
          if (_list == null && _error == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
          for (final b in local)
            ListTile(
              leading: Icon(b['current'] == true ? LucideIcons.check : LucideIcons.gitBranch, size: 18, color: b['current'] == true ? t.accent : null),
              title: Text('${b['name']}'),
              subtitle: b['upstream'] == null ? null : Text('${b['upstream']}'),
              onTap: b['current'] == true ? null : () => Navigator.pop(context, ('${b['name']}', false)),
            ),
          if (remote.isNotEmpty) SectionLabel(l.gitRemoteBranches),
          for (final b in remote)
            ListTile(
              leading: const Icon(LucideIcons.cloud, size: 18),
              title: Text('${b['name']}'),
              // origin/feature → switches to the local "feature" branch (git switch creates it tracking the remote).
              onTap: () => Navigator.pop(context, ('${b['name']}'.split('/').skip(1).join('/'), false)),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TField(controller: _new, label: l.gitNewBranch, mono: true)),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                final n = _new.text.trim();
                if (n.isNotEmpty) Navigator.pop(context, (n, true));
              },
              child: Text(l.commonCreate),
            ),
          ]),
        ]),
      ),
    );
  }
}

class GitDiffScreen extends ConsumerStatefulWidget {
  const GitDiffScreen({super.key, required this.hostId, required this.path, required this.title, this.file, this.staged = false, this.head = false, this.commit});
  final String hostId;
  final String path;
  final String title;
  final String? file;
  final bool staged;

  /// Relative to HEAD (staged + unstaged together; Claude session changes).
  final bool head;
  final String? commit;
  @override
  ConsumerState<GitDiffScreen> createState() => _GitDiffScreenState();
}

class _GitDiffScreenState extends ConsumerState<GitDiffScreen> {
  String? _diff;
  bool _truncated = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final q = {
      'path': widget.path,
      if (widget.file != null) 'file': widget.file!,
      if (widget.staged) 'staged': 'true',
      if (widget.head) 'head': 'true',
      if (widget.commit != null) 'commit': widget.commit!,
    };
    agentCall(ref, widget.hostId, 'GET', Uri(path: '/v1/git/diff', queryParameters: q).toString()).then(
      (j) => mounted
          ? setState(() {
              _diff = '${(j as Map)['diff']}';
              _truncated = j['truncated'] == true;
            })
          : null,
      onError: (Object e) => mounted ? setState(() => _error = e) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(gitErrorText(l, _error!))))
          : _diff == null
              ? const Center(child: CircularProgressIndicator())
              : _diff!.isEmpty
                  ? Center(child: Text(l.gitNoDiff))
                  : DiffView(text: _diff!, truncated: _truncated),
    );
  }
}

/// Shows unified diff text with colored lines (horizontally scrollable, lines aren't clipped).
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.text, this.truncated = false});
  final String text;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);
    final add = t.isDark ? const Color(0x3330D158) : const Color(0xFFDCFCE7);
    final del = t.isDark ? const Color(0x33FF6961) : const Color(0xFFFEE2E2);
    final hunk = t.isDark ? const Color(0x335E5CE6) : const Color(0xFFEDEBFF);
    final lines = text.split('\n');
    const style = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.4);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1400,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: lines.length + (truncated ? 1 : 0),
          itemBuilder: (c, i) {
            if (i == lines.length) return Padding(padding: const EdgeInsets.all(12), child: Text(l.gitDiffTruncated, style: TextStyle(color: t.warning)));
            final s = lines[i];
            final header = s.startsWith('diff --git') || s.startsWith('index ') || s.startsWith('+++') || s.startsWith('---') || s.startsWith('new file') || s.startsWith('deleted file');
            final bg = header
                ? Colors.transparent
                : s.startsWith('@@')
                    ? hunk
                    : s.startsWith('+')
                        ? add
                        : (s.startsWith('-') ? del : Colors.transparent);
            return Container(
              color: bg,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(s.isEmpty ? ' ' : s,
                  softWrap: false, style: style.copyWith(color: header ? t.textSecondary : t.text, fontWeight: header ? FontWeight.w700 : null)),
            );
          },
        ),
      ),
    );
  }
}

String gitErrorText(AppLocalizations l, Object e) {
  final code = e is AgentError ? e.code : null;
  final stderr = e is AgentError ? '${e.params['stderr'] ?? ''}'.trim() : '';
  final base = switch (code) {
    'agent.git.notRepo' => l.gitNotRepo,
    'agent.git.nothingToCommit' => l.gitNothingToCommit,
    'agent.git.pushFailed' => l.gitPushFailed,
    'agent.git.pullFailed' => l.gitPullFailed,
    'agent.git.fetchFailed' => l.gitPullFailed,
    'agent.git.noUpstream' => l.gitNoUpstream,
    'agent.git.noRemote' => l.gitNoRemote,
    'agent.git.authFailed' => l.gitAuthFailed,
    'agent.git.pushRejected' => l.gitPushRejected,
    'agent.git.newFilesNeedConfirm' => l.gitNewFilesNeedConfirm,
    'agent.path.notAllowed' => l.agentPathNotAllowed,
    _ => agentErrorText(l, e),
  };
  return stderr.isEmpty ? base : '$base\n${stderr.split('\n').take(4).join('\n')}';
}
