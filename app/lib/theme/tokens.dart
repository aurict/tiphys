// Design tokens: "6 · Porselen × Bento" (light) and the dark/glass theme.
// Source: https://claude.ai/artifact/DKZjow6F3R9nsRgQDJuura (Karma.dc.html, KarmaKoyu.dc.html)
import 'package:flutter/material.dart';

@immutable
class TiphysTokens extends ThemeExtension<TiphysTokens> {
  const TiphysTokens({
    required this.isDark,
    required this.background,
    required this.card,
    required this.cardBorder,
    required this.text,
    required this.textSecondary,
    required this.separator,
    required this.accent,
    required this.onAccent,
    required this.claudeTile,
    required this.claudeTileBorder,
    required this.claudeTileText,
    required this.claudeTileSubtext,
    required this.ringTrack,
    required this.success,
    required this.warning,
    required this.danger,
    required this.tabBar,
    required this.tabBarBorder,
    required this.tabActive,
    required this.tabActiveIcon,
    required this.tabIcon,
    required this.rowIconTerminal,
    required this.rowIconFiles,
    required this.rowIconHomepage,
    required this.glass,
    required this.chipBackground,
  });

  final bool isDark;
  final Color background;
  final Color card;
  final Color cardBorder;
  final Color text;
  final Color textSecondary;
  final Color separator;
  final Color accent;
  final Color onAccent;
  final Color claudeTile;
  final Color claudeTileBorder;
  final Color claudeTileText;
  final Color claudeTileSubtext;
  final Color ringTrack;
  final Color success;
  final Color warning;
  final Color danger;
  final Color tabBar;
  final Color tabBarBorder;
  final Color tabActive;
  final Color tabActiveIcon;
  final Color tabIcon;
  final Color rowIconTerminal;
  final Color rowIconFiles;
  final Color rowIconHomepage;

  /// In the dark theme cards are drawn as glass (translucent fill + border + light line).
  final bool glass;
  final Color chipBackground;

  static const radiusCard = 24.0;
  static const radiusHero = 26.0;
  static const radiusList = 22.0;
  static const gutter = 18.0;

  static const light = TiphysTokens(
    isDark: false,
    background: Color(0xFFF2F2F7),
    card: Color(0xFFFFFFFF),
    cardBorder: Color(0x00000000),
    text: Color(0xFF111114),
    textSecondary: Color(0xFF6C6C70),
    separator: Color(0xFFE5E5EA),
    accent: Color(0xFF4338CA),
    onAccent: Color(0xFFFFFFFF),
    claudeTile: Color(0xFF1E1B4B),
    claudeTileBorder: Color(0x00000000),
    claudeTileText: Color(0xFFFFFFFF),
    claudeTileSubtext: Color(0xFFC7D2FE),
    ringTrack: Color(0xFFEDEDF2),
    success: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    danger: Color(0xFFC62828),
    tabBar: Color(0xE6111114),
    tabBarBorder: Color(0x14FFFFFF),
    tabActive: Color(0xFFFFFFFF),
    tabActiveIcon: Color(0xFF111114),
    tabIcon: Color(0xFFA1A1AA),
    rowIconTerminal: Color(0xFF111114),
    rowIconFiles: Color(0xFF4338CA),
    rowIconHomepage: Color(0xFF6CCB9F),
    glass: false,
    chipBackground: Color(0xFFF2F2F7),
  );

  static const dark = TiphysTokens(
    isDark: true,
    background: Color(0xFF000000),
    card: Color(0x0FFFFFFF),
    cardBorder: Color(0x1FFFFFFF),
    text: Color(0xFFF5F5F7),
    textSecondary: Color(0xFF98989F),
    separator: Color(0xFF38383A),
    accent: Color(0xFFA5B4FC),
    onAccent: Color(0xFF111114),
    claudeTile: Color(0x4D5E5CE6),
    claudeTileBorder: Color(0x47A5B4FC),
    claudeTileText: Color(0xFFFFFFFF),
    claudeTileSubtext: Color(0xFFC7D2FE),
    ringTrack: Color(0xFF2C2C2E),
    success: Color(0xFF30D158),
    warning: Color(0xFFFFB340),
    danger: Color(0xFFFF6961),
    tabBar: Color(0x14FFFFFF),
    tabBarBorder: Color(0x29FFFFFF),
    tabActive: Color(0xFFF5F5F7),
    tabActiveIcon: Color(0xFF000000),
    tabIcon: Color(0xFF8E8E93),
    rowIconTerminal: Color(0xFF3A3A3C),
    rowIconFiles: Color(0xFF5E5CE6),
    rowIconHomepage: Color(0xFF2F9E6A),
    glass: true,
    chipBackground: Color(0x14FFFFFF),
  );

  /// Host color is lightened a bit in the dark theme (so the stack and dots stand out on the black background).
  Color hostColor(Color base) => isDark ? Color.lerp(base, Colors.white, 0.18)! : base;

  @override
  TiphysTokens copyWith() => this;

  @override
  TiphysTokens lerp(TiphysTokens? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension TiphysTheme on BuildContext {
  TiphysTokens get tokens => Theme.of(this).extension<TiphysTokens>()!;
}
