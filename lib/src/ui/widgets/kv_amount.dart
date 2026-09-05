import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/tokens.dart';
import 'kv_rolling_text.dart';

/// Where an amount sits on the §2 ramp.
enum KvAmountRole {
  /// **A magnitude, in full.** Mono 46/52 at weight 500, and **every
  /// significant decimal with the trailing zeros trimmed** — see the precision
  /// law in the class doc.
  ///
  /// Named for the home balance, which is where it started, but the rule it
  /// carries is about the JOB and not the screen: a figure that states what
  /// something *is* rather than what is about to be committed. The transaction
  /// detail's amount takes it too, one ramp step down — a record of a settled
  /// transaction is a magnitude, and D-210's padding prohibition applies to it
  /// (`ux-auditor`, UX-5).
  hero,

  /// **A screen-level amount at the moment of commitment**: the ceremony's
  /// headline. Significant decimals with the trailing zeros trimmed, to a
  /// minimum of two — the same precision law every other role takes, since
  /// the founder withdrew D-210's exception on 2026-09-04. `12.40000000`
  /// reads `12.40`; `0.00010000` reads `0.0001`; a figure that genuinely runs
  /// to eight places still shows all eight, because the trim removes only
  /// zeros.
  ///
  /// It used to say *"a detail's value"* as well, and that reading is what put
  /// the fixed eight on a surface where nothing is being signed. A record takes
  /// [hero].
  screen,

  /// An amount in a ledger row. One mono run at 16, weight carrying direction,
  /// trailing zeros trimmed to two.
  row,
}

/// **Where the weight falls on a figure (BG-23).**
///
/// `KvAmount` splits an amount into a big bright integer and a small dim
/// fraction. For a **balance** that is right: the integer is the magnitude, and
/// the magnitude is what you own. For a **fee** it is inverted — a fee is always
/// below 1, so the one bright character is a `0` that is `0` in every case the
/// surface will ever show, while the digits that carry the cost sit at 48%.
///
/// **Founder's call, 2026-08-30, taken from the rendered comparison rather than
/// from an argument** (D-230): the balance keeps [magnitude], the fee takes
/// [significant]. The two surfaces have different jobs — one is a magnitude you
/// own, the other a cost you are checking — so the rule belongs to the ROLE and
/// not to the app. That is why this is resolved from [KvAmountRole] rather than
/// passed in at every call site: a future `screen`-role amount inherits the
/// decision instead of re-making it (BG-21).
enum KvAmountEmphasis {
  /// The integer takes the weight, always. Balances and ledger rows.
  magnitude,

  /// Below 1, the leading `0.` and its zeros drop to the fraction's size and
  /// the weight starts at the first digit that carries value. At or above 1
  /// this is identical to [magnitude], so it changes only the case that was
  /// wrong.
  significant,
}

/// Which way the money is moving (BG-7).
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
///  * **`0.00` for a real zero** at every role, [KvAmountRole.screen] included
///    since D-267 — a synced empty wallet is not unknown;
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
///    second law written for it. **The signing surface takes the same rule**
///    (founder, 2026-09-04: *"only 2 zeros show if the amount has no decimals,
///    and if it has decimals that is more than 2, it shows like this;
///    `1.004 KAS` instead of `1.00400000`"*), which withdraws D-210's one
///    exception. It is safe to withdraw because **trimming a trailing zero is
///    lossless**: `1.00400000` and `1.004` are the same number, no digit that
///    carries value is dropped, and nothing rounds — the trim only ever
///    removes zeros. What BG-6 actually needs from a restatement is that no
///    digit be *hidden*, and eight fixed places hid the end of the number
///    behind five zeros the user had to count past;
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
/// The unit is [KvColor.primaryMuted] — **teal, by founder ruling on glass**
/// (2026-09-04, D-262: *"let the KAS be in teal"*), reversing D-261's reading
/// of `S1`, which sets it in the meta grey. Ambient teal on structure, which
/// **not an emission** and costs nothing against BG-2's cap of three (§1.5).
/// It is most of what makes the figure read as money rather than as telemetry.
class KvAmount extends StatelessWidget {
  const KvAmount(
    this.sompi, {
    super.key,
    this.role = KvAmountRole.hero,
    this.emphasis,
    this.direction = KvMoneyDirection.internal,
    this.stale = false,
    this.muted = false,
    this.size,
    this.fractionDigits,
    this.rolling = false,
    this.showUnit,
  });

  /// Non-negative balance in sompi. `null` means **not yet known** (BG-8).
  final BigInt? sompi;

  final KvAmountRole role;

  /// Where the weight falls (BG-23). **Null resolves from [role]**, which is
  /// where the decision lives; pass one only to override a single composition.
  final KvAmountEmphasis? emphasis;

  /// The role's own rule (D-230). A signing surface restates a cost and takes
  /// [KvAmountEmphasis.significant]; a balance and a ledger row keep the
  /// magnitude.
  KvAmountEmphasis get _emphasis =>
      emphasis ??
      switch (role) {
        KvAmountRole.screen => KvAmountEmphasis.significant,
        KvAmountRole.hero || KvAmountRole.row => KvAmountEmphasis.magnitude,
      };
  final KvMoneyDirection direction;

  /// Dims to [KvFreshness.opacityStale]. BG-8 also requires a **visible age**
  /// beside a dimmed reading — that belongs to the line that vouches for the
  /// number, not to the number itself.
  final bool stale;

  /// **The figure in `inkDim`, its sign and weight kept.** A ledger row under
  /// a dark link dims as a region (D-276), and a hued figure at that opacity
  /// falls under BG-14's floor while `inkDim` clears it — so the row asks for
  /// the tone and keeps the sign, the arrow and the word carrying direction
  /// (BG-7's other channels) until the link is back.
  final bool muted;

  /// Overrides the ramp size for a composition that needs one (the plated
  /// balance reads one step down from the ramp because the unit now sits
  /// beside the figure instead of under it — D-191).
  final double? size;

  /// Fixed count of fractional digits. Null trims trailing zeros to a minimum
  /// of two. **Every role defaults to the trim since D-267** — the signing
  /// surface's fixed eight is withdrawn. A caller may still pin a width; the
  /// money plate is the only one that does.
  ///
  /// The hero used to fix at 4 and D-210 retired that — a hero stopping at
  /// four decimals told a user holding `21.12345678` that they held `21.1234`.
  /// The screen role kept a fixed eight until D-267 retired that too, for the
  /// same reason read the other way: padding is not precision.
  final int? fractionDigits;

  /// **The digits change in place instead of the figure being replaced**
  /// (founder, on glass 2026-09-04). For a live readout that re-answers as
  /// something else is typed — the Send screen's fee preview, and nothing else
  /// yet. See [KvRollingText] for why this is not a counter and does not
  /// break `KvStreamingCount`'s fourth law.
  ///
  /// **Never on a figure that is being committed.** The ceremony restates what
  /// Rust built and that number does not change under the user; animating it
  /// would suggest it might.
  final bool rolling;

  /// Null shows the unit on [KvAmountRole.hero] and [KvAmountRole.screen], and
  /// hides it in a row, where the column heading carries it.
  final bool? showUnit;

  /// Fraction and unit as a share of the integer's size. §2 pairs
  /// `balanceHero` 48 with a 24 fraction and `amountScreen` 44 with 22 — one
  /// half in both cases, so the ratio is derived rather than chosen.
  static const double fractionRatio = 0.5;

  /// The unit at 0.3 of the hero is 14.4 dp — the render's `KAS` measures a
  /// 10.5 dp cap height beside the 48 figure, which is a 14 dp face (D-261).
  static const double unitRatio = 0.3;

  /// 11dp is the floor for anything a user must read (§2/BG-14).
  static const double readableFloor = 11;

  static double _rampSize(KvAmountRole role) => switch (role) {
    // §2 as amended by Deep V6: `balanceHero` 48/52 (fraction 24),
    // `amountRow` 16/20.
    //
    // **`screen` is 40 since 2026-09-04** — the founder raised it from 32 on
    // glass: *"make the total amount number larger in the center its in. its
    // kinda small and not giving main thing."* `S7` measures 32 and his eye
    // outranks the render (D-262); the figure earned the weight when the rule
    // label above it was removed and it became the whole amount leaving the
    // wallet, centred, with nothing else in that region. It stays a step under
    // §2's `amountScreen` 44, which is a record read at a glance rather than a
    // commitment being checked.
    KvAmountRole.hero => 48,
    KvAmountRole.screen => 40,
    KvAmountRole.row => 16,
  };

  /// **A figure that has a direction takes that direction's hue** (BG-7 as
  /// amended in Deep V6 v4.2 — this *reverses* BG-26's colour channel).
  ///
  /// UX-5 made the figure neutral so a row read as a quantity first, and the
  /// reasoning was sound on Black Glass. On the tinted ground the coloured
  /// figure is what makes the ledger scannable at arm's length: the eye finds
  /// *what left* before it reads a digit, which on a money surface is the
  /// right order. **A neutral ledger figure is now the finding.**
  ///
  /// The cost BG-26 named — hue grading the *size* of money — is answered by
  /// weight instead (see [_weight]): incoming 700, outgoing 500. A balance,
  /// a fee and a self-send carry no direction and stay [KvColor.ink].
  Color get _digitTone => muted
      ? KvColor.inkDim
      : switch (direction) {
          KvMoneyDirection.incoming => KvColor.ok,
          KvMoneyDirection.outgoing => KvColor.risk,
          KvMoneyDirection.internal => KvColor.ink,
        };

  /// The quiet run. A directed figure is **one object in one hue** — splitting
  /// its fraction into a second colour would put two channels on one number —
  /// so only an undirected figure has a quiet tone at all, and §2 sets the
  /// balance hero's fraction in [KvColor.inkMeta].
  Color get _fractionTone => switch (direction) {
    KvMoneyDirection.incoming || KvMoneyDirection.outgoing => _digitTone,
    KvMoneyDirection.internal =>
      role == KvAmountRole.hero ? KvColor.inkMeta : KvColor.inkDim,
  };

  FontWeight get _weight => switch (role) {
    // §2 `amountRow`: **incoming 700, outgoing 500** — the channel that took
    // over the job hue used to do (BG-26 as amended).
    KvAmountRole.row =>
      direction == KvMoneyDirection.incoming
          ? FontWeight.w700
          : FontWeight.w500,
    // `balanceHero` and `amountScreen`: integer 700, fraction 600.
    _ => FontWeight.w700,
  };

  String get _sign => switch (direction) {
    KvMoneyDirection.incoming => '+',
    KvMoneyDirection.outgoing => '−',
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
        // **Every role, including the signing surface** (founder, 2026-09-04)
        // — see the precision law in the class doc.
        KvAmountRole.hero => null,
        KvAmountRole.screen => null,
        KvAmountRole.row => null,
      };

  bool get _unit => showUnit ?? (role != KvAmountRole.row);

  /// One emphasised run — a plain `Text`, or a [KvRollingText] whose digits
  /// change in place when [rolling] is set.
  Widget _run(String text, TextStyle style) => rolling
      ? KvRollingText(text, style: style)
      : Text(text, maxLines: 1, style: style);

  /// Splits a figure into `(text, isStrong)` runs under the chosen [emphasis].
  ///
  /// The default returns exactly what the two-`Text` version rendered, which is
  /// the property the guard pins: **a defaulted parameter that changed a shipped
  /// pixel would be a canon change wearing a proposal's clothes.**
  List<(String, bool)> _runs(String integer, String fraction) {
    // **Tight against the digits.** `'+ 12.40'` put a full mono space between
    // the sign and the magnitude, which read as two objects; `+12.40` is one
    // number with a sign on it, which is what it is.
    final head = '$_sign$integer';
    final tail = fraction.isEmpty ? '' : '.$fraction';
    // Above 1 the integer IS the magnitude, so every candidate agrees with the
    // shipped rule and only the sub-1 case differs. That is the whole scope of
    // the defect and therefore the whole scope of the variants.
    final subUnit = integer == '0' && fraction.isNotEmpty;
    if (_emphasis == KvAmountEmphasis.magnitude || !subUnit) {
      return [(head, true), (tail, false)];
    }
    // `significant`: the quiet run swallows `0.` plus every leading zero, and
    // the weight starts at the first digit that carries value.
    final firstSignificant = fraction.indexOf(RegExp('[1-9]'));
    if (firstSignificant < 0) return [(head, true), (tail, false)];
    return [
      ('$head.${fraction.substring(0, firstSignificant)}', false),
      (fraction.substring(firstSignificant), true),
    ];
  }

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
                fontVariations: KvWeight.of(_weight),
                color: KvColor.inkDim,
              ),
            ),
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
      // aloud it is noise.
      //
      // **The signing surface is no longer an exception** (founder,
      // 2026-09-04, withdrawing D-210's carve-out): it prints the trimmed
      // figure, so it speaks the trimmed figure, and what is heard is what is
      // on the glass. A surface whose spoken and printed forms differ is two
      // statements of one fact.
      final saidFraction = trimFraction(fraction, min: 0);
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
            // **Three runs, not two** — `quiet · strong · quiet` — so BG-23's
            // candidates are a matter of where the boundary falls rather than
            // a second widget. Under the default the first run is empty and
            // the boundary sits exactly where it always did.
            for (final (text, strong) in _runs(parts.integer, fraction))
              if (text.isNotEmpty)
                _run(
                  text,
                  TextStyle(
                    fontFamily: KvFont.mono,
                    // A row is one run at one size: §2 gives `rowAmount` a
                    // single style, and 48% of 15dp would land under the 11dp
                    // floor.
                    fontSize: strong || role == KvAmountRole.row
                        ? base
                        : fractionSize,
                    height: strong ? 1.14 : null,
                    // **Both channels, and BG-26 depends on it.** On a variable
                    // face `fontWeight` is a hint and `fontVariations` is the
                    // ink, and an inline style inherits the ambient axis — so
                    // until UX-R1 measured it, an incoming row declared at 700
                    // and an outgoing row declared at 500 rendered at
                    // **identical width, both at axis 400**. Direction was
                    // riding three channels, not four (L150).
                    fontWeight: strong || role == KvAmountRole.row
                        ? _weight
                        : FontWeight.w600,
                    fontVariations: KvWeight.of(
                      strong || role == KvAmountRole.row
                          ? _weight
                          : FontWeight.w600,
                    ),
                    letterSpacing: strong && role == KvAmountRole.hero
                        ? -0.5
                        : 0,
                    color: strong ? _digitTone : _fractionTone,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
          ],
        ),
      );
    }

    // **The 45% stale dim is a LARGE-TEXT device** (BG-8 as amended, D-257).
    // Measured on `plate`: it takes a 16 dp ledger amount to 3.03 and an 11 dp
    // meta line to 1.93, against BG-14's 4.5 — and BG-14 does not bend. Only
    // the balance figure is large enough to sit on the 3.0 bar, where the dim
    // lands at 4.22. Below the floor the staleness is carried by the visible
    // age, the amber lamp and a counter that stops, which is what BG-8 asks
    // for anyway.
    final dim = stale && base >= KvFreshness.staleDimFloor;
    return AnimatedOpacity(
      opacity: dim ? KvFreshness.opacityStale : 1,
      duration: KvMotion.instant,
      curve: KvMotion.out,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Every role scales down rather than clipping (BG-5) — including a
          // row, which the prototype left at a fixed size and which is exactly
          // where a long amount at 1.3x on a 320dp screen runs out of room. A
          // caller must give this a bounded width for the fit to have anything
          // to work with.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: content,
            ),
          ),
          // **The unit sits OUTSIDE the fit, and that is the whole point of
          // its floor.** Inside, [unitSize]'s `max(readableFloor, …)` was
          // computed and then multiplied away by the very scale that saved the
          // figure: a max-supply balance at 320dp/1.3× shrank the unit to
          // 7.89dp against an 11dp law, on a signing surface
          // (`ux-auditor`, UX-4). The figure may shrink — it is the thing
          // being fitted — but a three-letter unit costs almost nothing to
          // keep readable, and it is information the user must read.
          if (_unit) ...[
            const SizedBox(width: KvSpace.s),
            Padding(
              // An optical nudge so the unit sits on the figure's baseline
              // rather than its line-box bottom, now that it is outside the
              // fit and can no longer share a `CrossAxisAlignment.baseline`
              // with it. **By eye, not derived** — said plainly, because a
              // comment that implied a measurement would be the L121 defect
              // this codebase keeps paying for. It moves no size the law
              // governs; [unitSize] is computed and floored above.
              padding: EdgeInsets.only(bottom: unitSize * 0.18),
              child: ExcludeSemantics(
                child: Text(
                  'KAS',
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: unitSize,
                    fontWeight: FontWeight.w500,
                    fontVariations: KvWeight.w500,
                    letterSpacing: 0.6,
                    // Teal — the founder's ruling on glass (D-262), and it
                    // shipped grey once because the revert was grepped and
                    // not made (D-263). The test pins it now.
                    color: KvColor.primaryMuted,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
