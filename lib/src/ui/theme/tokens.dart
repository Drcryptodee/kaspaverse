/// KaspaVerse design tokens — the single source for colour, motion, spacing,
/// radii, layout classes and the freshness constants. The design-system record
/// (internal), **Deep V6** v4.2 (D-247; lifecycle and gauge by D-248), is the
/// law; this file is its code form.
///
/// **This is the one file in `lib/` permitted to hold a raw colour hex** (the
/// P1.3 zero-freestyle-hex acceptance grep excludes it by name). Every other
/// widget imports these tokens and references them by name — it never writes a
/// `Color(0x…)` or a bespoke dp/duration. Extend the doc first, then this file,
/// then the widgets (flutter-ui-architect skill).
///
/// The type ramp (§2) is assembled in `kv_theme.dart` from these primitives;
/// the window classes (§3a) live in `kv_window.dart` and read nothing here but
/// [KvLayout].
///
/// **`RevealActivity.kt` mirrors this palette by hand and must change in the
/// same commit** (§9.1). No gate lane compares them, and it is the seed-reveal
/// screen — a stale mirror means the most security-critical surface in the app
/// silently keeps the previous design system. `ux-auditor` item 16 is the only
/// check that exists.
///
/// **Names are owned here; values are owned by the design.** Legacy names that
/// widgets still reference are kept as aliases onto their new role rather than
/// renamed, so a palette change is never also a refactor. The alias block at
/// the foot of each class is **deleted by the sitting after the last screen
/// migrates** (Bible §9.8) — until then a screen still wearing Black Glass
/// compiles and renders Deep V6's nearest tone.
library;

import 'package:flutter/material.dart';

/// §1 — Colour. Dark-only, OLED-true. `#RRGGBB` ⇒ `Color(0xFFRRGGBB)`;
/// alpha-bearing tokens encode `#RRGGBBAA` as `0xAARRGGBB`.
///
/// **Every dark is teal-leaning; a pure grey is a defect** (BG-1, BG-3 — this
/// reverses v3.1's "every neutral is strictly R = G = B"). Every surface, line
/// and ink step carries the same slight teal cast on one lightness scale, so
/// `primary` reads as light the material emits rather than paint applied to it.
/// The only non-teal values in the system are the QR pair and the four value
/// hues with their tints.
abstract final class KvColor {
  // ── §1.1 Surfaces — five tones, one job each ──────────────────────────────
  //
  // Nearer is one step lighter. v3.1 had eight tones one step apart on black;
  // they could not be told apart and each needed its own edge. Five with a real
  // step between them, and radius and containment do the rest.

  /// Under the drawer; a disabled pill; the QR tile's error footprint ground.
  static const Color shelf = Color(0xFF060808);

  /// **The ground.** A glow pill at rest; the icon tile. (`void` in the design
  /// record — a Dart reserved word, so it lands under the name it always had.)
  static const Color abyss = Color(0xFF0A0D0D);

  /// Plates, row containers, sheets, keypad keys, fields, icon buttons,
  /// their-bubbles. **No edge on the ground**; [hairline] between rows inside.
  static const Color plate = Color(0xFF121717);

  /// Raised pills, chips, segmented thumb, lifted rows, a plate inside a sheet,
  /// the ring track, an inner card. No edge.
  static const Color chip = Color(0xFF1A2120);

  /// Pressed / hover of [chip]; a pressed ledger row; an unlit cadence bar.
  static const Color chipPressed = Color(0xFF212A29);

  // ── §1.2 Lines — demarcation, not structure ───────────────────────────────
  //
  // A control is identified by its text or its disc, never its boundary.

  /// Between rows inside one container; a divider inside a plate. White @ 7%.
  static const Color hairline = Color(0x12FFFFFF);

  /// The only drawn boundary: the icon tile's rim; a spec frame. 1.26:1 on
  /// [abyss] — it demarcates, it does not structure.
  static const Color plateEdge = Color(0xFF1E2626);

  /// An empty radio ring; a dashed placeholder; the sheet grabber; the
  /// segmented track edge if one is ever needed.
  static const Color edgeHi = Color(0xFF2A3433);

  /// The glow pill's resting border. White @ 12%.
  static const Color controlEdge = Color(0x1FFFFFFF);

  // ── §1.3 Ink — four steps, all cool ───────────────────────────────────────

  /// Titles, values, row titles, the wordmark, checkpoints. **Never pure
  /// white.** 17.79:1 on [abyss].
  static const Color ink = Color(0xFFF2F5F4);

  /// Body, sub-lines on [chip], quiet text actions, the middle of an address.
  static const Color inkDim = Color(0xFFA6B0AE);

  /// Labels, `caps`, times, units, the `kaspa:` scheme, an inactive tab,
  /// placeholders that are not information.
  ///
  /// **BG-14's one standing obligation: this may not carry information on
  /// [chip] (4.30) or [chipPressed] (3.86).** Inside a sheet's inner card every
  /// information-bearing sub-line is [inkDim].
  static const Color inkMeta = Color(0xFF7A8583);

  /// **Decorative only** — sleeping pill labels, field placeholders, empty
  /// radio rings, chevrons, masked dots. Carries no information anywhere.
  static const Color etch = Color(0xFF4B5553);

  // ── §1.5 Brand — two teals, a deliberate hierarchy ────────────────────────
  //
  // `primary` is what you press or what is alive; `primaryMuted` is who or what
  // is *ours*; `tealTint` is where ours sits.

  /// **Emits** (BG-2, counted — ≤3 per screen). The one primary pill per screen
  /// (ink [onPrimary]); the live dot; the caret; ghost text actions; the active
  /// tab underline; the armed edge and glyph of a glow pill; the orb disc.
  static const Color primary = Color(0xFF49EACB);

  /// Hover of [primary].
  static const Color primaryHover = Color(0xFF3DD9BB);

  /// Pressed of [primary].
  static const Color primaryPressed = Color(0xFF2FCBAD);

  /// **Carries** (uncounted). Avatars and socket glyphs, counts, the Paste
  /// chip, notice glyphs, links in prose, the bare mark below 28 dp, and **the
  /// orb's halo** — which is never [primary] (§1.8).
  static const Color primaryMuted = Color(0xFF70C7BA);

  /// **Surface** of teal: the avatar disc, my bubble, the hold badge's tint,
  /// the trust notice plate, a spec badge.
  static const Color tealTint = Color(0xFF0F2E28);

  /// A stroke on [tealTint]; an unlit chart bar; the drawer's active socket
  /// ring.
  static const Color tealTintEdge = Color(0xFF164A40);

  /// A glow pill's fill while armed — [abyss] lifted a hair toward teal.
  static const Color armed = Color(0xFF0B1715);

  /// Ink on a [primary] fill. 11.31:1.
  static const Color onPrimary = Color(0xFF06201B);

  // ── §1.6 Value — four hues, each with its tint ────────────────────────────
  //
  // The disc is the whole signal: a hue arrives as a 40 dp disc of its tint
  // with the glyph in the hue, and the container stays [plate]. No bloom, no
  // tinted edge, no tinted plate — except the amber notice plate.

  /// Arriving · **accepted** · switched on · link healthy · latency < 150 ms.
  static const Color ok = Color(0xFF7DD584);

  /// Surface of [ok].
  static const Color okTint = Color(0xFF0F2A1B);

  /// The check stroke and the toggle knob — ink that sits *on* [ok].
  static const Color okDeep = Color(0xFF0F2A1B);

  /// **Pending** · syncing · stale · check this · latency 150–400 ms.
  static const Color warn = Color(0xFFE0B15C);

  /// Surface of [warn]; the one tinted plate (the notice).
  static const Color warnTint = Color(0xFF2E2510);

  /// Body on [warnTint]. 10.98:1.
  static const Color warnInk = Color(0xFFF3D9A0);

  /// Leaving · at risk · remove · latency > 400 ms.
  static const Color risk = Color(0xFFF26D5F);

  /// Surface of [risk].
  static const Color riskTint = Color(0xFF33191A);

  /// **Past reversal — the terminal lifecycle rung, and nothing else** (D-248,
  /// BG-3's fourth hue).
  ///
  /// Spent on exactly three things: the `Settled` chip, the `Settled`
  /// graduation, and the burial track past 100. It is **never** a general
  /// status, a link state, a latency tier or an "info" colour, and **never the
  /// check** — [KvCheck] stays [ok] at every rung (BG-29), because the mark
  /// means *yes*, not *which rung*.
  ///
  /// Measured, not picked: 9.98:1 on [abyss] — between [ok] (10.89) and [warn]
  /// (9.86) — and AA on all five surfaces including [chipPressed] (7.52). Hue
  /// 206.8°, a full 38° off [primary] (168.4°), so it cannot be misread as the
  /// brand.
  static const Color settled = Color(0xFF7CC0F7);

  /// Surface of [settled]. 8.02:1 for [settled] on it.
  static const Color settledTint = Color(0xFF12243A);

  // ── §1.7 The other tinted surfaces ────────────────────────────────────────

  /// Scannability beats theming: dark on **white**, never themed. 19.51:1.
  static const Color qrTile = Color(0xFFFFFFFF);

  /// The QR's modules.
  static const Color qrModule = Color(0xFF0A0D0D);

  // ── §1.8 Atmosphere — the five slices, and nothing else uses them ─────────
  //
  // Order: scrim → blur → shadow → surface+border → glow. Plates, rows,
  // avatars, bubbles, lamps and figures have NO slice.

  /// Slice 1 under a sheet. `rgba(6,8,8,.55)`.
  static const Color sheetScrim = Color(0x8C060808);

  /// Slice 1 under the pushed page. `rgba(6,8,8,.45)`.
  static const Color drawerScrim = Color(0x73060808);

  /// Slice 5, inner ring of an armed control's glow. `rgba(73,234,203,.14)`.
  static const Color armedGlowRing = Color(0x2449EACB);

  /// Slice 5, outer bloom of an armed control's glow. `rgba(73,234,203,.25)`.
  static const Color armedGlowBloom = Color(0x4049EACB);

  /// Slice 3. `rgba(0,0,0,.55)` — floating layers only.
  static const Color layerShadow = Color(0x8C000000);

  // ── Legacy aliases (Bible §9.8) — deleted after the last screen migrates ──
  //
  // Every name a Black Glass screen still references, mapped to its Deep V6
  // successor. A screen that has not had its UX-R group sitting compiles and
  // renders the nearest correct tone rather than failing to build.

  /// @Deprecated — v3.1 sunken entry. Deep V6 sets a figure in a plate.
  static const Color well = plate;

  /// @Deprecated — v3.1 notice ground.
  static const Color notice = plate;

  /// @Deprecated — v3.1 keypad key.
  static const Color key = plate;

  /// @Deprecated — v3.1 pressed key.
  static const Color keyPressed = chip;

  /// @Deprecated — v3.1 summoned panel; the panel itself is retired (§4).
  static const Color summoned = plate;

  /// @Deprecated — v3.1 control ground. **Held identical to [notice]**, which
  /// is what it was in v3.1 (`control = notice`) and what `KvSurfaceTone.notice`
  /// still assumes: it is the tone every unmigrated control wears. Splitting the
  /// two here silently re-tones every legacy control — caught by
  /// `kv_widgets_test.dart`'s KvSurface law test, which is why that test exists.
  static const Color control = notice;

  /// @Deprecated — v3.1 generic surface.
  static const Color surface = plate;

  /// @Deprecated — v3.1 alternate surface.
  static const Color surfaceAlt = chip;

  /// @Deprecated — v3.1 row divider. Deep V6 has one line inside a container.
  static const Color rowDivider = hairline;

  /// @Deprecated — v3.1 plate divider.
  static const Color plateDivider = hairline;

  /// @Deprecated — v3.1 notice edge.
  static const Color noticeEdge = plateEdge;

  /// @Deprecated — v3.1 engraved datum line. The `datum` rule is gone (§1.2).
  static const Color datum = hairline;

  /// @Deprecated — v3.1 key edge.
  static const Color keyEdge = plateEdge;

  /// @Deprecated — v3.1 summoned edge.
  static const Color summonedEdge = edgeHi;

  /// @Deprecated — v3.1 gauge tick.
  static const Color tick = edgeHi;

  /// @Deprecated — v3.1 generic border.
  static const Color border = plateEdge;

  /// @Deprecated — v3.1 brightest ink step; Deep V6 has four.
  static const Color inkBright = ink;

  /// @Deprecated — v3.1 nav ink.
  static const Color inkNav = inkDim;

  /// @Deprecated — v3.1 fifth ink step.
  static const Color inkMetaLow = inkMeta;

  /// @Deprecated — v3.1 Material-ish alias.
  static const Color textPrimary = ink;

  /// @Deprecated — v3.1 Material-ish alias.
  static const Color textSecondary = inkDim;

  /// @Deprecated — v3.1 Material-ish alias.
  static const Color textTertiary = inkMeta;

  /// @Deprecated — v3.1 Material-ish alias.
  static const Color textDisabled = etch;

  /// @Deprecated — v3.1 semantic alias.
  static const Color success = ok;

  /// @Deprecated — v3.1 semantic alias.
  static const Color warning = warn;

  /// @Deprecated — v3.1 semantic alias.
  static const Color error = risk;

  /// @Deprecated — blooms are retired (§1.6); exactly two things glow (BG-32).
  static const Color okBloom = okTint;

  /// @Deprecated — see [okBloom].
  static const Color warnBloom = warnTint;

  /// @Deprecated — see [okBloom].
  static const Color riskBloom = riskTint;

  /// @Deprecated — see [okBloom].
  static const Color successGlow = okTint;

  /// @Deprecated — v3.1 teal glow; replaced by [armedGlowRing] and the halo.
  static const Color glow = armedGlowRing;

  /// @Deprecated — absorbed by [tealTint] (§10.2).
  static const Color messageMine = tealTint;

  /// @Deprecated — bubbles carry no edge in Deep V6 (§4).
  static const Color messageMineEdge = tealTintEdge;

  /// @Deprecated — their-bubbles are [plate] (§1.7).
  static const Color messageTheirs = plate;

  /// @Deprecated — bubbles carry no edge in Deep V6 (§4).
  static const Color messageTheirsEdge = plateEdge;

  /// @Deprecated — v3.1 message inset.
  static const Color messageInset = abyss;

  /// @Deprecated — the notice plate is [warnTint] itself (§1.6).
  static const Color noticeWarnFill = warnTint;

  /// @Deprecated — the notice plate carries no edge (§1.6).
  static const Color noticeWarnEdge = warnTint;

  /// @Deprecated — alias of [onPrimary] (§10.2).
  static const Color onPrimaryDim = onPrimary;

  /// @Deprecated — v3.1 frost fill. Glass floats, never sits (BG-31).
  static const Color glassFill = Color(0x08FFFFFF);
}

/// §3 — Spacing. 4 dp grid; the only permitted steps. Screen gutter **16 dp**
/// in `compact` (founder ruling 2026-09-04, D-261: the content stood too far
/// from the edges on a 360 dp phone and read as narrow; the plates now run
/// close to the glass).
abstract final class KvSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double s10 = 10;
  static const double sm = 12;
  static const double s14 = 14;
  static const double m = 16;
  static const double s20 = 20;
  static const double s22 = 22;
  static const double l = 24;
  static const double s28 = 28;
  static const double xl = 32;

  /// @Deprecated — not a Deep V6 step; nearest is [xl].
  static const double xxl = 48;

  /// Screen edge gutter in `compact`. Wider classes use [KvLayout.gutters].
  /// **16, not 24** (D-261): the intake render `S1 · Home` keeps 24 on a
  /// 393 dp frame, and on the 360 dp glass the same 24 left a column the
  /// founder read as narrow. Amended in the Bible (§3), not argued away here.
  static const double gutter = 16;

  /// Minimum touch target — **raised from 48 to 52 in v4.2** (BG-12). A
  /// smaller *visual* is permitted inside a target this size only if the code
  /// states it; the target itself never shrinks.
  static const double touchTarget = 52;

  /// Minimum gap between two adjacent targets (BG-12).
  static const double touchGap = 8;

  /// Primary action (button) height.
  static const double control = 56;

  /// The thumb-arc pair (Send / Receive) and secondary rows.
  static const double controlThumb = 52;

  /// An icon button's visual disc, inside a [touchTarget].
  static const double iconButton = 44;

  /// A row's height — **fixed in every window class** (BG-33). A tablet shows
  /// more rows, never smaller ones.
  static const double row = 64;

  /// The 40 dp disc that opens a row.
  static const double rowDisc = 40;

  /// The top strip that belongs to the real system status bar. Nothing is
  /// ever painted here, and no status bar is ever drawn in a spec frame
  /// (BG-14).
  static const double statusBarReserve = 52;
}

/// §3 — Corner radii. **Everything is round; the question is how round.**
/// v3.1's machined 4–8 dp language is retired.
abstract final class KvRadius {
  /// Every button, field, chip, tag, toggle, icon button, disc.
  static const double control = 999;

  /// Row containers, plates, settings groups.
  static const double plate = 28;

  /// Money plate, network plate, About header, a sheet's top, a frame.
  static const double plateHero = 32;

  /// The pushed page while the drawer is open (0 closed; animates).
  static const double page = 36;

  /// A plate inside a sheet; the QR tile; a text area.
  static const double inner = 22;

  /// The amber notice plate.
  static const double notice = 18;

  /// Keypad keys; the icon tile at 64 (27% of side).
  static const double key = 18;

  /// A lifted row's own rounding.
  static const double row = 14;

  /// A message bubble; its tail corner tightens to [bubbleTail].
  static const double bubble = 22;

  /// The tail corner of the last bubble in a run.
  static const double bubbleTail = 6;

  // ── Legacy aliases (Bible §9.8) ───────────────────────────────────────────

  /// @Deprecated — v3.1 pill; [control] is the name now.
  static const double pill = control;

  /// @Deprecated — v3.1 chip radius 4. Deep V6 chips are stadiums.
  static const double chip = control;

  /// @Deprecated — v3.1 panel radius 8.
  static const double panel = plate;

  /// @Deprecated — v3.1 card radius.
  static const double card = plate;

  /// @Deprecated — v3.1 button radius.
  static const double button = control;

  /// @Deprecated — v3.1 data radius.
  static const double data = inner;
}

/// §3 — Motion. **One curve, deceleration only, no overshoot.**
abstract final class KvMotion {
  /// The one curve. `Cubic(0.2, 0, 0, 1)`.
  static const Curve curve = Cubic(0.2, 0, 0, 1);

  /// A border, ink or fill tint — arming a glow pill.
  static const Duration fast = Duration(milliseconds: 160);

  /// A value change, a colour-tier change, a crossfade.
  static const Duration calm = Duration(milliseconds: 240);

  /// A sheet rising, the drawer push, page radius and shadow.
  static const Duration enter = Duration(milliseconds: 320);

  /// **The hold — linear, `AnimationBehavior.preserve`, never shortened and
  /// with no configuration surface** (BG-6).
  static const Duration deliberate = Duration(milliseconds: 800);

  /// The live dot: scale 1 → .7, opacity 1 → .55. One of exactly two ambient
  /// loops (BG-9).
  static const Duration pulse = Duration(milliseconds: 1600);

  /// The orb's halo, as a **round trip**. The other ambient loop.
  static const Duration breathe = Duration(milliseconds: breatheMs);

  /// [breathe] in milliseconds, so a caller that reverses can derive one leg as
  /// a `const` rather than restating 1600 (`kv_mark.dart`'s splash).
  static const int breatheMs = 3200;

  /// Entrance offset: fade + `translateY(24)`.
  static const double entranceOffset = 24;

  /// Entrance stagger between siblings.
  static const Duration stagger = Duration(milliseconds: 75);

  /// The drawer translates the page this far right.
  static const double drawerPush = 296;

  /// Streaming cadence for a chain counter (BG-18).
  static const Duration stream = Duration(seconds: 1);

  // ── Legacy aliases (Bible §9.8) ───────────────────────────────────────────

  /// @Deprecated — v3.1 name for [curve].
  static const Curve out = curve;

  /// @Deprecated — the 80 ms step is **retired** (BG-9); nearest is [fast].
  static const Duration instant = fast;

  /// @Deprecated — there are no toasts (§4).
  static const Duration toast = pulse;

  /// @Deprecated — v3.1 alias.
  static const Duration normal = calm;

  /// @Deprecated — v3.1 alias.
  static const Duration slow = enter;

  /// @Deprecated — retired with the five-bar loading cadence (§10.2).
  static const Duration breath = Duration(milliseconds: 1100);

  /// @Deprecated — retired with the five-bar loading cadence (§10.2).
  static const Duration cadenceStagger = Duration(milliseconds: 120);
}

/// §1.8 — Atmosphere constants. **Glass floats, it never sits** (BG-31): a
/// `BackdropFilter` exists at exactly two call sites in the app — under a sheet
/// and on the pushed page — and nowhere else.
abstract final class KvGlass {
  /// Sigma for both scrims. **6, not 16**: 16 read as frosted and hid the page
  /// the user had just left; 6 keeps it legible as *behind*, which is the only
  /// job the blur has.
  static const double blurSigma = 6;

  /// Under reduced transparency the blur is off and the scrim rises to this.
  static const double reducedScrimOpacity = 0.80;

  /// §1.8 `armedGlow` — `0 0 0 4px rgba(73,234,203,.14)` plus
  /// `0 0 24px rgba(73,234,203,.25)`. The armed edge of a glow pill, and one
  /// of exactly two things in the app that glow (BG-32).
  static const List<BoxShadow> armedGlow = [
    BoxShadow(color: KvColor.armedGlowRing, spreadRadius: 4),
    BoxShadow(color: KvColor.armedGlowBloom, blurRadius: 24),
  ];

  /// §1.8 `layerShadow` — `0 12px 32px rgba(0,0,0,.55)`. **A sheet only**: the
  /// drawer lost it by founder ruling (D-260), and nothing else in the app
  /// floats.
  static const List<BoxShadow> layerShadow = [
    BoxShadow(
      color: KvColor.layerShadow,
      blurRadius: 32,
      offset: Offset(0, 12),
    ),
  ];
}

/// §3a.3 — Layout constants (BG-33). **Widgets read [KvWindowClass], never raw
/// width**; these are the numbers that class resolves to. The class itself and
/// its provider live in `kv_window.dart`.
abstract final class KvLayout {
  /// A content column never exceeds this, in any window class.
  static const double columnMax = 560;

  /// A page never exceeds this; wider windows centre it.
  static const double pageMax = 1200;

  /// The list pane in a two-pane layout.
  static const double listPaneMin = 400;

  /// The list pane's upper bound.
  static const double listPaneMax = 480;

  /// The standing rail in `medium`.
  static const double rail = 80;

  /// The drawer, in all three postures.
  static const double drawer = 296;

  /// The gap between two columns — 24 in every class.
  static const double columnGap = 24;

  /// Outer gutter per width class: compact · medium · expanded · wide.
  static const List<double> gutters = [KvSpace.gutter, 32, 40, 48];

  /// A floating sheet's width in `medium` and above.
  static const double sheetFloatingWidth = 560;

  /// A floating sheet's inset from the bottom edge.
  static const double sheetFloatingInset = 24;

  /// The four spec frames a screen must be seen in before it is done (BG-33):
  /// 393 `compact` · 700 `medium` · 1180 `expanded` · 915 × 412 `expanded
  /// short`.
  static const List<Size> specFrames = [
    Size(393, 852),
    Size(700, 900),
    Size(1180, 800),
    Size(915, 412),
  ];
}

/// §1 — Freshness (BG-8). Stale dims and says its age; unknown renders `—`.
abstract final class KvFreshness {
  /// A stale reading dims to this.
  static const double opacityStale = 0.45;

  /// **The size at or above which the 45% dim is permitted** — and below which
  /// it is a BG-14 violation *(amended 2026-09-04, D-257; the collision was
  /// measured, not argued)*.
  ///
  /// BG-8 asks a stale reading to dim to [opacityStale]; BG-14 asks every
  /// information-bearing run to hold AA against the surface it lands on, and
  /// BG-14 is one of §0's four clauses that do not bend to taste. Composited on
  /// `plate`, the dim does this:
  ///
  /// | object | size | fresh | dimmed | bar | |
  /// |:--|--:|--:|--:|--:|:--|
  /// | balance figure | 48 | 16.49 | **4.22** | 3.0 | passes — large text |
  /// | ledger amount, in | 16 | 10.10 | **3.03** | 4.5 | fails |
  /// | ledger amount, out | 16 | 6.14 | **2.18** | 4.5 | fails |
  /// | row title | 15 | 16.49 | **4.22** | 4.5 | fails |
  /// | a `metaMono` time | 11 | 4.75 | **1.93** | 4.5 | fails |
  ///
  /// No opacity ≤ 1 rescues an `inkMeta` line: at full strength it is 4.75, so
  /// any multiply at all puts it under. **The dim is therefore a large-text
  /// device.** 18.66 is WCAG's own boundary between the 4.5 body bar and the
  /// 3.0 large-text bar, which is why it is this number and not a taste.
  ///
  /// A body-size live reading carries staleness the ways BG-8 already provides
  /// and BG-14 does not forbid: **the visible age**, the lamp going amber, and
  /// — for a counter — **stopping**, which BG-8 as amended names as the stale
  /// signal in its own right.
  static const double staleDimFloor = 18.66;

  /// How long a reading stays live without a refresh.
  static const Duration staleAfter = Duration(seconds: 5);

  /// Grace before a churning link is called stale.
  static const Duration linkChurnGrace = Duration(seconds: 2);
}

/// §2 — Font families (bundled assets, never runtime-fetched — BG-16).
/// **Two faces, never three, and they never trade jobs** (BG-30): Plus Jakarta
/// Sans speaks, JetBrains Mono counts. A unit beside a figure is Jakarta; mono
/// never carries a sentence. **Inter is removed.**
///
/// Both are variable; every slot pins `FontVariation('wght')` rather than
/// `FontWeight` — on a variable face the enum is a hint and the axis is the ink
/// (L150).
/// §2 — **a weight is TWO channels, and only one of them is ink.**
///
/// Both faces are variable. On a variable face `fontWeight:` is a *hint* and
/// `FontVariation('wght', …)` is what the rasteriser actually uses — and an
/// inline `TextStyle` merges over the ambient `DefaultTextStyle`, **inheriting
/// its `fontVariations`**. So a style that sets the enum and not the axis
/// declares a weight it does not paint.
///
/// **Measured again on the bundled Plus Jakarta Sans, 2026-09-04**, on the
/// widgets shipped that day: a `KvAmount` row at declared `w700` (incoming) and
/// one at declared `w500` (outgoing) rendered at **identical width, both at
/// axis 400** — so BG-26's weight channel, one of the four ways direction is
/// supposed to ride, did not exist. The enum alone measured 66.885 against
/// 68.326 with the axis set. That is [[L150]], and it is why these constants
/// exist rather than a helper function: they are `const`, so a `const
/// TextStyle` can carry one.
///
/// **Set both, always.** `fontWeight:` stays because the framework, the
/// semantics tree and every non-variable fallback read it.
abstract final class KvWeight {
  static const List<FontVariation> w400 = [FontVariation('wght', 400)];
  static const List<FontVariation> w500 = [FontVariation('wght', 500)];
  static const List<FontVariation> w600 = [FontVariation('wght', 600)];
  static const List<FontVariation> w700 = [FontVariation('wght', 700)];
  static const List<FontVariation> w800 = [FontVariation('wght', 800)];

  /// The axis list for a [FontWeight], for the one case a weight is chosen at
  /// run time (a ledger row's direction). Not `const`; prefer the constants.
  static List<FontVariation> of(FontWeight weight) => switch (weight.value) {
    <= 400 => w400,
    500 => w500,
    600 => w600,
    700 => w700,
    _ => w800,
  };
}

abstract final class KvFont {
  /// **Plus Jakarta Sans speaks** (§2, BG-30). Bundled, never fetched (BG-16).
  ///
  /// Landed 2026-09-03 (D-252) with its provenance checked: OFL 1.1 by Tokotype,
  /// fetched from google/fonts **and** the designer's own repo and found
  /// byte-identical — a compromise would have had to hit both. `fvar` carries
  /// one axis, `wght` 200–800 at default 400, which covers §2's 400–800 range.
  ///
  /// **Inter is gone from the bundle**, not merely unreferenced: an unused face
  /// is a third face waiting to be picked up by accident (§8, BG-30).
  static const String ui = 'PlusJakartaSans';

  static const String mono = 'JetBrainsMono';
}

/// §2a — Mark geometry. There is no icon package: every mark is a Lucide
/// outline redrawn with `CustomPaint` on the 24 dp grid (BG-16, BG-25, INV-7).
/// The set itself is the `KvGlyphSpec` enum in `widgets/kv_glyph.dart`.
abstract final class KvGlyphSpec {
  static const double grid = 24;

  /// **2.5 with round caps and joins** — Lucide's nominal 2 thins on the
  /// tinted dark. v3.1's 1.75 square is retired.
  static const double stroke = 2.5;

  /// Direction arrows inside a value disc.
  static const double strokeArrow = 2.75;

  /// The check inside [KvCheck] — a 12 dp glyph in a 22 disc reads thin below
  /// this.
  static const double strokeCheck = 3.5;

  /// Fingerprint and face at 46–56 dp, where the mark is illustrative.
  static const double strokeIllustrative = 2.25;

  static const StrokeCap cap = StrokeCap.round;
  static const StrokeJoin join = StrokeJoin.round;
}
