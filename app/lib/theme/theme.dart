import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'tokens.dart';

const fontFamily = 'PlusJakartaSans';
const monoFamily = 'JetBrainsMono';

ThemeData buildTheme(TiphysTokens t) {
  final scheme = ColorScheme.fromSeed(
    seedColor: t.accent,
    brightness: t.isDark ? Brightness.dark : Brightness.light,
  ).copyWith(
    surface: t.background,
    onSurface: t.text,
    primary: t.accent,
    onPrimary: t.onAccent,
    error: t.danger,
    outline: t.separator,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: t.background,
    splashFactory: InkSparkle.splashFactory,
    extensions: [t],
    actionIconTheme: ActionIconThemeData(backButtonIconBuilder: (_) => const Icon(LucideIcons.chevronLeft)),
  );
  TextStyle s(double size, FontWeight w, {double spacing = 0, Color? color}) =>
      TextStyle(fontFamily: fontFamily, fontSize: size, fontWeight: w, letterSpacing: spacing, color: color ?? t.text);
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displaySmall: s(34, FontWeight.w800, spacing: -0.8),
      headlineSmall: s(21, FontWeight.w800, spacing: -0.4),
      titleLarge: s(20, FontWeight.w800, spacing: -0.3),
      titleMedium: s(15.5, FontWeight.w600),
      titleSmall: s(13, FontWeight.w700),
      bodyLarge: s(15.5, FontWeight.w500),
      bodyMedium: s(14, FontWeight.w500),
      bodySmall: s(12.5, FontWeight.w500, color: t.textSecondary),
      labelLarge: s(14, FontWeight.w700),
      labelMedium: s(12, FontWeight.w600, color: t.textSecondary),
      labelSmall: s(11, FontWeight.w600, color: t.textSecondary),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: t.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: s(17, FontWeight.w700),
    ),
    dividerTheme: DividerThemeData(color: t.separator, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.isDark ? const Color(0x14FFFFFF) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: t.separator)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: t.separator)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: t.accent, width: 2)),
      labelStyle: s(14, FontWeight.w600, color: t.textSecondary),
      hintStyle: s(14, FontWeight.w500, color: t.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        backgroundColor: t.isDark ? t.tabActive : const Color(0xFF111114),
        foregroundColor: t.isDark ? Colors.black : Colors.white,
        textStyle: s(15, FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: t.accent, textStyle: s(15, FontWeight.w600)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? t.success : t.ringTrack),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: t.isDark ? const Color(0xFF2C2C2E) : const Color(0xFF111114),
      contentTextStyle: s(14, FontWeight.w600, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.isDark ? const Color(0xFF1C1C1E) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.isDark ? const Color(0xFF1C1C1E) : t.background,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    ),
  );
}
