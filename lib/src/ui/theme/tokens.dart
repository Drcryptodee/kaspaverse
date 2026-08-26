/// KaspaVerse design tokens — the single source for colour, motion, spacing,
/// radii and the freshness constants. The design-system record (internal),
/// **Black Glass · Machined Instrument** (D-185, BG-1…BG-14), is the law; this
/// file is its code form.
///
/// **This is the one file in `lib/` permitted to hold a raw colour hex** (the
/// P1.3 zero-freestyle-hex acceptance grep excludes it by name). Every other
/// widget imports these tokens and references them by name — it never writes a
/// `Color(0x…)` or a bespoke dp/duration. Extend the doc first, then this file,
/// then the widgets (flutter-ui-architect skill).
///
/// The type ramp (§2) is assembled in `kv_theme.dart` from these primitives.
///
/// **Names are owned here; values are owned by the design.** The export names
/// the ground token `void`, which is a Dart reserved word — it lands as
/// [KvColor.abyss], which carries the same meaning. Legacy names that widgets
/// still reference are kept as aliases onto their new role rather than
/// renamed, so a palette change is never also a refactor.
library;

import 'package:flutter/material.dart';

/// §1 — Colour. Dark-only, OLED-true. `#RRGGBB` ⇒ `Color(0xFFRRGGBB)`;
/// alpha-bearing tokens encode `#RRGGBBAA` as `0xAARRGGBB`.
///
/// **Every neutral is strictly R = G = B** (BG-3). The only tinted surfaces in
/// the system are named in the "deliberate exceptions" block at the bottom of
/// this class; anything else with a colour cast is a bug.
abstract final class KvColor {
  // ── Surfaces — depth is tone plus one honest edge, never a shadow (BG-4) ──
  //
  // Eight tones, one job each. Nearer is one step lighter; a recess goes one
  // step darker. The ground is literally off on OLED: the instrument floats in
  // nothing, which is the whole metaphor.

  /// The canvas — an absence, not a surface. (`void` in the design record.)
  static const Color abyss = Color(0xFF000000);

  /// Sunken entry: text fields, masked dots, word cells. Edge [hairline].
  static const Color well = Color(0xFF050505);

  /// A recessed alert/notice plate. Edge [noticeEdge].
  static const Color notice = Color(0xFF060606);

  /// **Every control that is not the one primary action.** Secondary buttons,
  /// input fields, chips — all of them sit at this one tone, deeper than the
  /// ground's plates rather than raised above them. A control that is not the
  /// primary action should read as a *recess you press into*, not as another
  /// plate competing with the surface it sits on; the primary action is the
  /// only thing on a screen that comes forward (D-194).
  static const Color control = notice;

  /// Chips, pills, activity rows, secondary controls. Edge [plateDivider] or
  /// [edgeHi].
  static const Color chip = Color(0xFF0A0A0A);

  /// A bounded, earned panel. Edge [plateEdge]. Containers are earned by a
  /// real grouping job, never by habit (BG-1).
  static const Color plate = Color(0xFF0C0C0C);

  /// Keypad keys, grid cells, word cells. Edge [keyEdge].
  static const Color key = Color(0xFF111111);

  /// A pressed key, an inline mono badge, a gauge track.
  static const Color keyPressed = Color(0xFF141414);

  /// Summoned layers — sheets, the nav panel's milled roadmap block.
  static const Color summoned = Color(0xFF161616);

  /// Legacy alias — the elevated surface widgets already ask for.
  static const Color surface = plate;

  /// Legacy alias — interiors and pressed fills.
  static const Color surfaceAlt = key;

  // ── Lines — non-text; a boundary gets a single 1dp rule only where it is
  // real (BG-4). WCAG 1.4.11's 3:1 floor governs any of these that carries
  // meaning; the purely decorative ones are exempt and are marked.

  /// Between activity or chat rows.
  static const Color rowDivider = Color(0xFF181818);

  /// A divider inside a plate.
  static const Color plateDivider = Color(0xFF1C1C1C);

  /// The resting hairline — the default edge.
  static const Color hairline = Color(0xFF1E1E1E);

  /// The edge of a notice plate.
  static const Color noticeEdge = Color(0xFF202020);

  /// **The datum line** — the engraved rule a key number sits on, like a
  /// gauge's zero mark. It gives the void structure without a container, and
  /// it is the system's signature move.
  static const Color datum = Color(0xFF212121);

  /// The edge of a [plate].
  static const Color plateEdge = Color(0xFF242424);

  /// The edge of a [key] or a frame.
  static const Color keyEdge = Color(0xFF262626);

  /// Nearer layers, a focused field, focus-adjacent strokes.
  static const Color edgeHi = Color(0xFF2A2A2A);

  /// The edge of a [summoned] block.
  static const Color summonedEdge = Color(0xFF2E2E2E);

  /// Decorative only — the tick before a section label, a dashed placeholder.
  static const Color tick = Color(0xFF3A3A3A);

  /// Legacy alias — the generic hairline border.
  static const Color border = keyEdge;

  // ── Ink — contrast measured on every surface it can land on (BG-14).
  // Hierarchy is weight and scale, never colour (BG-7).

  /// Primary text and every amount — never pure white. 17.94:1 on [abyss].
  static const Color ink = Color(0xFFEDEDED);

  /// A brighter secondary — nav panel row labels. 15.02:1 on [abyss].
  static const Color inkBright = Color(0xFFDADADA);

  /// Nav destination names, the wordmark, icon strokes. 10.13:1 on [abyss].
  static const Color inkNav = Color(0xFFB4B4B4);

  /// Secondary text, helper copy, the hero's fraction. 7.84:1 on [abyss].
  static const Color inkDim = Color(0xFF9E9E9E);

  /// Labels, timestamps, units, `PLANNED` tags. 6.08:1 on [abyss], 5.24:1 on
  /// [summoned] — the smallest tone that clears AA on every surface.
  static const Color inkMeta = Color(0xFF8A8A8A);

  /// The smallest information tone on the darker surfaces. 5.32:1 on [abyss],
  /// 4.58:1 on [summoned].
  static const Color inkMetaLow = Color(0xFF808080);

  /// **Decorative only — 3.04:1, below AA by design.** Glyph accents and
  /// disabled figures. It never carries information alone; a disabled control
  /// always says why, in [inkDim] words (BG-12).
  static const Color etch = Color(0xFF5A5A5A);

  /// Legacy aliases onto the ink ramp.
  static const Color textPrimary = ink;
  static const Color textSecondary = inkDim;
  static const Color textTertiary = inkMeta;
  static const Color textDisabled = etch;

  // ── Brand — the light (BG-2) ──
  //
  // Teal is emitted, not applied. At most three emissions per screen; a fill
  // only ever marks the one primary action. Only three things emit at all: a
  // lit lamp, the live cadence, and a filling sign ring. Emission is never
  // elevation, and teal is never a health signal.

  /// The light. 13.91:1 on [abyss]; text on a primary fill is [abyss] itself.
  static const Color primary = Color(0xFF49EACB);

  /// Ambient teal — links, quiet badges, decorative strokes. 10.57:1.
  static const Color primaryMuted = Color(0xFF70C7BA);

  /// `primary` @ 12% — emission, never elevation, never a material.
  static const Color glow = Color(0x1F49EACB);

  /// Ink on a [primary] fill.
  static const Color onPrimary = abyss;

  // ── Value & state (BG-7) — one hue, one meaning, always with sign + words ──
  //
  // Every meaning survives greyscale because colour never travels alone.
  // **Information has no hue**: a tip carries itself through type, weight,
  // position and a quiet outline glyph. There is no informational blue and no
  // fourth accent (founder directive, 2026-08-25).

  /// Money **arriving**, and things confirmed or final. 11.72:1 on [abyss].
  /// Narrowed from the 2026-07-11 "confirmed OR healthy/active" widening: the
  /// health job now belongs to the cadence and the connection line (D-185).
  static const Color ok = Color(0xFF7DD584);

  /// **Not yet certain** — stale, syncing, settling, degraded, and any block
  /// that needs checking. 10.61:1 on [abyss].
  static const Color warn = Color(0xFFE0B15C);

  /// Money **leaving**, or money at risk — outgoing amounts, destruction,
  /// irreversibility. **Never a validation nit.** 7.13:1 on [abyss].
  static const Color risk = Color(0xFFF26D5F);

  /// Legacy aliases onto the value set.
  static const Color success = ok;
  static const Color warning = warn;
  static const Color error = risk;

  // Lamp blooms — a 6dp dot under an 8dp blur with no spread. With the
  // cadence and the sign ring, these are the only simulated light in the app.
  // The lamp and its words carry the meaning; the plate stays plain, with only
  // its edge tinted to the same hue.

  /// `ok` @ 55%.
  static const Color okBloom = Color(0x8C7DD584);

  /// `warn` @ 55%.
  static const Color warnBloom = Color(0x8CE0B15C);

  /// `risk` @ 50%.
  static const Color riskBloom = Color(0x80F26D5F);

  /// Legacy alias.
  static const Color successGlow = okBloom;

  // ── Deliberate exceptions to the neutral ramp ──
  //
  // These four are the ONLY tinted surfaces in the system. Each is named here
  // so that "is this hue legitimate?" is answerable by grep rather than taste.

  /// The QR tile (BG-5). Always dark modules on a light tile regardless of
  /// theme: scannability is the function and a dark-themed QR defeats
  /// scanners. 18.37:1 measured. Never themed, never inverted (D-045b).
  static const Color qrTile = Color(0xFFF7F7F7);
  static const Color qrModule = Color(0xFF0B0B0B);

  /// My message field — teal mixed down to a quiet surface, not the light
  /// itself: a column of `primary` would shout over every button on screen.
  /// What survives is the lineage. `ink` 15.09:1, `inkDim` 6.59:1.
  static const Color messageMine = Color(0xFF0E1B18);
  static const Color messageMineEdge = Color(0xFF1E332E);

  /// Their message field — neutral raised. `ink` 15.87:1, `inkDim` 6.94:1.
  static const Color messageTheirs = Color(0xFF131313);
  static const Color messageTheirsEdge = keyEdge;

  /// A sunken panel INSIDE a bubble (a text attachment's body). Depth reads as
  /// darker-than-its-container, and it is the same on both sides because the
  /// panel is the file's content, not the speaker's voice.
  static const Color messageInset = abyss;

  /// The warning notice plate — a faintly warm fill behind a warm edge, the
  /// same move the lamp makes with its plate edge. `ink` 16.84:1, `warn`
  /// 9.97:1. Used for validation blocks, which are amber and never red: red
  /// would claim money is at risk when none is.
  static const Color noticeWarnFill = Color(0xFF0D0A0A);
  static const Color noticeWarnEdge = Color(0xFF3A2D1A);

  /// Subordinate ink on a [primary] fill — the exact fee printed on the
  /// control that spends it. 8.67:1 on `primary`.
  static const Color onPrimaryDim = Color(0xFF00382E);

  /// GlassPanel fill — 3% white over a σ16 backdrop blur; the frost, not a
  /// surface. **At most one live blur per screen** (BG-4), only under a
  /// summoned layer, never inside a scroll. Solid fallback is [summoned].
  static const Color glassFill = Color(0x08FFFFFF);
}

/// §3 — Spacing. 4 dp base grid; the only permitted steps. Screen gutter 24 dp.
abstract final class KvSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double sm = 12;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Screen edge gutter.
  static const double gutter = 24;

  /// Minimum touch target — Material, not HIG's 44 (BG-12, P1 §0.6 lock). A
  /// smaller *visual* is permitted inside a target this size; the target
  /// itself never shrinks.
  static const double touchTarget = 48;

  /// Minimum gap between two adjacent targets (BG-12).
  static const double touchGap = 8;

  /// Primary action (button) height — comfortably above the 48 dp law for the
  /// thumb-zone money actions.
  static const double control = 56;

  /// The top strip that belongs to the real system status bar. Nothing is
  /// ever painted here, and no status bar is ever drawn (BG-14).
  static const double statusBarReserve = 52;
}

/// §3 — Corner radii. Machined, not rounded: the form language is milled metal,
/// so every radius is small and deliberate.
abstract final class KvRadius {
  static const double chip = 4;
  static const double key = 5;
  static const double plate = 6;
  static const double panel = 8;
  static const double pill = 999;

  /// A message bubble; its tail corner tightens to [bubbleTail] on the last
  /// bubble of a run, which is the third way direction is carried.
  static const double bubble = 8;
  static const double bubbleTail = 3;

  /// **Controls are pills; surfaces are machined.** A radius this large would
  /// be wrong on a plate — a rounded panel reads as soft, and the form language
  /// is milled. On a *control* it does the opposite: it separates the things
  /// you press from the things you read, at a glance and without a second
  /// colour. Buttons, chips and input fields take this; plates never do (D-194).
  static const double control = pill;

  /// Legacy aliases.
  static const double card = panel;
  static const double button = panel;
  static const double data = plate;
}

/// §3 — Motion. **Decelerate only, no overshoot, ever** (BG-9).
abstract final class KvMotion {
  /// 80ms — a state tint.
  static const Duration instant = Duration(milliseconds: 80);

  /// 160ms — tap feedback.
  static const Duration fast = Duration(milliseconds: 160);

  /// 240ms — a panel or value transition.
  static const Duration calm = Duration(milliseconds: 240);

  /// 320ms — something arriving on screen.
  static const Duration enter = Duration(milliseconds: 320);

  /// **800ms — the hold-to-sign fill. A constant with no configuration
  /// surface.** Never shortened, including under reduced motion (BG-6/BG-9).
  static const Duration deliberate = Duration(milliseconds: 800);

  /// Legacy aliases.
  static const Duration normal = calm;
  static const Duration slow = enter;

  /// One full cadence cycle — the five bars breathing at block rhythm. It is
  /// both the liveness signal and the app's one loading indicator, and it
  /// freezes the instant the link dies (BG-8).
  static const Duration breath = Duration(milliseconds: 1100);

  /// Per-bar delay across the cadence meter.
  static const Duration cadenceStagger = Duration(milliseconds: 120);

  /// The one easing — `cubic-bezier(0.2, 0, 0, 1)`. Decelerating, no
  /// overshoot. There is no second curve; a spring anywhere in this app is a
  /// defect, including in the arcade register.
  static const Curve out = Cubic(0.2, 0, 0, 1);

  /// Entrance law: elements arrive with `translateY(entranceOffset)` + fade,
  /// staggered [stagger] per element. Reduced motion ⇒ opacity-only.
  static const double entranceOffset = 24;
  static const Duration stagger = Duration(milliseconds: 75);
}

/// §3 — GlassPanel blur strength. At most ONE live blur per screen, never
/// inside a scrollable (saveLayer cost); the solid fallback needs no budget.
abstract final class KvGlass {
  static const double blurSigma = 16;
}

/// BG-8 — Freshness. A chain-derived datum renders live, stale (dimmed + a
/// visible age) or unknown (`—`); these are the stale boundary and the dim
/// level. Dimmed cached truth beats a shimmer.
abstract final class KvFreshness {
  /// Last-known data dims to this when stale, and says how old it is.
  static const double opacityStale = 0.45;

  /// A datum with no fresh snapshot for longer than this reads as stale. At
  /// ~10 bps a multi-second silence is anomalous, not jitter (tuned for the
  /// on-device kill-the-network observation).
  static const Duration staleAfter = Duration(seconds: 5);

  /// A link that drops and returns inside this window never flips the glass
  /// (the engine's twin is `link::MIN_STRIKE_RUN_SECS`, 10 s): Wi-Fi
  /// re-association noise is not information, and a beacon that blinks on it
  /// teaches distrust. Strictly below [staleAfter], so the hold can never
  /// present stale data as live.
  static const Duration linkChurnGrace = Duration(seconds: 2);
}

/// §2 — Font families (bundled assets, never runtime-fetched). **Two faces,
/// never three**: Inter for UI, JetBrains Mono for every amount, address, hash,
/// timestamp and counter — always with tabular figures, so digits never shift
/// as values tick.
abstract final class KvFont {
  static const String ui = 'Inter';
  static const String mono = 'JetBrainsMono';
}

/// §2 — Glyphs. There is no icon package: every glyph is 1–3 strokes drawn
/// with `CustomPaint` on a 24 dp grid. This is a dependency decision (INV-7)
/// as much as a visual one.
abstract final class KvGlyph {
  static const double grid = 24;
  static const double stroke = 1.75;
  static const StrokeCap cap = StrokeCap.square;
}
