// Files and text shared to Tiphys from the Android "Share" menu: pick host + folder, sent via SFTP.
// Text shares can also be sent to the PC clipboard; if the text contains a link, "Open on PC" opens it in the
// PC's browser (if the agent's "desktop" feature is enabled).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/profile/model.dart';
import '../../core/ssh/connection.dart' show shellQuote;
import '../../core/ssh/remote_files.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../system/agent_providers.dart';
import '../system/open_on_pc.dart';
import 'files_screen.dart' show fileBrowsersProvider, formatSize;

/// Listens to the share stream; opens the "Send to PC" screen for incoming items.
class ShareIntake {
  StreamSubscription<List<SharedMediaFile>>? _sub;

  Future<void> start(void Function(List<SharedMediaFile>) open) async {
    if (!Platform.isAndroid) return;
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen((items) {
      if (items.isNotEmpty) open(items);
    }, onError: (_) {});
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) {
      open(initial);
      await ReceiveSharingIntent.instance.reset();
    }
  }

  void dispose() => _sub?.cancel();
}

bool _isText(SharedMediaFile f) => f.type == SharedMediaType.text || f.type == SharedMediaType.url;

class ShareToPcScreen extends ConsumerStatefulWidget {
  const ShareToPcScreen({super.key, required this.items});
  final List<SharedMediaFile> items;
  @override
  ConsumerState<ShareToPcScreen> createState() => _ShareToPcScreenState();
}

class _ShareToPcScreenState extends ConsumerState<ShareToPcScreen> {
  String? _hostId;
  final _dir = TextEditingController(text: '~/Downloads');
  double? _progress;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    _hostId = (p.host(p.claude.agentHostId)?.ssh != null ? p.claude.agentHostId : null) ?? p.hosts.where((h) => h.ssh != null).firstOrNull?.id;
  }

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l = AppLocalizations.of(context);
    final host = ref.read(profileProvider).host(_hostId);
    if (host == null) return;
    setState(() => _progress = 0);
    try {
      final f = await ref.read(fileBrowsersProvider.notifier).get(host);
      final dir = f.resolve(_dir.text.trim().isEmpty ? '~' : _dir.text.trim());
      await f.conn.exec('mkdir -p -- ${shellQuote(dir)}');
      final files = widget.items.where((x) => !_isText(x)).toList();
      final texts = widget.items.where(_isText).toList();
      var done = 0;
      for (final item in files) {
        final local = File(item.path);
        final name = item.path.split('/').last;
        await f.write(RemoteFiles.join(dir, name), await local.readAsBytes());
        setState(() => _progress = ++done / (files.length + texts.length));
      }
      if (texts.isNotEmpty) {
        final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
        final body = texts.map((t) => t.path).join('\n\n');
        await f.write(RemoteFiles.join(dir, 'paylasim-$stamp.txt'), Uint8List.fromList(utf8.encode(body)));
        done += texts.length;
      }
      if (!mounted) return;
      toast(context, l.shareSent(done, host.name));
      context.canPop() ? context.pop() : context.go('/files');
    } catch (e) {
      if (mounted) {
        setState(() => _progress = null);
        toast(context, '${l.commonError}: $e');
      }
    }
  }

  Future<void> _openOnPc(Host host, String url) async {
    setState(() => _progress = 0);
    final ok = await openOnPc(context, ref, host, url);
    if (!mounted) return;
    setState(() => _progress = null);
    if (ok) context.canPop() ? context.pop() : context.go('/');
  }

  Future<void> _toClipboard() async {
    final l = AppLocalizations.of(context);
    final text = widget.items.where(_isText).map((t) => t.path).join('\n');
    try {
      await agentCall(ref, _hostId!, 'PUT', '/v1/desktop/clipboard', {'text': text});
      if (!mounted) return;
      toast(context, l.clipboardSent);
      context.canPop() ? context.pop() : context.go('/');
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final p = ref.watch(profileProvider);
    final hosts = p.hosts.where((h) => h.ssh != null).toList();
    final locale = Localizations.localeOf(context).toLanguageTag();
    final onlyText = widget.items.every(_isText);
    final host = p.host(_hostId);
    // Link in the shared text: opened on the selected host if it has an agent, otherwise on the PC (Claude host).
    final url = findUrl(widget.items.where(_isText).map((t) => t.path).join('\n'));
    final pcHost = host?.agent != null ? host : ref.watch(claudeHostProvider);
    return SettingsPage(
      title: l.shareTitle,
      children: [
        GroupedSection(title: l.shareItems(widget.items.length), children: [
          for (final f in widget.items.take(20))
            GroupedRow(
              title: _isText(f) ? f.path.split('\n').first : f.path.split('/').last,
              subtitle: _isText(f) ? l.shareText : (File(f.path).existsSync() ? formatSize(File(f.path).lengthSync(), locale) : f.mimeType),
              icon: switch (f.type) {
                SharedMediaType.image => LucideIcons.image,
                SharedMediaType.video => LucideIcons.video,
                SharedMediaType.text || SharedMediaType.url => LucideIcons.text,
                _ => LucideIcons.file,
              },
              iconBackground: t.accent,
              showChevron: false,
            ),
        ]),
        if (url != null && pcHost != null) ...[
          const SizedBox(height: 12),
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(LucideIcons.link, size: 18, color: t.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5))),
              ]),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _progress != null ? null : () => _openOnPc(pcHost, url),
                icon: const Icon(LucideIcons.squareArrowOutUpRight, size: 18),
                label: Text(l.openOnPcOn(pcHost.name)),
              ),
            ]),
          ),
          const SizedBox(height: 12),
        ],
        if (hosts.isEmpty)
          TCard(child: Text(l.terminalNoSshHosts))
        else ...[
          ChoiceSection<String>(
            title: l.shareToHost,
            value: _hostId ?? hosts.first.id,
            options: [for (final h in hosts) (h.id, h.name)],
            onChanged: (v) => setState(() => _hostId = v),
          ),
          FieldCard(children: [TField(controller: _dir, label: l.shareFolder, mono: true)]),
          const SizedBox(height: 8),
          if (_progress != null) ...[LinearProgressIndicator(value: _progress), const SizedBox(height: 12)],
          FilledButton.icon(
            onPressed: _progress != null ? null : _send,
            icon: const Icon(LucideIcons.upload, size: 18),
            label: Text(l.shareSend),
          ),
          if (onlyText && host?.agent != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _progress != null ? null : _toClipboard,
              icon: const Icon(LucideIcons.clipboard, size: 18),
              label: Text(l.clipboardToPc),
            ),
          ],
        ],
      ],
    );
  }
}
