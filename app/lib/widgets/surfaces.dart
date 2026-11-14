// Tasarımın yüzeyleri: açık temada beyaz kart + yumuşak gölge, koyu temada buzlu cam.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class TCard extends StatelessWidget {
  const TCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = TiphysTokens.radiusCard,
    this.color,
    this.borderColor,
    this.onTap,
    this.semanticLabel,
    this.height,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Özel dolgu (ör. Claude kutusu). Verilmezse temanın kart rengi.
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final br = BorderRadius.circular(radius);
    Widget body = Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: br,
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
    final decoration = BoxDecoration(
      color: color ?? t.card,
      borderRadius: br,
      border: t.isDark ? Border.all(color: borderColor ?? t.cardBorder) : null,
      boxShadow: t.isDark
          ? null
          : const [
              BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
              BoxShadow(color: Color(0x0F3C3C5A), blurRadius: 24, offset: Offset(0, 8)),
            ],
    );
    body = Container(height: height, decoration: decoration, child: body);
    if (t.glass) {
      // Koyu cam: yarı saydam dolgu + kenar + üstte ince ışık çizgisi. Arkada yalnız yumuşak renk lekeleri
      // olduğundan BackdropFilter bulanıklığı görüntüyü neredeyse değiştirmiyor ama her karede kart başına
      // katman + bulanıklaştırma maliyeti getiriyordu (koyu temadaki takılmanın kaynağı). Bu yüzden yok.
      body = Stack(fit: StackFit.passthrough, children: [
        body,
        Positioned(
          left: radius / 2,
          right: radius / 2,
          top: 0,
          height: 1,
          child: const ColoredBox(color: Color(0x12FFFFFF)),
        ),
      ]);
    }
    if (semanticLabel != null) body = Semantics(label: semanticLabel, button: onTap != null, child: body);
    return body;
  }
}

/// Koyu temada camın arkasında görünen hafif renk lekeleri (host renkleri).
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child, this.colors = const []});
  final Widget child;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!t.isDark) return ColoredBox(color: t.background, child: child);
    final c = [...colors, const Color(0xFF7C74F0), const Color(0xFF50C896), const Color(0xFFF2A985)];
    Widget blob(Color color, double size, double opacity) => IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0)], stops: const [0, 0.7]),
            ),
          ),
        );
    return ColoredBox(
      color: t.background,
      child: Stack(children: [
        // Lekeler değişmez: kaydırma sırasında yeniden boyanmasın.
        Positioned.fill(
          child: RepaintBoundary(
            child: Stack(children: [
              Positioned(right: -90, top: 90, child: blob(c[0], 300, 0.55)),
              Positioned(left: -110, top: 330, child: blob(c[1], 280, 0.32)),
              Positioned(right: -60, bottom: -40, child: blob(c[2], 320, 0.28)),
            ]),
          ),
        ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

/// iOS tarzı gruplu liste bölümü.
class GroupedSection extends StatelessWidget {
  const GroupedSection({super.key, this.title, required this.children, this.footer});
  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) rows.add(Padding(padding: const EdgeInsets.only(left: 58), child: Divider(color: t.separator)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) SectionLabel(title!),
        TCard(padding: EdgeInsets.zero, radius: TiphysTokens.radiusList, child: Column(children: rows)),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(footer!, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final locale = Localizations.localeOf(context).languageCode;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Text(
          upper(text, locale),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textSecondary, letterSpacing: 0.4),
        ),
      ),
    );
  }
}

/// Türkçe büyük harf dönüşümü: i → İ (Dart'ın toUpperCase'i dile duyarlı değildir).
String upper(String s, String languageCode) =>
    languageCode == 'tr' ? s.replaceAll('i', 'İ').toUpperCase() : s.toUpperCase();

String lower(String s, String languageCode) =>
    languageCode == 'tr' ? s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase() : s.toLowerCase();

class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    required this.title,
    this.icon,
    this.iconBackground,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.onTap,
    this.external = false,
    this.showChevron = true,
    this.destructive = false,
    this.badge,
  });

  /// Turuncu uyarı rozeti (ör. eksik gizli bilgi sayısı).
  final String? badge;
  final String title;
  final IconData? icon;
  final Color? iconBackground;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool external;
  final bool showChevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            if (icon != null) ...[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: iconBackground ?? t.accent, borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, style: tt.titleMedium?.copyWith(color: destructive ? t.danger : t.text)),
                if (subtitle != null) Text(subtitle!, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (badge != null)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: t.warning, borderRadius: BorderRadius.circular(999)),
                child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            if (trailingText != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    trailingText!,
                    style: tt.bodyMedium?.copyWith(color: t.textSecondary, fontSize: 13.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ?trailing,
            if (onTap != null && showChevron && trailing == null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(external ? Icons.north_east_rounded : Icons.chevron_right_rounded,
                    size: external ? 16 : 20, color: t.isDark ? const Color(0xFF636366) : const Color(0xFFAEAEB2)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Büyük başlıklı sayfa: tarih/üst etiket + 34 px başlık + sağda yuvarlak buton.
class LargeTitleHeader extends StatelessWidget {
  const LargeTitleHeader({super.key, this.overline, required this.title, this.action});
  final String? overline;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final lang = Localizations.localeOf(context).languageCode;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (overline != null)
            Text(upper(overline!, lang),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textSecondary, letterSpacing: 0.4)),
          Semantics(header: true, child: Text(title, style: tt.displaySmall)),
        ]),
      ),
      ?action,
    ]);
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: TCard(
        radius: 14,
        padding: EdgeInsets.zero,
        onTap: onPressed,
        semanticLabel: tooltip,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 20, color: t.text)),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 9, this.square = false});
  final Color color;
  final double size;
  final bool square;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(square ? 3 : size)),
      );
}

Color hexColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));
