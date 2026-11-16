// Two views derived from session events:
//  • "While you were away": what happened since the last event you saw (turns, commands, changed files, cost, last reply).
//  • "Changes": files edited by the session, per-file diff, commit + push of only these files, or
//    revert (via the agent's git endpoints).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../git/git_screen.dart';
import '../system/agent_providers.dart';
import 'claude_chat_screen.dart';
import 'claude_controller.dart';
import 'claude_screen.dart';

const _editTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

class AwayDigest {
  const AwayDigest({required this.turns, required this.commands, required this.files, required this.costUsd, required this.lastText, this.lastFull});
  final int turns;
  final int commands;
  final List<String> files;
  final double costUsd;
  final String? lastText;

  /// The untruncated last reply (for the Obsidian note).
  final String? lastFull;
}

/// Note text of the "While you were away" summary (Save to Obsidian).
String awayNoteText(AppLocalizations l, AwayDigest d) => [
      [
        if (d.turns > 0) l.awayTurns(d.turns),
        if (d.commands > 0) l.awayCommands(d.commands),
        if (d.files.isNotEmpty) l.awayFiles(d.files.length),
        if (d.costUsd >= 0.01) '\$${d.costUsd.toStringAsFixed(2)}',
      ].join(' · '),
      if (d.files.isNotEmpty) d.files.map((f) => '- `$f`').join('\n'),
      ?(d.lastFull ?? d.lastText),
    ].where((s) => s.trim().isNotEmpty).join('\n\n');

/// Summary of the events after `seenSeq`; null if there's nothing to tell.
AwayDigest? awayDigest(List<ClaudeEvent> events, int seenSeq) {
  final fresh = events.where((e) => e.seq > seenSeq).toList();
  if (!fresh.any((e) => e.kind == 'tool_use' || e.kind == 'text')) return null;
  double cost(Iterable<ClaudeEvent> es) => es.where((e) => e.kind == 'result').map((e) => (e.get<num>('costUsd') ?? 0).toDouble()).lastOrNull ?? 0;
  final before = cost(events.where((e) => e.seq <= seenSeq));
  final after = cost(fresh);
  final files = <String>{
    for (final e in fresh)
      if (e.kind == 'tool_use' && _editTools.contains(e.get<String>('name'))) '${(e.json['input'] as Map?)?['file_path'] ?? (e.json['input'] as Map?)?['notebook_path'] ?? ''}',
  }..remove('');
  final last = fresh.lastWhere((e) => e.kind == 'text', orElse: () => ClaudeEvent(const {'kind': 'none'})).json['text'] as String?;
  return AwayDigest(
    turns: fresh.where((e) => e.kind == 'result').length,
    commands: fresh.where((e) => e.kind == 'tool_use' && e.get<String>('name') == 'Bash').length,
    files: files.toList(),
    costUsd: after > before ? after - before : 0,
    lastText: last == null ? null : (last.length > 220 ? '${last.substring(0, 220)}…' : last),
    lastFull: last,
  );
}

/// Files changed by the session (in order of first change) and the tool-call diffs for each file.
Map<String, List<List<(String, String)>>> sessionChanges(List<ClaudeEvent> events) {
  final out = <String, List<List<(String, String)>>>{};
  for (final e in events) {
    if (e.kind != 'tool_use' || !_editTools.contains(e.get<String>('name'))) continue;
    final input = Map<String, dynamic>.from((e.json['input'] as Map?) ?? const {});
    final path = '${input['file_path'] ?? input['notebook_path'] ?? ''}';
    if (path.isEmpty) continue;
    (out[path] ??= []).add(toolDiff(e.get<String>('name')!, input));
  }
  return out;
}

/// Up to which event each session was last viewed: {session: (seq, epoch)}. If the agent restarts (epoch
/// changes) the old number is invalid. Stored in a file (in memory only if the folder is null: widget tests).
class ClaudeSeen extends Notifier<Map<String, (int, String)>> {
  @override
  Map<String, (int, String)> build() {
    Future(() async {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        state = {for (final e in j.entries) e.key: ((e.value as Map)['seq'] as int, (e.value as Map)['epoch'] as String)};
      } catch (_) {}
    });
    return {};
  }

  Future<File?> _file() async {
    final dir = await ref.read(outboxDirProvider)();
    return dir == null ? null : File('$dir/claude-seen.json');
  }

  Future<void> mark(String sessionId, int seq, String epoch) async {
    if (!ref.mounted) return;
    state = {...state, sessionId: (seq, epoch)};
    final f = await _file();
    if (f == null) return;
    await f.writeAsString(jsonEncode({for (final e in state.entries) e.key: {'seq': e.value.$1, 'epoch': e.value.$2}}));
  }
}

final claudeSeenProvider = NotifierProvider<ClaudeSeen, Map<String, (int, String)>>(ClaudeSeen.new);

/// "While you were away" card below the chat.
class AwayCard extends StatelessWidget {
  const AwayCard({super.key, required this.digest, required this.onClose, this.onChanges, this.onSaveNote});
  final AwayDigest digest;
  final VoidCallback onClose;
  final VoidCallback? onChanges;

  /// Save the summary to Obsidian (quick note screen).
  final VoidCallback? onSaveNote;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final d = digest;
    final facts = [
      if (d.turns > 0) l.awayTurns(d.turns),
      if (d.commands > 0) l.awayCommands(d.commands),
      if (d.files.isNotEmpty) l.awayFiles(d.files.length),
      if (d.costUsd >= 0.01) '\$${d.costUsd.toStringAsFixed(2)}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: TCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(LucideIcons.history, size: 18, color: t.accent)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.awayTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              if (facts.isNotEmpty) Text(facts.join(' · '), style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
              if (d.files.isNotEmpty)
                Text(d.files.map((f) => f.split('/').last).take(4).join(', ') + (d.files.length > 4 ? '…' : ''),
                    style: TextStyle(color: t.textSecondary, fontSize: 12.5, fontFamily: 'JetBrainsMono'), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (d.lastText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(d.lastText!, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.35)),
                ),
              if (onChanges != null && d.files.isNotEmpty)
                Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: onChanges, child: Text(l.sessionChanges))),
            ]),
          ),
          Column(children: [
            IconButton(tooltip: l.commonClose, icon: const Icon(LucideIcons.x, size: 18), onPressed: onClose),
            if (onSaveNote != null) IconButton(tooltip: l.noteSave, icon: const Icon(LucideIcons.notebookPen, size: 18), onPressed: onSaveNote),
          ]),
        ]),
      ),
    );
  }
}

/// "a/./b/../c" → "a/c" (for absolute paths; `..` doesn't go above the root).
String _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(part);
    }
  }
  return '/${out.join('/')}';
}

/// A file changed by the session and its current Git status.
class SessionFile {
  const SessionFile({required this.path, required this.rel, required this.git});

  /// Path in the tool call (mostly absolute).
  final String path;

  /// Path relative to the repo root; null if outside the repo.
  final String? rel;

  /// `git status` line; null if the file currently has no changes.
  final Map<String, dynamic>? git;

  /// File not in HEAD (untracked or newly added): deleted on revert.
  bool get isNew => git != null && (git!['untracked'] == true || git!['index'] == 'A');
}

/// Matches session files with Git status (relative paths are resolved against the session folder).
List<SessionFile> mapSessionFiles(Iterable<String> paths, String? cwd, Map<String, dynamic>? status) {
  final root = status?['root'] as String?;
  final files = ((status?['files'] as List?) ?? const []).cast<Map<String, dynamic>>();
  return [
    for (final p in paths)
      () {
        final abs = p.startsWith('/') ? _normalize(p) : (cwd == null ? null : _normalize('$cwd/$p'));
        final rel = root != null && abs != null && abs.startsWith('$root/') ? abs.substring(root.length + 1) : null;
        return SessionFile(path: p, rel: rel, git: rel == null ? null : files.where((f) => f['path'] == rel).firstOrNull);
      }(),
  ];
}

/// Files changed by the session: per-file diff (against HEAD), "Commit + push" of only these files and
/// "Revert changes". The tool-call diffs are also shown below.
class SessionChangesScreen extends ConsumerStatefulWidget {
  const SessionChangesScreen({super.key, required this.events, required this.cwd, this.title});
  final List<ClaudeEvent> events;
  final String? cwd;

  /// Session title: commit message suggestion.
  final String? title;

  @override
  ConsumerState<SessionChangesScreen> createState() => _SessionChangesScreenState();
}

class _SessionChangesScreenState extends ConsumerState<SessionChangesScreen> {
  String? _busy; // 'commit' | 'revert'

  Future<void> _commit(GitKey k, String? branch, List<SessionFile> files) async {
    final l = AppLocalizations.of(context);
    final message = await showModalBottomSheet<String>(
      useRootNavigator: true, // open above the bottom tab bar
      context: context,
      isScrollControlled: true,
      builder: (c) => _CommitSheet(branch: branch, files: [for (final f in files) f.rel!], initial: widget.title ?? ''),
    );
    if (message == null || !mounted) return;
    setState(() => _busy = 'commit');
    try {
      await agentCall(ref, k.$1, 'POST', '/v1/git/commit', {'path': k.$2, 'message': message, 'files': [for (final f in files) f.rel!]});
    } catch (e) {
      if (mounted) toast(context, gitErrorText(l, e));
      return _done(k);
    }
    try {
      await _push(k, branch);
      if (mounted) toast(context, l.sessionPushed);
    } catch (e) {
      // The commit stays; only the push failed.
      if (mounted) toast(context, '${l.gitCommitted}. ${gitErrorText(l, e)}');
    }
    _done(k);
  }

  /// Push; if the branch doesn't exist on the remote, asks and pushes with upstream tracking. Ends silently if cancelled.
  Future<void> _push(GitKey k, String? branch) async {
    final l = AppLocalizations.of(context);
    try {
      await agentCall(ref, k.$1, 'POST', '/v1/git/push', {'path': k.$2});
    } on AgentError catch (e) {
      if (e.code != 'agent.git.noUpstream' || !mounted) rethrow;
      final name = '${e.params['branch'] ?? branch ?? ''}';
      if (!await confirmDialog(context, message: l.gitNoUpstreamConfirm(name), confirmLabel: l.gitPublishBranch)) rethrow;
      await agentCall(ref, k.$1, 'POST', '/v1/git/push', {'path': k.$2, 'setUpstream': true});
    }
  }

  Future<void> _revert(GitKey k, List<SessionFile> files) async {
    final l = AppLocalizations.of(context);
    final deleteNew = await showDialog<bool>(context: context, builder: (c) => _RevertDialog(files: files));
    if (deleteNew == null || !mounted) return;
    final chosen = files.where((f) => deleteNew || !f.isNew).toList();
    if (chosen.isEmpty) return;
    setState(() => _busy = 'revert');
    try {
      await agentCall(ref, k.$1, 'POST', '/v1/git/discard', {
        'path': k.$2,
        'files': [for (final f in chosen) f.rel!],
        'source': 'head',
        'confirm': true,
        'deleteNew': deleteNew,
      });
      if (mounted) toast(context, l.sessionReverted);
    } catch (e) {
      if (mounted) toast(context, gitErrorText(l, e));
    }
    _done(k);
  }

  void _done(GitKey k) {
    ref.invalidate(gitStatusProvider(k));
    if (mounted) setState(() => _busy = null);
  }

  void _openDiff(GitKey k, SessionFile f) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => GitDiffScreen(hostId: k.$1, path: k.$2, file: f.rel, head: true, title: f.rel!),
      ));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final changes = sessionChanges(widget.events);
    final host = ref.watch(claudeHostProvider);
    final GitKey? k = host != null && widget.cwd != null ? (host.id, widget.cwd!) : null;
    final status = k == null || changes.isEmpty ? null : ref.watch(gitStatusProvider(k));
    final st = status?.value;
    final files = mapSessionFiles(changes.keys, widget.cwd, st);
    final actionable = files.where((f) => f.rel != null && f.git != null).toList();
    final branch = st?['branch'] as String?;
    final busy = _busy != null;
    Widget spinner() => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    return SettingsPage(
      title: l.sessionChanges,
      actions: [
        if (k != null)
          IconButton(
            tooltip: l.sessionOpenGit,
            icon: const Icon(LucideIcons.gitCommitHorizontal),
            onPressed: () => context.push('/git?host=${Uri.encodeQueryComponent(k.$1)}&path=${Uri.encodeQueryComponent(k.$2)}'),
          ),
      ],
      children: [
        if (changes.isEmpty) TCard(child: Text(l.sessionNoChanges)),
        // Branch and remote: in a worktree session (branch tiphys/…) a reminder that push doesn't go to main.
        if (status != null)
          TCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: status.when(
              skipLoadingOnRefresh: true,
              loading: () => Row(children: [spinner(), const SizedBox(width: 10), Text(l.commonLoading)]),
              error: (e, _) => Text(gitErrorText(l, e)),
              data: (s) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(LucideIcons.gitBranch, size: 20, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(branch ?? l.gitDetached, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16), overflow: TextOverflow.ellipsis)),
                ]),
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 2),
                  child: Text('${s['upstream'] ?? l.sessionNoUpstream}', style: TextStyle(color: t.textSecondary, fontSize: 12)),
                ),
                if (branch != null && branch.startsWith('tiphys/'))
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(LucideIcons.triangleAlert, size: 18, color: t.warning),
                      const SizedBox(width: 10),
                      Expanded(child: Text(l.sessionWorktreeWarning(branch), style: const TextStyle(fontSize: 13, height: 1.35))),
                    ]),
                  ),
              ]),
            ),
          ),
        for (final f in files) ...[
          SectionLabel('${f.path.split('/').last} · ${l.sessionEditCount(changes[f.path]!.length)}'),
          TCard(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                if (f.git != null) ...[GitCodeChip(GitCodeChip.of(f.git!)), const SizedBox(width: 10)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f.rel ?? f.path, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: t.textSecondary)),
                    if (st != null && f.git == null)
                      Text(f.rel == null ? l.sessionFileOutside : l.sessionFileUnchanged, style: TextStyle(fontSize: 12, color: t.textSecondary)),
                  ]),
                ),
                if (k != null && f.git != null)
                  IconButton(tooltip: l.sessionViewDiff, icon: const Icon(LucideIcons.fileDiff, size: 20), onPressed: () => _openDiff(k, f)),
              ]),
              for (final d in changes[f.path]!) ...[const SizedBox(height: 8), ToolDiffView(lines: d)],
            ]),
          ),
        ],
        if (k != null && actionable.isNotEmpty) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : () => _commit(k, branch, actionable),
            icon: _busy == 'commit' ? spinner() : const Icon(LucideIcons.gitCommitHorizontal, size: 18),
            label: Text(l.sessionCommitPush),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: t.danger),
            onPressed: busy ? null : () => _revert(k, actionable),
            icon: _busy == 'revert' ? spinner() : const Icon(LucideIcons.undo2, size: 18),
            label: Text(l.gitDiscard),
          ),
        ],
      ],
    );
  }
}

/// Commit message (session title suggested), branch and the files to commit.
class _CommitSheet extends StatefulWidget {
  const _CommitSheet({required this.branch, required this.files, required this.initial});
  final String? branch;
  final List<String> files;
  final String initial;
  @override
  State<_CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends State<_CommitSheet> {
  late final _message = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _submit() {
    final m = _message.text.trim();
    if (m.isEmpty) return toast(context, AppLocalizations.of(context).gitMessageRequired);
    Navigator.pop(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final b = widget.branch;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(shrinkWrap: true, padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom), children: [
          Text(l.sessionCommitPush, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Row(children: [
            Icon(LucideIcons.gitBranch, size: 16, color: t.accent),
            const SizedBox(width: 6),
            Expanded(child: Text(b ?? l.gitDetached, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          ]),
          if (b != null && b.startsWith('tiphys/'))
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.sessionWorktreeWarning(b), style: TextStyle(color: t.warning, fontSize: 12.5))),
          const SizedBox(height: 10),
          Text(l.sessionCommitFiles(widget.files.length), style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
          const SizedBox(height: 4),
          for (final f in widget.files.take(12)) Text(f, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5), overflow: TextOverflow.ellipsis),
          if (widget.files.length > 12) Text('… +${widget.files.length - 12}', style: TextStyle(color: t.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          TField(controller: _message, label: l.gitCommitMessage, maxLines: 4),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _submit, icon: const Icon(LucideIcons.arrowUpFromLine, size: 18), label: Text(l.sessionCommitPush)),
        ]),
      ),
    );
  }
}

/// Revert confirmation: files are listed; new files are deleted only if a separate box is checked.
/// Result: null = cancelled, otherwise the "also delete new files" choice.
class _RevertDialog extends StatefulWidget {
  const _RevertDialog({required this.files});
  final List<SessionFile> files;
  @override
  State<_RevertDialog> createState() => _RevertDialogState();
}

class _RevertDialogState extends State<_RevertDialog> {
  bool _deleteNew = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fresh = widget.files.where((f) => f.isNew).length;
    final canRun = _deleteNew || widget.files.any((f) => !f.isNew);
    return AlertDialog(
      title: Text(l.sessionRevertTitle),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.sessionRevertBody(widget.files.length - fresh)),
          const SizedBox(height: 10),
          for (final f in widget.files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(f.rel!, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12), overflow: TextOverflow.ellipsis)),
                if (f.isNew) Text(l.sessionRevertNewTag, style: TextStyle(color: t.success, fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          if (fresh > 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _deleteNew,
              onChanged: (v) => setState(() => _deleteNew = v ?? false),
              title: Text(l.sessionRevertDeleteNew(fresh), style: TextStyle(color: t.danger, fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(
          onPressed: canRun ? () => Navigator.pop(context, _deleteNew) : null,
          style: TextButton.styleFrom(foregroundColor: t.danger),
          child: Text(l.gitDiscard),
        ),
      ],
    );
  }
}
