import '../../rust/api/wallet.dart';
import 'kv_amount.dart';
import 'kv_glyph.dart';

/// **How one transaction names itself** — the word, the mark and the money
/// direction, resolved once.
///
/// Direction rides four ways at once — word, sign, colour and weight — so a
/// row survives greyscale, colour-blindness and a screen reader (BG-7).
/// [KvAmount] carries the last three; the [title] here is the word.
///
/// It is a function rather than a private switch inside the ledger row because
/// UX-5 gave the same transaction a second surface. A detail screen with its
/// own copy of this switch is how one of them ends up saying `Sent` where the
/// other says `Consolidated` — L143's shape, in vocabulary rather than
/// formatting, which is exactly where it turned up a second time (D-229's
/// finding 7).
typedef KvActivityFace = ({
  KvGlyph mark,
  KvMoneyDirection direction,
  String title,
});

KvActivityFace kvActivityFace(ActivityRecord record) =>
    switch (record.direction) {
      ActivityDirection.incoming => (
        mark: KvGlyph.arrowIn,
        direction: KvMoneyDirection.incoming,
        // A coinbase is money that was mined to this wallet, not money someone
        // sent it, and the two are different facts about where value came from.
        title: record.isCoinbase ? 'Mined' : 'Received',
      ),
      ActivityDirection.outgoing => (
        mark: KvGlyph.arrowOut,
        direction: KvMoneyDirection.outgoing,
        title: 'Sent',
      ),
      // Value that never left the wallet. Unsigned and colourless: nothing
      // arrived and nothing went.
      ActivityDirection.change => (
        mark: KvGlyph.selfSend,
        direction: KvMoneyDirection.internal,
        title: 'Consolidated',
      ),
    };
