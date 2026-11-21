// Screen mode screen (route /screen?host=<display host>; PLAN.md §20 U3/U4): a hero with the mode, its state, Start/Stop,
// "change mode" and the privacy veil (in Focus the countdown and its controls), then one tab per mode (Work · Focus ·
// Game) with its layout, look and own settings, then the connections (sources) and the setup. Every change goes to the
// display host at once. An agent older than §20 has Game mode only: the other tabs say it needs an update.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../core/push/focus_notices.dart' show clockText, focusPhaseName;
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show ClaudeFolderPicker;
import '../system/agent_providers.dart';
import 'screen_card.dart';
import 'screen_data.dart';
import 'screen_setup.dart';
import 'screen_sheet.dart';
import 'screen_texts.dart';
import 'screen_widgets.dart';

class ScreenModeScreen extends ConsumerStatefulWidget {
  const ScreenModeScreen({super.key, required this.hostId, this.tab});

  /// The display host; empty: the home card's (the running one, else the first host with the feature).
  final String hostId;

  /// The tab to open (work | focus | game); null: the running or last mode.
  final String? tab;
  @override
  ConsumerState<ScreenModeScreen> createState() => _ScreenModeScreenState();
}

class _ScreenModeScreenState extends ConsumerState<ScreenModeScreen> {
  late String _hostId = widget.hostId;
  late String? _tab = screenModes.contains(widget.tab) ? widget.tab : null;

  /// null: an older agent without a source shows the wizard; true: the wizard is open (add a source / its result).
  bool? _wizard;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final profile = ref.watch(profileProvider);
    var hostId = _hostId;
    if (hostId.isEmpty) {
      final target = ref.watch(screenTargetProvider);
      if (target.isLoading && !target.hasValue) return _page(l, null, [const ScreenLoading()]);
      hostId = target.value?.host.id ?? '';
    }
    final host = profile.host(hostId);
    if (host == null) return _page(l, null, [ScreenNotice(icon: LucideIcons.monitor, title: l.smNoHostTitle, body: l.smNoHostBody)]);

    final features = ref.watch(healthProvider(host.id)).value?['features'] as Map?;
    if (features != null && features['screen'] != true && features['gamemode'] != true) return _page(l, host, [ScreenFeatureOff(host: host)]);

    final status = ref.watch(screenProvider(host.id));
    final s = status.value;
    if (s == null) {
      return _page(l, host, [
        status.when(
          loading: () => const ScreenLoading(),
          error: (e, _) => ScreenErrorCard(error: e, onRetry: () => ref.read(screenProvider(host.id).notifier).retry()),
          data: (_) => const SizedBox.shrink(),
        ),
      ]);
    }
    final wizard = _wizard ?? (s.legacy && s.remoteSources.isEmpty);
    final tab = _tab ?? (s.legacy ? 'game' : s.shownMode);
    return _page(l, host, [
      if (status.hasError) ScreenErrorCard(error: status.error!, onRetry: () => ref.read(screenProvider(host.id).notifier).retry()),
      if (wizard)
        ScreenSetupWizard(
          initialDisplay: host.id,
          onStarted: () => setState(() => _wizard = true),
          onDone: (display) => setState(() {
            _wizard = false;
            _hostId = display;
          }),
          onCancel: s.legacy && s.remoteSources.isEmpty ? null : () => setState(() => _wizard = false),
        )
      else ...[
        ScreenHero(host: host, status: s),
        if (s.legacy) Padding(padding: const EdgeInsets.only(top: 12), child: _LegacyNote(host: host)),
        const SizedBox(height: 18),
        Semantics(
          label: l.smTabsLabel,
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final m in screenModes)
                  ButtonSegment(
                    value: m,
                    icon: Icon(screenModeIcon(m), size: 16),
                    label: Text(screenModeName(l, m), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              selected: {tab},
              onSelectionChanged: (v) => setState(() => _tab = v.first),
            ),
          ),
        ),
        if (s.legacy && tab != 'game')
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: ScreenNotice(icon: LucideIcons.circleArrowUp, title: l.smNeedsUpdateTitle, body: l.smNeedsUpdate),
          )
        else ...[
          if (!s.legacy) LayoutSection(host: host, status: s, mode: tab),
          _LookSection(hostId: host.id, status: s, mode: tab),
          switch (tab) {
            'work' => _WorkSection(host: host, status: s),
            'focus' => _FocusSection(hostId: host.id, status: s),
            _ => _GameSection(hostId: host.id, status: s),
          },
        ],
        ConnectionsSection(host: host, status: s, onAdd: () => setState(() => _wizard = true)),
        SetupSection(host: host, status: s),
      ],
    ]);
  }

  Widget _page(AppLocalizations l, Host? host, List<Widget> body) => SettingsPage(
    title: host?.name ?? l.smTitle,
    children: [
      LargeTitleHeader(title: l.smTitle),
      const SizedBox(height: 14),
      ...body,
    ],
  );
}

/// The feature is off on this host: explain and lead to the agent settings where it is turned on.
class ScreenFeatureOff extends StatelessWidget {
  const ScreenFeatureOff({super.key, required this.host});
  final Host host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ScreenNotice(
      icon: LucideIcons.powerOff,
      title: l.smFeatureOffTitle,
      body: l.smFeatureOffBody,
      action: FilledButton.icon(
        onPressed: () => context.push('/settings/hosts/agent?id=${Uri.encodeQueryComponent(host.id)}'),
        icon: const Icon(LucideIcons.slidersHorizontal, size: 18),
        label: Text(l.gmFeatureOpenSettings),
      ),
    );
  }
}

class _LegacyNote extends StatelessWidget {
  const _LegacyNote({required this.host});
  final Host host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return TCard(
      child: Row(
        children: [
          Icon(LucideIcons.circleArrowUp, color: t.warning, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(l.smLegacyNote(host.name), style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

// ───────────────────────────── hero ─────────────────────────────

class ScreenHero extends ConsumerStatefulWidget {
  const ScreenHero({super.key, required this.host, required this.status});
  final Host host;
  final ScreenStatus status;
  @override
  ConsumerState<ScreenHero> createState() => _ScreenHeroState();
}

class _ScreenHeroState extends ConsumerState<ScreenHero> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final s = widget.status;
    final on = s.running;
    final mode = on ? s.mode : null;
    final n = ref.read(screenProvider(widget.host.id).notifier);
    final profile = ref.watch(profileProvider);
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ModeIconBox(mode: mode ?? s.settings.lastMode, size: 48, filled: on),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusDot(color: on ? t.success : t.textSecondary),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            on ? screenModeName(l, mode) : l.gmOff,
                            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      on
                          ? [l.smOnHost(widget.host.name), if (s.startedAt != null) elapsedText(l, s.startedAt, DateTime.now())].join(' · ')
                          : l.smLastUsed(screenModeName(l, s.settings.lastMode), widget.host.name),
                      style: tt.bodySmall?.copyWith(color: t.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (on && mode == 'focus') ...[const SizedBox(height: 16), FocusPanel(hostId: widget.host.id, status: s)],
          if (on && mode == 'work') ...[
            const SizedBox(height: 14),
            Divider(color: t.separator, height: 1),
            const SizedBox(height: 12),
            PreviewRow(icon: LucideIcons.sparkle, title: workLine(l, s), subtitle: (s.claudeWaiting ?? 0) > 0 ? l.smClaudeWaiting(s.claudeWaiting!) : null),
            const SizedBox(height: 10),
            PreviewRow(icon: LucideIcons.monitorSmartphone, title: layoutSourceText(l, profile, widget.host, s, 'work'), dim: true),
          ],
          if (on && mode == 'game') ...[
            const SizedBox(height: 14),
            Divider(color: t.separator, height: 1),
            const SizedBox(height: 12),
            PreviewRow(
              icon: LucideIcons.music,
              title: s.music == null ? l.gmNothingPlaying : s.music!.title,
              subtitle: s.music == null || s.music!.artist.isEmpty ? null : s.music!.artist,
              dim: s.music == null,
            ),
            const SizedBox(height: 10),
            PreviewRow(
              icon: LucideIcons.truck,
              title: s.truck?.driving == true && s.truck?.speedKmh != null ? l.gmDrivingSpeed('${s.truck!.speedKmh}') : gameEts2Text(l, s.truck),
              subtitle: s.truck?.driving == true && s.truck?.from != null && s.truck?.to != null ? '${s.truck!.from} → ${s.truck!.to}' : null,
              dim: s.truck?.driving != true,
            ),
          ],
          if (on && !s.legacy) ...[
            const SizedBox(height: 12),
            MergeSemantics(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _busy ? null : () => _run(() => n.veil(!s.veil)),
                child: Row(
                children: [
                  Icon(s.veil ? LucideIcons.eyeOff : LucideIcons.eye, size: 18, color: t.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.smVeil, style: tt.titleMedium),
                        Text(l.smVeilHint, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Switch(value: s.veil, onChanged: _busy ? null : (v) => _run(() => n.veil(v))),
                ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: on ? t.danger : t.accent,
                      foregroundColor: on ? Colors.white : t.onAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      textStyle: tt.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    onPressed: _busy ? null : (on ? () => _run(n.stop) : () => showScreenSheet(context, hostId: widget.host.id)),
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(on ? LucideIcons.square : LucideIcons.play, size: 20),
                    label: Text(on ? l.gmStop : l.gmStart),
                  ),
                ),
              ),
              if (on && !s.legacy) ...[
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      side: BorderSide(color: t.isDark ? t.cardBorder : t.separator),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: _busy ? null : () => showScreenSheet(context, hostId: widget.host.id),
                    icon: const Icon(LucideIcons.arrowLeftRight, size: 18),
                    label: Text(l.smChangeMode),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

String gameEts2Text(AppLocalizations l, GameTruck? t) => switch (t?.state) {
  'menu' => l.gmEts2Menu,
  'paused' => l.gmEts2Paused,
  'driving' => l.gmEts2Driving,
  _ => l.gmEts2None,
};

class PreviewRow extends StatelessWidget {
  const PreviewRow({super.key, required this.icon, required this.title, this.subtitle, this.dim = false});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool dim;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 17, color: t.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: subtitle == null ? 6 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.titleMedium?.copyWith(color: dim ? t.textSecondary : t.text), maxLines: 2, overflow: TextOverflow.ellipsis),
                if (subtitle != null) Text(subtitle!, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── Focus controls (U4) ─────────────────────────────

class FocusPanel extends ConsumerStatefulWidget {
  const FocusPanel({super.key, required this.hostId, required this.status});
  final String hostId;
  final ScreenStatus status;
  @override
  ConsumerState<FocusPanel> createState() => _FocusPanelState();
}

class _FocusPanelState extends ConsumerState<FocusPanel> {
  late final _task = TextEditingController(text: widget.status.focus.task ?? '');
  final _taskFocus = FocusNode();
  bool _busy = false;

  @override
  void didUpdateWidget(FocusPanel old) {
    super.didUpdateWidget(old);
    // The agent's task line, unless it is being typed.
    final t = widget.status.focus.task ?? '';
    if (!_taskFocus.hasFocus && _task.text != t) _task.text = t;
  }

  @override
  void dispose() {
    _task.dispose();
    _taskFocus.dispose();
    super.dispose();
  }

  Future<void> _act({String? action, String? task}) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(screenProvider(widget.hostId).notifier).focus(action: action, task: task);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final f = widget.status.focus;
    final color = f.isBreak ? t.hostColor(const Color(0xFFF2A985)) : screenModeColor(t, 'focus');
    return TickBuilder(
      active: f.ticking,
      builder: (context) {
        final now = DateTime.now();
        final left = f.idle ? Duration(minutes: widget.status.settings.mode('focus').focusMin) : f.remaining(now);
        final phase = f.idle ? l.smPhaseIdle : (f.phase == 'focus' ? l.smOngoingRound(focusPhaseName(l, f.phase), f.round, f.longEvery) : focusPhaseName(l, f.phase));
        Widget control(IconData icon, String label, VoidCallback? onTap, {bool primary = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              height: 52,
              child: primary
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: const Color(0xFF111114), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), padding: EdgeInsets.zero),
                      onPressed: onTap,
                      icon: Icon(icon, size: 18),
                      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    )
                  : OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        side: BorderSide(color: t.isDark ? t.cardBorder : t.separator),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: onTap,
                      icon: Icon(icon, size: 17),
                      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ),
        );
        final running = f.ticking;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: false,
              label: '$phase, ${focusLine(l, f, now)}',
              child: ExcludeSemantics(
                child: Column(
                  children: [
                    Text(phase, style: tt.titleSmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      clockText(left),
                      style: TextStyle(fontSize: 64, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -2, color: f.paused || f.idle ? t.textSecondary : t.text, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: f.idle ? 0 : f.progress(now), minHeight: 6, color: color, backgroundColor: t.ringTrack),
                    ),
                    if (f.paused) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.smFocusPaused, style: tt.bodySmall)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                control(
                  running ? LucideIcons.pause : LucideIcons.play,
                  running ? l.smFocusPause : (f.paused ? l.smFocusResume : l.gmStart),
                  _busy ? null : () => _act(action: running ? 'pause' : (f.paused ? 'resume' : 'start')),
                  primary: true,
                ),
                control(LucideIcons.skipForward, l.smFocusSkip, _busy || f.idle ? null : () => _act(action: 'skip')),
                control(LucideIcons.rotateCcw, l.smFocusReset, _busy || f.idle ? null : () => _act(action: 'reset')),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _task,
              focusNode: _taskFocus,
              maxLength: 80,
              maxLines: 1,
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r  ]'))],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l.smTask,
                hintText: l.smTaskHint,
                suffixIcon: IconButton(
                  tooltip: l.smTaskSave,
                  icon: const Icon(LucideIcons.check, size: 18),
                  onPressed: _busy ? null : () => _act(task: _task.text.trim()),
                ),
              ),
              onSubmitted: (v) => _act(task: v.trim()),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────────── layout (Düzen) ─────────────────────────────

/// The mode's cards: on/off, order (drag), each card's source, back to the template.
class LayoutSection extends ConsumerWidget {
  const LayoutSection({super.key, required this.host, required this.status, required this.mode});
  final Host host;
  final ScreenStatus status;
  final String mode;

  Future<void> _save(BuildContext context, WidgetRef ref, List<LayoutCard> cards) async {
    final l = AppLocalizations.of(context);
    try {
      await ref.read(screenProvider(host.id).notifier).saveSettings({
        'modes': {
          mode: {'layout': ScreenLayout(mode, cards).toJson()},
        },
      });
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final profile = ref.watch(profileProvider);
    final layout = status.settings.mode(mode).layout;
    final cards = layout.complete(mode);
    final sources = [for (final src in status.sources) (src.name, src.isSelf ? l.smSelfSource(host.name) : sourceLabel(profile, host, status, src.name))];
    String srcName(String name) => sources.where((x) => x.$1 == name).firstOrNull?.$2 ?? name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l.smSectionLayout),
        TCard(
          padding: EdgeInsets.zero,
          radius: TiphysTokens.radiusList,
          child: Column(
            children: [
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) {
                  final next = [...cards];
                  next.insert(to, next.removeAt(from));
                  unawaited(_save(context, ref, next));
                },
                children: [
                  for (final (i, c) in cards.indexed)
                    Container(
                      key: ValueKey(c.kind),
                      decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: t.separator, width: 0.5))),
                      child: _CardRow(
                        index: i,
                        card: c,
                        title: screenCardName(l, c.kind),
                        sourceText: srcName(c.source),
                        sources: sources,
                        onToggle: (v) => _save(context, ref, [for (final x in cards) x.kind == c.kind ? x.copyWith(enabled: v) : x]),
                        onSource: (v) => _save(context, ref, [for (final x in cards) x.kind == c.kind ? x.copyWith(source: v) : x]),
                      ),
                    ),
                ],
              ),
              Divider(color: t.separator, height: 1),
              GroupedRow(
                title: l.smLayoutReset,
                icon: LucideIcons.listRestart,
                iconBackground: const Color(0xFF6C6C70),
                showChevron: false,
                onTap: () => _save(context, ref, ScreenLayout.template(mode, layout.commonSource ?? selfSource).cards),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(l.smLayoutHint, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.index, required this.card, required this.title, required this.sourceText, required this.sources, required this.onToggle, required this.onSource});
  final int index;
  final LayoutCard card;
  final String title;
  final String sourceText;
  final List<(String, String)> sources;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onSource;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Semantics(
                label: l.smReorder(title),
                child: SizedBox(width: 40, height: 48, child: Icon(LucideIcons.gripVertical, size: 18, color: t.textSecondary)),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: tt.titleMedium?.copyWith(color: card.enabled ? t.text : t.textSecondary)),
                  if (sources.length > 1)
                    PopupMenuButton<String>(
                      tooltip: l.smCardSource(title),
                      initialValue: card.source,
                      onSelected: onSource,
                      itemBuilder: (_) => [for (final (v, name) in sources) PopupMenuItem(value: v, child: Text(name))],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.server, size: 13, color: t.accent),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(sourceText, style: tt.bodySmall?.copyWith(color: t.accent, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            Icon(LucideIcons.chevronDown, size: 13, color: t.accent),
                          ],
                        ),
                      ),
                    )
                  else
                    Text(sourceText, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Semantics(label: title, child: Switch(value: card.enabled, onChanged: onToggle)),
          ],
        ),
      ),
    );
  }
}

String screenCardName(AppLocalizations l, String kind) => switch (kind) {
  'city' => l.smCardCity,
  'day' => l.smCardDay,
  'system' => l.smCardSystem,
  'jobs' => l.smCardJobs,
  'git' => 'Git',
  'music' => l.smCardMusic,
  'servers' => l.smCardServers,
  'focus' => l.smCardFocus,
  'task' => l.smCardTask,
  'map' => l.smCardMap,
  'cockpit' => l.smCardCockpit,
  'lyrics' => l.gmLyrics,
  _ => kind,
};

// ───────────────────────────── look (Görünüm) ─────────────────────────────

class _LookSection extends ConsumerStatefulWidget {
  const _LookSection({required this.hostId, required this.status, required this.mode});
  final String hostId;
  final ScreenStatus status;
  final String mode;
  @override
  ConsumerState<_LookSection> createState() => _LookSectionState();
}

class _LookSectionState extends ConsumerState<_LookSection> {
  /// While the slider is dragged its own value shows (the status polls would pull it back).
  double? _drag;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _save(Map<String, Object?> patch, {bool global = false}) => saveScreen(context, ref, widget.hostId, global ? patch : {'modes': {widget.mode: patch}});

  void _brightness(double v, {bool end = false}) {
    setState(() => _drag = v);
    _debounce?.cancel();
    void send() {
      unawaited(_save({'brightness': v.round()}));
      if (mounted) setState(() => _drag = null);
    }

    if (end) {
      send();
    } else {
      _debounce = Timer(const Duration(milliseconds: 350), send);
    }
  }

  Future<void> _editBind() async {
    final l = AppLocalizations.of(context);
    final c = TextEditingController(text: widget.status.settings.scratchBind);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.smBind),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14),
          decoration: InputDecoration(helperText: l.smBindHelp, helperMaxLines: 3),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(l.commonSave)),
        ],
      ),
    );
    c.dispose();
    if (v == null || v.isEmpty || v == widget.status.settings.scratchBind) return;
    if (!scratchBindPattern.hasMatch(v)) {
      if (mounted) toast(context, l.smBindInvalid);
      return;
    }
    await _save({'scratchBind': v}, global: true);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = widget.status.settings;
    final m = s.mode(widget.mode);
    final legacy = widget.status.legacy;
    final keep = m.brightness == null;
    final shown = (_drag ?? m.brightness ?? 60).clamp(5, 100).toDouble();
    final dim = {0, 5, 10, 30, 60, m.dimIdleMinutes}.toList()..sort();
    return GroupedSection(
      title: l.smSectionLook,
      children: [
        SegRow<String>(
          title: l.gmMotion,
          value: m.motion,
          options: [('low', l.gmMotionLow), ('normal', l.gmMotionNormal), ('high', l.gmMotionHigh)],
          onChanged: (v) => _save({'motion': v}),
        ),
        SwitchRow(
          title: l.gmBrightnessKeep,
          subtitle: l.gmBrightnessKeepHint,
          icon: LucideIcons.sun,
          iconBackground: const Color(0xFFFF9F0A),
          value: keep,
          onChanged: (v) => _save({'brightness': v ? null : 60}),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l.gmBrightness, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: keep ? t.textSecondary : t.text)),
                  ),
                  Text(
                    keep ? '–' : '${shown.round()}%',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
              Semantics(
                label: l.gmBrightness,
                value: keep ? null : '${shown.round()}%',
                child: Slider(
                  value: shown,
                  min: 5,
                  max: 100,
                  divisions: 19,
                  onChanged: keep ? null : _brightness,
                  onChangeEnd: keep ? null : (v) => _brightness(v, end: true),
                ),
              ),
            ],
          ),
        ),
        SwitchRow(
          title: l.gmClock24,
          icon: LucideIcons.clock,
          iconBackground: const Color(0xFF0A84FF),
          value: m.clock24,
          onChanged: (v) => _save({'clock24': v}),
        ),
        if (widget.mode != 'focus')
          SegRow<int>(
            title: l.gmDimAfter,
            subtitle: l.gmDimHint,
            value: m.dimIdleMinutes,
            options: [for (final x in dim) (x, x == 0 ? l.gmDimNever : '$x')],
            onChanged: (v) => _save({'dimIdleMinutes': v}),
          ),
        if (!legacy) ...[
          SegRow<String>(
            title: l.smPlacement,
            subtitle: l.smPlacementHint,
            value: s.placement,
            options: [('fullscreen', l.smPlacementFull), ('scratch', l.smPlacementScratch)],
            onChanged: (v) => _save({'placement': v}, global: true),
          ),
          if (s.placement == 'scratch')
            GroupedRow(
              title: l.smBind,
              icon: LucideIcons.keyboard,
              iconBackground: const Color(0xFF6C6C70),
              trailingText: bindText(s.scratchBind),
              onTap: _editBind,
            ),
        ],
      ],
    );
  }
}

/// Hyprland's `MODS,key` (agent: config.ts SCRATCH_BIND).
final scratchBindPattern = RegExp(r'^(?:(?:SUPER|SHIFT|CTRL|CONTROL|ALT|MOD2|MOD3|MOD5)(?:[ _](?:SUPER|SHIFT|CTRL|CONTROL|ALT|MOD2|MOD3|MOD5)){0,3})?,[A-Za-z0-9_]{1,32}$');

/// Sends a settings patch for [hostId], with a toast on failure.
Future<void> saveScreen(BuildContext context, WidgetRef ref, String hostId, Map<String, Object?> patch) async {
  final l = AppLocalizations.of(context);
  try {
    await ref.read(screenProvider(hostId).notifier).saveSettings(patch);
  } catch (e) {
    if (context.mounted) toast(context, agentErrorText(l, e));
  }
}

// ───────────────────────────── Work ─────────────────────────────

class _WorkSection extends ConsumerWidget {
  const _WorkSection({required this.host, required this.status});
  final Host host;
  final ScreenStatus status;

  Future<void> _save(BuildContext context, WidgetRef ref, Map<String, Object?> p) => saveScreen(context, ref, host.id, {'modes': {'work': p}});

  /// The source the code city (and so the project, the diff) reads.
  String get _citySource => status.settings.mode('work').layout.cards.where((c) => c.kind == 'city').firstOrNull?.source ?? selfSource;

  Future<void> _project(BuildContext context, WidgetRef ref, Host? src) async {
    final l = AppLocalizations.of(context);
    final w = status.settings.mode('work');
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.sparkles),
              title: Text(l.smProjectAuto),
              subtitle: Text(l.smProjectAutoHint),
              trailing: w.projectPath == null ? const Icon(LucideIcons.check) : null,
              onTap: () => Navigator.pop(ctx, 'auto'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.folderOpen),
              title: Text(l.smProjectPick),
              subtitle: Text(src == null ? l.smProjectPickNoHost : (w.projectPath ?? l.smProjectPickHint(src.name))),
              enabled: src != null,
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'auto') return _save(context, ref, {'project': 'auto'});
    final path = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ClaudeFolderPicker(hostId: src!.id, start: w.projectPath ?? '~', absolute: true)));
    if (path != null && context.mounted) await _save(context, ref, {'project': {'path': path}});
  }

  Future<void> _share(BuildContext context, WidgetRef ref, Host src, bool on) async {
    final l = AppLocalizations.of(context);
    if (on && !await confirmDialog(context, message: l.smShareConfirm(src.name, host.name), confirmLabel: l.smShareOn)) return;
    try {
      final c = await ref.read(agentClientFactoryProvider)(src);
      try {
        await setShareCode(c, on);
      } finally {
        c.close();
      }
      ref.invalidate(shareCodeProvider(src.id));
      ref.invalidate(screenProvider(src.id));
      if (context.mounted) toast(context, on ? l.smShareDone(src.name) : l.systemDone);
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final profile = ref.watch(profileProvider);
    final w = status.settings.mode('work');
    final srcName = _citySource;
    final src = hostForSource(profile, host, status, srcName);
    final share = srcName == selfSource ? status.settings.shareCode : (src == null ? null : ref.watch(shareCodeProvider(src.id)).value);
    final srcLabel = srcName == selfSource ? host.name : sourceLabel(profile, host, status, srcName);
    return GroupedSection(
      title: l.smModeWork,
      children: [
        GroupedRow(
          title: l.smProject,
          subtitle: w.projectPath ?? l.smProjectAuto,
          icon: LucideIcons.folderGit2,
          iconBackground: const Color(0xFF5E5CE6),
          onTap: () => _project(context, ref, src),
        ),
        SegRow<String>(title: l.smCity, subtitle: l.smCityHint, value: w.city, options: [('3d', '3D'), ('2d', '2D')], onChanged: (v) => _save(context, ref, {'city': v})),
        SwitchRow(
          title: l.smDiff,
          subtitle: l.smDiffHint,
          icon: LucideIcons.fileDiff,
          iconBackground: const Color(0xFF30B0C7),
          value: w.diff,
          onChanged: (v) => _save(context, ref, {'diff': v}),
        ),
        if (w.diff)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              children: [
                Icon(share == true ? LucideIcons.shieldCheck : LucideIcons.shieldAlert, size: 18, color: share == true ? t.success : t.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    share == true ? l.smShareIsOn(srcLabel) : (share == false ? l.smShareIsOff(srcLabel) : l.smShareUnknown(srcLabel)),
                    style: tt.bodySmall,
                  ),
                ),
                if (src != null && share != null)
                  TextButton(
                    onPressed: () => _share(context, ref, src, !share),
                    style: share ? TextButton.styleFrom(foregroundColor: t.danger) : null,
                    child: Text(share ? l.smShareOff : l.smShareOpen),
                  ),
              ],
            ),
          ),
        SwitchRow(
          title: l.smCi,
          subtitle: l.smCiHint,
          icon: LucideIcons.circleCheckBig,
          iconBackground: const Color(0xFF34C759),
          value: w.ci,
          onChanged: (v) => _save(context, ref, {'ci': v}),
        ),
      ],
    );
  }
}

// ───────────────────────────── Focus ─────────────────────────────

class _FocusSection extends ConsumerStatefulWidget {
  const _FocusSection({required this.hostId, required this.status});
  final String hostId;
  final ScreenStatus status;
  @override
  ConsumerState<_FocusSection> createState() => _FocusSectionState();
}

class _FocusSectionState extends ConsumerState<_FocusSection> {
  double? _drag;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _save(Map<String, Object?> p) => saveScreen(context, ref, widget.hostId, {'modes': {'focus': p}});

  void _volume(double v, {bool end = false}) {
    setState(() => _drag = v);
    _debounce?.cancel();
    void send() {
      unawaited(_save({'ambientVolume': v.round()}));
      if (mounted) setState(() => _drag = null);
    }

    if (end) {
      send();
    } else {
      _debounce = Timer(const Duration(milliseconds: 350), send);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final f = widget.status.settings.mode('focus');
    final off = f.ambient == 'off';
    final vol = (_drag ?? f.ambientVolume).clamp(0, 100).toDouble();
    String min(int v) => l.durationMinutes(v);
    return GroupedSection(
      title: l.smModeFocus,
      footer: l.smDurationsHint,
      children: [
        StepperRow(title: l.smFocusMin, value: f.focusMin, min: 5, max: 120, unit: min, icon: LucideIcons.target, iconBackground: const Color(0xFF34C759), onChanged: (v) => _save({'focusMin': v})),
        StepperRow(title: l.smShortMin, value: f.shortMin, min: 5, max: 120, unit: min, icon: LucideIcons.coffee, iconBackground: const Color(0xFFFF9F0A), onChanged: (v) => _save({'shortMin': v})),
        StepperRow(title: l.smLongMin, value: f.longMin, min: 5, max: 120, unit: min, icon: LucideIcons.sofa, iconBackground: const Color(0xFFFF6B35), onChanged: (v) => _save({'longMin': v})),
        StepperRow(
          title: l.smLongEvery,
          value: f.longEvery,
          min: 2,
          max: 8,
          step: 1,
          unit: l.smRounds,
          icon: LucideIcons.repeat,
          iconBackground: const Color(0xFF5E5CE6),
          onChanged: (v) => _save({'longEvery': v}),
        ),
        SegRow<String>(
          title: l.smAmbient,
          subtitle: l.smAmbientHint,
          value: f.ambient,
          options: [('off', l.smAmbientOff), ('brown', l.smAmbientBrown), ('pink', l.smAmbientPink), ('rain', l.smAmbientRain)],
          onChanged: (v) => _save({'ambient': v}),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(l.smVolume, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: off ? t.textSecondary : t.text))),
                  Text(
                    off ? '–' : '${vol.round()}%',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
              Semantics(
                label: l.smVolume,
                value: off ? null : '${vol.round()}%',
                child: Slider(value: vol, min: 0, max: 100, divisions: 20, onChanged: off ? null : _volume, onChangeEnd: off ? null : (v) => _volume(v, end: true)),
              ),
            ],
          ),
        ),
        SwitchRow(title: l.smChime, subtitle: l.smChimeHint, icon: LucideIcons.bell, iconBackground: const Color(0xFFFF375F), value: f.chime, onChanged: (v) => _save({'chime': v})),
        SwitchRow(title: l.smQuietPhone, subtitle: l.smQuietPhoneHint, icon: LucideIcons.bellOff, iconBackground: const Color(0xFF6C6C70), value: f.quietPhone, onChanged: (v) => _save({'quietPhone': v})),
      ],
    );
  }
}

// ───────────────────────────── Game (§19) ─────────────────────────────

class _GameSection extends ConsumerWidget {
  const _GameSection({required this.hostId, required this.status});
  final String hostId;
  final ScreenStatus status;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final g = status.settings.mode('game');
    Future<void> save(Map<String, Object?> p) => saveScreen(context, ref, hostId, {'modes': {'game': p}});
    return GroupedSection(
      title: l.smModeGame,
      children: [
        SegRow<String>(
          title: l.gmScene,
          value: g.scene,
          options: [('auto', l.gmSceneAuto), ('drive', l.gmSceneDrive), ('music', l.gmSceneMusic)],
          onChanged: (v) => save({'scene': v}),
        ),
        SwitchRow(title: l.gmLyrics, icon: LucideIcons.textQuote, iconBackground: const Color(0xFF5E5CE6), value: g.lyrics, onChanged: (v) => save({'lyrics': v})),
        SwitchRow(title: l.gmSpectrum, icon: LucideIcons.audioLines, iconBackground: const Color(0xFFFF375F), value: g.spectrum, onChanged: (v) => save({'spectrum': v})),
      ],
    );
  }
}
