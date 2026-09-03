import 'package:flutter/material.dart';

import 'tokens.dart';

/// Assembles the KaspaVerse [ThemeData] and [TextTheme] from [KvColor] /
/// [KvFont] tokens. design_system.md §1 (colour) + §2 (type) is the law.
///
/// No raw colour hex lives here — only token references — so the P1.3
/// zero-freestyle-hex grep passes. Black Glass · Machined Instrument,
/// dark-only (D-185).

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
    // Monospace data never lets its digits jiggle as values tick (BG-5/§2).
    fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
  );
}

/// §2 — Roles → Material 3 `TextTheme` (dp, not rem). Two faces and no third.
/// Every amount, address, hash, timestamp and counter is mono with tabular
/// figures. Colour is intentionally absent — it inherits `onSurface` (= [ink])
/// so hierarchy reads through weight and scale, never colour (BG-7).
TextTheme kvTextTheme() {
  return TextTheme(
    // balanceHero — the home number. 46/52, and its fraction is subordinate by
    // scale and tone, not by a different family.
    displayMedium: _slot(
      family: KvFont.mono,
      size: 46,
      weight: 600,
      heightRatio: 52 / 46,
      letterSpacing: -0.5,
      mono: true,
    ),
    // amountScreen — a screen-level amount. At signing this carries all eight
    // decimals (BG-6).
    displaySmall: _slot(
      family: KvFont.mono,
      size: 32,
      weight: 600,
      heightRatio: 38 / 32,
      letterSpacing: 0,
      mono: true,
    ),
    // screenTitle.
    headlineSmall: _slot(
      family: KvFont.ui,
      size: 22,
      weight: 600,
      heightRatio: 28 / 22,
      letterSpacing: -0.2,
    ),
    // button — names the action and its object (BG-11). Also the app bar.
    titleMedium: _slot(
      family: KvFont.ui,
      size: 15,
      weight: 600,
      heightRatio: 20 / 15,
      letterSpacing: 0,
    ),
    // The `button` role again, for TabBar's unselected label — same metrics as
    // titleMedium so a tab's two states differ by colour alone. Pinned because
    // "neither pinned nor unused" is how L115 happens.
    titleSmall: _slot(
      family: KvFont.ui,
      size: 15,
      weight: 600,
      heightRatio: 20 / 15,
      letterSpacing: 0,
    ),
    // sectionTitle — engraved, caps applied at the call site.
    labelLarge: _slot(
      family: KvFont.ui,
      size: 11,
      weight: 600,
      heightRatio: 16 / 11,
      letterSpacing: 1.6,
    ),
    // rowAmount — an amount in a list row. Direction sets the weight at the
    // call site: incoming 600, outgoing 400, internal unsigned 400 (BG-7).
    bodyLarge: _slot(
      family: KvFont.mono,
      size: 15,
      weight: 400,
      heightRatio: 20 / 15,
      letterSpacing: 0,
      mono: true,
    ),
    // body copy.
    bodyMedium: _slot(
      family: KvFont.ui,
      size: 15,
      weight: 400,
      heightRatio: 22 / 15,
      letterSpacing: 0,
    ),
    // address / hash / data.
    bodySmall: _slot(
      family: KvFont.mono,
      size: 13,
      weight: 500,
      heightRatio: 22 / 13,
      letterSpacing: 0,
      mono: true,
    ),
    // meta — labels and timestamps.
    labelSmall: _slot(
      family: KvFont.ui,
      size: 12,
      weight: 500,
      heightRatio: 16 / 12,
      letterSpacing: 0,
    ),
  );
}

/// Screen transitions (BG-9/§3): fade + a small decelerating
/// rise — no zoom, no overshoot, spatial and calm. Honors reduced motion by
/// dropping the translation (opacity-only — never the hold, BG-9).
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

/// The app theme. The `ColorScheme` is **constructed explicitly, never seeded**
/// — every role is a ramp token, so an unnamed role cannot exist (D-185; this
/// docstring described the banned practice as current until the wrap audit
/// caught it). Elevation is lightness + hairline border, never a
/// drop shadow (BG-4), so surface tint and shadows are zeroed.
///
/// Component themes carry the system so screens stay free of styling: buttons
/// (§3 heights and radii), inputs (sunk to `well`, with an **ink** focus ring —
/// teal would spend an emission, BG-2), sheets/snackbars/dividers, and the §3 page
/// transition. Hierarchy: filled = primary action, tonal = secondary money
/// action, outlined = a plain plate, text = link (`primaryMuted`, §1.5).
ThemeData kvDarkTheme() {
  final scheme = const ColorScheme(
    // EXPLICIT, never `fromSeed`. A seeded scheme generates ~30 roles and
    // every generated one is teal-cast — `primaryContainer` #005144 under a
    // FAB, `surfaceContainer` #1B211F under a menu. Those hexes exist in no
    // token file, so they evade the zero-freestyle-hex grep by being made at
    // runtime, and they falsify §1.6's claim that the four named exceptions
    // are the only tinted surfaces in the system (BG-3). Overriding a subset
    // is not enough: the roles nobody names are exactly the ones that bite.
    // Every role below is a ramp token, so an unnamed role cannot exist.
    brightness: Brightness.dark,

    // The light, and the one fill it is allowed (BG-2).
    primary: KvColor.primary,
    onPrimary: KvColor.onPrimary,
    // A *container* is a plate, not an emission — teal never fills one.
    primaryContainer: KvColor.chip,
    onPrimaryContainer: KvColor.ink,
    primaryFixed: KvColor.chip,
    primaryFixedDim: KvColor.key,
    onPrimaryFixed: KvColor.ink,
    onPrimaryFixedVariant: KvColor.inkDim,

    secondary: KvColor.primaryMuted,
    onSecondary: KvColor.onPrimary,
    secondaryContainer: KvColor.chip,
    onSecondaryContainer: KvColor.ink,
    secondaryFixed: KvColor.chip,
    secondaryFixedDim: KvColor.key,
    onSecondaryFixed: KvColor.ink,
    onSecondaryFixedVariant: KvColor.inkDim,

    // There is no third brand hue (BG-3), so the tertiary family is neutral
    // all the way down rather than left for the framework to invent one.
    tertiary: KvColor.inkDim,
    onTertiary: KvColor.onPrimary,
    tertiaryContainer: KvColor.chip,
    onTertiaryContainer: KvColor.ink,
    tertiaryFixed: KvColor.chip,
    tertiaryFixedDim: KvColor.key,
    onTertiaryFixed: KvColor.ink,
    onTertiaryFixedVariant: KvColor.inkDim,

    // The plate stays plain; the hue rides the words (BG-7/§1.5).
    error: KvColor.risk,
    onError: KvColor.onPrimary,
    errorContainer: KvColor.notice,
    onErrorContainer: KvColor.risk,

    // The surface ramp, in the order M3 expects: lowest is deepest.
    surface: KvColor.plate,
    onSurface: KvColor.ink,
    surfaceDim: KvColor.abyss,
    surfaceBright: KvColor.summoned,
    surfaceContainerLowest: KvColor.well,
    surfaceContainerLow: KvColor.chip,
    surfaceContainer: KvColor.plate,
    surfaceContainerHigh: KvColor.key,
    surfaceContainerHighest: KvColor.summoned,
    onSurfaceVariant: KvColor.inkDim,

    outline: KvColor.keyEdge,
    outlineVariant: KvColor.hairline,

    // Depth is tone plus one edge — never a shadow (BG-4). A scrim is the
    // one legitimate use of black-over-content, under a summoned layer.
    shadow: KvColor.abyss,
    scrim: KvColor.abyss,

    inverseSurface: KvColor.ink,
    onInverseSurface: KvColor.abyss,
    inversePrimary: KvColor.primary,

    // M3 tints elevated surfaces with this. Elevation does not exist here.
    surfaceTint: Colors.transparent,
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
    iconTheme: const IconThemeData(color: KvColor.inkDim),
    // **No `switchTheme`, and its absence is the decision** (D-206, retired
    // here at UX-3). It pinned a Material `Switch` in exactly `KvToggle`'s
    // colours — the same decision rendered twice, and the copy nothing could
    // ever use: `Switch` animates its thumb through `AnimationController`s
    // that consult no `disableAnimations` anywhere in the pinned SDK, so a
    // framework switch slides under reduced motion while BG-9 says everything
    // collapses to opacity. `KvToggle` is the app's only switch.
    //
    // Removing a component theme is the inverse of L115's trap and needs the
    // same proof: L115 is about a slot NO theme pins, so the framework picks.
    // Here nothing resolves this one — and the first version of this comment
    // claimed that on a `grep -rn 'Switch('` which **misses
    // `SwitchListTile(`**, while `history_fill_sheet.dart` was rendering one
    // in a release build (`ux-auditor`, this sitting: L121 again, and it is
    // why the pattern is now spelled out). The proof is
    // `grep -rnE 'Switch(List)?Tile?\(' lib/ test/`, and it returns only
    // `KvToggle`'s own call sites.
    //
    // The removal is also safe in the direction that matters: an unthemed
    // `Switch` resolves its selected track to `colorScheme.primary` — teal as
    // a status, which BG-2 forbids — so the next one to land arrives visibly
    // wrong rather than quietly correct.
    appBarTheme: AppBarTheme(
      backgroundColor: KvColor.abyss,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: const IconThemeData(color: KvColor.ink),
      // The §2 `button` role (`titleMedium`), not M3's default titleLarge.
      titleTextStyle: text.titleMedium?.copyWith(color: KvColor.ink),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const KvPageTransitionsBuilder(),
      },
    ),
    // Colours flow from the scheme (so filled stays primary and tonal stays
    // the chip plate); shape/size/type are pinned here once for both variants.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.control),
        shape: buttonShape,
        textStyle: text.titleMedium,
      ),
    ),
    // The tenth `labelLarge` consumer, found by the third audit pass. Only the
    // debug-gated dev panels use it today; pinned anyway, because the cost is
    // one line and the failure mode is silent (L115).
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(textStyle: text.titleMedium),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.control),
        shape: buttonShape,
        textStyle: text.titleMedium,
        foregroundColor: KvColor.ink,
        backgroundColor: KvColor.chip,
        // The secondary action is identified by its label (16.91:1 on `chip`),
        // not by its edge — teal there would spend an emission the screen has
        // already allocated to the one primary action (BG-2).
        side: const BorderSide(color: KvColor.edgeHi),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(KvSpace.touchTarget, KvSpace.touchTarget),
        shape: buttonShape,
        // PIN THIS. M3 defaults a TextButton's label to `labelLarge`, which in
        // this ramp is `sectionTitle` — 11dp engraved caps. An action label is
        // the §2 `button` role, and every button theme must say so explicitly.
        textStyle: text.titleMedium,
        foregroundColor: KvColor.primaryMuted, // links are muted teal (§1.5)
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KvColor.well,
      hintStyle: const TextStyle(color: KvColor.inkMeta),
      suffixIconColor: KvColor.inkDim,
      suffixStyle: text.bodyLarge?.copyWith(color: KvColor.inkDim),
      // The border is amber, so the words must be too — M3 would resolve this
      // from `colorScheme.error` and print risk-red inside an amber field.
      errorStyle: text.bodySmall?.copyWith(color: KvColor.warn),
      // Colour only — the focused label would otherwise go teal. Which FACE
      // these resolve is UX-6's call; it was mono before this diff too.
      labelStyle: const TextStyle(color: KvColor.inkMeta),
      floatingLabelStyle: const TextStyle(color: KvColor.inkDim),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.m,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.key),
        borderSide: const BorderSide(color: KvColor.hairline),
      ),
      // A focus ring must clear 3:1 against what surrounds it (WCAG 1.4.11).
      // The export's `hairlineHi` does not, and teal would spend an emission,
      // so focus rides bright neutral ink — 16.71:1 on a plate.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.key),
        borderSide: const BorderSide(color: KvColor.ink, width: 1.5),
      ),
      // A blocked field is AMBER, never red: red claims money is at risk, and
      // a validation nit puts nothing at risk (BG-7).
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.key),
        borderSide: const BorderSide(color: KvColor.warn),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.key),
        borderSide: const BorderSide(color: KvColor.warn, width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(KvRadius.key),
        borderSide: const BorderSide(color: KvColor.hairline),
      ),
    ),
    // ── The layer after the role sweep ──────────────────────────────────────
    // `primary` MUST stay teal, so these four cannot be fixed by pinning a role:
    // the component theme is the only place to say "not here". Each of these
    // was painting teal from a framework default that no call-site grep sees.

    // TabBar takes its label AND its indicator from `primary` (tabs.dart:2742,
    // :2745) — a teal fill marking a selection state, which BG-2 forbids.
    tabBarTheme: const TabBarThemeData(
      labelColor: KvColor.ink,
      unselectedLabelColor: KvColor.inkDim,
      indicatorColor: KvColor.edgeHi,
      dividerColor: KvColor.hairline,
    ),
    // The cursor, the selection and the focused label all resolve `primary`
    // (text_field.dart:1628/1630, input_decorator.dart:6043/6067). The focus
    // ring above already refused teal for costing an emission; these are the
    // unmade half of that same decision.
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: KvColor.ink,
      selectionColor: KvColor.edgeHi,
      selectionHandleColor: KvColor.ink,
    ),
    // A FAB defaults to elevation 6 and a 16dp radius (floating_action_button
    // .dart:778, :817) — a shadow BG-4 forbids, on a radius off the machined
    // 4/5/6/8 ramp.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: KvColor.chip,
      foregroundColor: KvColor.ink,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KvRadius.panel),
        side: const BorderSide(color: KvColor.edgeHi),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: KvColor.hairline,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: KvColor.summoned,
      contentTextStyle: text.bodyMedium?.copyWith(color: KvColor.ink),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KvRadius.button),
      ),
      actionTextColor: KvColor.primary,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KvColor.summoned,
      modalBackgroundColor: KvColor.summoned,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: KvColor.edgeHi,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(KvRadius.panel),
        ),
      ),
    ),
    // PIN THIS. ListTile resolves its title from `bodyLarge` and its subtitle
    // from `bodyMedium` by default (`list_tile.dart:1785/:1788`), and the D-185
    // ramp moved those two toward each other until they met at 15dp/w400 — so
    // the hierarchy on the destructive-actions menu collapsed to nothing. And
    // `textColor` is deliberately ABSENT: `list_tile.dart:935-937` stamps the
    // tile's effective colour over the subtitle's own, which would make a
    // dimmed `subtitleTextStyle` a silent no-op. Disabled tiles still grey both
    // lines through `theme.disabledColor` (`:880-886`).
    listTileTheme: ListTileThemeData(
      iconColor: KvColor.inkDim,
      titleTextStyle: text.titleMedium?.copyWith(color: KvColor.ink),
      subtitleTextStyle: text.labelSmall?.copyWith(color: KvColor.inkDim),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KvColor.primaryMuted,
      linearTrackColor: KvColor.key,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: KvColor.chip,
      side: const BorderSide(color: KvColor.edgeHi),
      labelStyle: text.labelSmall?.copyWith(color: KvColor.ink),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KvRadius.chip),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        // Same M3 `labelLarge` default as TextButton — pinned for the same reason.
        textStyle: text.titleMedium,
        selectedBackgroundColor: KvColor.keyPressed,
        selectedForegroundColor: KvColor.ink,
        foregroundColor: KvColor.inkDim,
        side: const BorderSide(color: KvColor.keyEdge),
      ),
    ),
  );
}
