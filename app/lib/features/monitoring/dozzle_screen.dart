// Dozzle: container listesi ve canlı log akışı (duraklat, ara, seviye renkleri, JSON katlama).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/integrations/dozzle_client.dart';
import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
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

class DozzleScreen extends ConsumerStatefulWidget {
  const DozzleScreen({super.key});
  @override
  ConsumerState<DozzleScreen> createState() => _DozzleScreenState();
}

class _DozzleScreenState extends ConsumerState<DozzleScreen> {
  String? _id;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final list = ref.watch(profileProvider.select((p) => p.integrations.dozzle));
    final cfg = list.where((d) => d.id == _id).firstOrNull ?? list.firstOrNull;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return SettingsPage(title: cfg?.name ?? 'Dozzle', children: [
      if (cfg == null)
        TCard(child: Text(l.integrationNotSet))
      else ...[
        if (list.length > 1)
          Wrap(spacing: 8, children: [
            for (final d in list) ChoiceChip(label: Text(d.name), selected: d.id == cfg.id, onSelected: (_) => setState(() => _id = d.id)),
          ]),
        TextField(
          decoration: InputDecoration(hintText: l.homeSearch, prefixIcon: const Icon(LucideIcons.search, size: 18)),
          onChanged: (v) => setState(() => _q = v.toLowerCase()),
        ),
        const SizedBox(height: 10),
        ref.watch(dozzleContainersProvider(cfg.id)).when(
              loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
              data: (cs) {
                final f = cs.where((c) => _q.isEmpty || '${c.name} ${c.image} ${c.project}'.toLowerCase().contains(_q)).toList();
                return GroupedSection(children: [
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
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DozzleLogsScreen(config: cfg, container: c))),
                    ),
                ]);
              },
            ),
      ],
    ]);
  }
}

class DozzleLogsScreen extends ConsumerStatefulWidget {
  const DozzleLogsScreen({super.key, required this.config, required this.container});
  final DozzleConfig config;
  final DozzleContainer container;
  @override
  ConsumerState<DozzleLogsScreen> createState() => _DozzleLogsState();
}

class _DozzleLogsState extends ConsumerState<DozzleLogsScreen> {
  DozzleClient? _c;
  final _logs = <DozzleLog>[];
  StreamSubscription<DozzleLog>? _sub;
  bool _paused = false;
  final _buffer = <DozzleLog>[];
  String _q = '';
  final Set<String> _levels = {...dozzleLevels};
  Object? _error;
  bool _loading = true;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = await ref.read(dozzleFactoryProvider)(widget.config);
      _c = c;
      final hist = await c.history(widget.container);
      if (!mounted) return;
      setState(() {
        _logs.addAll(hist);
        _loading = false;
      });
      _sub = c.stream(widget.container).listen((e) {
        if (!mounted) return;
        if (_paused) {
          _buffer.add(e);
        } else {
          setState(() => _add(e));
        }
      }, onError: (Object e) => mounted ? setState(() => _error = e) : null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _add(DozzleLog e) {
    if (_logs.isNotEmpty && e.id != 0 && _logs.last.id == e.id) return;
    _logs.add(e);
    if (_logs.length > 5000) _logs.removeRange(0, _logs.length - 5000);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c?.close();
    _scroll.dispose();
    super.dispose();
  }

  Color _levelColor(TiphysTokens t, String level) => switch (level) {
        'error' || 'fatal' => t.danger,
        'warn' => t.warning,
        'debug' || 'trace' => t.textSecondary,
        _ => t.text,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final fmt = DateFormat.Hms();
    final shown = _logs.reversed.where((e) => _levels.contains(e.level) && (_q.isEmpty || e.text.toLowerCase().contains(_q))).take(1500).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.container.name),
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
            tooltip: l.filesMore,
            icon: const Icon(LucideIcons.listFilter),
            onSelected: (lv) => setState(() => _levels.contains(lv) ? _levels.remove(lv) : _levels.add(lv)),
            itemBuilder: (_) => [
              for (final lv in dozzleLevels) CheckedPopupMenuItem(value: lv, checked: _levels.contains(lv), child: Text(lv)),
            ],
          ),
          IconButton(
            tooltip: l.commonCopy,
            icon: const Icon(LucideIcons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: shown.reversed.map((e) => '${e.time.toIso8601String()} ${e.text}').join('\n')));
              toast(context, l.commonCopied);
            },
          ),
          IconButton(
            tooltip: l.dozzleShareLog,
            icon: const Icon(LucideIcons.share2),
            onPressed: () {
              // Filtrelenmiş görünüm değil, tüm tampon (en fazla 5000 satır) .log dosyası olarak paylaşılır.
              final text = _logs.map((e) => '${e.time.toIso8601String()} [${e.level}] ${e.text}').join('\n');
              final name = '${widget.container.name}-${DateFormat('yyyyMMdd-HHmm').format(DateTime.now())}.log';
              SharePlus.instance.share(ShareParams(files: [XFile.fromData(utf8.encode(text), mimeType: 'text/plain', name: name)], fileNameOverrides: [name]));
            },
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
                        final e = shown[i];
                        final line = Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${fmt.format(e.time)}  ', style: TextStyle(color: t.textSecondary)),
                            if (e.stream == 'stderr') TextSpan(text: '! ', style: TextStyle(color: t.warning)),
                            TextSpan(text: e.isJson ? e.text.split('\n').first : e.text, style: TextStyle(color: _levelColor(t, e.level))),
                          ]),
                          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.35),
                        );
                        if (!e.isJson) return Padding(padding: const EdgeInsets.only(bottom: 3), child: line);
                        return Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            dense: true,
                            tilePadding: EdgeInsets.zero,
                            title: line,
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(e.text, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
