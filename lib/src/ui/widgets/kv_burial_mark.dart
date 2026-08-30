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
/// Under a hundred the row shows an amber dot and *the streaming number alone*
/// — a live count says more than any word, so the word steps aside and `Seen`
/// appears only when the depth cannot be computed. At a hundred the dot turns
/// green and the row says `Confirmed`. At a thousand the dot goes away entirely
/// and the row says `final`, because a mark that never changes again is not an
/// indicator.
///
/// **It will not claim `final` from a maturity flag.** A confirmed row whose
/// depth cannot be computed — a stale link, a cold start, a row the live DAA
/// cannot anchor — reads `Confirmed`, which is what the pin actually said.
/// Depth is what earns the third word, and without it the honest answer is the
/// second.
class KvBurialMark extends StatelessWidget {
  const KvBurialMark({
    super.key,
    required this.state,
    required this.confirmations,
    required this.maturity,
    this.verbose = false,
  });

  final TxChipState state;
  final int? confirmations;
  final MaturityState maturity;

  /// Names the number as well as showing it — `Seen 42` rather than `42`.
  /// A feed stays terse; a receipt explains itself.
  final bool verbose;

  /// D-192's two thresholds, named once.
  static const int safe = 100;
  static const int settled = 1000;

  @override
  Widget build(BuildContext context) {
    // A stalled submit is a fault, not a depth, and keeps its sentence.
    if (state == TxChipState.stalled) {
      return const _Mark(tone: KvLampTone.warn, words: 'Not accepted yet');
    }
    final n = confirmations;
    if (n == null) {
      if (maturity == MaturityState.pending) {
        return const _Mark(tone: KvLampTone.warn, words: 'Seen');
      }
      return const _Mark(tone: KvLampTone.ok, words: 'Confirmed');
    }
    if (n < safe) {
      // **The feed shows the number alone; a receipt names it.** In a ledger
      // of many rows the live count says more than any word and the word
      // steps aside — that is the density argument, and it holds for a feed.
      // On the signing receipt there is one transaction and room to say what
      // the number MEANS, so it reads `Seen 42` (founder, on glass
      // 2026-08-30). Same ladder, same thresholds, same data.
      // **Streamed, not stepped** (D-226). The depth is read on a 1 Hz poll;
      // replaying the interval between the last two readings at the panel's
      // refresh rate makes the count move rather than tick. Every frame is a
      // depth the chain actually reached, and the count never runs past the
      // newest reading — a burial depth that overstated itself, even by one,
      // would be the gauge lying about how buried the money is.
      return KvStreamingCount(
        value: BigInt.from(n),
        builder: (context, shown) => _Mark(
          tone: KvLampTone.warn,
          words: verbose ? 'Seen $shown' : '$shown',
          mono: true,
        ),
      );
    }
    if (n < settled) {
      return const _Mark(tone: KvLampTone.ok, words: 'Confirmed');
    }
    return const _Mark(words: 'final');
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
