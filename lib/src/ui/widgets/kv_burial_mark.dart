import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart';
import '../theme/tokens.dart';
import 'kv_streaming_count.dart';
import 'tx_status_chip.dart';

/// **The maturity thresholds, as data** — never as a number typed into `lib/`.
///
/// D-249 made this a bridge concern in as many words: *"UX-R3 **must not
/// hardcode** 100 or 1,000. Both live on the pinned side and cross the FFI from
/// `NetworkParams::from(network_id)`."* The reason is not tidiness. The shipped
/// ladder carried `safe = 100` / `settled = 1000` as constants, and D-249 found
/// that the pair was right by accident: they are wallet-core's **mainnet**
/// user/coinbase maturity numbers, while `10 / 100` is its **devnet** pair. A
/// re-pin, or a network that is not mainnet, would have moved the library's
/// numbers and left the glass quoting the old ones — over a balance computed
/// with the new ones.
///
/// So the two numbers arrive from `maturityThresholds()` and are threaded to
/// every renderer of the ladder. There is no default and no fallback: a surface
/// that has not been handed thresholds cannot draw a rung, which is the honest
/// failure rather than a plausible one.
@immutable
class KvMaturity {
  const KvMaturity({required this.userDaa, required this.coinbaseDaa});

  /// The one conversion from the bridge's DTO, so the `BigInt`-to-`int` narrowing
  /// happens once. Both numbers are DAA *periods* — hundreds or thousands, never
  /// near the 53-bit boundary a web build would care about.
  factory KvMaturity.from(MaturityParamsDto dto) => KvMaturity(
    userDaa: dto.userDaa.toInt(),
    coinbaseDaa: dto.coinbaseDaa.toInt(),
  );

  /// `user_transaction_maturity_period_daa` — the depth at which a payment from
  /// someone else is counted in the balance and can be selected for a send.
  /// **Wallet-core's own client-side policy, not a consensus rule** (D-251).
  final int userDaa;

  /// `coinbase_transaction_maturity_period_daa` — consensus `coinbase_maturity`,
  /// mirrored by the library. A mined output is genuinely unspendable until it.
  final int coinbaseDaa;

  /// **The ceiling this row is measured against**, which is the whole of D-249's
  /// last finding: `rungFor` never read `is_coinbase`, so a coinbase at 150
  /// rendered as settled while wallet-core still called it pending and the
  /// balance excluded it. One row, two answers, and the wrong one was the
  /// reassuring one.
  int ceilingFor({required bool coinbase}) => coinbase ? coinbaseDaa : userDaa;

  @override
  bool operator ==(Object other) =>
      other is KvMaturity &&
      other.userDaa == userDaa &&
      other.coinbaseDaa == coinbaseDaa;

  @override
  int get hashCode => Object.hash(userDaa, coinbaseDaa);

  @override
  String toString() => 'KvMaturity(user: $userDaa, coinbase: $coinbaseDaa)';
}

/// The rungs of the burial ladder — **the one resolution of "how settled is
/// this?" in the app**, and what every renderer of that fact reads from.
///
/// **The vocabulary is `Pending · Accepted · Settled`** (founder ruling
/// 2026-09-03, D-248; thresholds corrected against the pin, D-249). It replaces
/// `Seen · Settling · Confirmed · final`, which was a *second* vocabulary for a
/// fact the Rust bridge had always surfaced as
/// `MaturityState { pending, accepted, confirmed, unknown }` — one fact, two
/// names, with the seam sitting exactly where a user checks whether their money
/// is safe. The words the user reads and the words the chain layer speaks are
/// now the same words.
///
/// It is public, and separate from the widgets below, because the fact has two
/// **registers**: the ledger row wears [KvBurialMark], the transaction detail
/// wears `KvBurialGauge`. BG-21 permits two registers of one fact and forbids
/// two *implementations* of the law behind it — which is exactly what L143 cost
/// the address tail. So the rung arithmetic and the words live here once, and
/// both renderers call them.
enum KvBurialRung {
  /// A submit the tracker has seen no acceptance for past the stall threshold.
  /// Not a depth at all — a fault, and it keeps its sentence.
  stalled,

  /// **Submitted, not yet accepted.** Amber. Only ever observable for our own
  /// submits: an incoming payment is learned from the DAG and is therefore
  /// first seen already accepted (D-248 §9.0a — the wallet must not invent a
  /// mempool rung it never observed).
  pending,

  /// **On chain, and not yet spendable.** Green. The acceptance event at depth
  /// 0, and the linear `0 → ceiling` track runs inside this rung.
  accepted,

  /// **Counted in your balance, and spendable.** Blue. Reached at the pin's own
  /// maturity threshold for this row.
  ///
  /// **It claims nothing more than that.** D-249 struck "past reversal" from
  /// the law: acceptance is explicitly revocable, the pin's only reversal
  /// bounds are `merge_depth` 36,000 and `finality_depth` 432,000, and 432,000
  /// finality is out of scope by founder ruling (D-251).
  settled,
}

/// The rung arithmetic and the words, in one place (BG-21).
abstract final class KvBurial {
  /// Which rung a row is on — **and the direction is load-bearing**, because
  /// one `MaturityState` means two different things depending on it (D-249,
  /// correction (a)).
  ///
  /// For a **spend**, `wallet_sync.rs` derives `Confirmed` from
  /// `accepted_daa_score.is_some()` — the DAG accepted it, which is `Accepted`
  /// at depth 0, not spendable-and-settled. For a **receive**, it derives from
  /// `record.maturity(daa)`, so `Pending` means *on chain and under the
  /// maturity period* — never in a mempool. Read without the direction, an
  /// incoming deposit wore an amber `Pending` chip for its first ten seconds
  /// while it was already accepted: the exact misstatement `Accepted` was
  /// introduced to kill for spends.
  ///
  /// **This, and not the words, is what a crossfade is keyed on** (BG-24): the
  /// depth streams every frame inside the `accepted` rung, and a switcher keyed
  /// on the rendered text would crossfade the row sixty times a second.
  static KvBurialRung rungFor(
    TxChipState state,
    int? confirmations,
    MaturityState maturity, {
    required ActivityDirection direction,
    required bool isCoinbase,
    required KvMaturity thresholds,
  }) {
    if (state == TxChipState.stalled) return KvBurialRung.stalled;
    final incoming = direction == ActivityDirection.incoming;
    final depth = confirmations;
    // **A spend that the DAG has not accepted is the one true `Pending` — and
    // a computable depth is itself proof that it HAS been accepted.**
    //
    // The two inputs cannot honestly disagree: `depthOf` anchors a spend on
    // `acceptedDaaScore`, and `wallet_sync.rs` derives that record's maturity
    // from `accepted_daa_score.is_some()` — the same field. So a spend with a
    // depth and a `Pending` flag is contradictory input, and the depth is the
    // stronger of the two: it is the raw score, while maturity is a projection
    // of it. Reading the projection first would let a stale flag print
    // `Pending` over a transaction the screen is actively counting the burial
    // of.
    if (!incoming && maturity == MaturityState.pending && depth == null) {
      return KvBurialRung.pending;
    }
    if (depth == null) {
      // No reading. A receive already past the library's own maturity check is
      // settled on the library's word; everything else is on chain and not yet
      // spendable, which is `Accepted`. Never `Pending` without a spend's
      // unaccepted submit behind it (BG-8: the absence of a depth is a dash on
      // the word, not a demotion to a rung we did not observe).
      return incoming && maturity == MaturityState.confirmed
          ? KvBurialRung.settled
          : KvBurialRung.accepted;
    }
    return depth >= thresholds.ceilingFor(coinbase: isCoinbase)
        ? KvBurialRung.settled
        : KvBurialRung.accepted;
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
  /// clock: a Change row 2,500 scores behind the tip rendered as fully settled,
  /// over a `maturity: Pending` record (`consensus-auditor`, UX-5 — reproduced
  /// against the built widgets, not argued). Written as "not incoming", a
  /// fourth lane inherits the safe answer instead of the unsafe one.
  ///
  /// **A stale link never counts.** A frozen last-known DAA must not read live
  /// (BG-8), so the answer is null and every renderer of it says so.
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
  /// `Accepted` means two different things without its number: *on chain, this
  /// many deep*, which is a measurement, and *on chain, depth unknown*, which is
  /// the absence of one. Two states that need different actions — wait, or go
  /// and find out why the wallet cannot see the chain — must not wear one face,
  /// so an unknown depth renders `Accepted —` beside the word it qualifies.
  ///
  /// Under the ceiling the word and the number travel together on every surface
  /// (founder, on glass 2026-08-30). The word used to step aside the moment a
  /// count arrived, so a row read `Seen` and then bare `42` — the label
  /// vanishing at exactly the moment it became meaningful.
  ///
  /// [depth] is the reading actually in hand: null means there is none.
  static String words(KvBurialRung rung, {int? depth}) => switch (rung) {
    KvBurialRung.accepted =>
      depth == null ? '${rungWord(rung)} —' : '${rungWord(rung)} $depth',
    _ => rungWord(rung),
  };

  /// **The rung's bare word, with no measurement attached.**
  ///
  /// `S9` puts the word in a chip and the number on the gauge below it, and
  /// BG-19 is why: *nothing is stated twice on one surface*. Two REGISTERS of
  /// one fact are permitted — a word, and how far along a declared scale it
  /// sits — but two printings of the count are not, and the first cut of the
  /// detail printed `Accepted 42` in both (caught by the suite, not by reading).
  ///
  /// It is the same string [words] builds from, so the chip and the gauge can
  /// never disagree about what the rung is called (BG-21).
  static String rungWord(KvBurialRung rung) => switch (rung) {
    KvBurialRung.stalled => 'Not accepted yet',
    KvBurialRung.pending => 'Pending',
    KvBurialRung.accepted => 'Accepted',
    KvBurialRung.settled => 'Settled',
  };

  /// **The hue a rung wears** (BG-7 as amended by D-248).
  ///
  /// `settled` is a *fourth* value hue and its fence is part of the ruling: it
  /// is spent on the terminal lifecycle rung and nowhere else — never a general
  /// status, never an "info" colour, never a latency tier, and never the check.
  /// That is why it is returned as a [Color] here rather than added to
  /// [KvLampTone], which is the app's general three-signal vocabulary: putting
  /// a fourth member on that enum is how a fenced hue escapes its fence.
  static Color hueFor(KvBurialRung rung) => switch (rung) {
    KvBurialRung.stalled => KvColor.warn,
    KvBurialRung.pending => KvColor.warn,
    KvBurialRung.accepted => KvColor.ok,
    KvBurialRung.settled => KvColor.settled,
  };

  /// The tint the hue sits on, for a chip or a disc.
  static Color tintFor(KvBurialRung rung) => switch (rung) {
    KvBurialRung.stalled => KvColor.warnTint,
    KvBurialRung.pending => KvColor.warnTint,
    KvBurialRung.accepted => KvColor.okTint,
    KvBurialRung.settled => KvColor.settledTint,
  };
}

/// How deeply a row is buried, **in a ledger row's register**: a dot, a word,
/// and — inside the `accepted` rung — the streaming depth beside it.
///
/// The vocabulary, the thresholds and the rung arithmetic are [KvBurial]'s;
/// this widget is one *rendering* of them. The transaction detail's
/// `KvBurialGauge` is the other, and the two read the same functions so they
/// cannot drift into disagreeing about one number (BG-21 / L143).
///
/// **Each crossing between rungs is a crossfade, never a cut** (BG-24, D-229).
///
/// **It will not claim `Settled` from a maturity flag alone on a spend.** A
/// spend whose depth cannot be computed — a stale link, a cold start, a row the
/// live DAA cannot anchor — reads `Accepted —`: the word the pin actually
/// justifies, and BG-8's dash for the measurement nobody has.
class KvBurialMark extends StatefulWidget {
  const KvBurialMark({
    super.key,
    required this.state,
    required this.confirmations,
    required this.maturity,
    required this.direction,
    required this.isCoinbase,
    required this.thresholds,
    this.fontSize = 11,
  });

  final TxChipState state;

  /// `metaMono`'s 11 by default; the ledger row passes `sub`'s 13, because
  /// the render sets `Settled · 2 h ago` as one 13 dp line (S1, D-261).
  final double fontSize;
  final int? confirmations;
  final MaturityState maturity;

  /// One `MaturityState` means different things on a spend and on a receive —
  /// see [KvBurial.rungFor].
  final ActivityDirection direction;

  /// A mined output matures at a different depth (D-249's last finding).
  final bool isCoinbase;

  /// The pin's own thresholds, crossed from `NetworkParams` (D-249).
  final KvMaturity thresholds;

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
  /// replaced it with the settled word — the row claiming to have crossed the
  /// ceiling while the last number it ever showed was ninety-six. The gauge had
  /// the same defect and was fixed first; this is the second register, and a
  /// rule swept once is a rule swept nowhere (L144, `ux-auditor`, UX-5).
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
  /// often — a depth reading **arriving late**, where a row read `Settled` from
  /// its maturity flag and then learns it is only fifty deep. Crossfaded, that
  /// superimposes two states on one face for 160 ms, which is BG-20
  /// (`ux-auditor`, D-229). The counter needs no reset for it —
  /// [KvStreamingCount] snaps on a decrease by its own rule, so a depth that
  /// went down does not stream down to meet it.
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
    final rung = KvBurial.rungFor(
      widget.state,
      depth,
      widget.maturity,
      direction: widget.direction,
      isCoinbase: widget.isCoinbase,
      thresholds: widget.thresholds,
    );
    final previous = _shown;
    if (previous != null && rung.index < previous.index) _epoch++;
    _shown = rung;

    // **The rung change crosses, it does not cut** (BG-24, D-229). The
    // amber -> green -> blue crossings are the moments the money changes what
    // it licenses, and they were hard swaps: a different `_Mark` returned on
    // the next rebuild with nothing between.
    //
    // **The geometry belongs to the rung arriving, from the first frame.**
    // A crossfade alone does not discharge BG-24, it relocates the cut: the
    // switcher's default stack holds the LARGER of the two children for the
    // whole 160 ms and releases in one frame, so a widening word moved the
    // timestamp beside it in a single un-eased step at the END of a transition
    // that had already finished visually (`ux-auditor`, D-229).
    //
    // So the outgoing mark is `Positioned` — present, fading, and **sizing
    // nothing**. The row takes the incoming width immediately, which puts the
    // one width change at the same instant as the fade that explains it,
    // left-aligned so the words settle where they started.
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
          hue: KvBurial.hueFor(rung),
          words: KvBurial.words(rung, depth: depth),
          mono: rung == KvBurialRung.accepted && depth != null,
          fontSize: widget.fontSize,
        ),
      ),
    );
  }
}

/// A dot and a word.
///
/// **Every rung keeps its dot, including the terminal one.** The retired ladder
/// dropped the mark at `final` on the argument that a state which never changes
/// again is not an indicator — but `Settled` is not that state: D-249 struck the
/// irreversibility claim, and a settled row can still be displaced. The dot is
/// what carries D-248's fourth hue to the ledger, and BG-7 wants the hue
/// present wherever the word is.
class _Mark extends StatelessWidget {
  const _Mark({
    required this.hue,
    required this.words,
    this.mono = false,
    this.fontSize = 11,
  });

  final double fontSize;
  final Color hue;
  final String words;
  final bool mono;

  /// The run, split at the first digit: word in Jakarta, number in mono.
  /// Tabular figures ride the number alone, which is where they mean something
  /// — a depth ticking ten times a second must not jiggle (§4).
  TextSpan _spans(String text, double size) {
    const base = TextStyle(
      height: 18 / 13,
      fontWeight: FontWeight.w500,
      fontVariations: KvWeight.w500,
      // The dot carries the hue; the words do not (§1.5).
      color: KvColor.inkDim,
    );
    final split = text.indexOf(RegExp(r'[0-9]'));
    if (!mono || split <= 0) {
      return TextSpan(
        text: text,
        style: base.copyWith(fontFamily: KvFont.ui, fontSize: size),
      );
    }
    return TextSpan(
      style: base.copyWith(fontSize: size),
      children: [
        TextSpan(
          text: text.substring(0, split),
          style: const TextStyle(fontFamily: KvFont.ui),
        ),
        TextSpan(
          text: text.substring(split),
          style: const TextStyle(
            fontFamily: KvFont.mono,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // No bloom: §1.5 reserves that for a lamp, and a ledger of pending
        // rows must not spend the screen's emission budget one row at a time.
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: hue, shape: BoxShape.circle),
        ),
        const SizedBox(width: KvSpace.xs),
        // Bounded, or the longest word in the set — `Not accepted yet` — walks
        // straight out of a 320dp row at 1.3x. The `Wrap` above gives this a
        // width; the flex is what makes it use it.
        // **Digits in mono, the word in Jakarta** (BG-30, and the ledger row's
        // own `Yesterday, 09:14` is set exactly so). The whole run used to take
        // `KvFont.mono` whenever a depth was present, which put the *word*
        // `Accepted` in JetBrains Mono in every ledger row — mono is for digits
        // and identifiers, and a word borrowing the figure's face is the seam
        // BG-30 closes (`ux-auditor`, UX-R3).
        Flexible(
          child: Text.rich(
            _spans(words, fontSize),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
