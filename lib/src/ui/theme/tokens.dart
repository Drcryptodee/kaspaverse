/// KaspaVerse design tokens — the single source for colour, motion, spacing,
/// radii and the freshness constants. `docs/research/design_system.md` v2
/// (D-027, DS-1…8) is the law; this file is its code form.
///
/// **This is the one file in `lib/` permitted to hold a raw colour hex** (the
/// P1.3 zero-freestyle-hex acceptance grep excludes it by name). Every other
/// widget imports these tokens and references them by name — it never writes a
/// `Color(0x…)` or a bespoke dp/duration. Extend the doc first, then this file,
/// then the widgets (flutter-ui-architect skill).
///
/// The type ramp (§4) is assembled in `kv_theme.dart` from these primitives.
library;

import 'package:flutter/material.dart';

/// §3 — Colour. Dark-only at P1 (OLED-true, vault-native). `#RRGGBB` ⇒
/// `Color(0xFFRRGGBB)`; alpha-bearing tokens encode `#RRGGBBAA` as `0xAARRGGBB`.
abstract final class KvColor {
  // Foundations — depth by surface lightness, never drop shadows (§3 hard rule).
  static const Color abyss = Color(0xFF0A0A0B); // true background
  static const Color surface = Color(0xFF111113); // elevated surface — cards
  static const Color surfaceAlt = Color(0xFF1A1A1E); // interiors, pressed fills
  static const Color border = Color(0xFF2A2A2F); // hairline borders

  // Dual teal — the Kaspa lineage (identity, not taste). primary = neon sign,
  // primaryMuted = ambient lighting; never interchangeable.
  static const Color primary = Color(0xFF49EACB); // CTAs, active, live data
  static const Color primaryMuted = Color(0xFF70C7BA); // links, badges, icons
  static const Color glow = Color(0x3349EACB); // #49EACB @ 20% — primary only

  // Text ramp — contrast verified on `abyss` (§3). Hierarchy is weight, not
  // colour (§4); these are presence levels, not a palette.
  static const Color textPrimary = Color(0xFFF0F0F2); // ~17:1 AAA (never #FFF)
  static const Color textSecondary = Color(0xFF8A8A95); // ~5.8:1 AA — support
  static const Color textTertiary = Color(0xFF7A7A85); // ~4.6:1 AA — meta/time
  static const Color textDisabled = Color(0xFF55555F); // decoration only

  // Semantic — meaning is rationed (§3). Each colour means exactly one thing.
  // success widened by founder directive (2026-07-11, V2b wrap): green =
  // "chain-confirmed OR healthy/active" — the live mainnet beacon and active
  // toggles wear it; teal stays the brand/CTA voice, never a health signal.
  static const Color success = Color(
    0xFF34D399,
  ); // chain-confirmed; healthy/active
  static const Color successGlow = Color(
    0x3334D399,
  ); // #34D399 @ 20% — live-dot glow
  static const Color warning = Color(0xFFFBBF24); // degraded: stale link
  static const Color error = Color(0xFFF87171); // fund risk + destruction only
  static const Color info = Color(0xFF60A5FA); // explanatory callouts

  // QR identity tile (DS-8/§8) — deliberately OUTSIDE the dark palette. A QR is
  // ALWAYS dark modules on a light tile regardless of theme: scanability is the
  // function, and a dark-themed QR defeats scanners. Pure black-on-white is the
  // maximum-contrast standard. Never themed, never inverted (D-045b).
  static const Color qrTile = Color(0xFFFFFFFF); // the light tile
  static const Color qrModule = Color(0xFF000000); // the dark modules

  // GlassPanel fill (§8) — 3% white over a σ16 backdrop blur; the frost, not a
  // surface. Solid fallback is [surfaceAlt] (same layout, lesser shimmer).
  static const Color glassFill = Color(0x08FFFFFF);
}

/// §9 — Spacing. 4 dp base grid; the only permitted steps. Screen gutter 24 dp.
abstract final class KvSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double sm = 12;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Screen edge gutter (§9; shipped at the home screen).
  static const double gutter = 24;

  /// Minimum touch target — Material, not HIG's 44 (§9, P1 §0.6 lock).
  static const double touchTarget = 48;

  /// Primary action (button) height — comfortably above the 48 dp law for the
  /// thumb-zone money actions (§9).
  static const double control = 56;
}

/// §9 — Corner radii. Cards/sheets 16 · buttons 12 · data blocks 8.
abstract final class KvRadius {
  static const double card = 16;
  static const double button = 12;
  static const double data = 8;
}

/// §6 — Motion. Decelerate-only in the vault register (DS-5): `out` is the
/// default; `spring` is arcade-only and must never touch keys or signatures.
abstract final class KvMotion {
  static const Duration instant = Durations.short2; // 100ms — state tint
  static const Duration fast = Durations.short4; // 200ms — tap feedback
  static const Duration normal = Durations.medium3; // 350ms — panel transitions
  static const Duration slow = Durations.long2; // 500ms — screen transitions
  static const Duration deliberate =
      Durations.extralong2; // 800ms — hold-to-sign

  /// One full live-dot breathing cycle (§6 v2.2) — a calm resting cadence
  /// (~20 breaths/min), consumed only by KvBreath (§8).
  static const Duration breath = Duration(milliseconds: 3000);

  /// Default vault easing — decelerate, no overshoot (DS-5).
  static const Curve out = Easing.emphasizedDecelerate;

  /// Symmetric transitions.
  static const Curve inOut = Curves.easeInOutCubicEmphasized;

  /// Overshoot — **arcade register only** (DS-5). Never near custody.
  static const Curve spring = Curves.easeOutBack;

  /// Entrance law (§6): elements arrive with `translateY(entranceOffset) +
  /// fade`, staggered [stagger] per element. Reduced motion ⇒ opacity-only.
  static const double entranceOffset = 24;
  static const Duration stagger = Duration(milliseconds: 75);
}

/// §8 — GlassPanel blur strength. At most ONE live blur per screen, never
/// inside a scrollable (saveLayer cost); the solid fallback needs no budget.
abstract final class KvGlass {
  static const double blurSigma = 16;
}

/// §8/DS-1 — Freshness. A chain-derived datum renders live, stale (dimmed +
/// age) or unknown (`—`); these are the stale boundary and the dim level.
abstract final class KvFreshness {
  /// `opacity-stale` (§8) — last-known data dims to this when stale.
  static const double opacityStale = 0.45;

  /// A datum with no fresh snapshot for longer than this reads as stale. At
  /// ~10 bps a multi-second silence is anomalous, not jitter (tuned for the
  /// on-device kill-the-network observation; DS-1 acceptance).
  static const Duration staleAfter = Duration(seconds: 5);
}

/// §4 — Font families (bundled assets, never runtime-fetched — DS-6). The two
/// permitted faces (§13: never more than two): Inter for UI, JetBrains Mono for
/// every amount, address, hash and score (monospace for trust, DS-2).
abstract final class KvFont {
  static const String ui = 'Inter';
  static const String mono = 'JetBrainsMono';
}
