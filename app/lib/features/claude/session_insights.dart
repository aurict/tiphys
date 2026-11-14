// Oturum olaylarından türetilen iki görünüm:
//  • "Sen yokken": en son baktığın olaydan sonra ne oldu (tur, komut, değişen dosyalar, maliyet, son cevap).
//  • "Değişiklikler": oturumun düzenlediği dosyalar ve farkları; oradan Git ekranına geçip commit atılır.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'claude_chat_screen.dart';
import 'claude_controller.dart';
import 'claude_screen.dart';

const _editTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

class AwayDigest {
  const AwayDigest({required this.turns, required this.commands, required this.files, required this.costUsd, required this.lastText});
  final int turns;
  final int commands;
  final List<String> files;
  final double costUsd;
  final String? lastText;
}

/// `seenSeq`'ten sonraki olayların özeti; anlatacak bir şey yoksa null.
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
  );
}

/// Oturumun değiştirdiği dosyalar (ilk değişiklik sırasıyla) ve her dosya için araç çağrılarının farkları.
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

/// Hangi oturumda en son hangi olaya kadar bakıldı: {oturum: (seq, epoch)}. Ajan yeniden başlarsa (epoch
/// değişir) eski numara geçersizdir. Dosyada saklanır (klasör null ise yalnız bellekte: widget testleri).
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
    state = {...state, sessionId: (seq, epoch)};
    final f = await _file();
    if (f == null) return;
    await f.writeAsString(jsonEncode({for (final e in state.entries) e.key: {'seq': e.value.$1, 'epoch': e.value.$2}}));
  }
}

final claudeSeenProvider = NotifierProvider<ClaudeSeen, Map<String, (int, String)>>(ClaudeSeen.new);

/// Sohbetin altında "Sen yokken" kartı.
class AwayCard extends StatelessWidget {
  const AwayCard({super.key, required this.digest, required this.onClose, this.onChanges});
  final AwayDigest digest;
  final VoidCallback onClose;
  final VoidCallback? onChanges;

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
          IconButton(tooltip: l.commonClose, icon: const Icon(LucideIcons.x, size: 18), onPressed: onClose),
        ]),
      ),
    );
  }
}

/// Oturumun değiştirdiği dosyalar ve farkları; Git ekranına geçiş (commit oradan).
class SessionChangesScreen extends ConsumerWidget {
  const SessionChangesScreen({super.key, required this.events, required this.cwd});
  final List<ClaudeEvent> events;
  final String? cwd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final changes = sessionChanges(events);
    final host = ref.watch(claudeHostProvider);
    return SettingsPage(
      title: l.sessionChanges,
      actions: [
        if (host != null && cwd != null)
          IconButton(
            tooltip: l.sessionOpenGit,
            icon: const Icon(LucideIcons.gitCommitHorizontal),
            onPressed: () => context.push('/git?host=${Uri.encodeQueryComponent(host.id)}&path=${Uri.encodeQueryComponent(cwd!)}'),
          ),
      ],
      children: [
        if (changes.isEmpty) TCard(child: Text(l.sessionNoChanges)),
        for (final MapEntry(key: path, value: diffs) in changes.entries) ...[
          SectionLabel('${path.split('/').last} · ${l.sessionEditCount(diffs.length)}'),
          TCard(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(path, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: context.tokens.textSecondary)),
              for (final d in diffs) ...[const SizedBox(height: 8), ToolDiffView(lines: d)],
            ]),
          ),
        ],
        if (host != null && cwd != null && changes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: FilledButton.icon(
              onPressed: () => context.push('/git?host=${Uri.encodeQueryComponent(host.id)}&path=${Uri.encodeQueryComponent(cwd!)}'),
              icon: const Icon(LucideIcons.gitCommitHorizontal),
              label: Text(l.sessionOpenGit),
            ),
          ),
      ],
    );
  }
}
