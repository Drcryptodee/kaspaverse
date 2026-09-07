import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart' show WalletAddressDto;
import '../address_order.dart';
import '../address_text.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_check.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_reading.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_sheet.dart';

/// **`Receive at`** — which of the wallet's own addresses the QR upstairs
/// shows.
///
/// Every address here is derived from the same account key, so the choice is
/// cosmetic to the balance and material to the person paying you: it decides
/// which string they scan. Nothing here can lose money — that is what the
/// sheet's own first sentence says, and it is why this surface has no warning.
///
/// ## What `FRESH` means
///
/// **An address with nothing in it.** Founder's ruling on glass, 2026-09-07:
/// *"'fresh' address simply mean an address with zero balance."* `USED` is the
/// complement — it is holding coins, or something is on its way to it.
///
/// It replaced a narrower claim that was true and awkward. The approved render
/// says `FRESH · never seen on the chain` and gives every used row a
/// `14 received · last 3 Sep` line; **neither can be answered offline**, because
/// a Kaspa node is a UTXO-state machine (`RpcApi` @ `cfafeb4` has no
/// address-history call at all) and INV-8 forbids asking an indexer. The first
/// build therefore said *"not handed out from this phone"*, over a record the
/// app wrote whenever it displayed an address — true, but scoped to one handset
/// and needing a sentence to explain itself.
///
/// Balance is better on every axis: the node answers it, a restored wallet gets
/// the same answer as the one that earned the coins, and it needs no local
/// state at all. The handout record and its FFI seam were **removed** with it
/// (D-295) rather than left as a field nothing reads. [AddressOrder] holds the
/// rule, because `T4`'s list obeys it too.
///
/// A coin count replaces the render's `14 received` for the same reason: what
/// is HERE is checkable, what once arrived is not.
class ReceivePicker extends StatefulWidget {
  const ReceivePicker({
    required this.addresses,
    required this.selected,
    super.key,
  });

  /// The wallet's receive window, balances folded in. The sheet calls it once.
  final Future<List<WalletAddressDto>> Function() addresses;

  /// Which index the screen behind is showing, so the sheet can mark it.
  final int selected;

  /// **The deepest index this sheet will OFFER as fresh.**
  ///
  /// Handing out an address is a promise that the money will be findable
  /// again, and the honest bound on that promise is how deep this app's own
  /// rediscovery reaches: `MANUAL_DISCOVERY_DEPTH` in `bridge::api::wallet`,
  /// which probes indices 0…2047 and is the deepest pass the app has. The
  /// watch window is `mark + GAP_LIMIT`, so it can run past that — and an
  /// address offered past it is one a restore of this very wallet would not
  /// find (`consensus`, this sitting).
  ///
  /// Unreachable in practice: reaching a mark of 2019 needs 2019 funded
  /// receive addresses. It is a floor under a promise, not a live guard, and
  /// the number is mirrored rather than shared because it lives in Rust —
  /// `wallet.rs` names this constant beside its own so a change to one finds
  /// the other.
  ///
  /// **It bounds the OFFER, not the list**: an address already handed out or
  /// already holding coins is still shown under `USED`, because hiding it
  /// would hide money. `T4`'s list, which audits rather than offers, shows
  /// every watched address at every depth.
  static const int deepestOffer = 2048;

  /// Fresh addresses shown before the list folds. A fresh wallet has thirty of
  /// them and they are interchangeable by definition; the useful offer is the
  /// next few, with the rest one tap away — the same `Show` idiom `T4` uses for
  /// its empty tail.
  static const int freshPreview = 5;

  /// Open the sheet. Resolves to the chosen address, or null on cancel.
  static Future<WalletAddressDto?> open(
    BuildContext context, {
    required Future<List<WalletAddressDto>> Function() addresses,
    required int selected,
  }) => Navigator.of(context).push(
    KvSheetRoute<WalletAddressDto>(
      builder: (_) => ReceivePicker(addresses: addresses, selected: selected),
    ),
  );

  /// Holding something, so it is `USED`. The law is [AddressOrder]'s, stated
  /// once and obeyed by every surface that draws these rows.
  static bool isUsed(WalletAddressDto a) => AddressOrder.holdsSomething(a);

  /// `Main` for the wallet's default, `Receive 05` for the rest — zero-padded,
  /// as `T4` prints it, because the index is a slot in a derivation path and a
  /// padded slot sorts and scans as one.
  static String labelFor(int index) =>
      index == 0 ? 'Main' : 'Receive ${index.toString().padLeft(2, '0')}';

  /// The line under the pill on the Receive screen: which of the three states
  /// this address is in, and one checkable fact about it.
  ///
  /// `Default` takes the state slot for index 0 — the render's own choice, and
  /// the right one: which address the wallet uses by itself is more useful to
  /// know about it than whether it has been handed out.
  ///
  /// The render's fact is `14 received`. This one counts what is **here**,
  /// because that is the half a node can answer (the class doc).
  static ReceiveCaption captionFor(WalletAddressDto a) {
    final state = a.index == 0 ? 'Default' : (isUsed(a) ? 'Used' : 'Fresh');
    if (a.coinCount > 0) {
      return ReceiveCaption(
        state: state,
        figure: a.coinCount,
        words: a.coinCount == 1 ? 'coin here' : 'coins here',
      );
    }
    return ReceiveCaption(
      state: state,
      words: a.settling ? 'something on its way' : 'zero balance',
    );
  }

  @override
  State<ReceivePicker> createState() => _ReceivePickerState();
}

class _ReceivePickerState extends State<ReceivePicker> {
  late Future<List<WalletAddressDto>> _addresses = widget.addresses();

  /// The fresh card's reading level. Held here, not inside the scope, because
  /// `Show` reaches it from outside the card — the same arrangement `T4`'s
  /// `All` and the home feed use.
  final _fresh = KvReadingController();

  @override
  void dispose() {
    _fresh.dispose();
    super.dispose();
  }

  void _retry() {
    final next = widget.addresses();
    setState(() => _addresses = next);
  }

  void _choose(WalletAddressDto a) {
    KvHaptic.selection();
    Navigator.of(context).pop(a);
  }

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'Receive at',
      onCancel: () => Navigator.of(context).pop(),
      child: KvScrollEdge(
        // The sheet's own ground, not the page's — the fade resolves to what
        // is actually behind the rows.
        ground: KvColor.plate,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: KvSpace.s),
              // The render's own sentence, kept word for word: it is the whole
              // trust story of this sheet and it is why no warning belongs on
              // it (§7.1 — three short statements, each carrying one fact).
              const Text(
                'Every address here belongs to this wallet. Anything sent to '
                'any of them lands in the same balance.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 21 / 15,
                  color: KvColor.inkMeta,
                ),
              ),
              const SizedBox(height: KvSpace.s),
              FutureBuilder<List<WalletAddressDto>>(
                future: _addresses,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const _Waiting();
                  }
                  final list = snapshot.data;
                  if (list == null || list.isEmpty) {
                    return _Failed(
                      error: displayError(
                        snapshot.error ?? 'no addresses came back',
                      ),
                      onRetry: _retry,
                    );
                  }
                  return _Groups(
                    addresses: list,
                    selected: widget.selected,
                    fresh: _fresh,
                    onChoose: _choose,
                  );
                },
              ),
              const SizedBox(height: KvSpace.s),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two groups, in the order the render draws them: what you can hand out
/// next, then what you have handed out already.
class _Groups extends StatelessWidget {
  const _Groups({
    required this.addresses,
    required this.selected,
    required this.fresh,
    required this.onChoose,
  });

  final List<WalletAddressDto> addresses;
  final int selected;
  final KvReadingController fresh;
  final void Function(WalletAddressDto) onChoose;

  /// The fresh card at rest — four and a half rows, so the half row says there
  /// is more without a control having to. `T4`'s own number.
  static const double restCap = KvRow.height * 4.5;

  @override
  Widget build(BuildContext context) {
    final ordered = AddressOrder.sorted(addresses);
    final used = ordered.where(ReceivePicker.isUsed).toList(growable: false);
    final freshRows = ordered
        .where(
          (a) =>
              !ReceivePicker.isUsed(a) && a.index < ReceivePicker.deepestOffer,
        )
        .toList(growable: false);
    // Index order within each group — a derivation slot, and the order `T4`
    // prints. The render sorts its used group by last receipt, a date this
    // wallet cannot know (see the class doc).

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (freshRows.isNotEmpty) ...[
          const KvSectionHeader('FRESH', gloss: 'zero balance'),
          // **The reading room, exactly as `T4`'s `All` uses it** (D-289) —
          // founder, on glass 2026-09-07: *"clicking on 'show' literally does
          // what 'All' does in wallet settings, where it pushes used below a
          // little, and user can scroll it and scrolling back the opposite way
          // snaps it back to position. this should happen on scroll too."*
          //
          // So `Show` is not a filter any more: every fresh address is already
          // in this list, and the control asks for ROOM rather than for rows.
          // The gesture and the motion are the shared part's; this card states
          // only its two caps.
          //
          // **The container is OUTSIDE the cap**, as `T4` has it. Inside, its
          // `Column` hands the list unbounded height and a `shrinkWrap` list
          // takes all of it — 438 dp past the sheet, in a card whose whole job
          // is to be capped.
          KvReadingScope(
            controller: fresh,
            builder: (context, reading) => KvRowContainer(
              ground: KvColor.chip,
              divided: false,
              children: [
                KvExpands(
                  rest: restCap,
                  reading: _readingCap(context),
                  child: KvScrollEdge(
                    ground: KvColor.chip,
                    child: KvReadingArea(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        // Below the cap nothing scrolls, so the sheet's own
                        // scroll keeps working over the card; at the cap this
                        // list takes the drag.
                        physics: const ClampingScrollPhysics(),
                        itemCount: freshRows.length,
                        itemBuilder: (context, i) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (i > 0) const KvHairline(),
                            _AddressRow(
                              address: freshRows[i],
                              selected: freshRows[i].index == selected,
                              onTap: () => onChoose(freshRows[i]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // The opener is the card's FOOTER, not the list's last row —
                // inside the scroll it is the one thing a clipped list hides,
                // which `T4` found in a frame at 320 dp / 1.3×.
                if (freshRows.length > _restRows &&
                    !reading.value.reaches(KvReadingLevel.full)) ...[
                  const KvHairline(),
                  KvFoldRow(
                    figure: freshRows.length,
                    words: freshRows.length == 1
                        ? ' address with zero balance'
                        : ' addresses with zero balance',
                    semanticLabel:
                        'Show all ${freshRows.length} addresses with zero '
                        'balance',
                    // `inkMeta` measures 4.30 on `chip` — BG-14's one standing
                    // prohibition, and this card is on `chip`.
                    tone: KvColor.inkDim,
                    onTap: () {
                      KvHaptic.selection();
                      reading.openFully();
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
        if (used.isNotEmpty) ...[
          const KvSectionHeader('USED', gloss: 'holding coins'),
          _Card(
            rows: [
              for (final a in used)
                _AddressRow(
                  address: a,
                  selected: a.index == selected,
                  onTap: () => onChoose(a),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Rows the resting cap shows whole.
  static const int _restRows = 4;

  /// The cap while it is being read: most of the sheet, so the fresh list has
  /// somewhere to grow into and `USED` is pushed down rather than replaced.
  static double _readingCap(BuildContext context) => math.max(
    restCap,
    MediaQuery.sizeOf(context).height * KvSheet.maxHeightFraction * 0.62,
  );
}

/// One group's card: rows on the sheet's inner ground, ruled between.
class _Card extends StatelessWidget {
  const _Card({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return KvRowContainer(
      // **`chip`, because the sheet under it is `plate`** (§1.1: a card inside
      // a sheet is a step up). Left at the default the card painted #121717 on
      // a #121717 panel and drew nothing at all — the render measures it at
      // `chip` with the disc a further step up (`ux-auditor`, D-293).
      ground: KvColor.chip,
      divided: false,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const KvHairline(),
          rows[i],
        ],
      ],
    );
  }
}

/// One address: what it is called, the address itself, and what it holds.
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.address,
    required this.selected,
    required this.onTap,
  });

  final WalletAddressDto address;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = address;
    final used = ReceivePicker.isUsed(a);
    final label = ReceivePicker.labelFor(a.index);
    // Spoken and printed are the same figure (`kv_amount.dart`'s own rule):
    // never sompi, which is a hundred million times the number on the glass
    // read out to the one user who cannot check it.
    final spoken = [
      label,
      used ? 'used' : 'zero balance',
      if (a.balanceSompi > BigInt.zero) '${kasSpoken(a.balanceSompi)} KAS',
      if (a.lockedSompi > BigInt.zero) '${kasSpoken(a.lockedSompi)} KAS locked',
      if (selected) 'showing now',
    ].join(', ');

    return KvRow(
      leading: KvRowDisc(
        mark: used ? KvGlyph.history : KvGlyph.circleDashed,
        // One step above the `chip` card it sits on, with the render's own
        // glyph tone — `KvRowDisc.neutral` is the `plate`-card seat and would
        // have drawn a `chip` disc on a `chip` card.
        tint: KvColor.chipPressed,
        tone: KvColor.inkDim,
      ),
      title: label,
      badge: a.index == 0 ? const KvDefaultChip() : null,
      subWidget: Padding(
        padding: const EdgeInsets.only(top: KvSpace.xs),
        child: AddressText(a.address, tight: true),
      ),
      dense: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A fresh address holds nothing by definition, so it prints no
          // figure — a column of zeros beside interchangeable addresses is
          // noise, and BG-8's rule is about unknowns, not about absences.
          if (used)
            Flexible(
              child: KvAmount(
                a.balanceSompi,
                role: KvAmountRole.row,
                showUnit: false,
                // Holding nothing is a fact, not a fault: it recedes rather
                // than shouting a zero at a balance's weight.
                muted: a.balanceSompi == BigInt.zero,
              ),
            ),
          if (selected) ...[const SizedBox(width: KvSpace.s), const KvCheck()],
        ],
      ),
      // `Locked` wins the slot when both apply: a coin the wallet will never
      // move is a harder fact than one merely on its way.
      // **`Accepted`, not `Pending`** (founder, on glass 2026-09-07: *"no
      // pending, just Accepted and Settled after 100 blocks"*). The DAG has
      // the coin; the wallet cannot spend it for 100 more blocks. `Pending`
      // said the first half was in doubt when only the second is.
      trailingMeta: a.lockedSompi > BigInt.zero
          ? const KvRowMeta('Locked')
          : (a.settling ? const KvRowMeta('Accepted') : null),
      semanticLabel: spoken,
      onTap: onTap,
    );
  }
}

/// The list has not landed. It reserves a card's worth of height so the sheet
/// does not grow under a thumb already on its way to a row (BG-24).
class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: KvRow.height * 3,
    child: Center(child: KvLoader()),
  );
}

/// Three beats (BG-11): what happened, what it means, what to do.
class _Failed extends StatelessWidget {
  const _Failed({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: KvSpace.m),
    child: Column(
      children: [
        const Text(
          "Couldn't read this wallet's addresses.",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 15,
            height: 21 / 15,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: KvColor.ink,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 14,
            height: 20 / 14,
            color: KvColor.inkDim,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        const Text(
          'The address behind this sheet is still good to receive at.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 14,
            height: 20 / 14,
            color: KvColor.inkDim,
          ),
        ),
        const SizedBox(height: KvSpace.sm),
        KvAction.raised(label: 'Try again', onTap: onRetry),
      ],
    ),
  );
}

/// The Receive screen's line under the pill, split so BG-30 can hold: **the
/// figure is mono and the words are not**.
///
/// A plain sentence would have had to be re-split at the render layer by
/// hunting for a digit run, which is the kind of parsing that survives exactly
/// until a count reaches four digits.
class ReceiveCaption {
  const ReceiveCaption({required this.state, required this.words, this.figure});

  /// `Default`, `Fresh` or `Used` — see [ReceivePicker] for what the last two
  /// are scoped to, which is narrower than the words alone suggest.
  final String state;

  /// The number in the fact, when it has one. Mono.
  final int? figure;

  /// The rest of the fact.
  final String words;

  /// True when the mark for an unhanded-out address belongs before the state
  /// word — the render draws one, and it is the same mark the sheet seats
  /// beside every fresh row.
  bool get fresh => state == 'Fresh';

  /// True when the state is the wallet's default address, which is drawn as the
  /// green `KvDefaultChip` rather than as a word.
  bool get isDefault => state == 'Default';

  /// One line, for a screen reader and for a test.
  String get spoken =>
      figure == null ? '$state · $words' : '$state · $figure $words';
}
