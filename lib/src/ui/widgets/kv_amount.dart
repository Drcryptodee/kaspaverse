import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/tokens.dart';

/// Where an amount sits on the §2 ramp.
enum KvAmountRole {
  /// The home balance. Mono 46/52 at weight 500. **Every significant decimal,
  /// trailing zeros trimmed** — see the precision law in the class doc.
  hero,

  /// A screen-level amount: the confirm sheet's headline, a detail's value.
  /// All eight decimals, because this is where commitment happens.
  screen,

  /// An amount in a ledger row. One mono run at 15, weight carrying direction,
  /// trailing zeros trimmed to two.
  row,
}

/// Which way the money is moving (BG-7). Direction rides **four ways at once**
/// — word, sign, colour and weight — so a row survives greyscale,
/// colour-blindness and a screen reader. The word is the caller's; the other
/// three are here.
enum KvMoneyDirection {
  /// Money arriving.
  incoming,

  /// Money leaving.
  outgoing,

  /// Neither — a balance, a fee, a self-send. Unsigned and colourless.
  internal,
}

/// BG-5 money, and the whole of it:
///
///  * **floors toward zero**, never rounds a balance up (via [kasParts]);
///  * **`—` when unknown** — never a fabricated zero;
///  * **`0.00000000` for a real zero** at [KvAmountRole.screen], and a real
///    zero at every role — a synced empty wallet is not unknown;
///  * **every significant decimal, and not one more** — the precision law
///    (founder, 2026-08-27). A balance shows each digit that carries value and
///    stops: `21.12345678` reads in full because the last digit is a digit;
///    `21.12345600` reads `21.123456`; `21.12340000` reads `21.1234`. Trailing
///    zeros are noise a user has to read past to find where the number ends,
///    and a truncation at a fixed width is worse — it hides value the wallet
///    holds.
///
///    **The ceiling is the UNIT's, not this widget's.** KAS carries eight
///    decimals, so eight is where KAS stops; a token that carries six stops at
///    six. The rule is "significant digits up to the unit's precision", which
///    is why it survives the token surface unchanged rather than needing a
///    second law written for it. A signing surface is the one exception and
///    keeps its fixed eight: BG-6 restates what was BUILT, and a trimmed
///    figure is a different string from the one that was signed;
///  * **a non-zero balance never renders as zero.** Where a caller pins a
///    fixed width that would erase the whole figure, the pin is lifted — a
///    concession to type size is not a licence to tell someone holding dust
///    that they hold nothing (`consensus-auditor`, UX-2);
///  * **scales down before it clips** — it never wraps, never ellipsizes and
///    never truncates a digit, at any text scale;
///  * mono and tabular, so a value that ticks does not jiggle;
///  * spoken naturally — *"plus 12.4 KAS"*, not digit soup.
///
/// Sizes resolve from the §2 ramp for the [role]. The fraction is 48% of the
/// integer and the unit 33%, **floored at 11dp** — the unit is information a
/// user must read, and 33% of the screen role would land under the floor.
///
/// The unit is [KvColor.primaryMuted]: ambient teal on structure, which is
/// **not an emission** and costs nothing against BG-2's cap of three (§1.5).
/// It is most of what makes the figure read as money rather than as telemetry.
class KvAmount extends StatelessWidget {
  const KvAmount(
    this.sompi, {
    super.key,
    this.role = KvAmountRole.hero,
    this.direction = KvMoneyDirection.internal,
    this.stale = false,
    this.size,
    this.fractionDigits,
    this.showUnit,
  });

  /// Non-negative balance in sompi. `null` means **not yet known** (BG-8).
  final BigInt? sompi;

  final KvAmountRole role;
  final KvMoneyDirection direction;

  /// Dims to [KvFreshness.opacityStale]. BG-8 also requires a **visible age**
  /// beside a dimmed reading — that belongs to the line that vouches for the
  /// number, not to the number itself.
  final bool stale;

  /// Overrides the ramp size for a composition that needs one (the plated
  /// balance reads one step down from the ramp because the unit now sits
  /// beside the figure instead of under it — D-191).
  final double? size;

  /// Fixed count of fractional digits. Null trims trailing zeros to a minimum
  /// of two. Defaults per role: hero **4**, screen **8**, row trimmed.
  final int? fractionDigits;

  /// Null shows the unit on [KvAmountRole.hero] and [KvAmountRole.screen], and
  /// hides it in a row, where the column heading carries it.
  final bool? showUnit;

  /// Fraction and unit as a share of the integer's size.
  static const double fractionRatio = 0.48;
  static const double unitRatio = 0.33;

  /// 11dp is the floor for anything a user must read (§2/BG-14).
  static const double readableFloor = 11;

  static double _rampSize(KvAmountRole role) => switch (role) {
    KvAmountRole.hero => 46,
    KvAmountRole.screen => 32,
    KvAmountRole.row => 15,
  };

  Color get _tone => switch (direction) {
    KvMoneyDirection.incoming => KvColor.ok,
    KvMoneyDirection.outgoing => KvColor.risk,
    KvMoneyDirection.internal => KvColor.ink,
  };

  /// A directional amount is one coloured number: splitting the hue across
  /// integer and fraction would weaken the very signal the hue is carrying.
  /// Only the neutral case takes the ink/inkDim hierarchy.
  Color get _fractionTone =>
      direction == KvMoneyDirection.internal ? KvColor.inkDim : _tone;

  FontWeight get _weight => switch (role) {
    // §2: incoming 600, outgoing 400, internal unsigned 400.
    KvAmountRole.row =>
      direction == KvMoneyDirection.incoming
          ? FontWeight.w600
          : FontWeight.w400,
    _ => FontWeight.w500,
  };

  String get _sign => switch (direction) {
    KvMoneyDirection.incoming => '+ ',
    KvMoneyDirection.outgoing => '− ',
    KvMoneyDirection.internal => '',
  };

  /// Spelt out, because a screen reader cannot be relied on to speak `−`
  /// (U+2212) as a word — and a sign nobody hears is not one of BG-7's four
  /// channels.
  String get _spokenSign => switch (direction) {
    KvMoneyDirection.incoming => 'plus ',
    KvMoneyDirection.outgoing => 'minus ',
    KvMoneyDirection.internal => '',
  };

  int? get _digits =>
      fractionDigits ??
      switch (role) {
        // Null means "trim": show every digit that carries value and stop.
        KvAmountRole.hero => null,
        KvAmountRole.screen => 8,
        KvAmountRole.row => null,
      };

  bool get _unit => showUnit ?? (role != KvAmountRole.row);

  @override
  Widget build(BuildContext context) {
    final base = size ?? _rampSize(role);
    // Both floored at 11dp, not just the unit: `size` exists so a composition
    // can drop below the ramp (the D-191 plated balance does), and money
    // decimals are the last thing that should go under the readable floor.
    final fractionSize = math.max(readableFloor, base * fractionRatio);
    final unitSize = math.max(readableFloor, base * unitRatio);

    final Widget content;
    if (sompi == null) {
      // **An unknown amount is still an amount OF something.** A bare `—` at
      // hero size is a small glyph adrift in a 48dp line box — on glass it
      // reads as a rendering glitch rather than as "we do not know your
      // balance yet" (founder, device sitting 2026-08-27). Keeping the unit
      // beside it makes the dash a value rather than a mark, and costs
      // nothing: BG-5 asks for `—`, not for `—` alone.
      content = Semantics(
        label: 'balance unknown',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '—',
              maxLines: 1,
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: base,
                height: 1.14,
                fontWeight: _weight,
                color: KvColor.inkDim,
              ),
            ),
            if (_unit) ...[
              const SizedBox(width: KvSpace.s),
              Text(
                'KAS',
                maxLines: 1,
                style: TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: unitSize,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.6,
                  color: KvColor.primaryMuted,
                ),
              ),
            ],
          ],
        ),
      );
    } else {
      final parts = kasParts(sompi!);
      var digits = _digits;
      // A truncation FLOORS the fraction — it can never round a balance up.
      // But flooring a dust balance to four decimals prints `0.0000`, which is
      // the same glyphs a real zero gets: the figure would have erased the
      // money rather than abbreviated it. So the floor yields whenever it
      // would leave nothing at all.
      if (digits != null &&
          sompi! > BigInt.zero &&
          parts.integer == '0' &&
          !parts.fraction
              .substring(0, math.min(digits, parts.fraction.length))
              .contains(RegExp(r'[1-9]'))) {
        digits = null;
      }
      final fraction = digits == null
          ? trimFraction(parts.fraction)
          : parts.fraction.substring(
              0,
              math.min(digits, parts.fraction.length),
            );
      // Spoken naturally — "1,284.5 KAS", not "1,284.5027000 KAS" (§4). The
      // padding that makes a column of digits line up is a VISUAL job; read
      // aloud it is noise. A signing surface is the exception and keeps all
      // eight, because BG-6 restates the built transaction in full.
      final saidFraction = role == KvAmountRole.screen
          ? fraction
          : trimFraction(fraction, min: 0);
      final spoken =
          '$_spokenSign${parts.integer}'
          '${saidFraction.isEmpty ? '' : '.$saidFraction'} KAS';

      content = Semantics(
        label: spoken,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$_sign${parts.integer}',
              maxLines: 1,
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: base,
                height: 1.14,
                fontWeight: _weight,
                letterSpacing: role == KvAmountRole.hero ? -0.5 : 0,
                color: _tone,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (fraction.isNotEmpty)
              Text(
                '.$fraction',
                maxLines: 1,
                style: TextStyle(
                  fontFamily: KvFont.mono,
                  // A row is one run at one size: §2 gives `rowAmount` a single
                  // style, and 48% of 15dp would land under the 11dp floor.
                  fontSize: role == KvAmountRole.row ? base : fractionSize,
                  fontWeight: role == KvAmountRole.row
                      ? _weight
                      : FontWeight.w400,
                  color: _fractionTone,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            if (_unit) ...[
              const SizedBox(width: KvSpace.s),
              Text(
                'KAS',
                maxLines: 1,
                style: TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: unitSize,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.6,
                  color: KvColor.primaryMuted,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return AnimatedOpacity(
      opacity: stale ? KvFreshness.opacityStale : 1,
      duration: KvMotion.instant,
      curve: KvMotion.out,
      // Every role scales down rather than clipping (BG-5) — including a row,
      // which the prototype left at a fixed size and which is exactly where a
      // long amount at 1.3x on a 320dp screen runs out of room. A caller must
      // give this a bounded width for the fit to have anything to work with.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: content,
      ),
    );
  }
}
