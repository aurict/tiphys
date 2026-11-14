// Claude sohbet ekranı: canlı akış, araç kartları, diff, izin kartları, slash komutları, durdurma,
// fotoğraf ekleme, sesli mesaj, maliyet ve bağlam doluluğu.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'attachments.dart';
import 'chat_markdown.dart';
import 'claude_controller.dart';
import 'claude_screen.dart';

/// Testlerde false yapılır (WebSocket açılmaz).
final claudeStreamEnabledProvider = Provider<bool>((ref) => true);

class ClaudeChatScreen extends ConsumerStatefulWidget {
  const ClaudeChatScreen({super.key, this.sessionId, this.historyId, this.historyCwd, this.inTerminal = false});
  final String? sessionId;
  final String? historyId;
  final String? historyCwd;

  /// Oturum PC'de terminalde hâlâ açık: yalnız okunur, buradan devam ettirilmez (iki yazar oturumu bozar).
  final bool inTerminal;
  @override
  ConsumerState<ClaudeChatScreen> createState() => _ClaudeChatScreenState();
}

class _ClaudeChatScreenState extends ConsumerState<ClaudeChatScreen> {
  ClaudeSessionController? _c;
  Object? _error;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map>? _commands;
  bool _sending = false;
  final List<ImageAttachment> _images = [];
  final _voice = VoiceRecorder();
  bool _transcribing = false;

  /// Yazıya çevirme başlangıcı ve tahmini süresi (sunucudaki Scriberr CPU'da ≈ ses süresinin 3 katı).
  DateTime? _transcribeStart;
  Duration _transcribeEstimate = Duration.zero;

  /// İptal edilen çevirinin sonucu sonradan gelirse yok sayılsın diye her çeviriye bir numara.
  int _transcribeRun = 0;

  void _cancelTranscribe() => setState(() {
        _transcribeRun++;
        _transcribing = false;
      });

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final host = ref.read(claudeHostProvider);
    if (host == null) return;
    try {
      final client = await ref.read(agentClientFactoryProvider)(host);
      List<ClaudeEvent>? history;
      if (widget.historyId != null) {
        final j = await client.get('/v1/claude/history/${widget.historyId}');
        history = [for (final e in (j['events'] as List)) ClaudeEvent(Map<String, dynamic>.from(e as Map))];
      }
      final c = ClaudeSessionController(
        client: client,
        sessionId: widget.sessionId ?? widget.historyId!,
        readOnlyEvents: history,
        stream: ref.read(claudeStreamEnabledProvider),
      );
      if (!mounted) {
        c.dispose(); // açılış bitmeden ekrandan çıkıldı
        return;
      }
      c.addListener(_onUpdate);
      setState(() => _c = c);
      await c.start();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool _takingOver = false;

  /// Terminaldeki oturumu telefona al: ajan terminaldeki Claude'u kapatır, aynı oturumu burada sürdürür.
  Future<void> _takeover() async {
    final l = AppLocalizations.of(context);
    final id = widget.historyId!;
    if (!await confirmDialog(context, message: l.claudeTakeoverConfirm(id), confirmLabel: l.claudeTakeover)) return;
    final host = ref.read(claudeHostProvider);
    if (host == null || !mounted) return;
    final c = ref.read(profileProvider).claude;
    setState(() => _takingOver = true);
    try {
      final res = await agentCall(ref, host.id, 'POST', '/v1/claude/terminal/$id/takeover', {
        'confirm': true,
        'permissionMode': c.permissionMode,
        'effort': c.effort,
        if (c.model.isNotEmpty) 'model': c.model,
        'profileId': c.profileId,
      }) as Map;
      if (!mounted) return;
      ref.invalidate(claudeSessionsProvider);
      context.pushReplacement('/claude/session/${res['id']}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _takingOver = false);
      toast(context, agentErrorText(l, e));
    }
  }

  /// Terminaldeki oturum ilerledikçe kaydı yeniden okur.
  Future<void> _reload() async {
    _c?.removeListener(_onUpdate);
    _c?.dispose();
    setState(() {
      _c = null;
      _error = null;
    });
    await _open();
  }

  void _onUpdate() {
    if (!mounted) return;
    // Liste ters (en yeni altta, konum 0 = en alt): yeni içerik kendiliğinden görünür kalır.
    setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_onUpdate);
    _c?.dispose();
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final c = _c;
    if ((text.isEmpty && _images.isEmpty) || c == null) return;
    setState(() => _sending = true);
    try {
      await c.send(text, images: [for (final i in _images) i.toJson()]);
      _input.clear();
      _images.clear();
      // Yukarıda eski mesajları okurken gönderildiyse en alta dön.
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(AppLocalizations.of(context), e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final l = AppLocalizations.of(context);
    try {
      final picked = await pickImages();
      if (picked.isNotEmpty && mounted) setState(() => _images.addAll(picked.take(5 - _images.length)));
    } catch (e) {
      if (mounted) toast(context, '${l.commonError}: $e');
    }
  }

  /// Mikrofon: ilk dokunuş kaydı başlatır, ikincisi bitirip yazıya çevirir; metin kutuya eklenir.
  Future<void> _mic() async {
    final l = AppLocalizations.of(context);
    if (!_voice.recording) {
      try {
        if (!await _voice.start() && mounted) toast(context, l.voiceNoPermission);
      } catch (e) {
        if (mounted) toast(context, '${l.commonError}: $e');
      }
      setState(() {});
      return;
    }
    final host = ref.read(claudeHostProvider);
    // Ayarlar › Entegrasyonlar › Scriberr: dil (tr/en/otomatik) ve model. Ayar yoksa arayüz dili.
    final stt = ref.read(profileProvider).integrations.scriberr;
    final lang = stt?.language ?? Localizations.localeOf(context).languageCode;
    final recorded = _voice.elapsed;
    final run = ++_transcribeRun;
    setState(() {
      _transcribing = true;
      _transcribeStart = DateTime.now();
      _transcribeEstimate = Duration(seconds: (recorded.inMilliseconds * 3.3 / 1000).round() + 4);
    });
    try {
      final audio = await _voice.stop();
      if (audio == null || host == null) return;
      final c = await ref.read(agentClientFactoryProvider)(host);
      try {
        final j = await c.request('POST', '/v1/transcribe',
            body: {
              'data': base64Encode(audio),
              'ext': 'm4a',
              if (lang == 'tr' || lang == 'en') 'language': lang,
              if (stt != null) 'model': stt.model,
            },
            timeout: const Duration(minutes: 10)) as Map;
        if (run != _transcribeRun) return; // kullanıcı iptal etti
        final text = '${j['text'] ?? ''}'.trim();
        if (text.isEmpty) {
          if (mounted) toast(context, l.voiceEmpty);
        } else {
          final cur = _input.text.trimRight();
          _input.text = cur.isEmpty ? text : '$cur $text';
          _input.selection = TextSelection.collapsed(offset: _input.text.length);
        }
      } finally {
        c.close();
      }
    } catch (e) {
      if (mounted && run == _transcribeRun) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted && run == _transcribeRun) setState(() => _transcribing = false);
    }
  }

  Future<void> _slash() async {
    final l = AppLocalizations.of(context);
    final host = ref.read(claudeHostProvider);
    final c = _c;
    if (host == null || c == null) return;
    final pinned = ref.read(profileProvider).claude.pinnedCommands;
    if (_commands == null) {
      try {
        final cwd = c.summary?['cwd'] as String? ?? '~';
        final j = await agentCall(ref, host.id, 'GET', '/v1/claude/commands?cwd=${Uri.encodeQueryComponent(cwd)}') as Map;
        _commands = (j['commands'] as List).cast<Map>();
      } catch (e) {
        if (mounted) toast(context, agentErrorText(l, e));
        return;
      }
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      useRootNavigator: true, // alt sekme barının üstünde açılsın; yoksa bar sayfanın altını örter
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _CommandSheet(commands: _commands!, pinned: pinned),
    );
    if (picked != null) {
      _input.text = '/$picked ';
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = _c;
    final summaryTitle = c?.summary?['title'] as String?;
    final title = summaryTitle == null ? (widget.inTerminal ? l.claudeTerminalSessions : (widget.historyId != null ? l.claudeHistory : 'Claude')) : (summaryTitle.isEmpty ? l.claudeUntitled : summaryTitle);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
              child: Row(children: [
                IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(LucideIcons.chevronLeft),
                  onPressed: () => context.canPop() ? context.pop() : context.go('/claude'),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                    if (c != null)
                      Row(children: [
                        StatusDot(color: c.connected || !c.isLive ? (c.busy ? t.accent : t.success) : t.warning, size: 7),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            c.isLive ? '${claudeStatusText(l, c.status)}${c.summary == null ? '' : ' · ${c.summary!['model']}'}' : l.claudeHistory,
                            style: Theme.of(context).textTheme.labelSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (c.isLive && c.summary != null) _UsageChip(summary: c.summary!),
                      ]),
                  ]),
                ),
                if (c != null && c.isLive)
                  PopupMenuButton<String>(
                    tooltip: l.filesMore,
                    icon: const Icon(LucideIcons.ellipsisVertical),
                    onSelected: (v) async {
                      try {
                        if (v == 'close') {
                          await c.close();
                          if (context.mounted) context.pop();
                        } else {
                          await c.setMode(v);
                          if (context.mounted) toast(context, l.systemDone);
                        }
                      } catch (e) {
                        if (context.mounted) toast(context, agentErrorText(l, e));
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'acceptEdits', child: Text(l.claudeModeAcceptShort)),
                      PopupMenuItem(value: 'default', child: Text(l.claudeModeDefaultShort)),
                      PopupMenuItem(value: 'plan', child: Text(l.claudeModePlan)),
                      PopupMenuItem(value: 'close', child: Text(l.claudeEndSession)),
                    ],
                  ),
              ]),
            ),
          ),
          if (c != null && c.isLive && (c.gone || (!c.connected && c.error != null)))
            _ConnectionBanner(text: c.gone ? l.claudeSessionGone : l.claudeReconnecting, danger: c.gone),
          Expanded(
            child: _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(agentErrorText(l, _error!))))
                : c == null
                    ? const Center(child: CircularProgressIndicator())
                    : _Messages(controller: c, scroll: _scroll),
          ),
          if (c != null && !c.isLive && widget.inTerminal)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TCard(
                    child: Row(children: [
                      Icon(LucideIcons.squareTerminal, color: context.tokens.warning),
                      const SizedBox(width: 10),
                      Expanded(child: Text(l.claudeInTerminalNote, style: const TextStyle(fontSize: 13))),
                      IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: _reload),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _takingOver ? null : _takeover,
                    icon: _takingOver
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(LucideIcons.smartphone),
                    label: Text(l.claudeTakeover),
                  ),
                ]),
              ),
            ),
          if (c != null && !c.isLive && !widget.inTerminal)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: () => showNewSession(context, ref, cwd: widget.historyCwd, resume: widget.historyId),
                  icon: const Icon(LucideIcons.play),
                  label: Text(l.claudeContinue),
                ),
              ),
            ),
          if (c != null && c.isLive)
            _Composer(
              controller: c,
              input: _input,
              sending: _sending,
              onSend: _send,
              onSlash: _slash,
              onAttach: _attach,
              onMic: _transcribing ? null : _mic,
              voice: _voice,
              transcribing: _transcribing,
              transcribeStart: _transcribeStart,
              transcribeEstimate: _transcribeEstimate,
              onCancelTranscribe: _cancelTranscribe,
              images: _images,
              onRemoveImage: (i) => setState(() => _images.removeAt(i)),
            ),
        ]),
      ),
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.controller, required this.scroll});
  final ClaudeSessionController controller;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final results = {for (final e in c.events.where((e) => e.kind == 'tool_result')) e.get<String>('toolUseId'): e};
    final resolved = {for (final e in c.events.where((e) => e.kind == 'permissionResolved')) e.get<String>('requestId'): e.get<bool>('allow') ?? false};
    final items = <Widget>[];
    for (final e in c.events) {
      switch (e.kind) {
        case 'user':
          items.add(_UserBubble(text: e.text, images: e.get<int>('images') ?? 0));
        case 'text':
          items.add(_AssistantText(text: e.text));
        case 'thinking':
          items.add(_Thinking(text: e.text));
        case 'tool_use':
          items.add(_ToolCard(event: e, result: results[e.get<String>('id')]));
        case 'permission':
          items.add(_PermissionCard(event: e, controller: c, decided: resolved[e.get<String>('requestId')]));
        case 'result':
          items.add(_ResultLine(event: e));
        case 'error':
          items.add(_ErrorLine(text: e.get<String>('message') ?? ''));
        case 'restored':
          items.add(_NoticeLine(text: AppLocalizations.of(context).claudeRestored));
        case 'compacted':
          items.add(_NoticeLine(text: AppLocalizations.of(context).claudeCompacted));
      }
    }
    if (c.live.isNotEmpty) items.add(_AssistantText(text: c.live, streaming: true));
    if (c.busy && c.live.isEmpty) items.add(const _Typing());
    // Ters liste: açılışta (geçmiş ya da devam edilen oturum) en son mesajdan başlar, yalnız görünenler çizilir.
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
  const _UserBubble({required this.text, required this.images});
  final String text;
  final int images;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 4, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: t.claudeTile, borderRadius: BorderRadius.circular(18), border: t.isDark ? Border.all(color: t.claudeTileBorder) : null),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SelectableText(text, style: TextStyle(color: t.claudeTileText, fontSize: 15, height: 1.35)),
          if (images > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Icon(LucideIcons.image, size: 14, color: t.claudeTileSubtext)),
        ]),
      ),
    );
  }
}

/// Basit biçim: ``` kod blokları monospace kutuda, gerisi seçilebilir metin.
class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.text, this.streaming = false});
  final String text;
  final bool streaming;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4, right: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ChatMarkdown(text),
        if (streaming) Padding(padding: const EdgeInsets.only(top: 2), child: Container(width: 8, height: 14, color: t.accent)),
      ]),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(LucideIcons.brain, size: 16, color: t.textSecondary),
        title: Text(l.claudeThinking, style: Theme.of(context).textTheme.labelMedium),
        children: [SelectableText(text, style: TextStyle(fontSize: 13, color: t.textSecondary, fontStyle: FontStyle.italic))],
      ),
    );
  }
}

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.event, required this.result});
  final ClaudeEvent event;
  final ClaudeEvent? result;
  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = widget.event.get<String>('name') ?? '?';
    final input = Map<String, dynamic>.from((widget.event.get<Map>('input')) ?? {});
    final diff = toolDiff(name, input);
    final res = widget.result;
    final isError = res?.get<bool>('isError') ?? false;
    final icon = switch (name) {
      'Bash' => LucideIcons.terminal,
      'Read' => LucideIcons.fileText,
      'Write' || 'Edit' || 'MultiEdit' => LucideIcons.filePen,
      'Glob' || 'Grep' => LucideIcons.search,
      'WebFetch' || 'WebSearch' => LucideIcons.globe,
      'Agent' || 'Task' => LucideIcons.bot,
      'TodoWrite' => LucideIcons.listChecks,
      _ => LucideIcons.wrench,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TCard(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        onTap: () => setState(() => _open = !_open),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: isError ? t.danger : t.accent),
            const SizedBox(width: 8),
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(toolSummary(name, input),
                  maxLines: _open ? 6 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: t.textSecondary)),
            ),
            if (res == null)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
            else
              Icon(isError ? LucideIcons.x : LucideIcons.check, size: 15, color: isError ? t.danger : t.success),
          ]),
          if (diff.isNotEmpty && (_open || diff.length <= 12)) ...[
            const SizedBox(height: 8),
            _Diff(lines: _open ? diff : diff.take(12).toList()),
          ],
          if (_open && res != null && res.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(
                res.text.length > 4000 ? '${res.text.substring(0, 4000)}…' : res.text,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: isError ? t.danger : t.text),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Diff extends StatelessWidget {
  const _Diff({required this.lines});
  final List<(String, String)> lines;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final add = t.isDark ? const Color(0x3330D158) : const Color(0xFFDCFCE7);
    final del = t.isDark ? const Color(0x33FF6961) : const Color(0xFFFEE2E2);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (sign, text) in lines)
          Container(
            color: sign == '+' ? add : (sign == '-' ? del : Colors.transparent),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Text('$sign $text', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: t.text)),
          ),
      ]),
    );
  }
}

class _PermissionCard extends StatefulWidget {
  const _PermissionCard({required this.event, required this.controller, required this.decided});
  final ClaudeEvent event;
  final ClaudeSessionController controller;
  final bool? decided;
  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _busy = false;

  Future<void> _decide(bool allow) async {
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    try {
      await widget.controller.decide(widget.event.get<String>('requestId')!, allow);
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
    final tool = widget.event.get<String>('toolName') ?? '?';
    final input = Map<String, dynamic>.from(widget.event.get<Map>('input') ?? {});
    final reason = widget.event.get<String>('reason');
    final decided = widget.decided;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        liveRegion: decided == null,
        child: TCard(
          radius: 18,
          borderColor: t.warning,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.shieldQuestion, color: t.warning, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(l.claudePermissionTitle(tool), style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 6),
            Text(toolSummary(tool, input), style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
            if (toolDiff(tool, input).isNotEmpty) ...[const SizedBox(height: 6), _Diff(lines: toolDiff(tool, input).take(20).toList())],
            if (reason != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(reason, style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(height: 10),
            if (decided == null)
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _decide(false),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48), foregroundColor: t.danger),
                    child: Text(l.claudeDeny),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: FilledButton(onPressed: _busy ? null : () => _decide(true), child: Text(l.claudeAllow))),
              ])
            else
              Text(decided ? l.claudeAllowed : l.claudeDenied, style: TextStyle(color: decided ? t.success : t.danger, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Bağlantı koptuğunda / oturum ajanda yoksa üstte ince şerit.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.text, this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = danger ? t.danger : t.warning;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        if (!danger) ...[SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color)), const SizedBox(width: 8)],
        Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color))),
      ]),
    );
  }
}

/// Sohbet içinde ince ayraç + kısa bilgi (ajan yeniden başladı, önceki kısım özetlendi).
class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Divider(color: t.separator)),
        Flexible(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.textSecondary)),
          ),
        ),
        Expanded(child: Divider(color: t.separator)),
      ]),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.event});
  final ClaudeEvent event;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final ok = event.get<bool>('ok') ?? false;
    final cost = (event.get<num>('costUsd') ?? 0).toDouble();
    final secs = ((event.get<num>('durationMs') ?? 0) / 1000).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Divider(color: t.separator)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${ok ? '✓' : '✕'}  ${l.claudeResultLine(event.get<int>('turns') ?? 0, secs)} · \$${cost.toStringAsFixed(2)}',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ok ? t.textSecondary : t.danger),
          ),
        ),
        Expanded(child: Divider(color: t.separator)),
      ]),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: TextStyle(color: context.tokens.danger, fontSize: 13)),
      );
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: context.tokens.accent)),
          const SizedBox(width: 10),
          Text(AppLocalizations.of(context).claudeWorking, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

/// Başlıktaki maliyet ve bağlam doluluğu (ör. "$0,42 · %38").
class _UsageChip extends StatelessWidget {
  const _UsageChip({required this.summary});
  final Map<String, dynamic> summary;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);
    final cost = (summary['costUsd'] as num?)?.toDouble() ?? 0;
    final used = (summary['contextTokens'] as num?)?.toDouble();
    final window = (summary['contextWindow'] as num?)?.toDouble();
    final pct = used != null && window != null && window > 0 ? (used / window).clamp(0, 1) : null;
    final color = pct == null ? t.textSecondary : (pct > 0.85 ? t.danger : (pct > 0.6 ? t.warning : t.textSecondary));
    final parts = [
      if (cost > 0) '\$${NumberFormat('0.00', Localizations.localeOf(context).toLanguageTag()).format(cost)}',
      if (pct != null) '%${(pct * 100).round()}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: l.claudeUsageSemantics(parts.join(', ')),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Text(' · ${parts.join(' · ')}', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.input,
    required this.sending,
    required this.onSend,
    required this.onSlash,
    required this.onAttach,
    required this.onMic,
    required this.voice,
    required this.transcribing,
    required this.transcribeStart,
    required this.transcribeEstimate,
    required this.onCancelTranscribe,
    required this.images,
    required this.onRemoveImage,
  });
  final ClaudeSessionController controller;
  final TextEditingController input;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onSlash;
  final VoidCallback onAttach;
  final VoidCallback? onMic;
  final VoiceRecorder voice;
  final bool transcribing;
  final DateTime? transcribeStart;
  final Duration transcribeEstimate;
  final VoidCallback onCancelTranscribe;
  final List<ImageAttachment> images;
  final void Function(int) onRemoveImage;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final busy = controller.busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: TCard(
          radius: 24,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
           if (images.isNotEmpty)
            SizedBox(
              height: 68,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(6, 6, 6, 2), children: [
                for (var i = 0; i < images.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(clipBehavior: Clip.none, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(images[i].bytes, width: 60, height: 60, fit: BoxFit.cover, semanticLabel: images[i].name),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: Semantics(
                          button: true,
                          label: l.claudeRemoveImage,
                          child: GestureDetector(
                            onTap: () => onRemoveImage(i),
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(color: t.text, shape: BoxShape.circle),
                              child: Icon(LucideIcons.x, size: 14, color: t.background),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
              ]),
            ),
           if (voice.recording || transcribing)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Row(children: [
                if (voice.recording) ...[
                  StatusDot(color: t.danger, size: 9),
                  const SizedBox(width: 8),
                  Text(l.voiceRecording(_mmss(voice.elapsed)), style: TextStyle(color: t.danger, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(onPressed: voice.cancel, child: Text(l.commonCancel)),
                ] else ...[
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: _TranscribeProgress(start: transcribeStart ?? DateTime.now(), estimate: transcribeEstimate)),
                  TextButton(onPressed: onCancelTranscribe, child: Text(l.commonCancel)),
                ],
              ]),
            ),
           Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(tooltip: l.claudeSlashCommands, icon: Icon(LucideIcons.slash, color: t.accent), onPressed: onSlash),
            IconButton(tooltip: l.claudeAttachImage, icon: Icon(LucideIcons.imagePlus, color: t.textSecondary), onPressed: images.length >= 5 ? null : onAttach),
            Expanded(
              child: TextField(
                controller: input,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                onChanged: (v) {
                  if (v == '/') onSlash();
                },
                decoration: InputDecoration(
                  hintText: busy ? l.claudeQueueHint : l.claudePromptHint,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
              ),
            ),
            if (busy)
              IconButton(
                tooltip: l.claudeStop,
                icon: Icon(LucideIcons.square, color: t.danger),
                onPressed: () async {
                  try {
                    await controller.interrupt();
                  } catch (e) {
                    if (context.mounted) toast(context, agentErrorText(l, e));
                  }
                },
              ),
            IconButton(
              tooltip: voice.recording ? l.voiceStop : l.voiceRecord,
              icon: Icon(voice.recording ? LucideIcons.circleStop : LucideIcons.mic, color: voice.recording ? t.danger : t.textSecondary),
              onPressed: onMic,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Semantics(
                button: true,
                label: l.claudeSend,
                child: Material(
                  color: t.isDark ? t.tabActive : const Color(0xFF111114),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: sending ? null : onSend,
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
           ]),
          ]),
        ),
      ),
    );
  }
}

String _mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class _CommandSheet extends StatefulWidget {
  const _CommandSheet({required this.commands, required this.pinned});
  final List<Map> commands;
  final List<String> pinned;
  @override
  State<_CommandSheet> createState() => _CommandSheetState();
}

class _CommandSheetState extends State<_CommandSheet> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pinned = widget.pinned.map((p) => p.replaceFirst('/', '')).toSet();
    final list = widget.commands.where((c) => _q.isEmpty || '${c['name']} ${c['description']}'.toLowerCase().contains(_q)).toList()
      ..sort((a, b) => (pinned.contains(a['name']) ? 0 : 1).compareTo(pinned.contains(b['name']) ? 0 : 1));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (c, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: InputDecoration(hintText: l.claudeSlashCommands, prefixIcon: const Icon(LucideIcons.search, size: 18)),
            onChanged: (v) => setState(() => _q = v.toLowerCase().replaceFirst('/', '')),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: list.length,
            itemBuilder: (_, i) {
              final cmd = list[i];
              return ListTile(
                leading: pinned.contains(cmd['name']) ? const Icon(LucideIcons.pin, size: 18) : null,
                title: Text('/${cmd['name']}', style: const TextStyle(fontFamily: 'JetBrainsMono', fontWeight: FontWeight.w700)),
                subtitle: Text('${cmd['description']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, '${cmd['name']}'),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// "Yazıya çevriliyor · 12 sn / ~35 sn": yalnız bu metin saniyede bir yenilenir (sohbet yeniden çizilmez).
class _TranscribeProgress extends StatefulWidget {
  const _TranscribeProgress({required this.start, required this.estimate});
  final DateTime start;
  final Duration estimate;
  @override
  State<_TranscribeProgress> createState() => _TranscribeProgressState();
}

class _TranscribeProgressState extends State<_TranscribeProgress> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final secs = DateTime.now().difference(widget.start).inSeconds;
    return Text(l.voiceTranscribingProgress(secs, widget.estimate.inSeconds), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

