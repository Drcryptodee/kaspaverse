import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';

/// **The sheet** (§4, §3a.2) — the app's one floating layer, and one of BG-31's
/// exactly two `BackdropFilter` call sites.
///
/// It carries §1.8's stack in order: scrim, blur 6, [KvGlass.layerShadow], the
/// `plate` surface, and no glow. There is no modal and no toast in this app; a
/// confirmation is a sheet and an error is three beats in place.
///
/// **The foot never scrolls.** A sheet that can scroll its own primary action
/// out of reach is not a ceremony — the objection that made the signing surface
/// a full screen in the first place (D-221 §1). It is answered here rather than
/// waived: [foot] is laid out below [child] and outside its scroll, so the
/// control that commits is under the thumb at every text scale, and only the
/// restatement above it moves.
///
/// **It transforms with the window** (BG-33, §3a.2): full width with a 32 dp
/// top radius in `compact`; 560 wide, radius 32 on all four corners and 24 dp
/// above the bottom edge in `medium` and above.
class KvSheet extends StatelessWidget {
  const KvSheet({
    super.key,
    required this.child,
    this.title,
    this.onCancel,
    this.cancelLabel = 'Cancel',
    this.foot,
    this.onDismiss,
  });

  /// The restatement. Scrolls inside the sheet when it does not fit.
  final Widget child;

  /// `barTitle` (§2), left, with [cancelLabel] opposite it.
  final String? title;

  /// Null hides the cancel action — for a sheet whose only exit is its own
  /// control.
  final VoidCallback? onCancel;
  final String cancelLabel;

  /// Pinned below the scroll. See the class doc.
  final Widget? foot;

  /// Tapping the scrim. Null makes the sheet undismissible, which is what a
  /// broadcast in flight needs.
  final VoidCallback? onDismiss;

  /// §3: the grabber is 40 × 4 in [KvColor.edgeHi].
  static const Size grabber = Size(40, 4);

  /// The tallest a sheet may be, as a share of the window. `short` windows take
  /// the same fraction and scroll inside it (§3a.1).
  static const double maxHeightFraction = 0.9;

  @override
  Widget build(BuildContext context) {
    // The window, never a raw width (BG-33). `KvWindowMetrics` carries the
    // size it was derived from, so the sheet's height cap costs no second
    // `MediaQuery` read below the root.
    final w = KvWindow.of(context);
    final floating = w.sheetFloats;
    final reducedTransparency =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    final radius = floating
        ? BorderRadius.circular(KvRadius.plateHero)
        : const BorderRadius.vertical(top: Radius.circular(KvRadius.plateHero));

    final panel = Container(
      constraints: BoxConstraints(
        maxWidth: floating ? KvLayout.sheetFloatingWidth : double.infinity,
        maxHeight: w.size.height * maxHeightFraction,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: radius,
        boxShadow: KvGlass.layerShadow,
      ),
      clipBehavior: Clip.antiAlias,
      // **A transparent `Material` around the panel.** A sheet rides a route
      // of its own with no `Scaffold` above it, and without a `Material` every
      // `Text` inherits `WidgetsApp`'s deliberately-ugly fallback
      // `DefaultTextStyle` — which carries `TextDecoration.underline`. Every
      // `Kv*` style sets family, size, weight and colour and leaves
      // `decoration` alone, so it comes straight through: the exact defect the
      // drawer shipped with at UX-R1, one layer down.
      child: Material(
        type: MaterialType.transparency,
        // The sheet paints its own bottom padding; the system inset is added
        // to it rather than replacing it.
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: KvSpace.s10),
              Container(
                width: grabber.width,
                height: grabber.height,
                decoration: BoxDecoration(
                  color: KvColor.edgeHi,
                  borderRadius: BorderRadius.circular(grabber.height),
                ),
              ),
              if (title != null) _SheetHead(title!, onCancel, cancelLabel),
              Flexible(child: child),
              ?foot,
              const SizedBox(height: KvSpace.l),
            ],
          ),
        ),
      ),
    );

    final scrim = reducedTransparency
        // A user who asked for less glass gets less glass, not a lighter
        // version of it (§1.8).
        ? ColoredBox(
            color: KvColor.shelf.withValues(alpha: KvGlass.reducedScrimOpacity),
          )
        : BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: KvGlass.blurSigma,
              sigmaY: KvGlass.blurSigma,
            ),
            child: const ColoredBox(color: KvColor.sheetScrim),
          );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: scrim,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: floating ? KvLayout.sheetFloatingInset : 0,
            ),
            child: panel,
          ),
        ),
      ],
    );
  }
}

class _SheetHead extends StatelessWidget {
  const _SheetHead(this.title, this.onCancel, this.cancelLabel);

  final String title;
  final VoidCallback? onCancel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.l,
        KvSpace.s20,
        KvSpace.l,
        KvSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 18,
                height: 22 / 18,
                letterSpacing: -0.18,
                fontWeight: FontWeight.w700,
                fontVariations: KvWeight.w700,
                color: KvColor.ink,
              ),
            ),
          ),
          if (onCancel != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCancel,
              child: Semantics(
                button: true,
                child: Padding(
                  // A quiet text action still owns a 52 dp target (BG-12).
                  // 52 dp, measured — `s14` around an 18 dp line is 46
                  // (`ux-auditor`, UX-R2), and BG-12's floor does not bend
                  // because a control is quiet.
                  padding: const EdgeInsets.symmetric(
                    horizontal: KvSpace.sm,
                    vertical: KvSpace.s,
                  ),
                  child: Text(
                    cancelLabel,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 14,
                      height: 18 / 14,
                      fontWeight: FontWeight.w600,
                      fontVariations: KvWeight.w600,
                      color: KvColor.inkDim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The route a [KvSheet] arrives on: **transparent, so the page it covers stays
/// on screen and legible as *behind*** (§1.8 — that is the blur's only job).
///
/// It rises on [KvMotion.enter] with the scrim fading in step; a crossfade is
/// opacity and a sheet rise is a translate, and neither ever blurs (§1.8).
class KvSheetRoute<T> extends PageRoute<T> {
  KvSheetRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => KvMotion.enter;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: KvMotion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
