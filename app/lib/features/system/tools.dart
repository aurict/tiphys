// System › Tools (agent host): processes, ports (preview), desktop panel, clipboard, open clipboard link on PC, media,
// screenshot, action log;
// and the quick actions defined for this host (run over SSH, no agent needed).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/util/refresh.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../files/files_screen.dart' show fileBrowsersProvider, formatSize;
import 'agent_providers.dart';
import 'media.dart';
import 'open_on_pc.dart';

/// The agent's enabled features (from the health response). Empty if unknown.
Map<String, dynamic> _features(WidgetRef ref, Host host) =>
    ((ref.watch(healthProvider(host.id)).value?['features'] as Map?) ?? const {}).cast<String, dynamic>();

class ToolsSection extends ConsumerWidget {
  const ToolsSection({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final f = host.agent == null ? const <String, dynamic>{} : _features(ref, host);
    final actions = ref.watch(profileProvider).quickActions.where((a) => a.hostId == host.id).toList();
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    final rows = <Widget>[
      if (f['system'] == true)
        GroupedRow(title: l.toolsProcesses, icon: LucideIcons.cpu, iconBackground: const Color(0xFF5E5CE6), onTap: () => open(ProcessesScreen(host: host))),
      if (f['ports'] == true)
        GroupedRow(title: l.toolsPorts, subtitle: l.toolsPortsHint, icon: LucideIcons.plug, iconBackground: const Color(0xFF0A84FF), onTap: () => open(PortsScreen(host: host))),
      if (f['desktop'] == true) ...[
        GroupedRow(
          title: l.desktopTitle,
          icon: LucideIcons.appWindow,
          iconBackground: const Color(0xFF5856D6),
          onTap: () => context.push('/system/desktop?host=${Uri.encodeQueryComponent(host.id)}'),
        ),
        GroupedRow(title: l.toolsClipboard, icon: LucideIcons.clipboard, iconBackground: const Color(0xFFBF5AF2), onTap: () => open(ClipboardScreen(host: host))),
        GroupedRow(
          title: l.openOnPc,
          subtitle: l.openOnPcClipboardHint,
          icon: LucideIcons.squareArrowOutUpRight,
          iconBackground: const Color(0xFF0A84FF),
          showChevron: false,
          onTap: () => openClipboardUrlOnPc(context, ref, host),
        ),
        GroupedRow(title: l.mediaTitle, icon: LucideIcons.music, iconBackground: const Color(0xFFFF375F), onTap: () => open(MediaScreen(hostId: host.id))),
        GroupedRow(title: l.toolsScreenshot, icon: LucideIcons.monitor, iconBackground: const Color(0xFF30B0C7), onTap: () => open(ScreenshotScreen(host: host))),
      ],
      if (f['telegram'] == true)
        GroupedRow(
          title: 'Telegram',
          subtitle: l.tgRowHint,
          icon: LucideIcons.send,
          iconBackground: const Color(0xFF2AABEE),
          onTap: () => context.push('/system/telegram?host=${Uri.encodeQueryComponent(host.id)}'),
        ),
      if (f['research'] == true)
        GroupedRow(
          title: l.researchTitle,
          subtitle: l.researchRowHint,
          icon: LucideIcons.search,
          iconBackground: const Color(0xFF0A84FF),
          onTap: () => context.push('/system/research?host=${Uri.encodeQueryComponent(host.id)}'),
        ),
      if (host.agent != null)
        GroupedRow(title: l.toolsAudit, icon: LucideIcons.scrollText, iconBackground: const Color(0xFF8E8E93), onTap: () => open(AuditScreen(host: host))),
    ];
    return Column(children: [
      if (rows.isNotEmpty) GroupedSection(title: l.toolsTitle, children: rows),
      if (actions.isNotEmpty)
        GroupedSection(title: l.quickActionsTitle, children: [
          for (final a in actions)
            GroupedRow(
              title: a.name,
              subtitle: a.command,
              icon: LucideIcons.zap,
              iconBackground: t.warning,
              showChevron: false,
              onTap: () => runQuickAction(context, ref, a),
            ),
        ]),
    ]);
  }
}

/// Runs a quick action over SSH (asks for confirmation first if needed) and shows the result in a subpage.
Future<void> runQuickAction(BuildContext context, WidgetRef ref, QuickAction a) async {
  final l = AppLocalizations.of(context);
  final host = ref.read(profileProvider).host(a.hostId);
  if (host == null) return;
  if (a.confirm && !await confirmDialog(context, message: l.quickActionRunConfirm(a.name, host.name), confirmLabel: l.quickActionRun)) return;
  if (!context.mounted) return;
  final result = (() async {
    final f = await ref.read(fileBrowsersProvider.notifier).get(host);
    return f.conn.exec(a.command, timeout: const Duration(minutes: 10));
  })();
  await showModalBottomSheet<void>(
      useRootNavigator: true, // open above the bottom tab bar; otherwise the bar covers the bottom of the page
    context: context,
    isScrollControlled: true,
    builder: (c) => _RunSheet(title: a.name, command: a.command, result: result),
  );
}

class _RunSheet extends StatelessWidget {
  const _RunSheet({required this.title, required this.command, required this.result});
  final String title;
  final String command;
  final Future<({String stdout, String stderr, int? code})> result;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: FutureBuilder(
            future: result,
            builder: (c, snap) {
              final r = snap.data;
              final out = r == null ? '' : [r.stdout, r.stderr].where((s) => s.trim().isNotEmpty).join('\n').trimRight();
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                  if (r != null) _CodeChip(code: r.code),
                ]),
                const SizedBox(height: 4),
                Text(command, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: t.textSecondary)),
                const SizedBox(height: 12),
                if (snap.hasError)
                  Text('${l.commonError}: ${snap.error}', style: TextStyle(color: t.danger))
                else if (r == null)
                  Row(children: [
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(l.quickActionRunning),
                  ])
                else
                  Flexible(
                    child: TCard(
                      padding: const EdgeInsets.all(12),
                      child: SingleChildScrollView(
                        child: SelectableText(out.isEmpty ? l.quickActionNoOutput : out,
                            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.35)),
                      ),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code});
  final int? code;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ok = code == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: (ok ? t.success : t.danger).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
      child: Text(ok ? 'OK' : 'exit ${code ?? '?'}', style: TextStyle(color: ok ? t.success : t.danger, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

/// Tool page with a simple "loading / error / data" scaffold.
class _AsyncPage<T> extends StatelessWidget {
  const _AsyncPage({required this.title, required this.value, required this.onRetry, required this.builder, this.actions});
  final String title;
  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final List<Widget> Function(T data) builder;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: title,
      actions: [...?actions, IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: onRetry)],
      children: value.when(
        skipLoadingOnRefresh: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          TCard(
            child: Row(children: [
              Icon(LucideIcons.circleAlert, color: context.tokens.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(agentErrorText(l, e))),
              TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
            ]),
          ),
        ],
        data: builder,
      ),
    );
  }
}

// ── Processes ───────────────────────────────────────────────────────────────

final processesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, (String, String)>((ref, key) async {
  final (hostId, sort) = key;
  autoRefresh(ref, const Duration(seconds: 5));
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/processes', query: {'sort': sort, 'limit': '150'}));
  return (j['processes'] as List).cast<Map<String, dynamic>>();
});

class ProcessesScreen extends ConsumerStatefulWidget {
  const ProcessesScreen({super.key, required this.host});
  final Host host;
  @override
  ConsumerState<ProcessesScreen> createState() => _ProcessesScreenState();
}

class _ProcessesScreenState extends ConsumerState<ProcessesScreen> {
  String _sort = 'cpu';
  String _q = '';

  Future<void> _signal(Map<String, dynamic> p, String signal) async {
    final l = AppLocalizations.of(context);
    final label = signal == 'KILL' ? l.processesKill : l.processesTerminate;
    if (!await confirmDialog(context, message: l.processesConfirm(label, '${p['name']}', p['pid'] as int), confirmLabel: label, destructive: true)) return;
    try {
      await agentCall(ref, widget.host.id, 'POST', '/v1/processes/${p['pid']}/signal', {'signal': signal, 'confirm': true});
      ref.invalidate(processesProvider((widget.host.id, _sort)));
      if (mounted) toast(context, l.systemDone);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final key = (widget.host.id, _sort);
    return _AsyncPage<List<Map<String, dynamic>>>(
      title: '${l.toolsProcesses} · ${widget.host.name}',
      value: ref.watch(processesProvider(key)),
      onRetry: () => ref.invalidate(processesProvider(key)),
      builder: (list) {
        final q = lower(_q, locale);
        final shown = list.where((p) => q.isEmpty || lower('${p['name']} ${p['command']} ${p['user']} ${p['pid']}', locale).contains(q)).toList();
        return [
          Row(children: [
            SegmentedButton<String>(
              segments: [ButtonSegment(value: 'cpu', label: Text(l.processesByCpu)), ButtonSegment(value: 'mem', label: Text(l.processesByMemory))],
              selected: {_sort},
              onSelectionChanged: (s) => setState(() => _sort = s.first),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                decoration: InputDecoration(hintText: l.homeSearch, prefixIcon: const Icon(LucideIcons.search, size: 18), isDense: true),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (shown.isEmpty)
            TCard(child: Text(l.commonNothingFound))
          else
            GroupedSection(children: [
              for (final p in shown.take(80))
                GroupedRow(
                  title: '${p['name']}',
                  subtitle: '${p['pid']} · ${p['user']} · ${p['command']}',
                  trailingText: _sort == 'cpu'
                      ? '%${(p['cpuPercent'] as num).toStringAsFixed(1)}'
                      : formatSize((p['rssBytes'] as num).toInt(), locale),
                  showChevron: false,
                  trailing: PopupMenuButton<String>(
                    tooltip: l.filesMore,
                    icon: Icon(LucideIcons.ellipsisVertical, size: 20, color: t.textSecondary),
                    onSelected: (s) => _signal(p, s),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'TERM', child: Text(l.processesTerminate)),
                      PopupMenuItem(value: 'KILL', child: Text(l.processesKill, style: TextStyle(color: t.danger))),
                    ],
                  ),
                ),
            ]),
        ];
      },
    );
  }
}

// ── Ports ───────────────────────────────────────────────────────────────────

final portsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, hostId) async {
  return withAgent(ref, hostId, (c) => c.get('/v1/ports'));
});

class PortsScreen extends ConsumerWidget {
  const PortsScreen({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    Future<void> share(int port, bool on) async {
      if (on && !await confirmDialog(context, message: l.portsShareConfirm(port), confirmLabel: l.portsShare)) return;
      try {
        final r = await agentCall(ref, host.id, on ? 'POST' : 'DELETE', '/v1/ports/$port/share');
        ref.invalidate(portsProvider(host.id));
        if (on && r is Map && r['url'] != null) await launchUrl(Uri.parse('${r['url']}'), mode: LaunchMode.externalApplication);
      } catch (e) {
        if (context.mounted) toast(context, agentErrorText(l, e));
      }
    }

    return _AsyncPage<Map<String, dynamic>>(
      title: '${l.toolsPorts} · ${host.name}',
      value: ref.watch(portsProvider(host.id)),
      onRetry: () => ref.invalidate(portsProvider(host.id)),
      builder: (j) {
        final ports = (j['ports'] as List).cast<Map>().where((p) => p['reserved'] != true).toList();
        return [
          Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 12), child: Text(l.portsExplain, style: TextStyle(color: t.textSecondary, fontSize: 13))),
          GroupedSection(children: [
            for (final p in ports)
              GroupedRow(
                title: ':${p['port']}${p['process'] == null ? '' : '  ${p['process']}'}',
                subtitle: p['shared'] == true
                    ? l.portsShared
                    : (p['localOnly'] == true ? l.portsLocalOnly(p['address'] as String) : l.portsOpen(p['address'] as String)),
                icon: p['shared'] == true ? LucideIcons.globe : (p['localOnly'] == true ? LucideIcons.lock : LucideIcons.plug),
                iconBackground: p['shared'] == true ? t.success : (p['localOnly'] == true ? const Color(0xFF8E8E93) : const Color(0xFF0A84FF)),
                external: p['url'] != null,
                showChevron: false,
                onTap: p['url'] != null
                    ? () => launchUrl(Uri.parse('${p['url']}'), mode: LaunchMode.externalApplication)
                    : (p['localOnly'] == true ? () => share(p['port'] as int, true) : null),
                trailing: p['shared'] == true
                    ? IconButton(tooltip: l.portsUnshare, icon: Icon(LucideIcons.x, color: t.danger), onPressed: () => share(p['port'] as int, false))
                    : (p['localOnly'] == true
                        ? TextButton(onPressed: () => share(p['port'] as int, true), child: Text(l.portsShare))
                        : null),
              ),
          ]),
        ];
      },
    );
  }
}

// ── Clipboard ───────────────────────────────────────────────────────────────

class ClipboardScreen extends ConsumerStatefulWidget {
  const ClipboardScreen({super.key, required this.host});
  final Host host;
  @override
  ConsumerState<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends ConsumerState<ClipboardScreen> {
  final _text = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _pull();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pull() => _run(() async {
        final j = await agentCall(ref, widget.host.id, 'GET', '/v1/desktop/clipboard') as Map;
        _text.text = '${j['text'] ?? ''}';
      });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SettingsPage(
      title: '${l.toolsClipboard} · ${widget.host.name}',
      children: [
        if (_error != null) TCard(child: Text(agentErrorText(l, _error!), style: TextStyle(color: context.tokens.danger))),
        if (_error != null) const SizedBox(height: 10),
        TField(controller: _text, label: l.clipboardPcContent, mono: true, maxLines: 12),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _busy ? null : _pull,
            icon: const Icon(LucideIcons.download, size: 18),
            label: Text(l.clipboardFromPc),
          ),
          FilledButton.tonalIcon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      await agentCall(ref, widget.host.id, 'PUT', '/v1/desktop/clipboard', {'text': _text.text});
                      if (!mounted) return;
                      toast(this.context, l.clipboardSent);
                    }),
            icon: const Icon(LucideIcons.upload, size: 18),
            label: Text(l.clipboardToPc),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _text.text));
              if (context.mounted) toast(context, l.clipboardCopiedPhone);
            },
            icon: const Icon(LucideIcons.copy, size: 18),
            label: Text(l.clipboardCopyPhone),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await Clipboard.getData(Clipboard.kTextPlain);
              if (d?.text != null) _text.text = d!.text!;
            },
            icon: const Icon(LucideIcons.clipboardPaste, size: 18),
            label: Text(l.clipboardPastePhone),
          ),
        ]),
      ],
    );
  }
}

// ── Screenshot ──────────────────────────────────────────────────────────────

class ScreenshotScreen extends ConsumerStatefulWidget {
  const ScreenshotScreen({super.key, required this.host});
  final Host host;
  @override
  ConsumerState<ScreenshotScreen> createState() => _ScreenshotScreenState();
}

class _ScreenshotScreenState extends ConsumerState<ScreenshotScreen> {
  Uint8List? _png;
  DateTime? _at;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _take();
  }

  Future<void> _take() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final host = ref.read(profileProvider).host(widget.host.id)!;
      final c = await ref.read(agentClientFactoryProvider)(host);
      try {
        final bytes = await c.requestBytes('/v1/desktop/screenshot', query: {'scale': '0.6'});
        setState(() {
          _png = bytes;
          _at = DateTime.now();
        });
      } finally {
        c.close();
      }
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.toolsScreenshot),
        actions: [
          if (_png != null)
            IconButton(
              tooltip: l.filesDownload,
              icon: const Icon(LucideIcons.share2),
              onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile.fromData(_png!, mimeType: 'image/png', name: 'ekran.png')])),
            ),
          IconButton(tooltip: l.toolsScreenshotRetake, icon: const Icon(LucideIcons.camera), onPressed: _busy ? null : _take),
        ],
      ),
      body: Column(children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(agentErrorText(l, _error!), textAlign: TextAlign.center)))
              : _png == null
                  ? const SizedBox.shrink()
                  : InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(_png!, gaplessPlayback: true))),
        ),
        if (_at != null)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(DateFormat.Hms(Localizations.localeOf(context).toLanguageTag()).format(_at!), style: TextStyle(color: t.textSecondary, fontSize: 12)),
          ),
      ]),
    );
  }
}

// ── Action log ──────────────────────────────────────────────────────────────

final auditProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, hostId) async {
  final j = await withAgent(ref, hostId, (c) => c.get('/v1/audit', query: {'limit': '300'}));
  return (j['entries'] as List).cast<Map<String, dynamic>>();
});

class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final fmt = DateFormat('d MMM HH:mm:ss', locale);
    return _AsyncPage<List<Map<String, dynamic>>>(
      title: '${l.toolsAudit} · ${host.name}',
      value: ref.watch(auditProvider(host.id)),
      onRetry: () => ref.invalidate(auditProvider(host.id)),
      builder: (list) => [
        if (list.isEmpty)
          TCard(child: Text(l.auditEmpty))
        else
          GroupedSection(children: [
            for (final e in list)
              GroupedRow(
                title: '${e['method']} ${e['path']}',
                subtitle: '${fmt.format(DateTime.parse('${e['at']}').toLocal())} · ${e['device'] ?? '—'}',
                trailingText: '${e['status']}',
                icon: (e['status'] as int) < 400 ? LucideIcons.check : LucideIcons.x,
                iconBackground: (e['status'] as int) < 400 ? t.success : t.danger,
                showChevron: false,
              ),
          ]),
      ],
    );
  }
}
