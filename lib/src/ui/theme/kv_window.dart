/// §3a — Responsiveness (BG-33). **Layout transforms, never stretches.**
///
/// The one decision point for window shape in the whole app. [KvWindowClass]
/// and [KvHeightClass] are derived **once, at the app root**, and provided down
/// the tree; every widget reads the class from context and **never raw width**.
/// A `MediaQuery` or `LayoutBuilder` breakpoint inside a screen or a `Kv*`
/// widget is a BG-33 violation (`ux-auditor` item 24a), and Flutter's default
/// per-widget adaptive guessing is deliberately not used.
///
/// **Why a class and not a width.** A phone laid on its side is not a bigger
/// phone; it is a different window, and the design has already decided what
/// that window shows. Width decides **how many columns with jobs stand side by
/// side** — it never decides how big a figure, a control, a row or a gap is.
/// Type roles, control heights (56 / 52), the 44 dp icon button, the 64 dp row,
/// radii, discs, the halo and the hold's 800 ms are **fixed in every class**;
/// only the outer gutter and the column count change (§3a.2).
///
/// The Rust core is layout-blind: this is presentation, and nothing here
/// crosses the bridge.
library;

import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Width classes, from the width **available after any hinge split** (§3a.1).
enum KvWindowClass {
  /// `< 600` — every phone portrait: 360 budget phones, **412 LG V60
  /// (reference)**, 430 large phones. One column; the drawer *pushes*.
  compact,

  /// `600–839` — unfolded foldables (≈ 673–720), 7–8" tablets portrait. One
  /// centred column capped at [KvLayout.columnMax]; an 80 dp standing rail.
  medium,

  /// `840–1199` — tablets landscape, large tablets portrait, **phones in
  /// landscape by width**. Two columns; a standing drawer, opaque, no scrim.
  expanded,

  /// `≥ 1200` — ChromeOS, DeX, desktop windows. Two columns, the page clamped
  /// at [KvLayout.pageMax] and centred; a third column only if it has a job.
  wide,
}

/// Height classes, applied **after** width (§3a.1).
enum KvHeightClass {
  /// `≥ 480`. No effect.
  tall,

  /// `< 480` — phone landscape. The standing drawer demotes to the rail (seven
  /// rows do not seat in 412 dp) and the money plate collapses to `KvMoneyBar`.
  /// **Nothing else collapses.**
  short,
}

/// The resolved window, derived once at the root.
@immutable
class KvWindowMetrics {
  const KvWindowMetrics({
    required this.widthClass,
    required this.heightClass,
    required this.size,
    required this.hinge,
  });

  final KvWindowClass widthClass;
  final KvHeightClass heightClass;

  /// The size the classes were derived from — **available**, already reduced by
  /// a hinge split where one exists.
  final Size size;

  /// The hinge band in local coordinates, when `displayFeatures` reports one.
  /// **No control, figure or address may sit across it** (BG-33).
  final Rect? hinge;

  /// The outer gutter for this class: 24 · 32 · 40 · 48 (§3a.2).
  double get gutter => KvLayout.gutters[widthClass.index];

  /// `true` where the layout puts two columns side by side.
  bool get isTwoPane =>
      widthClass == KvWindowClass.expanded || widthClass == KvWindowClass.wide;

  /// `true` where the drawer stands rather than pushes — and is not demoted to
  /// the rail by a short window.
  bool get hasStandingDrawer => isTwoPane && heightClass == KvHeightClass.tall;

  /// `true` where navigation is the 80 dp rail: `medium` at any height, and
  /// `expanded`+ when the window is too short to seat the drawer's rows.
  bool get hasRail =>
      widthClass == KvWindowClass.medium ||
      (isTwoPane && heightClass == KvHeightClass.short);

  /// `true` where the drawer pushes the page and an edge-swipe summons it.
  /// **`compact` only** (§3a.2).
  bool get drawerPushes => widthClass == KvWindowClass.compact;

  /// The money plate collapses to `KvMoneyBar` in a short window, and only
  /// there.
  bool get collapseMoneyPlate => heightClass == KvHeightClass.short;

  /// A sheet floats (560 wide, all four corners, inset from the bottom) in
  /// every class above `compact`; in `compact` it is a full-width bottom sheet.
  bool get sheetFloats => widthClass != KvWindowClass.compact;

  /// The width one content column actually gets: never more than
  /// [KvLayout.columnMax], and never wider than the gutters allow.
  double get columnWidth =>
      (size.width - gutter * 2).clamp(0.0, KvLayout.columnMax);

  /// The page's own width: clamped at [KvLayout.pageMax] and centred beyond it.
  double get pageWidth => size.width.clamp(0.0, KvLayout.pageMax);

  /// Whether [rect] straddles the hinge band. A control, figure or address for
  /// which this is `true` is a BG-33 finding.
  bool straddlesHinge(Rect rect) {
    final h = hinge;
    return h != null && rect.left < h.right && rect.right > h.left;
  }

  /// Derive the classes from a raw size and the platform's display features.
  ///
  /// **The hinge is applied first**: on a folded device the *available* width
  /// is one pane's, not the panel's, so a 1768 dp foldable reports `compact`
  /// per pane rather than `wide` across the fold.
  factory KvWindowMetrics.from(Size size, List<DisplayFeature> features) {
    final hinge = _hingeOf(size, features);
    var available = size.width;
    if (hinge != null && hinge.width > 0) {
      // Vertical hinge: the widest pane either side of the band is what a
      // column actually gets.
      final left = hinge.left;
      final right = size.width - hinge.right;
      available = left > right ? left : right;
    }
    return KvWindowMetrics(
      widthClass: _widthClassFor(available),
      heightClass: size.height < 480 ? KvHeightClass.short : KvHeightClass.tall,
      size: Size(available, size.height),
      hinge: hinge,
    );
  }

  static KvWindowClass _widthClassFor(double width) {
    if (width < 600) return KvWindowClass.compact;
    if (width < 840) return KvWindowClass.medium;
    if (width < 1200) return KvWindowClass.expanded;
    return KvWindowClass.wide;
  }

  /// A vertical hinge or fold that actually separates two panes. A flat,
  /// fully-open posture reports a feature with no obscured band and is not a
  /// split.
  static Rect? _hingeOf(Size size, List<DisplayFeature> features) {
    for (final f in features) {
      final isSeparator =
          f.type == DisplayFeatureType.hinge ||
          f.type == DisplayFeatureType.fold;
      if (!isSeparator) continue;
      if (f.state == DisplayFeatureState.postureFlat && f.bounds.width == 0) {
        continue;
      }
      if (f.bounds.height >= size.height - 1) return f.bounds; // vertical split
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is KvWindowMetrics &&
      other.widthClass == widthClass &&
      other.heightClass == heightClass &&
      other.size == size &&
      other.hinge == hinge;

  @override
  int get hashCode => Object.hash(widthClass, heightClass, size, hinge);
}

/// Provides [KvWindowMetrics] to the tree. **Mount this once, at the app
/// root** — one derivation, one decision point (BG-33).
class KvWindow extends StatelessWidget {
  const KvWindow({super.key, required this.child});

  final Widget child;

  /// The window, or a `compact tall` default when no [KvWindow] is above —
  /// which is what a bare widget test gets, and is the phone case.
  ///
  /// **The fallback asserts in debug, and that is deliberate.** A default that
  /// is indistinguishable from a real `compact` reading is BG-8's own failure
  /// mode one layer down: an unmounted provider lays a tablet out as a phone,
  /// silently, with nothing raising — and the first migrated screen would be
  /// the one that discovered it, on a device. Release keeps the phone answer,
  /// because it is right for every shipped surface today; debug refuses to let
  /// it pass unnoticed. (`ux-auditor`, UX-R0.)
  static KvWindowMetrics of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_KvWindowScope>();
    assert(
      scope != null,
      'No KvWindow above this context. Mount KvWindow once at the app root '
      '(UX-R1) — reading the compact fallback here would lay a tablet out as '
      'a phone with nothing to raise the alarm (BG-33).',
    );
    return scope?.metrics ??
        const KvWindowMetrics(
          widthClass: KvWindowClass.compact,
          heightClass: KvHeightClass.tall,
          size: Size(412, 915),
          hinge: null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return _KvWindowScope(
      metrics: KvWindowMetrics.from(media.size, media.displayFeatures),
      child: child,
    );
  }
}

class _KvWindowScope extends InheritedWidget {
  const _KvWindowScope({required this.metrics, required super.child});

  final KvWindowMetrics metrics;

  @override
  bool updateShouldNotify(_KvWindowScope old) => old.metrics != metrics;
}
