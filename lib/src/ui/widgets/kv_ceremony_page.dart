import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import 'kv_two_pane.dart';

/// **The shape every custody ceremony keeps**: a bar, a clamped column that
/// centres when there is room and scrolls when there is not, a pinned foot
/// inside the gutter, and a full-bleed slot under it for a pad.
///
/// **Why it is a part.** `create_screen` and `restore_screen` each carried a
/// private `_page` doing exactly this, character for character apart from the
/// bar each passes, and UX-R7 needed the same shape a third time for
/// `passphrase_unlock_screen`. Three ceremonies with three copies is the drift
/// BG-21 exists to stop, and the copies had already begun to diverge in their
/// comments while agreeing in their code — which is the state just before they
/// diverge in their code too.
///
/// **The bar is the caller's**, because that is the one thing the three do not
/// share: the create ceremony draws [KvSteps] in its bar, restore draws a
/// title and a back arrow, and the unlock screen draws a title alone. So is
/// the [SecretScreenGuard] wrapper — a page does not decide whether what it
/// holds is a secret, and a part that guarded some of its callers and not
/// others would be a guard sitting one layer above the artefact it protects
/// (L203).
class KvCeremonyPage extends StatelessWidget {
  const KvCeremonyPage({
    super.key,
    required this.bar,
    required this.children,
    this.foot,
    this.bleed,
    this.centred = false,
    this.onTapOutside,
  });

  /// The chrome at the top. Null for a ceremony with none.
  final Widget? bar;

  /// The body, laid out in a clamped column inside the class's gutter.
  final List<Widget> children;

  /// Pinned below the scroll, **inside** the column's gutter — because a pill
  /// IS content.
  final Widget? foot;

  /// **Rendered full-bleed, outside the content gutter.** [KvColumn] clamps to
  /// 560 and insets by the window class's gutter, which is right for a pill
  /// and wrong for a keyboard: the founder read the resulting strip of ground
  /// down each side of the pad as unfinished (UX-R6 glass beat). A keypad is
  /// chrome for the whole screen, not content inside the column — so it gets
  /// its own slot rather than the column's air.
  final Widget? bleed;

  /// **Centre the body in whatever room is left.** `O6` draws its mark and its
  /// question in the middle of the screen; the build stacked them at the top,
  /// which the founder read on glass as the content having fallen upward. A
  /// [SliverFillRemaining] with no scroll body centres when there is room and
  /// scrolls when there is not — the one idiom that does both without asking
  /// the layout for its height (BG-33 forbids reading a breakpoint here).
  final bool centred;

  /// **Tapping the body gives the keyboard back** (`O5`'s F18).
  ///
  /// A pad this app raises is a pad this app has to be able to lower, and the
  /// only gesture a user will try is tapping somewhere else. Null on every
  /// screen with no focus model, so the body stays inert rather than
  /// swallowing taps for a state that does not exist.
  final VoidCallback? onTapOutside;

  /// **§2's `display` rung, and its `short` step-down — one copy** (BG-21).
  ///
  /// This lived three times over, byte for byte, with a private `_short`
  /// beside each: `create_screen`, `restore_screen` and (as of UX-R7)
  /// `passphrase_unlock_screen`. The extraction of the page stopped at the
  /// page and left the type behind, which is how the *next* divergence starts
  /// — the `_heading()` wrappers around it have already drifted, and that one
  /// is noted for the register rather than changed here, because unifying it
  /// moves two shipped ceremonies' layout and that belongs on glass
  /// (`ux-auditor`, UX-R7).
  ///
  /// **The `short` arm is the chrome giving way, not a smaller mood.** At
  /// 915 × 412 the body is ~42 dp and a 34 dp line with a descender is cut at
  /// the fold — type clipped through its glyphs, which BG-14 refuses. The
  /// heading keeps its job at `barTitle`'s size.
  static TextStyle headingStyle(BuildContext context) =>
      KvWindow.of(context).heightClass == KvHeightClass.short
      ? const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 18,
          height: 22 / 18,
          fontWeight: FontWeight.w700,
          fontVariations: KvWeight.w700,
          letterSpacing: -0.18,
          color: KvColor.ink,
        )
      : const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 30,
          height: 34 / 30,
          fontWeight: FontWeight.w800,
          fontVariations: KvWeight.w800,
          letterSpacing: -0.75,
          color: KvColor.ink,
        );

  /// The heading itself — [headingStyle] on a line that takes the column's
  /// full width, so a centred one centres in the column and not in its own
  /// shrink-wrapped box (the column is `start`-aligned). One copy: UX-R7 left
  /// `create_screen` wrapping its centred heading at the call site and
  /// `restore_screen` wrapping every heading in its helper — the same
  /// composition two ways, which is the drift BG-21 names. UX-R8 seated it
  /// here, where the style already lived.
  static Widget heading(
    BuildContext context,
    String text, {
    TextAlign align = TextAlign.start,
  }) => SizedBox(
    width: double.infinity,
    child: Text(text, style: headingStyle(context), textAlign: align),
  );

  @override
  Widget build(BuildContext context) {
    final short = KvWindow.of(context).heightClass == KvHeightClass.short;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            ?bar,
            Expanded(
              child: KvColumn(
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      // **No air at `short`.** 48 dp of top-and-bottom padding
                      // is right on a phone and is more than the whole body at
                      // 915 × 412, where a bar, a pinned pill and a 220 dp
                      // keypad leave ~42: with it the heading scrolled out and
                      // the passphrase step said nothing about what it was
                      // asking for (`ux-auditor` BLOCK, UX-R6).
                      padding: EdgeInsets.symmetric(
                        vertical: short ? 0 : KvSpace.l,
                      ),
                      sliver: SliverFillRemaining(
                        hasScrollBody: false,
                        child: GestureDetector(
                          // `deferToChild`, not `opaque`: the fields and the
                          // switch inside must keep their own taps, and only
                          // the ground between them drops the keyboard.
                          behavior: HitTestBehavior.deferToChild,
                          onTap: onTapOutside,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: centred
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.start,
                            children: children,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // The keyboard is inside the column's gutter, not full-bleed:
            // `O7` seats its caps at x 29 against content at 25, which is
            // `KvKeypad`'s own 4 dp of side air and nothing more. A part
            // inside a clamped column owns no horizontal air of its own
            // (L195).
            if (foot != null) KvColumn(child: foot!),
            // **The pad arrives and leaves with motion** (BG-24). Three sites
            // changed it in one frame after D-312: F18 raising and dropping the
            // keyboard (236 dp), the `Next` pill vanishing on the pad switch,
            // and the number pad swapping for the alphanumeric one (236 → 248).
            // A 236 dp block appearing between two frames is exactly the
            // "section appears with no motion that accounts for it" this law
            // was written for (`ux-auditor`, D-312). Zero under
            // `disableAnimations`, like every other easing in this file.
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : KvMotion.calm,
              curve: KvMotion.curve,
              alignment: Alignment.topCenter,
              child: bleed ?? const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
