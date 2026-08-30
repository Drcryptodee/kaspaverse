import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart';
import '../theme/tokens.dart';
import 'kv_status_chip.dart';
import 'kv_streaming_count.dart';
import 'tx_status_chip.dart';

/// How deeply a row is buried, in the vocabulary D-192 settled for the
/// transaction-detail gauge: **100 is safe, 1,000 is final.**
///
/// **The vocabulary is `Seen` -> `Confirmed` -> `final`** (founder, 2026-08-27).
/// Not "pending": pending describes what the WALLET is doing about a
/// transaction, and what the user needs is what the NETWORK has done with it.
/// The network has seen it, then confirmed it, then buried it past reversal —
/// three facts about the chain, in the chain's order.
///
/// Under a hundred the row shows an amber dot, the word `Seen` **and** the
/// streaming depth beside it — the two travel together on every surface
/// (founder, on glass 2026-08-30; see the branch below for why the word no
/// longer steps aside). At a hundred the dot turns green and the row says
/// `Confirmed`. At a thousand the dot goes away entirely and the row says
/// `final`, because a mark that never changes again is not an indicator.
///
/// **Each crossing between those rungs is a crossfade, never a cut** (BG-24,
/// D-229).
///
/// **It will not claim `final` from a maturity flag.** A confirmed row whose
/// depth cannot be computed — a stale link, a cold start, a row the live DAA
/// cannot anchor — reads `Confirmed`, which is what the pin actually said.
/// Depth is what earns the third word, and without it the honest answer is the
/// second.
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

  /// D-192's two thresholds, named once.
  static const int safe = 100;
  static const int settled = 1000;

  /// Which rung of the ladder a row is on. **This, and not the words, is what
  /// the crossfade is keyed on** (BG-24): the depth streams every frame inside
  /// the `Seen` rung, and a switcher keyed on the rendered text would crossfade
  /// the row sixty times a second.
  static _Rung _rungFor(TxChipState state, int? n, MaturityState maturity) {
    if (state == TxChipState.stalled) return _Rung.stalled;
    if (n == null) {
      return maturity == MaturityState.pending ? _Rung.seen : _Rung.confirmed;
    }
    if (n < safe) return _Rung.seen;
    if (n < settled) return _Rung.confirmed;
    return _Rung.settled;
  }

  _Rung get _rung => _rungFor(state, confirmations, maturity);

  @override
  State<KvBurialMark> createState() => _KvBurialMarkState();
}

class _KvBurialMarkState extends State<KvBurialMark> {
  late _Rung _rung = widget._rung;

  /// True when the rung most recently changed **downward**.
  ///
  /// A rung that goes down is not progress. Two things cause it and neither
  /// should be dressed as movement: a **reorg**, which BG-18 says snaps rather
  /// than animating backwards as if burial were being undone, and — far more
  /// often — a depth reading **arriving late**, where a row read `Confirmed`
  /// from its maturity flag and then learns it is only fifty deep. Crossfaded,
  /// that superimposes `Confirmed` over `Seen 50` for 160 ms: two states
  /// wearing one face, which is BG-20 (`ux-auditor`, D-229).
  /// Bumped on every BACKWARD rung change, and it is the switcher's key — so
  /// the switcher itself is remounted rather than asked to animate in zero
  /// time. `duration: Duration.zero` looks like the obvious way to say "snap"
  /// and does not work: the outgoing child is never released, so both rungs
  /// stay mounted for good (measured, not assumed). A fresh switcher shows its
  /// first child with no animation by construction, which is exactly the
  /// semantics wanted — and it resets `KvStreamingCount` with it, which is
  /// also right: a depth that went down does not stream down to meet it.
  int _epoch = 0;

  @override
  void didUpdateWidget(KvBurialMark old) {
    super.didUpdateWidget(old);
    final next = widget._rung;
    if (next != _rung) {
      if (next.index < _rung.index) _epoch++;
      _rung = next;
    }
  }

  @override
  Widget build(BuildContext context) {
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
      child: KeyedSubtree(key: ValueKey(_rung), child: _body()),
    );
  }

  Widget _body() {
    final state = widget.state;
    final maturity = widget.maturity;
    // A stalled submit is a fault, not a depth, and keeps its sentence.
    if (state == TxChipState.stalled) {
      return const _Mark(tone: KvLampTone.warn, words: 'Not accepted yet');
    }
    final n = widget.confirmations;
    if (n == null) {
      if (maturity == MaturityState.pending) {
        return const _Mark(tone: KvLampTone.warn, words: 'Seen');
      }
      return const _Mark(tone: KvLampTone.ok, words: 'Confirmed');
    }
    if (n < KvBurialMark.safe) {
      // **`Seen` STAYS while the number streams** (founder, on glass
      // 2026-08-30, revising the density call made earlier the same day). The
      // word used to step aside the moment a count arrived, so a row read
      // `Seen` and then bare `42` — the label vanishing at exactly the moment
      // it became meaningful. A number alone does not say what it counts, and
      // the ladder's whole job is to say how buried the money is. The word and
      // the number now travel together on every surface, and the `verbose`
      // flag that used to decide it is gone — a parameter that no longer
      // changes anything is the API-level form of a control that does nothing.
      //
      // **Streamed, not stepped** (BG-18 / D-226). The depth is read on a 1 Hz
      // poll; replaying the interval between the last two readings at the
      // panel's refresh rate makes the count move rather than tick. Every frame
      // is a depth the chain actually reached, and the count never runs past
      // the newest reading — a burial depth that overstated itself, even by
      // one, would be the gauge lying about how buried the money is.
      return KvStreamingCount(
        value: BigInt.from(n),
        builder: (context, shown) => _Mark(
          tone: KvLampTone.warn,
          // `shown` is null only when there is no reading, and this branch is
          // reached with one in hand — so the fallback is the observed count,
          // never a blank where a depth belongs.
          words: 'Seen ${shown ?? n}',
          mono: true,
        ),
      );
    }
    if (n < KvBurialMark.settled) {
      return const _Mark(tone: KvLampTone.ok, words: 'Confirmed');
    }
    return const _Mark(words: 'final');
  }
}

/// The rungs of the ladder, which is what a crossing is between.
enum _Rung { stalled, seen, confirmed, settled }

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
