// agy tab content: open sessions, earlier conversations (agy's own list, also ones started in a terminal) and the
// new-session sheet. Only reachable when an agent reports the `agy` feature.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show ClaudeFolderPicker, relativeTime;
import '../system/agent_providers.dart';
import 'agy_data.dart';
import 'agy_texts.dart';

/// Route of a session's chat; the host id tells which agent it lives on.
String agyChatRoute(String id, String hostId) => '/agy/$id?host=${Uri.encodeQueryComponent(hostId)}';

String agyFolder(String cwd) {
  final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? '/' : (parts.length == 1 ? parts.last : '${parts[parts.length - 2]}/${parts.last}');
}

class AgyScreen extends ConsumerStatefulWidget {
  const AgyScreen({super.key, this.hostHint});
  final String? hostHint;
  @override
  ConsumerState<AgyScreen> createState() => _AgyScreenState();
}

class _AgyScreenState extends ConsumerState<AgyScreen> {
  late String _cwd = ref.read(profileProvider).claude.favoriteFolders.firstOrNull ?? '~';

  Future<void> _pickFolder(Host host) async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ClaudeFolderPicker(hostId: host.id, start: _cwd),
      ),
    );
    if (picked != null) setState(() => _cwd = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hostAsync = ref.watch(agyHostProvider(widget.hostHint));
    final host = hostAsync.value;
    final now = ref.watch(clockProvider)();
    Color statusColor(String s) => switch (s) {
      'running' || 'starting' => t.accent,
      'waiting' => t.warning,
      'error' => t.danger,
      'idle' => t.success,
      _ => const Color(0xFF6C6C70),
    };
    return SettingsPage(
      title: 'agy',
      onRefresh: () async {
        if (host == null) return;
        ref.invalidate(agySessionsProvider(host.id));
        ref.invalidate(agyConversationsProvider((host.id, _cwd)));
      },
      actions: [
        if (host != null)
          IconButton(
            tooltip: l.agyNewSession,
            icon: const Icon(LucideIcons.plus),
            onPressed: () => showAgyNewSession(context, ref, host: host, cwd: _cwd),
          ),
      ],
      children: [
        if (hostAsync.isLoading)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (host == null)
          TCard(child: Text(l.agyNoHost))
        else ...[
          Text(host.name, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: t.textSecondary)),
          const SizedBox(height: 8),
          ref
              .watch(agySessionsProvider(host.id))
              .when(
                skipLoadingOnRefresh: true,
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
                data: (live) => live.isEmpty
                    ? TCard(
                        onTap: () => showAgyNewSession(context, ref, host: host, cwd: _cwd),
                        child: Row(
                          children: [
                            Icon(LucideIcons.sparkles, color: t.accent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(l.agyNewSession, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            ),
                            Icon(LucideIcons.plus, color: t.textSecondary),
                          ],
                        ),
                      )
                    : GroupedSection(
                        title: l.claudeLive,
                        children: [
                          for (final s in live)
                            GroupedRow(
                              title: '${s['title']}'.isEmpty ? l.claudeUntitled : '${s['title']}',
                              subtitle:
                                  '${agyFolder('${s['cwd']}')} · '
                                  '${((s['pendingPermissions'] as List?)?.length ?? 0) > 0 ? l.claudeStatusWaiting : agyStatusText(l, '${s['status']}')}',
                              icon: LucideIcons.sparkles,
                              iconBackground: statusColor('${s['status']}'),
                              trailingText: s['model'] == null ? null : '${s['model']}',
                              onTap: () => context.push(agyChatRoute('${s['id']}', host.id)),
                            ),
                        ],
                      ),
              ),
          SectionLabel(l.agyPrevious),
          TCard(
            onTap: () => _pickFolder(host),
            semanticLabel: l.claudeFolder,
            child: Row(
              children: [
                Icon(LucideIcons.folder, color: t.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_cwd, style: const TextStyle(fontFamily: monoFamily, fontSize: 13)),
                ),
                Icon(LucideIcons.chevronRight, color: t.textSecondary),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ref
              .watch(agyConversationsProvider((host.id, _cwd)))
              .when(
                skipLoadingOnRefresh: true,
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
                data: (items) => items.isEmpty
                    ? TCard(child: Text(l.agyPreviousEmpty))
                    : GroupedSection(
                        footer: l.agyPreviousHint,
                        children: [
                          for (final c in items.take(50))
                            GroupedRow(
                              title: '${c['title']}'.isEmpty ? l.claudeUntitled : '${c['title']}',
                              subtitle: [
                                agyFolder('${c['cwd'] ?? ''}'),
                                if (DateTime.tryParse('${c['updatedAt']}') != null) relativeTime(l, DateTime.parse('${c['updatedAt']}'), now),
                              ].join(' · '),
                              icon: LucideIcons.history,
                              iconBackground: const Color(0xFF6C6C70),
                              badge: c['liveId'] != null ? l.agyOpenBadge : null,
                              onTap: () => c['liveId'] != null
                                  ? context.push(agyChatRoute('${c['liveId']}', host.id))
                                  : showAgyNewSession(
                                      context,
                                      ref,
                                      host: host,
                                      cwd: '${c['cwd'] ?? _cwd}',
                                      resume: '${c['sessionId']}',
                                      title: '${c['title']}',
                                    ),
                            ),
                        ],
                      ),
              ),
        ],
      ],
    );
  }
}

/// New session: folder, optional first message, mode (with a short explanation). With [resume] it continues an earlier
/// conversation in its own folder. On success the chat screen opens.
Future<void> showAgyNewSession(BuildContext context, WidgetRef ref, {required Host host, String? cwd, String? resume, String? title}) {
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: AgyNewSessionSheet(host: host, initialCwd: cwd, resume: resume, title: title),
    ),
  );
}

class AgyNewSessionSheet extends ConsumerStatefulWidget {
  const AgyNewSessionSheet({super.key, required this.host, this.initialCwd, this.resume, this.title});
  final Host host;
  final String? initialCwd;
  final String? resume;
  final String? title;
  @override
  ConsumerState<AgyNewSessionSheet> createState() => _AgyNewSessionSheetState();
}

class _AgyNewSessionSheetState extends ConsumerState<AgyNewSessionSheet> {
  final _prompt = TextEditingController();
  late String _cwd = widget.initialCwd ?? ref.read(profileProvider).claude.favoriteFolders.firstOrNull ?? '~';
  String _mode = 'default';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ClaudeFolderPicker(hostId: widget.host.id, start: _cwd),
      ),
    );
    if (picked != null) setState(() => _cwd = picked);
  }

  Future<void> _start() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prompt = _prompt.text.trim();
      final res = await agentCall(ref, widget.host.id, 'POST', '/v1/agy/sessions', {
        'cwd': _cwd,
        if (prompt.isNotEmpty) 'prompt': prompt,
        'resume': ?widget.resume,
        if (_mode != 'default') 'modeId': _mode,
      }) as Map;
      if (!mounted) return;
      ref.invalidate(agySessionsProvider(widget.host.id));
      ref.invalidate(agyConversationsProvider((widget.host.id, _cwd)));
      Navigator.pop(context);
      context.push(agyChatRoute('${res['id']}', widget.host.id));
    } catch (e) {
      if (!mounted) return;
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
    final hint = agyModeHint(l, _mode);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.resume == null ? l.agyNewSession : l.claudeContinue, style: Theme.of(context).textTheme.titleLarge),
            if (widget.title != null && widget.title!.isNotEmpty) Text(widget.title!, style: Theme.of(context).textTheme.bodySmall, maxLines: 2),
            const SizedBox(height: 12),
            TCard(
              onTap: widget.resume == null ? _pickFolder : null,
              semanticLabel: l.claudeFolder,
              child: Row(
                children: [
                  Icon(LucideIcons.folder, color: t.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_cwd, style: const TextStyle(fontFamily: monoFamily, fontSize: 13)),
                  ),
                  if (widget.resume == null) Icon(LucideIcons.chevronRight, color: t.textSecondary),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 8,
              decoration: InputDecoration(hintText: l.claudePromptOptional, errorText: _error),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Text(l.agyMode, style: Theme.of(context).textTheme.labelMedium),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in agyKnownModes)
                  ChoiceChip(
                    label: Text(agyModeLabel(l, m)),
                    selected: m == _mode,
                    onSelected: (_) => setState(() => _mode = m),
                    showCheckmark: false,
                    selectedColor: t.isDark ? t.tabActive : const Color(0xFF111114),
                    labelStyle: TextStyle(color: m == _mode ? (t.isDark ? Colors.black : Colors.white) : t.text, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _start,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.arrowUp),
              label: Text(widget.resume == null ? l.claudeStart : l.claudeContinue),
            ),
          ],
        ),
      ),
    );
  }
}
