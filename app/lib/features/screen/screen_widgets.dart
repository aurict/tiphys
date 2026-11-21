// Small pieces shared by the screen mode card, chooser sheet, screen and setup (PLAN.md §20 U).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'screen_texts.dart';

/// Each mode's color (the W0 mock: Work the accent, Focus and Game the second and third host colors).
Color screenModeColor(TiphysTokens t, String? mode) => switch (mode) {
  'focus' => t.hostColor(const Color(0xFF6CCB9F)),
  'game' => t.hostColor(const Color(0xFFF2A985)),
  'sleep' => t.hostColor(const Color(0xFFA48BF0)),
  _ => t.accent,
};

/// Rounded tile with the mode's icon on a tint of its color.
class ModeIconBox extends StatelessWidget {
  const ModeIconBox({super.key, required this.mode, this.size = 46, this.filled = false});
  final String? mode;
  final double size;

  /// The color itself as the background (a running mode), else a light tint.
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = screenModeColor(t, mode);
    final darkText = t.isDark ? const Color(0xFF111114) : Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: filled ? c : c.withValues(alpha: t.isDark ? 0.16 : 0.13), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(screenModeIcon(mode), size: size * 0.48, color: filled ? darkText : (t.isDark ? c : Color.lerp(c, Colors.black, 0.25))),
    );
  }
}

/// Rebuilds every second while [active] (a Focus countdown); nothing runs otherwise.
class TickBuilder extends StatefulWidget {
  const TickBuilder({super.key, required this.active, required this.builder});
  final bool active;
  final WidgetBuilder builder;
  @override
  State<TickBuilder> createState() => _TickBuilderState();
}

class _TickBuilderState extends State<TickBuilder> {
  Timer? _t;

  void _arm() {
    _t?.cancel();
    _t = widget.active ? Timer.periodic(const Duration(seconds: 1), (_) => setState(() {})) : null;
  }

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(TickBuilder old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _arm();
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class ScreenNotice extends StatelessWidget {
  const ScreenNotice({super.key, required this.icon, required this.title, required this.body, this.action, this.iconColor});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final Color? iconColor;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28, color: iconColor ?? t.textSecondary),
          const SizedBox(height: 12),
          Text(title, style: tt.titleLarge),
          const SizedBox(height: 6),
          Text(body, style: tt.bodyMedium?.copyWith(color: t.textSecondary)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class ScreenErrorCard extends StatelessWidget {
  const ScreenErrorCard({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TCard(
        child: Row(
          children: [
            Icon(LucideIcons.triangleAlert, color: t.warning, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(agentErrorText(l, error))),
            TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
          ],
        ),
      ),
    );
  }
}

class ScreenLoading extends StatelessWidget {
  const ScreenLoading({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(40),
    child: Center(child: CircularProgressIndicator()),
  );
}

/// A row with a title and a segmented choice under it (full width, so three or four segments fit at 375 px).
class SegRow<T> extends StatelessWidget {
  const SegRow({super.key, required this.title, required this.value, required this.options, required this.onChanged, this.subtitle});
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: tt.titleMedium),
          if (subtitle != null) Text(subtitle!, style: tt.bodySmall),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final (v, label) in options)
                  ButtonSegment(
                    value: v,
                    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              selected: {value},
              onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// A number with − and + (Focus durations).
class StepperRow extends StatelessWidget {
  const StepperRow({super.key, required this.title, required this.value, required this.min, required this.max, required this.onChanged, this.step = 5, this.unit, this.icon, this.iconBackground});
  final String title;
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int)? unit;
  final ValueChanged<int> onChanged;
  final IconData? icon;
  final Color? iconBackground;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final text = unit?.call(value) ?? '$value';
    Widget btn(IconData i, String label, int? to) => IconButton(
      tooltip: label,
      onPressed: to == null ? null : () => onChanged(to),
      icon: Icon(i, size: 18),
      style: IconButton.styleFrom(backgroundColor: t.chipBackground, minimumSize: const Size(36, 36)),
    );
    return Semantics(
      label: title,
      value: text,
      increasedValue: value < max ? (unit?.call((value + step).clamp(min, max)) ?? '${(value + step).clamp(min, max)}') : null,
      decreasedValue: value > min ? (unit?.call((value - step).clamp(min, max)) ?? '${(value - step).clamp(min, max)}') : null,
      onIncrease: value < max ? () => onChanged((value + step).clamp(min, max)) : null,
      onDecrease: value > min ? () => onChanged((value - step).clamp(min, max)) : null,
      child: GroupedRow(
        title: title,
        icon: icon,
        iconBackground: iconBackground,
        showChevron: false,
        trailing: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              btn(LucideIcons.minus, l.smLess, value > min ? (value - step).clamp(min, max) : null),
              SizedBox(
                width: 62,
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.text, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              btn(LucideIcons.plus, l.smMore, value < max ? (value + step).clamp(min, max) : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dot and a short state text (sources, keybind).
class StateText extends StatelessWidget {
  const StateText({super.key, required this.text, required this.color, this.maxWidth = 140});
  final String text;
  final Color color;
  final double maxWidth;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 13.5, color: t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// A source's connection state in words and color.
(String, Color) sourceStateText(AppLocalizations l, TiphysTokens t, String state) => switch (state) {
  'ok' => (l.gmStateOk, t.success),
  'connecting' => (l.gmStateConnecting, t.warning),
  'down' => (l.gmStateDown, t.danger),
  _ => (l.gmStateOff, t.textSecondary),
};
