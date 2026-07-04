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

/// Screen transitions in the vault register (§6): fade + a small decelerating
/// rise — no zoom, no overshoot, spatial and calm. Honors reduced motion by
/// dropping the translation (opacity-only, §6 rule).
class KvPageTransitionsBuilder extends PageTransitionsBuilder {
  const KvPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: KvMotion.out);
    final fade = FadeTransition(opacity: curved, child: child);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return fade;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.03),
        end: Offset.zero,
      ).animate(curved),
      child: fade,
    );
  }
}

/// The app theme. Seeded from the real `primary` (this is where the D-027
/// `0xFF00E5C7` drift dies), then the design's exact tokens are pinned over the
/// generated tonal roles. Elevation is lightness + hairline border, never a
/// drop shadow (§3), so surface tint and shadows are zeroed.
///
/// Component themes carry the system so screens stay free of styling: buttons
/// (§9 heights, §9 radii), inputs (filled `surface-alt`, `primary` focus — §3
/// interactive-boundary rule), sheets/snackbars/dividers, and the §6 page
/// transition. Hierarchy: filled = primary action, tonal = secondary money
/// action, outlined = tertiary path, text = link (`primary-muted`, §3).
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
        // FilledButton.tonal reads these — the secondary money action.
        secondaryContainer: KvColor.surfaceAlt,
        onSecondaryContainer: KvColor.textPrimary,
        surface: KvColor.surface,
        onSurface: KvColor.textPrimary,
        surfaceContainerHighest: KvColor.surfaceAlt,
        onSurfaceVariant: KvColor.textSecondary,
        outline: KvColor.border,
        outlineVariant: KvColor.border,
        error: KvColor.error,
        onError: KvColor.abyss,
      );
  final text = kvTextTheme();
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(KvRadius.button),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: KvColor.abyss,
    canvasColor: KvColor.abyss,
    fontFamily: KvFont.ui,
    textTheme: text,
    splashColor: KvColor.glow,
    highlightColor: KvColor.glow,
    iconTheme: const IconThemeData(color: KvColor.textSecondary),
    appBarTheme: AppBarTheme(
      backgroundColor: KvColor.abyss,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: const IconThemeData(color: KvColor.textPrimary),
      // §4 section-title role, not M3's default titleLarge.
      titleTextStyle: text.titleMedium?.copyWith(color: KvColor.textPrimary),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const KvPageTransitionsBuilder(),
      },
    ),
    // Colours flow from the scheme (so filled stays primary and tonal stays
    // surface-alt); shape/size/type are pinned here once for both variants.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.control),
        shape: buttonShape,
        textStyle: text.titleMedium,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.control),
        shape: buttonShape,
        textStyle: text.titleMedium,
        foregroundColor: KvColor.textPrimary,
        // An outlined button's border IS its affordance — it must read (≥3:1,
        // §3), so it rides `primary-muted`, never the decorative hairline.
        side: const BorderSide(color: KvColor.primaryMuted),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.touchTarget),
        shape: buttonShape,
        foregroundColor: KvColor.primaryMuted, // links are muted teal (§3)
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KvColor.surfaceAlt,
      hintStyle: const TextStyle(color: KvColor.textTertiary),
      suffixIconColor: KvColor.textSecondary,
      suffixStyle: text.bodyLarge?.copyWith(color: KvColor.textSecondary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.m,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
        borderSide: const BorderSide(color: KvColor.border),
      ),
      // Focus carries meaning → `primary`, ≥3:1 (§3 hard rule).
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
        borderSide: const BorderSide(color: KvColor.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
        borderSide: const BorderSide(color: KvColor.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
        borderSide: const BorderSide(color: KvColor.error, width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
        borderSide: const BorderSide(color: KvColor.border),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: KvColor.border,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: KvColor.surfaceAlt,
      contentTextStyle: text.bodyMedium?.copyWith(color: KvColor.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
      ),
      actionTextColor: KvColor.primary,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KvColor.surface,
      modalBackgroundColor: KvColor.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: KvColor.border,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(KvRadius.card),
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: KvColor.textSecondary,
      textColor: KvColor.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KvColor.primaryMuted,
      linearTrackColor: KvColor.surfaceAlt,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: KvColor.surfaceAlt,
      side: const BorderSide(color: KvColor.border),
      labelStyle: text.bodyMedium?.copyWith(color: KvColor.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KvRadius.data),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: KvColor.glow,
        selectedForegroundColor: KvColor.primary,
        foregroundColor: KvColor.textSecondary,
        side: const BorderSide(color: KvColor.border),
      ),
    ),
  );
}
