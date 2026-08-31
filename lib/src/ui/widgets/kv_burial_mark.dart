import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart';
import '../theme/tokens.dart';
import 'kv_status_chip.dart';
import 'kv_streaming_count.dart';
import 'tx_status_chip.dart';

/// The rungs of the burial ladder — **the one resolution of "how buried is
/// this?" in the app**, and what every renderer of that fact reads from.
///
/// It is public, and separate from the widget below, because UX-5 gave the
/// fact a second **register**: the ledger row wears [KvBurialMark], the
/// transaction detail wears `KvBurialGauge`. BG-21 permits two registers of
/// one fact and forbids two *implementations* of the law behind it — which is
/// exactly what L143 cost the address tail. So the thresholds, the rung
/// arithmetic and the words live here once, and both renderers call them.
enum KvBurialRung {
  /// A submit the tracker has seen no acceptance for past the stall threshold.
  /// Not a depth at all — a fault, and it keeps its sentence.
  stalled,

  /// Accepted, under a hundred blocks deep. Amber: still settling.
  seen,

  /// A hundred or more blocks deep. Green: safe to act on.
  confirmed,

  /// A thousand or more. Final, and nothing about it changes again.
  settled,
}

/// The thresholds, the rung arithmetic and the words, in one place (BG-21).
///
/// **The vocabulary is `Seen` → `Confirmed` → `final`** (founder, 2026-08-27,
/// D-192). Not "pending": pending describes what the WALLET is doing about a
/// transaction, and what the user needs is what the NETWORK has done with it.
/// The network has seen it, then confirmed it, then buried it past reversal —
/// three facts about the chain, in the chain's order.
abstract final class KvBurial {
  /// D-192's two thresholds, named once. **100 is safe, 1,000 is final.**
  static const int safe = 100;
  static const int settled = 1000;

  /// Which rung a row is on. **This, and not the words, is what a crossfade is
  /// keyed on** (BG-24): the depth streams every frame inside the `seen` rung,
  /// and a switcher keyed on the rendered text would crossfade the row sixty
  /// times a second.
  static KvBurialRung rungFor(
    TxChipState state,
    int? confirmations,
    MaturityState maturity,
  ) {
    if (state == TxChipState.stalled) return KvBurialRung.stalled;
    if (confirmations == null) {
      return maturity == MaturityState.pending
          ? KvBurialRung.seen
          : KvBurialRung.confirmed;
    }
    if (confirmations < safe) return KvBurialRung.seen;
    if (confirmations < settled) return KvBurialRung.confirmed;
    return KvBurialRung.settled;
  }

  /// **The observed burial depth of one row**, or null when there is none to
  /// be had — and it is the ONE implementation of that arithmetic.
  ///
  /// **Anything the wallet SENT counts from DAG acceptance; only a deposit
  /// counts from its own inclusion.** A spend's `blockDaaScore` is submit time,
  /// so measuring from it would accrue burial on a transaction the DAG has
  /// never accepted. A deposit has no acceptance score — inclusion is its
  /// maturity clock, and `record.maturity()` at the pin is what governs it.
  ///
  /// The lane test is on **incoming**, and the polarity is the whole point.
  /// It used to read `direction == outgoing ? accepted : block`, which is the
  /// same thing for two of the three lanes and wrong for the third:
  /// `ActivityDirection.change` is `TransactionData::Batch` — the compounding
  /// leg of a >100k-mass chained send — and Rust surfaces its
  /// `accepted_daa_score` exactly as it does for a payment. Anchored on submit
  /// time instead, a leg the DAG never accepted accrued depth off the wall
  /// clock: a Change row 2,500 scores behind the tip rendered **`final`**, with
  /// the thousand mark closed, over a `maturity: Pending` record
  /// (`consensus-auditor`, UX-5 — reproduced against the built widgets, not
  /// argued). Written as "not incoming", a fourth lane inherits the safe
  /// answer instead of the unsafe one.
  ///
  /// **A stale link never counts.** A frozen last-known DAA must not read live
  /// (BG-8), so the answer is null and every renderer of it says so.
  ///
  /// It lives here rather than inside the ledger feed because UX-5 gave the
  /// fact a second surface: the transaction detail plots this number on a
  /// gauge while the money screen prints it in a row. Two copies of this
  /// subtraction would be two surfaces disagreeing about one transaction —
  /// L143 with real money on it.
  static int? depthOf(
    ActivityRecord record,
    BigInt? virtualDaaScore, {
    required bool stale,
  }) {
    if (stale) return null;
    final daa = virtualDaaScore;
    if (daa == null) return null;
    final anchor = record.direction == ActivityDirection.incoming
        ? record.blockDaaScore
        : record.acceptedDaaScore;
    if (anchor == null || daa < anchor) return null;
    return (daa - anchor).toInt();
  }

  /// The words for a rung, **and the depth's own presence is part of them**
  /// (BG-20, D-229).
  ///
  /// `Confirmed` used to mean two different things: *accepted and 100–999
  /// blocks deep*, which is a measurement, and *accepted, depth unknown*,
  /// which is the absence of one. Two states that need different actions —
  /// wait, or go and find out why the wallet cannot see the chain — wore one
  /// face, and the face was the stronger of the two. The ratified vocabulary
  /// is untouched; what was missing was BG-8's own marker for a datum the
  /// wallet does not have, so an unknown depth now renders `Seen —` /
  /// `Confirmed —` beside the word it qualifies.
  ///
  /// [depth] is the reading actually in hand: null means there is none.
  static String words(KvBurialRung rung, {int? depth}) => switch (rung) {
    KvBurialRung.stalled => 'Not accepted yet',
    // Under a hundred the word and the number travel together on every
    // surface (founder, on glass 2026-08-30). The word used to step aside the
    // moment a count arrived, so a row read `Seen` and then bare `42` — the
    // label vanishing at exactly the moment it became meaningful.
    KvBurialRung.seen => depth == null ? 'Seen —' : 'Seen $depth',
    KvBurialRung.confirmed => depth == null ? 'Confirmed —' : 'Confirmed',
    KvBurialRung.settled => 'final',
  };

  /// The lamp the rung wears. **Null past the final mark**: a mark that never
  /// changes again is not an indicator, and BG-7 gives lamps three hues while
  /// a settled row needs none of them.
  static KvLampTone? toneFor(KvBurialRung rung) => switch (rung) {
    KvBurialRung.stalled => KvLampTone.warn,
    KvBurialRung.seen => KvLampTone.warn,
    KvBurialRung.confirmed => KvLampTone.ok,
    KvBurialRung.settled => null,
  };
}

/// How deeply a row is buried, **in a ledger row's register**: a dot, a word,
/// and — inside the `seen` rung — the streaming depth beside it.
///
/// The vocabulary, the thresholds and the rung arithmetic are [KvBurial]'s;
/// this widget is one *rendering* of them. The transaction detail's
/// `KvBurialGauge` is the other, and the two read the same functions so they
/// cannot drift into disagreeing about one number (BG-21 / L143).
///
/// **Each crossing between rungs is a crossfade, never a cut** (BG-24, D-229).
///
/// **It will not claim `final` from a maturity flag.** A confirmed row whose
/// depth cannot be computed — a stale link, a cold start, a row the live DAA
/// cannot anchor — reads `Confirmed —`: the word the pin actually justified,
/// and BG-8's dash for the measurement nobody has. Depth is what earns the
/// third word, and without it the honest answer is the second one, said so
/// that it cannot be mistaken for a hundred blocks of burial (BG-20).
class KvBurialMark extends StatefulWidget {
  const KvBurialMark({
    super.key,
    required this.state,
    required this.confirmations,
    required this.maturity,
  });

  final TxChipState state;
  final int? confirmations;
  final MaturityState maturity;

  /// D-192's two thresholds, forwarded from [KvBurial] so existing call sites
  /// and tests keep one name for them.
  static const int safe = KvBurial.safe;
  static const int settled = KvBurial.settled;

  @override
  State<KvBurialMark> createState() => _KvBurialMarkState();
}

class _KvBurialMarkState extends State<KvBurialMark> {
  /// The rung the **last built frame actually rendered**.
  ///
  /// It is derived from the DRAWN depth, not from the newest reading, and that
  /// is the whole correction. Taken from `widget.confirmations` it abandoned
  /// the streaming branch the instant a poll crossed a threshold: a reading of
  /// 106 arriving over a row showing 96 stopped the count dead at **96** and
  /// replaced it with `Confirmed` — the row claiming to have crossed a hundred
  /// while the last number it ever showed was ninety-six. The gauge had the
  /// same defect and was fixed first; this is the second register, and a rule
  /// swept once is a rule swept nowhere (L144, `ux-auditor`, UX-5).
  KvBurialRung? _shown;

  /// Bumped on every BACKWARD rung change, and it is the switcher's key — so
  /// the switcher itself is remounted rather than asked to animate in zero
  /// time. `duration: Duration.zero` looks like the obvious way to say "snap"
  /// and does not work: the outgoing child is never released, so both rungs
  /// stay mounted for good (measured, not assumed). A fresh switcher shows its
  /// first child with no animation by construction.
  ///
  /// A rung that goes down is not progress. Two things cause it and neither
  /// should be dressed as movement: a **reorg**, which BG-18 says snaps rather
  /// than animating backwards as if burial were being undone, and — far more
  /// often — a depth reading **arriving late**, where a row read `Confirmed`
  /// from its maturity flag and then learns it is only fifty deep. Crossfaded,
  /// that superimposes `Confirmed` over `Seen 50` for 160 ms: two states
  /// wearing one face, which is BG-20 (`ux-auditor`, D-229). The counter needs
  /// no reset for it — [KvStreamingCount] snaps on a decrease by its own rule,
  /// so a depth that went down does not stream down to meet it.
  int _epoch = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.confirmations;
    // **Streamed, not stepped** (BG-18 / D-226). The depth is read on a 1 Hz
    // poll; replaying the interval between the last two readings at the panel's
    // refresh rate makes the count move rather than tick. Every frame is a
    // depth the chain actually reached, and the count never runs past the
    // newest reading — a burial depth that overstated itself, even by one,
    // would be the row lying about how buried the money is.
    //
    // It wraps the switcher rather than sitting inside one branch of it, so the
    // rung and the number it is drawn from are the same integer in the same
    // frame.
    return KvStreamingCount(
      value: n == null ? null : BigInt.from(n),
      builder: (context, shown) => _body(shown?.toInt() ?? n),
    );
  }

  Widget _body(int? depth) {
    final rung = KvBurial.rungFor(widget.state, depth, widget.maturity);
    final previous = _shown;
    if (previous != null && rung.index < previous.index) _epoch++;
    _shown = rung;

    // **The rung change crosses, it does not cut** (BG-24, D-229). The
    // amber -> green crossing at a hundred confirmations is the moment the
    // money becomes safe, and it was a hard swap: a different `_Mark` returned
    // on the next rebuild with nothing between. `TxStatusChip` — the widget
    // this vocabulary replaced — has always crossfaded at `fast`, so the app
    // lost a transition exactly where it gained the better words.
    //
    // **The geometry belongs to the rung arriving, from the first frame.**
    // A crossfade alone does not discharge BG-24, it relocates the cut: the
    // switcher's default stack holds the LARGER of the two children for the
    // whole 160 ms and releases in one frame, so `Confirmed` -> `final` moved
    // the timestamp beside it 54 dp in a single un-eased step at the END of a
    // transition that had already finished visually (`ux-auditor`, D-229).
    //
    // So the outgoing mark is `Positioned` — present, fading, and **sizing
    // nothing**. The row takes the incoming width immediately, which puts the
    // one width change at the same instant as the fade that explains it,
    // left-aligned so the words settle where they started.
    //
    // `TxStatusChip` solves its own version with a vertical `SizeTransition`,
    // and that is right for it and wrong here: it dissolves to NOTHING, so its
    // extent goes to zero. This mark never disappears — it changes width.
    //
    // `AnimatedSize` around the switcher was tried before this and is wrong
    // twice: the stack it measures does not change size until the fade is
    // already over, and it asserts outright on a zero duration.
    return AnimatedSwitcher(
      key: ValueKey(_epoch),
      duration: KvMotion.fast,
      switchInCurve: KvMotion.out,
      switchOutCurve: KvMotion.out,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none,
        children: [
          for (final old in previous)
            Positioned(left: 0, top: 0, bottom: 0, child: old),
          ?current,
        ],
      ),
      child: KeyedSubtree(
        key: ValueKey(rung),
        child: _Mark(
          tone: KvBurial.toneFor(rung),
          // **`Seen` STAYS while the number streams** (founder, on glass
          // 2026-08-30, revising the density call made earlier the same day).
          // The word used to step aside the moment a count arrived, so a row
          // read `Seen` and then bare `42` — the label vanishing at exactly the
          // moment it became meaningful. A number alone does not say what it
          // counts, and the ladder's whole job is to say how buried the money
          // is.
          words: KvBurial.words(rung, depth: depth),
          mono: rung == KvBurialRung.seen && depth != null,
        ),
      ),
    );
  }
}

/// A dot and a word — or, past the final mark, a word alone.
class _Mark extends StatelessWidget {
  const _Mark({this.tone, required this.words, this.mono = false});

  /// Null draws no dot at all: `final` never changes again, so it has nothing
  /// to indicate.
  final KvLampTone? tone;
  final String words;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final dot = tone;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot != null) ...[
          // No bloom: §1.5 reserves that for a lamp, and a ledger of pending
          // rows must not spend the screen's emission budget one row at a time.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: KvSpace.xs),
        ],
        // Bounded, or the longest word in the set — `Not accepted yet` — walks
        // straight out of a 320dp row at 1.3x. The `Wrap` above gives this a
        // width; the flex is what makes it use it.
        Flexible(
          child: Text(
            words,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: mono ? KvFont.mono : KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              fontWeight: FontWeight.w500,
              // The dot carries the hue; the words do not (§1.5).
              color: KvColor.inkDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
