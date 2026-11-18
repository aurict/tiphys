// Small pieces shared by the security screens: score badge, colored chip and the time formatting.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import 'security_data.dart';

Color securityBandColor(TiphysTokens t, SecurityBand b) => switch (b) {
      SecurityBand.good => t.success,
      SecurityBand.warn => t.warning,
      SecurityBand.bad => t.danger,
      SecurityBand.none => t.textSecondary,
    };

Color securitySeverityColor(TiphysTokens t, String severity) => switch (severity) {
      'critical' || 'high' => t.danger,
      'medium' => t.warning,
      _ => t.textSecondary,
    };

String securityWhen(BuildContext context, DateTime d) => DateFormat('d MMM HH:mm', Localizations.localeOf(context).toLanguageTag()).format(d);

/// Round badge with the score (0-100), colored by band; "—" without a score.
class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score, this.size = 52});
  final int? score;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = securityBandColor(t, securityBand(score));
    return Semantics(
      label: score == null ? l.secScoreNone : l.secScoreSemantic(score!),
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: 0.14), border: Border.all(color: c, width: 2)),
        child: Text(score == null ? '—' : '$score', style: TextStyle(color: c, fontSize: size * 0.38, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class SecChip extends StatelessWidget {
  const SecChip(this.text, this.color, {super.key, this.filled = false, this.icon});
  final String text;
  final Color color;

  /// Prominent: solid color with white text.
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: filled ? color : color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700))),
      ]),
    );
  }
}
