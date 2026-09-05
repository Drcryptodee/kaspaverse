import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **Promoted out of `signing_ceremony.dart` at UX-R3, not copied.**
///
/// The transaction detail's facts plate is the same object as the ceremony's:
/// `S9` measures its values ending at 347.75 dp, which is the receipt's own
/// right edge to a quarter of a pixel. A second private copy of this layout is
/// exactly how two funds surfaces start disagreeing about where a number sits
/// (L143), and the stack-when-tight rule below was earned in a floor frame —
/// it must not have to be earned twice.
///

/// **One grid, and every value ends on the same right edge.**
///
/// `S7` and `S8` were measured and they agree to a decimal: every value on the
/// card — the fee, what leaves, the name, the stamp, the status — ends at
/// 348.5 dp on the sheet and 347.5 dp on the receipt, with the labels on one
/// left edge. The founder's note said the same thing from the glass: *"let the
/// numbers move to the right edge instead of the position you put them so its
/// not clunky."*
///
/// **Why the old construction drifted.** It was a `Wrap` with
/// `spaceBetween`, chosen so a very wide figure could take a run of its own
/// instead of being squeezed under the 11 dp floor. That works for the squeeze
/// and fails for the alignment: the instant a value wrapped it became the only
/// child of its run, and `spaceBetween` start-aligns a lone child — so the
/// figure landed on the LEFT, under its own label.
///
/// This keeps both properties. The label is `Expanded`, so it takes whatever
/// the value does not and wraps rather than pushing; the value is measured
/// against a share of the row and `KvAmount` fits itself inside that, keeping
/// its unit outside the fit so the 11 dp floor survives. The value cannot
/// drift left because it is the last child of a full-width row.
class KvFactLine extends StatelessWidget {
  const KvFactLine({
    super.key,
    required this.label,
    required this.value,
    this.valueText,
    // `S7` draws `Network fee` and `Leaves your wallet` both inline at the
    // reference width; 0.62 stacked the second of them there (`ux-auditor`,
    // measured off the 393 frame). 0.45 restores the render's grid and still
    // leaves a whole-supply figure room to fit itself.
    this.valueShare = 0.45,
    this.strongLabel = false,
    this.labelColor,
    this.dense = false,
  });

  /// **The compact density** (D-278): 10 % off the row's air and its type,
  /// for a screen whose whole content must stand in one view. The floors do
  /// not scale with it — 11 dp of type and a 52 dp target are BG-14 and BG-12
  /// and neither bends to a fit.

  final String label;
  final Widget value;

  /// **What [value] will print, for MEASUREMENT only.**
  ///
  /// A widget's intrinsic width cannot be asked for before layout, and the row
  /// has to decide its arrangement before it lays anything out — so the caller
  /// that knows the string hands it over. It is never rendered from here, so a
  /// small inaccuracy costs a stack-or-not decision and never a wrong figure.
  ///
  /// Null means "assume it fits": the row then only protects the label.
  final String? valueText;

  /// The most of the row the value may take before it starts fitting itself
  /// down. The label wraps into the rest.
  final double valueShare;

  /// `Leaves your wallet` is the row a user must not miss (`S7` sets it in
  /// `ink` at 600 while its neighbours stay `inkDim`).
  final bool strongLabel;

  /// The label's tone, where the ground allows a quieter one. `S9` measures
  /// its labels at `inkMeta` (122,133,131) on `plate`, where it is 4.75:1;
  /// the default stays `inkDim` because the ceremony's rows live on a `chip`
  /// inner card, where `inkMeta` is 4.30 and under AA (§1.4, BG-14). The
  /// caller that knows its ground says so; nothing here guesses it.
  final Color? labelColor;

  final bool dense;

  TextStyle get _labelStyle => TextStyle(
    fontFamily: KvFont.ui,
    fontSize: dense ? 12 : 13,
    height: dense ? 17 / 12 : 19 / 13,
    // A fact's label carries a little weight — 500, the founder's own bar
    // on glass (2026-09-05): *Sent · To · Network fee · Transaction ID* and
    // the connection card's rows, all at once from here.
    fontWeight: strongLabel ? FontWeight.w600 : FontWeight.w500,
    fontVariations: strongLabel ? KvWeight.w600 : KvWeight.w500,
    color: strongLabel ? KvColor.ink : (labelColor ?? KvColor.inkDim),
  );

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? KvSpace.s10 : KvSpace.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // **What the label needs to stay one word.** Measured, not guessed:
          // at 320 dp / 1.3× the value's share left `Accepted` about 70 dp,
          // which is under the width of the word — so Flutter did the only
          // thing left and broke it, rendering `Accepte` over `d` on a
          // receipt (found in the floor frame, not argued).
          final painter = TextPainter(
            text: TextSpan(text: label, style: _labelStyle),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout();
          final needed = painter.maxIntrinsicWidth;
          painter.dispose();
          final room = width * (1 - valueShare) - KvSpace.m;

          final text = Text(label, style: _labelStyle);
          // **The value gets everything the label does not need**, floored at
          // its share so a long label cannot starve it either way.
          //
          // A flat `width * valueShare` was wrong in both directions and the
          // suite caught the second: at 0.62 it stacked `Leaves your wallet`
          // at the 393 reference where `S7` draws it inline; tightened to 0.45
          // it scaled a whole-supply figure to **6.71 dp** at 320 dp / 1.3×,
          // under BG-14's floor, because the share was capping a value the
          // short label beside it was not using.
          final valueRoom = math.max(
            width * valueShare,
            width - needed - KvSpace.m,
          );
          final bounded = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: valueRoom),
            child: value,
          );

          // **And the VALUE gets the same protection as the label.** A figure
          // that cannot fit beside its label scales itself down, and nothing
          // bounded that shrink: at 320 dp / 1.3× a whole-supply amount beside
          // `Returns to you` rendered at **7.34 dp**, under BG-14's floor. So
          // the row asks whether the figure fits in the room it would get, and
          // stacks when it does not — where it gets the whole width and needs
          // no scaling at all.
          var valueFits = true;
          final printed = valueText;
          if (printed != null) {
            final vp = TextPainter(
              text: TextSpan(
                text: printed,
                style: TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: dense ? 12 : 13,
                ),
              ),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            )..layout();
            valueFits = vp.width <= valueRoom;
            vp.dispose();
          }

          // **Tight: stack, and keep the right edge.** Wrapping the label into
          // a column beneath is what the space allows; what must NOT change is
          // where the value sits, because one right edge down the card is the
          // whole point of this widget (`S7`/`S8` measured, founder's own
          // note). So the fallback is a column whose value is still hard
          // right, never a run that drifts back to the left.
          if (needed > room || !valueFits) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                text,
                const SizedBox(height: KvSpace.xs),
                Align(alignment: Alignment.centerRight, child: value),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: text),
              const SizedBox(width: KvSpace.m),
              bounded,
            ],
          );
        },
      ),
    );
  }
}
