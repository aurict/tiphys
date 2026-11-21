// Mode chooser (PLAN.md §20 U2; W0 mock display/draft/app-card.html, the fourth phone): three big options (Work · Focus
// · Game), the display host (when there are several) and where the data comes from (mirror a source host / this
// machine itself / custom), then Start. While a mode runs the same sheet switches modes without restarting the display.
// A preset rewrites the chosen mode's card sources (PUT /v1/screen) before the start; "custom" keeps the layout.
// The fourth option, Sleep (§21), starts the whole sleep group instead (every display host; sleep/sleep_data.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../system/agent_providers.dart';
import 'screen_data.dart';
import 'screen_texts.dart';
import 'screen_widgets.dart';
import 'sleep/sleep_data.dart';
import 'sleep/sleep_screen.dart' show startSleepGroup;
import 'sleep/sleep_texts.dart' show sleepAlarmLine;

/// Opens the chooser for [hostId] (the display host; the sheet can change it).
Future<void> showScreenSheet(BuildContext context, {required String hostId, String? mode}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  useRootNavigator: true, // above the floating tab bar
  backgroundColor: context.tokens.isDark ? const Color(0xFF161619) : context.tokens.background,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
  builder: (_) => ScreenSheet(hostId: hostId, mode: mode),
);

/// "Custom" in the where-from choice: the layout's own sources stay.
const customPreset = '';

class ScreenSheet extends ConsumerStatefulWidget {
  const ScreenSheet({super.key, required this.hostId, this.mode});
  final String hostId;
  final String? mode;
  @override
  ConsumerState<ScreenSheet> createState() => _ScreenSheetState();
}

class _ScreenSheetState extends ConsumerState<ScreenSheet> {
  late String _hostId = widget.hostId;
  late String? _mode = widget.mode;

  /// A source name, or [customPreset]; null: what the mode's layout reads now.
  String? _preset;
  bool _busy = false;

  Future<void> _go(ScreenStatus s, String mode, String preset) async {
    final l = AppLocalizations.of(context);
    final n = ref.read(screenProvider(_hostId).notifier);
    setState(() => _busy = true);
    try {
      final layout = s.settings.mode(mode).layout;
      if (preset != customPreset && layout.commonSource != preset) {
        final cards = layout.complete(mode);
        await n.saveSettings({
          'modes': {
            mode: {'layout': ScreenLayout(layout.template, cards).withSource(preset).toJson()},
          },
        });
      }
      await n.start(mode);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sleep: the group starts (leader first); not set up yet, or a machine failed: the sleep screen opens.
  Future<void> _sleep(SleepGroup g) async {
    final nav = Navigator.of(context);
    final router = GoRouter.of(context);
    if (g.running || !g.configured) {
      nav.pop();
      await router.push('/screen/sleep');
      return;
    }
    setState(() => _busy = true);
    final ok = await startSleepGroup(context, ref);
    if (!mounted) return;
    setState(() => _busy = false);
    nav.pop();
    if (!ok) await router.push('/screen/sleep');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final profile = ref.watch(profileProvider);
    final sleep = ref.watch(sleepGroupProvider).value;
    final hosts = ref.watch(screenHostsProvider).value ?? [?profile.host(_hostId)];
    final display = profile.host(_hostId);
    final async = ref.watch(screenProvider(_hostId));
    final s = async.value;

    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.textSecondary)),
    );

    final body = <Widget>[
      Semantics(header: true, child: Text(l.smTitle, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4))),
      const SizedBox(height: 4),
      Text(l.smSheetIntro, style: tt.bodyMedium?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600)),
    ];

    if (s == null || display == null) {
      body.add(
        async.hasError
            ? Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ScreenErrorCard(error: async.error!, onRetry: () => ref.read(screenProvider(_hostId).notifier).retry()),
              )
            : const ScreenLoading(),
      );
    } else {
      final mode = _mode ?? (sleep?.running == true ? 'sleep' : s.shownMode);
      final isSleep = mode == 'sleep';
      final layout = s.settings.mode(isSleep ? s.shownMode : mode).layout;
      final preset = _preset ?? layout.commonSource ?? customPreset;
      final running = s.running;
      body.addAll([
        const SizedBox(height: 14),
        Semantics(
          label: l.smModeLabel,
          child: Column(
            children: [
              for (final m in [...screenModes, 'sleep'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: _ModeOption(
                    mode: m,
                    selected: m == mode,
                    running: m == 'sleep' ? sleep?.running == true : running && s.mode == m,
                    disabled: m == 'sleep' ? sleep == null || !sleep.anySupported : s.legacy && m != 'game',
                    onTap: () => setState(() {
                      _mode = m;
                      _preset = null;
                    }),
                  ),
                ),
            ],
          ),
        ),
        if (s.legacy) Text(l.smLegacyHint, style: tt.bodySmall),
        if (sleep != null && sleep.allUnsupported) Text(l.slNeedsUpdate, style: tt.bodySmall),
        if (isSleep && sleep != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(LucideIcons.moonStar, size: 16, color: t.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sleep.configured ? sleepAlarmLine(l, sleep) : l.slSetupNeeded,
                  style: tt.bodyMedium?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
        if (!isSleep && hosts.length > 1) ...[
          label(l.smDisplayLabel),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final h in hosts)
                  ButtonSegment(
                    value: h.id,
                    icon: Icon(h.id == _hostId && running ? LucideIcons.monitorPlay : LucideIcons.monitor, size: 16),
                    label: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              selected: {_hostId},
              onSelectionChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _hostId = v.first;
                      _mode = null;
                      _preset = null;
                    }),
            ),
          ),
        ],
        if (!s.legacy && !isSleep) ...[
          label(l.smFromLabel),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final src in s.remoteSources)
                _Chip(
                  icon: LucideIcons.monitorSmartphone,
                  text: l.smMirror(sourceLabel(profile, display, s, src.name)),
                  selected: preset == src.name,
                  onTap: () => setState(() => _preset = src.name),
                ),
              _Chip(icon: LucideIcons.monitor, text: l.smFromSelf, selected: preset == selfSource, onTap: () => setState(() => _preset = selfSource)),
              _Chip(icon: LucideIcons.slidersHorizontal, text: l.smFromCustom, selected: preset == customPreset, onTap: () => setState(() => _preset = customPreset)),
            ],
          ),
          if (preset == customPreset) Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 0), child: Text(l.smFromCustomHint, style: tt.bodySmall)),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: t.isDark ? const Color(0xFFF5F5F7) : t.accent,
              foregroundColor: t.isDark ? Colors.black : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: tt.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            onPressed: isSleep
                ? (_busy || sleep == null || !sleep.anySupported ? null : () => _sleep(sleep))
                : _busy || (s.legacy && mode != 'game') || (running && s.mode == mode && (preset == customPreset || preset == layout.commonSource))
                ? null
                : () => _go(s, mode, preset),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(isSleep ? (sleep?.running == true || sleep?.configured != true ? LucideIcons.settings2 : LucideIcons.moon) : (running ? LucideIcons.arrowLeftRight : LucideIcons.play), size: 18),
            label: Text(
              isSleep
                  ? (sleep?.running == true ? l.slSettings : (sleep?.configured == true ? l.slStart : l.slSetup))
                  : (running ? (s.mode == mode ? l.smApply : l.smSwitchTo(screenModeName(l, mode))) : l.gmStart),
            ),
          ),
        ),
      ]);
    }

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(18, 0, 18, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: body),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.mode, required this.selected, required this.running, required this.disabled, required this.onTap});
  final String mode;
  final bool selected;
  final bool running;
  final bool disabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final br = BorderRadius.circular(TiphysTokens.radiusList);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: !disabled,
      button: true,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: Material(
          color: selected ? t.accent.withValues(alpha: t.isDark ? 0.12 : 0.08) : t.card,
          shape: RoundedRectangleBorder(
            borderRadius: br,
            side: BorderSide(color: selected ? t.accent : (t.isDark ? t.cardBorder : t.separator), width: selected ? 1.5 : 1),
          ),
          child: InkWell(
            borderRadius: br,
            onTap: disabled ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  ModeIconBox(mode: mode),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(screenModeName(l, mode), style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            if (running) ...[const SizedBox(width: 8), StateText(text: l.gmOn, color: t.success, maxWidth: 90)],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          screenModeHint(l, mode),
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.textSecondary),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: selected ? t.accent : (t.isDark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC)), width: selected ? 7 : 2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.selected, required this.onTap});
  final IconData icon;
  final String text;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final br = BorderRadius.circular(999);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: Material(
        color: selected ? t.accent.withValues(alpha: t.isDark ? 0.16 : 0.1) : t.chipBackground,
        shape: RoundedRectangleBorder(
          borderRadius: br,
          side: BorderSide(color: selected ? t.accent.withValues(alpha: 0.5) : (t.isDark ? const Color(0x14FFFFFF) : t.separator)),
        ),
        child: InkWell(
          borderRadius: br,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: selected ? t.accent : t.textSecondary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: selected ? t.text : (t.isDark ? const Color(0xFFD1D1D6) : t.text)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
