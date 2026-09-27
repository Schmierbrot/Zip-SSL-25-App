import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Farbpalette: reines Schwarz, graue Flächen, Rot als einziger Akzent.
abstract final class ZipColors {
  static const background = Color(0xFF000000);
  static const card = Color(0xFF1C1C1E);

  /// Minimal hellere Karte für aktive Zustände (z. B. eingeschaltetes Licht).
  static const cardActive = Color(0xFF232325);
  static const elevated = Color(0xFF2C2C2E);
  static const separator = Color(0xFF38383A);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF8E8E93);
  static const textTertiary = Color(0xFF48484A);

  static const accent = Color(0xFFFF3B30);
  static const accentDark = Color(0xFF8B1A15);

  /// Durchscheinender Hintergrund der Tab-Leiste (liegt über einem Blur).
  static const tabBar = Color(0xB3161618);
}

/// Abstände im 8er-Raster (16/24 als Standard).
abstract final class ZipSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double s = 12;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Seitlicher Rand aller Seiten.
  static const double page = 16;
}

abstract final class ZipRadii {
  static const double card = 20;
  static const double control = 12;
  static const double icon = 14;

  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(card));
}

/// Kurze, weiche Animationen.
abstract final class ZipMotion {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOutCubic;
}

/// Höhe der Inhaltszeile der Tab-Leiste (ohne Safe Area).
const double kZipTabBarHeight = 52;

/// Typografie auf Basis von Inter.
abstract final class ZipText {
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static TextStyle inter({
    double size = 17,
    FontWeight weight = FontWeight.w400,
    Color color = ZipColors.textPrimary,
    double? letterSpacing,
    double? height,
    bool tabular = false,
  }) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: tabular ? _tabular : null,
    );
  }

  /// Große dünne Zahl mit festen Ziffernbreiten, damit nichts springt.
  static TextStyle number(
    double size, {
    FontWeight weight = FontWeight.w300,
    Color color = ZipColors.textPrimary,
  }) => inter(
    size: size,
    weight: weight,
    color: color,
    tabular: true,
    height: 1.0,
    letterSpacing: -size * 0.02,
  );

  /// Kleine graue Beschriftung in Großbuchstaben, leicht gesperrt.
  static final TextStyle label = inter(
    size: 12,
    weight: FontWeight.w500,
    color: ZipColors.textSecondary,
    letterSpacing: 1.1,
  );

  static final TextStyle largeTitle = inter(size: 34, weight: FontWeight.w700, letterSpacing: 0.2);

  static final TextStyle title = inter(size: 20, weight: FontWeight.w600);
  static final TextStyle headline = inter(size: 17, weight: FontWeight.w600);
  static final TextStyle body = inter(size: 17);
  static final TextStyle bodySecondary = inter(size: 15, color: ZipColors.textSecondary);
  static final TextStyle caption = inter(size: 13, color: ZipColors.textSecondary);
  static final TextStyle footnote = inter(size: 13, color: ZipColors.textSecondary, height: 1.35);
}

ThemeData buildZipTheme() {
  const scheme = ColorScheme.dark(
    primary: ZipColors.accent,
    onPrimary: ZipColors.textPrimary,
    secondary: ZipColors.accent,
    onSecondary: ZipColors.textPrimary,
    error: ZipColors.accent,
    onError: ZipColors.textPrimary,
    surface: ZipColors.background,
    onSurface: ZipColors.textPrimary,
    surfaceContainerLowest: ZipColors.background,
    surfaceContainerLow: ZipColors.card,
    surfaceContainer: ZipColors.card,
    surfaceContainerHigh: ZipColors.elevated,
    surfaceContainerHighest: ZipColors.elevated,
    onSurfaceVariant: ZipColors.textSecondary,
    outline: ZipColors.textTertiary,
    outlineVariant: ZipColors.separator,
  );

  final base = ThemeData(brightness: Brightness.dark, colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: ZipColors.background,
    canvasColor: ZipColors.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    dividerColor: ZipColors.separator,
    textTheme: GoogleFonts.interTextTheme(base.textTheme)
        .apply(bodyColor: ZipColors.textPrimary, displayColor: ZipColors.textPrimary),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZipColors.elevated,
      elevation: 0,
      contentTextStyle: ZipText.inter(size: 15),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ZipColors.accent,
      linearTrackColor: ZipColors.elevated,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: ZipColors.accent,
      selectionColor: Color(0x66FF3B30),
      selectionHandleColor: ZipColors.accent,
    ),
    cupertinoOverrideTheme: const CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: ZipColors.accent,
      scaffoldBackgroundColor: ZipColors.background,
      barBackgroundColor: ZipColors.tabBar,
    ),
  );
}
