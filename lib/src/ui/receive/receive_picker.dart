import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart' show WalletAddressDto;
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
/// ## What `FRESH` means, and what it deliberately does not
///
/// The approved render splits the list into `FRESH · never seen on the chain`
/// and `USED · has received before`, and gives every used row a `14 received ·
/// last 3 Sep` history line. **Neither claim can be made offline**, so neither
/// is made here.
///
/// A Kaspa node is a UTXO-state machine: it answers *what does this address
/// hold right now* and nothing else. History lives in indexers and INV-8
/// forbids trusting one, which `kaspaverse_chain::discovery` explains at length
/// — it is the same fact that makes address discovery balance-driven. So a
/// mature balance of zero is equally **never seen** and **used and swept**, and
/// no field crossing the bridge can tell them apart.
///
/// What the wallet *can* answer, outright and about itself, is whether **this
/// phone has put an address in front of someone** — the Receive screen records
/// each address it displays (`vault`'s `receive.given`, D-293). That is the
/// split this sheet draws, and every word on it is scoped to it:
///
/// | | says | true because |
/// |:--|:--|:--|
/// | `FRESH` | not handed out from this phone | this app wrote the record |
/// | `USED` | handed out, or holding coins | the record, or the node's own UTXO set |
///
/// The bound is real and stated rather than hidden: a wallet **restored** onto
/// a new phone starts with an empty record, so addresses used on the old one
/// read as fresh until something arrives at them. The group's own sub-label is
/// where that is said — *from this phone*, not *never* — because a header that
/// defines its term is worth more than a paragraph nobody reads.
///
/// A coin count replaces the render's `14 received`: what is HERE is checkable
/// against the node, where what once arrived is not.
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

  /// Has this address been handed out, or does the chain say it holds
  /// something? Either answer puts it under `USED`.
  ///
  /// The chain half is what keeps a **restored** wallet honest: its handout
  /// record is empty, but an address holding coins has plainly received them,
  /// and filing that under "fresh" would be the one reading this sheet must
  /// never produce.
  static bool isUsed(WalletAddressDto a) =>
      a.givenOut ||
      a.balanceSompi > BigInt.zero ||
      a.lockedSompi > BigInt.zero ||
      a.settling;

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
      words: a.settling
          ? 'something on its way'
          : (isUsed(a) ? 'nothing here now' : 'not handed out yet'),
    );
  }

  @override
  State<ReceivePicker> createState() => _ReceivePickerState();
}

class _ReceivePickerState extends State<ReceivePicker> {
  late Future<List<WalletAddressDto>> _addresses = widget.addresses();
  bool _allFresh = false;

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
                    allFresh: _allFresh,
                    onShowAllFresh: () {
                      KvHaptic.selection();
                      setState(() => _allFresh = true);
                    },
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
    required this.allFresh,
    required this.onShowAllFresh,
    required this.onChoose,
  });

  final List<WalletAddressDto> addresses;
  final int selected;
  final bool allFresh;
  final VoidCallback onShowAllFresh;
  final void Function(WalletAddressDto) onChoose;

  @override
  Widget build(BuildContext context) {
    final used = addresses.where(ReceivePicker.isUsed).toList(growable: false);
    final fresh = addresses
        .where(
          (a) =>
              !ReceivePicker.isUsed(a) && a.index < ReceivePicker.deepestOffer,
        )
        .toList(growable: false);
    // Index order in both, which is the order a derivation path has and the
    // order `T4` already prints. The render sorts its used group by last
    // receipt — a date this wallet cannot know (see the class doc).
    final freshShown = allFresh
        ? fresh
        : fresh.take(ReceivePicker.freshPreview).toList(growable: false);
    final foldedAway = fresh.length - freshShown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fresh.isNotEmpty) ...[
          const KvSectionHeader(
            'FRESH',
            gloss: 'not handed out from this phone',
          ),
          _Card(
            rows: [
              for (final a in freshShown)
                _AddressRow(
                  address: a,
                  selected: a.index == selected,
                  onTap: () => onChoose(a),
                ),
            ],
            // The opener is the card's footer, not the list's last row — `T4`
            // learned that one in a preview frame at 320 dp / 1.3×, where a
            // control inside the scroll went below the fold exactly when it
            // was needed.
            footer: foldedAway > 0
                ? KvFoldRow(
                    figure: foldedAway,
                    words: foldedAway == 1
                        ? ' more fresh address'
                        : ' more fresh addresses',
                    semanticLabel:
                        'Show $foldedAway more fresh '
                        '${foldedAway == 1 ? 'address' : 'addresses'}',
                    // `inkMeta` measures 4.30 on `chip` — BG-14's one standing
                    // prohibition, and this card is on `chip`.
                    tone: KvColor.inkDim,
                    onTap: onShowAllFresh,
                  )
                : null,
          ),
        ],
        if (used.isNotEmpty) ...[
          const KvSectionHeader('USED', gloss: 'handed out, or holding coins'),
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
}

/// One group's card: rows on the sheet's inner ground, ruled between.
class _Card extends StatelessWidget {
  const _Card({required this.rows, this.footer});

  final List<Widget> rows;
  final Widget? footer;

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
        if (footer case final footer?) ...[const KvHairline(), footer],
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
      used ? 'used' : 'fresh',
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
      trailingMeta: a.lockedSompi > BigInt.zero
          ? const KvRowMeta('Locked')
          : (a.settling ? const KvRowMeta('Pending') : null),
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

  /// One line, for a screen reader and for a test.
  String get spoken =>
      figure == null ? '$state · $words' : '$state · $figure $words';
}
