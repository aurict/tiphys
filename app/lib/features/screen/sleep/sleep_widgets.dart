// Small pieces of the sleep mode screens (PLAN.md §21 U): the colors, the moon, a slider row that holds its own value
// while dragged, a time row and a "needs an agent update" row.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/surfaces.dart';

/// The sleep mode's color (moonlight lavender) and the warm sunrise color of the alarm and the morning.
Color sleepColor(TiphysTokens t) => t.hostColor(const Color(0xFFA48BF0));
Color sleepSunColor(TiphysTokens t) => t.hostColor(const Color(0xFFF2A65A));

/// The ember colors of the scene (display/sleep): the hero's glow while the mode runs.
const emberDeep = Color(0xFF4A0A00);
const emberMid = Color(0xFFC24A0A);
const emberHot = Color(0xFFE8862A);

/// A big moon on a soft glow (embers while [on]).
class SleepMoon extends StatelessWidget {
  const SleepMoon({super.key, this.size = 76, this.on = false, this.ringing = false});
  final double size;
  final bool on;
  final bool ringing;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = ringing ? sleepSunColor(t) : sleepColor(t);
    final glow = on ? (ringing ? sleepSunColor(t) : emberMid) : c;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: on
                ? [glow.withValues(alpha: t.isDark ? 0.42 : 0.30), (ringing ? glow : emberDeep).withValues(alpha: t.isDark ? 0.22 : 0.10), Colors.transparent]
                : [c.withValues(alpha: t.isDark ? 0.24 : 0.18), c.withValues(alpha: t.isDark ? 0.08 : 0.06), Colors.transparent],
            stops: const [0, 0.62, 1],
          ),
        ),
        child: Icon(
          ringing ? LucideIcons.sunrise : LucideIcons.moonStar,
          size: size * 0.5,
          color: on ? (ringing ? (t.isDark ? c : Color.lerp(c, Colors.black, 0.3)) : (t.isDark ? emberHot : emberMid)) : (t.isDark ? c : Color.lerp(c, Colors.black, 0.25)),
        ),
      ),
    );
  }
}

/// A title, the value on the right and a slider under it. While dragged the row shows its own value (the polls would
/// pull it back); [onChanged] runs on each move (e.g. a live preview), [onChangeEnd] once at the end (the save).
class SleepSliderRow extends StatefulWidget {
  const SleepSliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChangeEnd,
    this.onChanged,
    this.divisions,
    this.unit = '%',
    this.subtitle,
    this.enabled = true,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final int value;
  final int min;
  final int max;
  final int? divisions;
  final String unit;
  final bool enabled;
  final ValueChanged<int>? onChanged;
  final ValueChanged<int> onChangeEnd;

  /// After the value (e.g. a preview indicator).
  final Widget? trailing;
  @override
  State<SleepSliderRow> createState() => _SleepSliderRowState();
}

class _SleepSliderRowState extends State<SleepSliderRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final v = (_drag ?? widget.value.toDouble()).clamp(widget.min.toDouble(), widget.max.toDouble());
    final text = '${v.round()}${widget.unit}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.title, style: tt.titleMedium?.copyWith(color: widget.enabled ? t.text : t.textSecondary))),
              ?widget.trailing,
              Text(
                widget.enabled ? text : '–',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          if (widget.subtitle != null) Text(widget.subtitle!, style: tt.bodySmall),
          Semantics(
            label: widget.title,
            value: widget.enabled ? text : null,
            child: SliderTheme(
              // Fine steps: no tick dots (they'd fill the track).
              data: SliderTheme.of(context).copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
              child: Slider(
              value: v,
              min: widget.min.toDouble(),
              max: widget.max.toDouble(),
              divisions: widget.divisions ?? (widget.max - widget.min),
              onChanged: !widget.enabled
                  ? null
                  : (x) {
                      setState(() => _drag = x);
                      widget.onChanged?.call(x.round());
                    },
              onChangeEnd: !widget.enabled
                  ? null
                  : (x) {
                      widget.onChangeEnd(x.round());
                      setState(() => _drag = null);
                    },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row with a time (HH:MM) that opens the time picker.
class SleepTimeRow extends StatelessWidget {
  const SleepTimeRow({super.key, required this.title, required this.value, required this.onChanged, this.icon, this.iconBackground, this.enabled = true});
  final String title;
  final String value;
  final ValueChanged<String> onChanged;
  final IconData? icon;
  final Color? iconBackground;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    final p = value.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (picked == null) return;
    String two(int x) => x.toString().padLeft(2, '0');
    final v = '${two(picked.hour)}:${two(picked.minute)}';
    if (v != value) onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: title,
      value: value,
      child: ExcludeSemantics(
        child: GroupedRow(
          title: title,
          icon: icon,
          iconBackground: iconBackground,
          showChevron: false,
          onTap: enabled ? () => _pick(context) : null,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(10)),
            child: Text(
              value,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: enabled ? t.text : t.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section the agent can't do yet (its block is missing from the settings).
class SleepNeedsUpdateRow extends StatelessWidget {
  const SleepNeedsUpdateRow({super.key, this.host});

  /// The host that needs it, when it is one machine.
  final String? host;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Icon(LucideIcons.circleArrowUp, size: 20, color: t.warning),
          const SizedBox(width: 12),
          Expanded(child: Text(host == null ? l.slNeedsUpdate : l.slNeedsUpdateHost(host!), style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
