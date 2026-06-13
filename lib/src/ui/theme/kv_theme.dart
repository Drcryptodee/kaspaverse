import 'package:flutter/material.dart';

import 'tokens.dart';

/// Assembles the KaspaVerse [ThemeData] and [TextTheme] from [KvColor] /
/// [KvFont] tokens. design_system.md §3 (colour) + §4 (type) is the law.
///
/// No raw colour hex lives here — only token references — so the P1.3
/// zero-freestyle-hex grep passes. Bioluminescent Vault, dark-only (P1).

/// One TextTheme slot. Variable fonts carry the weight on the `wght` axis;
/// [FontVariation] pins it precisely while [FontWeight] stays the semantic
/// hint (some platforms read one, some the other).
TextStyle _slot({
  required String family,
  required double size,
  required int weight,
  required double heightRatio,
  required double letterSpacing,
  bool mono = false,
}) {
  return TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: FontWeight.values[(weight ~/ 100) - 1],
    fontVariations: [FontVariation('wght', weight.toDouble())],
    height: heightRatio,
    letterSpacing: letterSpacing,
    // Monospace data never lets its digits jiggle as values tick (DS-2/§4).
    fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
  );
}

/// §4 — Roles → Material 3 TextTheme (dp, not rem). Headlines tighten to −2%
/// and ride a 1.15 line; body breathes at 1.5; mono data widens +0.02em.
/// Colour is intentionally absent — it inherits `onSurface` (= `text-primary`)
/// so hierarchy reads through weight, not colour (§4 rule).
TextTheme kvTextTheme() {
  return TextTheme(
    // Balance hero — the home number.
    displayMedium: _slot(
      family: KvFont.mono,
      size: 45,
      weight: 600,
      heightRatio: 1.15,
      letterSpacing: -0.90, // −2%
      mono: true,
    ),
    // Score / screen-level amount (shipped: DAA + sink blue scores).
    displaySmall: _slot(
      family: KvFont.mono,
      size: 36,
      weight: 600,
      heightRatio: 1.15,
      letterSpacing: -0.72, // −2%
      mono: true,
    ),
    // Screen title.
    headlineSmall: _slot(
      family: KvFont.ui,
      size: 24,
      weight: 700,
      heightRatio: 1.15,
      letterSpacing: -0.48, // −2%
    ),
    // Section / card title.
    titleMedium: _slot(
      family: KvFont.ui,
      size: 16,
      weight: 600,
      heightRatio: 1.5,
      letterSpacing: 0,
    ),
    // Amount in a list row.
    bodyLarge: _slot(
      family: KvFont.mono,
      size: 16,
      weight: 500,
      heightRatio: 1.5,
      letterSpacing: 0.32, // +0.02em
      mono: true,
    ),
    // Body copy.
    bodyMedium: _slot(
      family: KvFont.ui,
      size: 14,
      weight: 400,
      heightRatio: 1.5,
      letterSpacing: 0,
    ),
    // Address / hash / data.
    bodySmall: _slot(
      family: KvFont.mono,
      size: 12,
      weight: 400,
      heightRatio: 1.5,
      letterSpacing: 0.24, // +0.02em
      mono: true,
    ),
    // Label / meta / timestamp.
    labelSmall: _slot(
      family: KvFont.ui,
      size: 11,
      weight: 400,
      heightRatio: 1.5,
      letterSpacing: 0,
    ),
  );
}

/// The app theme. Seeded from the real `primary` (this is where the D-027
/// `0xFF00E5C7` drift dies), then the design's exact tokens are pinned over the
/// generated tonal roles. Elevation is lightness + hairline border, never a
/// drop shadow (§3), so surface tint and shadows are zeroed.
ThemeData kvDarkTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: KvColor.primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: KvColor.primary,
        onPrimary: KvColor.abyss,
        secondary: KvColor.primaryMuted,
        onSecondary: KvColor.abyss,
        surface: KvColor.surface,
        onSurface: KvColor.textPrimary,
        surfaceContainerHighest: KvColor.surfaceAlt,
        onSurfaceVariant: KvColor.textSecondary,
        outline: KvColor.border,
        outlineVariant: KvColor.border,
        error: KvColor.error,
        onError: KvColor.abyss,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: KvColor.abyss,
    canvasColor: KvColor.abyss,
    fontFamily: KvFont.ui,
    textTheme: kvTextTheme(),
    splashColor: KvColor.glow,
    highlightColor: KvColor.glow,
    appBarTheme: const AppBarTheme(
      backgroundColor: KvColor.abyss,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
  );
}
