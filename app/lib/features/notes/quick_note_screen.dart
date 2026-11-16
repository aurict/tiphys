// Quick note: text (or voice input: agent on the PC → Scriberr) → "Save to Obsidian". The note is written via a link
// to the Obsidian app (see obsidian.dart). Redirects to settings if the vault isn't configured.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/attachments.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import '../system/agent_providers.dart';
import 'obsidian.dart';

class QuickNoteScreen extends ConsumerStatefulWidget {
  const QuickNoteScreen({super.key, this.args = const QuickNoteArgs()});
  final QuickNoteArgs args;
  @override
  ConsumerState<QuickNoteScreen> createState() => _QuickNoteScreenState();
}

class _QuickNoteScreenState extends ConsumerState<QuickNoteScreen> {
  late final _text = TextEditingController(text: widget.args.text);
  late final _title = TextEditingController(text: widget.args.title ?? '');
  final _voice = VoiceRecorder();
  bool? _daily;
  bool _transcribing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    _title.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    _voice.dispose();
    super.dispose();
  }

  /// The first tap starts recording, the second stops it and transcribes; the text is appended.
  Future<void> _mic() async {
    final l = AppLocalizations.of(context);
    if (!_voice.recording) {
      try {
        if (!await _voice.start() && mounted) toast(context, l.voiceNoPermission);
      } catch (e) {
        if (mounted) toast(context, '${l.commonError}: $e');
      }
      if (mounted) setState(() {});
      return;
    }
    final host = ref.read(claudeHostProvider);
    final stt = ref.read(profileProvider).integrations.scriberr;
    final lang = stt?.language ?? Localizations.localeOf(context).languageCode;
    setState(() => _transcribing = true);
    try {
      final audio = await _voice.stop();
      if (audio == null) return;
      if (host == null) {
        if (mounted) toast(context, l.hostAgentNone);
        return;
      }
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
        final text = '${j['text'] ?? ''}'.trim();
        if (!mounted) return;
        if (text.isEmpty) {
          toast(context, l.voiceEmpty);
        } else {
          final cur = _text.text.trimRight();
          _text.text = cur.isEmpty ? text : '$cur\n$text';
        }
      } finally {
        c.close();
      }
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final cfg = ref.read(profileProvider).integrations.obsidian;
    final text = _text.text.trim();
    if (cfg == null || text.isEmpty) return;
    if (text.length > obsidianMaxChars) {
      setState(() => _error = l.noteTooLong(obsidianMaxChars));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final uri = obsidianUri(cfg, text: text, now: ref.read(clockProvider)(), title: _title.text, daily: _daily);
    final ok = await ref.read(obsidianLauncherProvider)(uri);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      setState(() => _error = l.noteObsidianMissing);
      return;
    }
    toast(context, l.noteSent);
    context.canPop() ? context.pop() : context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final cfg = ref.watch(profileProvider.select((p) => p.integrations.obsidian));
    final daily = _daily ?? cfg?.mode == 'dailyNote';
    final now = ref.watch(clockProvider)();
    final target = cfg == null ? null : obsidianNotePath(cfg, text: _text.text, now: now, title: _title.text, daily: daily);
    final busy = _saving || _transcribing;
    return SettingsPage(
      title: l.noteTitle,
      children: [
        if (cfg == null)
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(LucideIcons.notebookPen, color: t.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(l.noteSetupTitle, style: Theme.of(context).textTheme.titleMedium)),
              ]),
              const SizedBox(height: 6),
              Text(l.noteSetupBody, style: TextStyle(color: t.textSecondary, fontSize: 13)),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/settings/integrations/obsidian'),
                icon: const Icon(LucideIcons.settings, size: 18),
                label: Text(l.noteSetupAction),
              ),
            ]),
          )
        else ...[
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(l.noteModeNew), icon: const Icon(LucideIcons.filePlus, size: 16)),
              ButtonSegment(value: true, label: Text(l.noteModeDaily), icon: const Icon(LucideIcons.calendarDays, size: 16)),
            ],
            selected: {daily},
            onSelectionChanged: (s) => setState(() => _daily = s.first),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Semantics(
              liveRegion: true,
              child: Text(l.noteTarget(cfg.vault, '$target.md'), style: TextStyle(color: t.textSecondary, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        const SizedBox(height: 12),
        FieldCard(children: [
          if (!daily) TField(controller: _title, label: l.noteTitleField, hint: noteTitle(_text.text, now), helper: l.noteTitleHelper),
          TextField(
            controller: _text,
            autofocus: widget.args.text.isEmpty,
            minLines: 6,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l.noteText, alignLabelWithHint: true),
          ),
        ]),
        const SizedBox(height: 12),
        if (_voice.recording || _transcribing)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Semantics(
              liveRegion: true,
              child: Row(children: [
                if (_voice.recording) StatusDot(color: t.danger, size: 9) else const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: ListenableBuilder(
                    listenable: _voice,
                    builder: (_, _) => Text(
                      _voice.recording ? l.voiceRecording('${_voice.elapsed.inMinutes}:${(_voice.elapsed.inSeconds % 60).toString().padLeft(2, '0')}') : l.voiceTranscribing,
                      style: TextStyle(color: _voice.recording ? t.danger : t.textSecondary, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                if (_voice.recording)
                  TextButton(
                    onPressed: () async {
                      await _voice.cancel();
                      if (mounted) setState(() {});
                    },
                    child: Text(l.commonCancel),
                  ),
              ]),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TCard(
              child: Semantics(
                liveRegion: true,
                child: Row(children: [
                  Icon(LucideIcons.circleAlert, color: t.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!)),
                ]),
              ),
            ),
          ),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _transcribing ? null : _mic,
            icon: Icon(_voice.recording ? LucideIcons.circleStop : LucideIcons.mic, size: 18, color: _voice.recording ? t.danger : null),
            label: Text(_voice.recording ? l.voiceStop : l.noteVoice),
            style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: cfg == null || busy || _voice.recording || _text.text.trim().isEmpty ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(LucideIcons.notebookPen, size: 18),
              label: Text(l.noteSave),
              style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(l.noteExplain, style: TextStyle(color: t.textSecondary, fontSize: 12.5)),
        ),
      ],
    );
  }
}
