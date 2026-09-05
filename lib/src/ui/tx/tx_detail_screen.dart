import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/wallet.dart';
import '../format.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_activity.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_burial_gauge.dart';
import '../widgets/kv_burial_mark.dart';
import '../widgets/kv_check.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_derived.dart';
import '../widgets/kv_explorer_exit.dart';
import '../widgets/kv_fact_line.dart';
import '../widgets/kv_fiat.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_icon_button.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_surface.dart';
import '../widgets/kv_two_pane.dart';

/// **Transaction detail** — one transaction, at full size, with the burial
/// gauge the money screen has no room for (`S9`, §5, D-191/D-248).
///
/// The ledger row answers *what happened*; this answers *how settled is it*.
/// Kaspa runs at about ten blocks a second, so the hundred DAA a payment waits
/// to become spendable is a ten-second event — watchable, which is why the
/// gauge here is a live instrument rather than a static mark.
///
/// **The composition is `S9`'s and it was measured, not eyeballed** (D-266):
/// a 56 dp direction disc in the direction's tint, the amount at 44 in the
/// direction's hue (the render's integer cap is 32.0 dp — 44 at JetBrains
/// Mono's 0.739 ratio, with its fraction at exactly half), the `≈` restatement,
/// one lifecycle chip, a plate for the depth and a plate for the facts, and two
/// raised actions on a bar that never scrolls.
///
/// **It stays live, and each region listens only to what it renders.** The
/// record is looked up out of the activity feed on every change of the feed —
/// a screen opened on a send that is four blocks deep is a screen the user is
/// watching precisely because the number is going to change — but the first
/// cut listened to *everything* at the top and rebuilt the whole body on every
/// DAA tick: **184 elements ten times a second**, the head, the amount, the
/// facts plate and the action bar included, measured with the framework's own
/// `debugOnRebuildDirtyWidget` at UX-R3's second beat. Now the record is a
/// [KvDerived] that notifies only when *this* transaction's row changes, the
/// depth is a second one over the record and the chain clock, and the head,
/// the facts and the bar never hear a tick at all. Everything is injected as
/// listenables, so the surface renders in a widget test with no native library.
///
/// **A row can leave the feed** — the list arrives already truncated by Rust —
/// so "this transaction is no longer in the recent activity" is a state with a
/// face of its own (BG-20) rather than an empty screen.
class TxDetailScreen extends StatefulWidget {
  const TxDetailScreen({
    super.key,
    required this.txid,
    required this.activity,
    required this.virtualDaaScore,
    required this.stale,
    required this.maturity,
    this.explorerUrl,
    this.openUrl,
    this.fiat,
    this.contacts,
    this.onSendAgain,
    this.onShare,
  });

  /// The transaction this screen is about. The identity, not the snapshot.
  final String txid;

  final ValueListenable<List<ActivityRecord>> activity;

  /// The live DAA the burial depth is measured against.
  final ValueListenable<BigInt?> virtualDaaScore;

  /// The link is not live, so nothing counts (BG-8).
  final ValueListenable<bool> stale;

  /// **The pin's own maturity thresholds** (D-249), which decide where this
  /// record's rung sits and where its gauge tops out. Required, and with no
  /// default: a screen whose entire job is answering *how settled is this* must
  /// not answer it against a number it invented.
  final KvMaturity maturity;

  /// Resolves a txid to the exact URL the user's chosen explorer would open.
  /// Null hides the exit entirely — a control with nowhere to go is worse than
  /// no control (BG-12).
  final Future<String> Function(String txid)? explorerUrl;

  final Future<bool> Function(String url)? openUrl;

  /// The `≈` restatement under the figure. **Permitted here** by BG-5 as
  /// amended (D-267): this is a record of what already happened, and fiat
  /// beside history has never been the part of the law that protects anyone.
  final FiatScope? fiat;

  /// The address book, so the chip can say *who* — and only when the book
  /// actually knows. A name never replaces the address, which the facts plate
  /// prints in full below (BG-15).
  final ContactsScope? contacts;

  /// **Send again**, pre-addressed to this transaction's counterparty (`S9`).
  /// Null, or a record with no counterparty, hides it: an action that cannot
  /// name its object is a control with nowhere to go (BG-12).
  final void Function(String address)? onSendAgain;

  /// The bar's share action. Null hides the button rather than dimming it.
  final void Function(String txid)? onShare;

  @override
  State<TxDetailScreen> createState() => _TxDetailScreenState();
}

class _TxDetailScreenState extends State<TxDetailScreen> {
  /// **This transaction's row, and nothing else in the feed.** The feed
  /// notifier fires on every list the wallet lane publishes; this fires only
  /// when the row for [TxDetailScreen.txid] is a different value — the
  /// bridge's `ActivityRecord` compares structurally, so a republished list
  /// carrying the same row is swallowed here (the V4 seam law).
  late final KvDerived<ActivityRecord?> _record = KvDerived(
    [widget.activity],
    () {
      for (final record in widget.activity.value) {
        if (record.txid == widget.txid) return record;
      }
      return null;
    },
  );

  /// The burial depth — the ONE thing on this screen that moves with the
  /// chain. It is the only notifier the chip and the depth plate listen to.
  late final KvDerived<int?> _depth = KvDerived(
    [_record, widget.virtualDaaScore, widget.stale],
    () {
      final record = _record.value;
      if (record == null) return null;
      return KvBurial.depthOf(
        record,
        widget.virtualDaaScore.value,
        stale: widget.stale.value,
      );
    },
  );

  @override
  void dispose() {
    _depth.dispose();
    _record.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onShare = widget.onShare;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // BG-14: the top 52dp belongs to the real system status bar and
            // nothing is painted there.
            const SizedBox(height: KvSpace.statusBarReserve),
            KvTopBar(
              title: 'Transaction',
              onBack: () => Navigator.of(context).pop(),
              // `S9`'s share disc, at the same 44 dp as the back chevron
              // opposite it — one component in two seats (§4, L143).
              trailing: onShare == null
                  ? null
                  : KvIconButton(
                      mark: KvGlyph.share,
                      label: 'Share this transaction',
                      onTap: () => onShare(widget.txid),
                    ),
            ),
            Expanded(
              child: ValueListenableBuilder<ActivityRecord?>(
                valueListenable: _record,
                builder: (context, record, _) => record == null
                    ? _Gone(txid: widget.txid)
                    : _Body(
                        record: record,
                        depth: _depth,
                        stale: widget.stale,
                        maturity: widget.maturity,
                        fiat: widget.fiat,
                        contacts: widget.contacts,
                        explorerUrl: widget.explorerUrl,
                        openUrl: widget.openUrl,
                        onSendAgain: widget.onSendAgain,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The record at full size. Built for one [record] and rebuilt only when that
/// record changes; the two regions that move with the chain listen to
/// [depth] on their own.
class _Body extends StatelessWidget {
  const _Body({
    required this.record,
    required this.depth,
    required this.stale,
    required this.maturity,
    required this.fiat,
    required this.contacts,
    required this.explorerUrl,
    required this.openUrl,
    required this.onSendAgain,
  });

  final ActivityRecord record;
  final ValueListenable<int?> depth;
  final ValueListenable<bool> stale;
  final KvMaturity maturity;
  final FiatScope? fiat;
  final ContactsScope? contacts;
  final Future<String> Function(String txid)? explorerUrl;
  final Future<bool> Function(String url)? openUrl;
  final void Function(String address)? onSendAgain;

  @override
  Widget build(BuildContext context) {
    final (:mark, :direction, :title) = kvActivityFace(record);
    final counterparty = record.counterpartyAddress;
    final book = contacts;
    return Column(
      children: [
        Expanded(
          child: KvColumn(
            gutter: false,
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: KvWindow.of(context).gutter,
              ),
              children: [
                const SizedBox(height: KvSpace.l),
                // **Nothing here dims, and that is the correction.** The head
                // used to sit under `Opacity(0.45)` while the link was stale —
                // dimming the one datum on the screen that CANNOT go stale, the
                // amount the chain already recorded, while the depth that
                // genuinely is unknown stayed at full brightness. BG-8's
                // dimmed-plus-an-age treatment is for a cached reading still
                // being shown; the depth here is not cached but **unknown**, so
                // it takes the dash and says why below (`ux-auditor`, UX-5).
                Entrance(
                  child: _Head(
                    mark: mark,
                    direction: direction,
                    record: record,
                    fiat: fiat,
                  ),
                ),
                const SizedBox(height: KvSpace.m),
                // The chip hears the depth (its rung) and the book (its name),
                // and nothing else.
                Entrance(
                  index: 1,
                  child: ListenableBuilder(
                    listenable: Listenable.merge([depth, ?book?.contacts]),
                    builder: (context, _) => _LifecycleChip(
                      depth: depth.value,
                      record: record,
                      thresholds: maturity,
                      name: counterparty == null
                          ? null
                          : book?.nameFor(counterparty),
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.l),
                // The gauge is the one region that paints on every frame of a
                // crossing, so it rasterises in a layer of its own: a tick
                // repaints the plate and never the amount above or the facts
                // below.
                Entrance(
                  index: 2,
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<int?>(
                      valueListenable: depth,
                      builder: (context, depth, _) => _DepthPlate(
                        record: record,
                        depth: depth,
                        stale: stale,
                        thresholds: maturity,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.m),
                Entrance(
                  index: 3,
                  child: _FactsPlate(
                    record: record,
                    title: title,
                    counterparty: counterparty,
                  ),
                ),
                const SizedBox(height: KvSpace.l),
              ],
            ),
          ),
        ),
        _ActionBar(
          txid: record.txid,
          counterparty: counterparty,
          explorerUrl: explorerUrl,
          openUrl: openUrl,
          onSendAgain: onSendAgain,
        ),
      ],
    );
  }
}

Future<void> _copy(BuildContext context, String value, String said) async {
  await Clipboard.setData(ClipboardData(text: value));
  KvHaptic.selection();
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(said), duration: KvMotion.toast));
  }
}

/// The direction disc, the money, and the `≈` restatement — the three things
/// `S9` puts above the fold, centred.
class _Head extends StatelessWidget {
  const _Head({
    required this.mark,
    required this.direction,
    required this.record,
    required this.fiat,
  });

  final KvGlyph mark;
  final KvMoneyDirection direction;
  final ActivityRecord record;
  final FiatScope? fiat;

  /// `S9`, measured: the disc runs 169.0 → 225.0 dp horizontally and
  /// 99.0 → 155.0 vertically — **56 dp**, on the screen's centre line, in
  /// `riskTint` (51,25,26) with a `risk` (242,109,95) mark. Both token values
  /// exactly.
  static const double disc = 56;

  @override
  Widget build(BuildContext context) {
    final (hue, tint) = switch (direction) {
      KvMoneyDirection.incoming => (KvColor.ok, KvColor.okTint),
      KvMoneyDirection.outgoing => (KvColor.risk, KvColor.riskTint),
      KvMoneyDirection.internal => (KvColor.inkDim, KvColor.chip),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: disc,
            height: disc,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            child: Center(child: KvGlyphIcon(mark, tone: hue, size: 24)),
          ),
        ),
        const SizedBox(height: KvSpace.l),
        Center(
          // **44, measured off the render** — its integer cap is 32.0 dp and
          // its fraction cap 16.5, a ratio of exactly one half, which is 44/22
          // at JetBrains Mono's 0.739 cap ratio. Neither `hero` (48) nor
          // `screen` (40) is that number, so the role carries the *rules* and
          // the size carries the measurement.
          //
          // `hero`, because a record is a **magnitude** — what this
          // transaction was — rather than something about to be committed.
          // With `emphasis: significant`, because the role's default is the
          // wrong half of D-230's split here: a balance keeps the weight on its
          // integer even at `0`, but a record can be 0.005 KAS, and then the
          // one bright character is a leading zero while the digits that are
          // the amount sit small (§8's named anti-pattern). At or above 1 the
          // two rules agree exactly, so this changes only the case that was
          // wrong.
          child: KvAmount(
            record.valueSompi,
            role: KvAmountRole.hero,
            emphasis: KvAmountEmphasis.significant,
            size: 44,
            direction: direction,
          ),
        ),
        const SizedBox(height: KvSpace.s),
        KvFiatLine(
          fiat: fiat,
          sompi: record.valueSompi,
          alignment: MainAxisAlignment.center,
        ),
      ],
    );
  }
}

/// **The lifecycle, as one pill** (`S9`: a 30 dp `okTint` pill carrying a check
/// disc and `Final · sent to Mara`).
///
/// The word is [KvBurial]'s, so this chip, the ledger row's mark and the gauge
/// below cannot disagree about one transaction (BG-21). The hue and its tint
/// are the rung's, which is where D-248's fourth colour is actually spent.
///
/// **The mark is not always a check.** BG-29 gives `KvCheck` one meaning —
/// *yes* — and there is nothing to affirm about a submit the DAG has not
/// accepted, so `Pending` and a stall wear the rung's dot instead. A check that
/// appeared before acceptance would be the reassurance arriving before the fact.
class _LifecycleChip extends StatefulWidget {
  const _LifecycleChip({
    required this.depth,
    required this.record,
    required this.thresholds,
    required this.name,
  });

  final int? depth;
  final ActivityRecord record;
  final KvMaturity thresholds;

  /// The contact name for this record's counterparty, or null when the book
  /// does not know it. **Only a name gets into the chip**: a truncated address
  /// here would be a second, worse rendering of the address the facts plate
  /// prints in full one plate down (BG-15/BG-19).
  final String? name;

  /// `S9`, measured: the pill runs 260.0 → 290.0 dp — **30 dp** — on `okTint`
  /// (15,42,27), the token exactly.
  static const double height = 30;

  @override
  State<_LifecycleChip> createState() => _LifecycleChipState();
}

class _LifecycleChipState extends State<_LifecycleChip> {
  KvBurialRung? _shown;
  int _epoch = 0;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final rung = KvBurial.rungFor(
      widget.depth,
      record.maturity,
      stalled: record.stalled,
      direction: record.direction,
      isCoinbase: record.isCoinbase,
      thresholds: widget.thresholds,
    );
    final hue = KvBurial.hueFor(rung);
    // **The word, never the number** (BG-19). The gauge one plate down carries
    // the count and the extent; a chip that also printed `Accepted 42` would be
    // the same measurement twice on one screen — which is exactly what the
    // first cut did, and what the suite caught.
    final words = KvBurial.rungWord(rung);
    final who = widget.name;
    final said = who == null
        ? words
        : switch (record.direction) {
            ActivityDirection.outgoing => '$words · sent to $who',
            ActivityDirection.incoming => '$words · from $who',
            ActivityDirection.change => words,
          };
    // **The chip crosses, it does not cut** (BG-24). The gauge one plate below
    // tweens the identical crossing over `KvMotion.fast`, and this pill was
    // snapping its ground, swapping its mark and resizing in one frame — the
    // two halves of one fact disagreeing about when the money changed what it
    // licenses (`ux-auditor`, UX-R3). A decrease still snaps: BG-18 wins over
    // BG-24 on a rung that goes down, and the switcher is remounted rather than
    // asked to animate in zero time (`KvBurialMark`'s own mechanism, and the
    // reason `Duration.zero` is not it).
    final previous = _shown;
    final backwards = previous != null && rung.index < previous.index;
    if (backwards) _epoch++;
    _shown = rung;
    final crossing = backwards ? Duration.zero : KvMotion.fast;
    return Center(
      child: AnimatedContainer(
        duration: crossing,
        curve: KvMotion.out,
        // **30 dp at every rung, measured** — and no vertical padding, which
        // is what keeps it so: the check's disc and ring are 28 and sat
        // inside 4 + 4 of padding, so the pill stepped 30 → 36 in one frame at
        // the settled crossing and took both plates beneath it down 6 dp
        // un-eased, on the surface built to watch that crossing (BG-24;
        // `ux-auditor`, measured per frame). `S9` draws the pill in its check
        // state at 30. A minimum rather than a fixed height, so a two-line
        // name at the floor still wraps rather than clips (BG-14).
        constraints: const BoxConstraints(minHeight: _LifecycleChip.height),
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
        decoration: BoxDecoration(
          color: KvBurial.tintFor(rung),
          borderRadius: BorderRadius.circular(KvRadius.control),
        ),
        child: AnimatedSwitcher(
          key: ValueKey(_epoch),
          duration: crossing,
          switchInCurve: KvMotion.out,
          switchOutCurve: KvMotion.out,
          child: KeyedSubtree(
            key: ValueKey(rung),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // **The check earns its place at the terminal rung, and only
                // there** (`S9` draws one; BG-29 gives `KvCheck` one meaning —
                // *yes*). There is nothing to affirm about a submit the DAG has not
                // accepted, or about money that is on chain but not yet spendable,
                // so those wear the rung's dot: a check arriving before the fact
                // would be the reassurance arriving before it is true.
                //
                // The mark stays `ok` at every rung it appears on (D-248's fence:
                // it means *yes*, not *which rung*) and only its ring takes the
                // pill's ground, so a green disc sits cleanly on the blue.
                if (rung == KvBurialRung.settled)
                  KvCheck(ground: KvBurial.tintFor(rung))
                else
                  // §4's lamp anatomy; the ring is the pill's own tint.
                  KvLamp.hued(color: hue, ring: KvBurial.tintFor(rung)),
                const SizedBox(width: KvSpace.s),
                // **The words carry the hue here, and only here.** §1.5 holds a
                // status's sentence at `inkDim` so a fault reads as an indicator
                // coming on — but that rule is written for a chip sitting in a
                // ledger row on the plate. This one sits on the rung's own tint,
                // where `inkDim` measures under AA on `okTint` and `settledTint`
                // alike; the tinted pill IS the indicator, and the label inside it
                // is body text on a coloured ground. Contrast is the token pair's
                // own measurement: `ok`/`okTint` 8.57, `settled`/`settledTint`
                // 8.02, `warn`/`warnTint` 7.64 (BG-14).
                Flexible(
                  child: Text(
                    said,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 14,
                      height: 18 / 14,
                      fontWeight: FontWeight.w600,
                      fontVariations: KvWeight.w600,
                      color: hue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The depth plate: the axis named in capitals, the gauge, and the one sentence
/// that explains a gauge which has stopped.
class _DepthPlate extends StatelessWidget {
  const _DepthPlate({
    required this.record,
    required this.depth,
    required this.stale,
    required this.thresholds,
  });

  final ActivityRecord record;
  final int? depth;
  final ValueListenable<bool> stale;
  final KvMaturity thresholds;

  @override
  Widget build(BuildContext context) {
    return KvSurface(
      padding: const EdgeInsets.all(KvSpace.s20),
      // The link's liveness flips rarely and this plate is the only region it
      // reaches: the gauge stops its counter on it and the caption says why.
      child: ValueListenableBuilder<bool>(
        valueListenable: stale,
        builder: (context, stale, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KvBurialGauge(
              // **The axis, named, on the reading's own row** (BG-22). `S9`
              // sets `DEPTH` at the plate's left edge — measured at 8.25 dp of
              // cap, which is 11 dp of Jakarta at its 0.773 ratio, the `caps`
              // role exactly — with the count hard right on the same line.
              heading: 'Depth',
              stalled: record.stalled,
              confirmations: depth,
              maturity: record.maturity,
              direction: record.direction,
              isCoinbase: record.isCoinbase,
              thresholds: thresholds,
              stale: stale,
            ),
            // **The dash says there is no reading; this says why.** A user
            // watching a gauge that has stopped is owed the reason, and the
            // reason is knowable here — it is the same bit the money plate
            // folds into its trust line (BG-11/BG-20).
            //
            // **Its slot is always reserved and only the ink fades** — the
            // same mechanism Receive's caption uses. Built as a bare
            // conditional it cut in with no transition AND took everything
            // below it down the screen in one frame, every time the link
            // flapped, on a surface whose whole purpose is watching a number
            // that is not moving (BG-24; measured, `ux-auditor`, UX-5).
            const SizedBox(height: KvSpace.s),
            AnimatedOpacity(
              opacity: stale ? 1 : 0,
              duration: KvMotion.fast,
              curve: KvMotion.out,
              child: const Text(
                'The link is not live, so the depth cannot be read.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 11,
                  height: 15 / 11,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The facts plate — what happened, to whom, for what fee, at which score,
/// under which id. It reads the record and nothing that ticks.
///
/// **The labels are `inkMeta`, measured off `S9`** ((122,133,131) at `Sent`,
/// `To`, `Network fee`) — the caps role's tone on a `plate` ground, where it
/// clears AA at 4.75. `KvFactLine`'s default is `inkDim` for the ceremony's
/// `chip` card, where `inkMeta` does not; this plate knows its own ground and
/// says so (BG-14).
class _FactsPlate extends StatelessWidget {
  const _FactsPlate({
    required this.record,
    required this.title,
    required this.counterparty,
  });

  final ActivityRecord record;

  /// `Sent` / `Received` / `Mined` — the record's own verb (`kvActivityFace`).
  final String title;
  final String? counterparty;

  static Widget _fact({
    required String label,
    required String valueText,
    required Widget value,
  }) => KvFactLine(
    label: label,
    labelColor: KvColor.inkMeta,
    valueText: valueText,
    value: value,
  );

  @override
  Widget build(BuildContext context) {
    final at = record.unixtimeMsec;
    final stamp = at == null
        ? null
        : formatStamp(DateTime.fromMillisecondsSinceEpoch(at.toInt()));
    final to = counterparty;
    final score = formatScore(record.acceptedDaaScore ?? record.blockDaaScore);
    return KvSurface(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s20,
        vertical: KvSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **`Sent` / `Received` / `Mined`, and the verb is the record's
          // own** (`kvActivityFace`), so the plate opens by naming what
          // happened rather than repeating a generic `Time`.
          //
          // It states what is true of BOTH clocks behind it without claiming
          // either. `ActivityRecord.unixtimeMsec` is wallet-core's
          // `TransactionRecord::unixtime_msec` — for a row observed live it is
          // the WALLET's clock at the moment it recorded the transaction, and
          // for a discovered row it is the node's
          // `get_daa_score_timestamp_estimate`. Neither is the accepting
          // block's header timestamp; the ceremony's `Accepted` line has that
          // one and this field does not borrow the word.
          _fact(
            label: title,
            valueText: stamp ?? '—',
            value: stamp == null ? const _Value('—') : _Stamp(stamp),
          ),
          if (to != null) ...[
            const _Rule(),
            _CounterpartyLine(
              address: to,
              onCopy: () => _copy(context, to, 'Address copied'),
            ),
          ],
          if (record.feeSompi case final fee?) ...[
            const _Rule(),
            // Trailing zeros trimmed, like every other figure in the app
            // since D-267: `0.00010000` reads `0.0001`.
            _FeeLine(sompi: fee),
          ],
          const _Rule(),
          // **The accepting score when the DAG has one, the containing
          // block's otherwise.** This is the number the depth is measured
          // against — `KvBurial.depthOf` subtracts exactly this from the
          // virtual DAA score — so putting it on the screen lets a reader
          // check the gauge's arithmetic instead of trusting it.
          _fact(label: 'DAA score', valueText: score, value: _Value(score)),
          const _Rule(),
          // **The id belongs IN the table, not in a well of its own.** It is
          // one more fact about this transaction, and giving it a card made
          // the screen read as two unrelated regions. The tap copies all 64
          // characters — a truncated txid is as useless as a truncated
          // address.
          _IdLine(
            txid: record.txid,
            onCopy: () => _copy(context, record.txid, 'Transaction id copied'),
          ),
        ],
      ),
    );
  }
}

/// **The stamp, in two tones** — `S9`, measured: `02 Sep 2026,` at `ink`
/// (242,245,244) and `04:06` at `inkMeta` (122,133,131). The date is what a
/// reader matches a statement against; the time is its qualifier, one step
/// down, exactly as the ledger row's `Yesterday, 09:14` treats its clock.
class _Stamp extends StatelessWidget {
  const _Stamp(this.stamp);

  /// `formatStamp`'s `30 Aug 2026, 03:48`.
  final String stamp;

  @override
  Widget build(BuildContext context) {
    final cut = stamp.lastIndexOf(', ');
    const base = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 13,
      height: 20 / 13,
      color: KvColor.ink,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Text.rich(
      cut < 0
          ? TextSpan(text: stamp, style: base)
          : TextSpan(
              style: base,
              children: [
                TextSpan(text: stamp.substring(0, cut + 2)),
                TextSpan(
                  text: stamp.substring(cut + 2),
                  style: const TextStyle(color: KvColor.inkMeta),
                ),
              ],
            ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
    );
  }
}

/// The `To` row: the address `S9` draws, with the copy glyph it draws beside
/// it (measured: the same `inkMeta` mark as the id row's, 16 dp).
///
/// **The address alone, and the name only in the chip above** (`S9`: the `To`
/// row is `kaspa: qr7m … gfx9t` and a copy glyph, no name). Rendering both put
/// the name twice above the fold, which is BG-19, and the address is this
/// row's whole added job — it is what the chip's name stands for, and what
/// BG-15 says must be visible whether or not the book knows a name.
class _CounterpartyLine extends StatelessWidget {
  const _CounterpartyLine({required this.address, required this.onCopy});

  final String address;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return _FactsPlate._fact(
      label: 'To',
      // **What the row will actually PRINT, not the whole address** — the
      // compact form is what `KvAddress` renders here, and handing the grid the
      // 67-character original made it decide the value could not fit and stack
      // the row at the reference width. `KvFactLine`'s own doc says the string
      // is for measurement only; a mismatch costs a stack-or-not decision, and
      // it cost exactly that. Found in a rendered frame, not in a test. The
      // three trailing spaces stand in for the glyph and its gap — 24 dp, three
      // mono characters at 13 — so the measurement includes the whole run.
      valueText: '${truncateAddressPayload(address)}   ',
      value: Semantics(
        button: true,
        label: 'Copy the address',
        child: InkWell(
          onTap: onCopy,
          highlightColor: KvColor.keyPressed,
          splashFactory: NoSplash.splashFactory,
          // **52 dp, and it is a constraint rather than whatever the text
          // happens to measure** (BG-12, item 21). Built from the run alone it
          // was 22.0 dp on the glass — a copy that a thumb misses on a funds
          // surface (`ux-auditor`, UX-R3).
          child: _Target(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: KvAddress(address, form: KvAddressForm.compact),
                ),
                const SizedBox(width: KvSpace.s),
                const KvGlyphIcon(
                  KvGlyph.copy,
                  tone: KvColor.inkMeta,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The fee row. `internal` direction, because a fee is a cost and not a
/// movement with a sign — the same treatment the ceremony's fee row takes.
class _FeeLine extends StatelessWidget {
  const _FeeLine({required this.sompi});

  final BigInt sompi;

  String get _printed {
    final parts = kasParts(sompi);
    return '${parts.integer}.${trimFraction(parts.fraction)} KAS';
  }

  @override
  Widget build(BuildContext context) => _FactsPlate._fact(
    label: 'Network fee',
    valueText: _printed,
    // **A fact row states a COST, and a cost is read for its digits**
    // (BG-23, D-230): a fee is always below 1, so `magnitude` would spend the
    // one bright character on a `0` that is `0` in every case this row will
    // ever show.
    value: KvAmount(
      sompi,
      role: KvAmountRole.row,
      emphasis: KvAmountEmphasis.significant,
      showUnit: true,
    ),
  );
}

/// The transaction id — the one string on this screen a user wants to take
/// somewhere else, so it copies on a tap rather than needing a long press.
class _IdLine extends StatelessWidget {
  const _IdLine({required this.txid, required this.onCopy});

  final String txid;
  final VoidCallback onCopy;

  /// `S9` truncates it: `0a3906da…e653e490`. The **copy takes all 64** — the
  /// display is for recognition, the clipboard is for use.
  String get _shown => '${txid.substring(0, 8)}…${txid.substring(56)}';

  @override
  Widget build(BuildContext context) => _FactsPlate._fact(
    label: 'Transaction ID',
    // Three trailing spaces for the glyph and its gap, as the `To` row.
    valueText: '$_shown   ',
    value: Semantics(
      button: true,
      label: 'Copy the transaction id',
      child: InkWell(
        onTap: onCopy,
        // **Grey, not teal** — the ledger row that navigates here presses in
        // `keyPressed` and there is no ripple in this language, so a teal
        // splash one tap later is two vocabularies for one gesture (BG-21).
        highlightColor: KvColor.keyPressed,
        splashFactory: NoSplash.splashFactory,
        child: _Target(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Value(_shown),
              const SizedBox(width: KvSpace.s),
              const KvGlyphIcon(KvGlyph.copy, tone: KvColor.inkMeta, size: 16),
            ],
          ),
        ),
      ),
    ),
  );
}

/// **A 52 dp touch target around a run of text** (BG-12).
///
/// A row of 13 dp mono is 20 dp tall, and an `InkWell` around it is a 20 dp
/// target — which is what both copy actions on this screen shipped as until
/// `ux-auditor` measured them. The height is a *constraint*, so the run inside
/// can change without the target quietly shrinking with it.
class _Target extends StatelessWidget {
  const _Target({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
    child: Align(alignment: Alignment.centerRight, child: child),
  );
}

/// A plain mono value in the facts plate's right column.
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.right,
    style: const TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 13,
      height: 20 / 13,
      color: KvColor.ink,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );
}

/// The hairline that divides one fact from the next.
///
/// [KvColor.rowDivider] — **the Activity ledger's own rule** (founder, device
/// sitting). `etch` is the gauge's track tone and is built to be seen; a table
/// rule is built to be read past, and at table density the heavier tone drew
/// the eye to the lines instead of to the facts between them. `S9` measures it
/// inset 20 dp from the plate's edges, which is the plate's own padding — so
/// the rule is drawn full-width inside a padded plate rather than inset again.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: KvColor.rowDivider);
}

/// **The bar `S9` ends on**: two raised actions, 52 dp tall, side by side above
/// the safe area and never scrolling with the record.
///
/// Measured off the render: each button is 167 dp wide with a 10 dp gap on a
/// 391 dp screen — that is one row of two equal halves at the screen's gutter,
/// which is what this builds rather than transcribing widths that only hold at
/// one frame.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.txid,
    required this.counterparty,
    required this.explorerUrl,
    required this.openUrl,
    required this.onSendAgain,
  });

  final String txid;
  final String? counterparty;
  final Future<String> Function(String txid)? explorerUrl;
  final Future<bool> Function(String url)? openUrl;
  final void Function(String address)? onSendAgain;

  @override
  Widget build(BuildContext context) {
    final resolve = explorerUrl;
    final to = counterparty;
    final again = onSendAgain;
    final explorer = resolve == null
        ? null
        : KvExplorerExit(
            subject: txid,
            resolve: resolve,
            open: openUrl ?? (_) async => false,
            compact: true,
          );
    // Both absent: no bar at all, rather than an empty strip of chrome (BG-4).
    if (explorer == null && (to == null || again == null)) {
      return const SizedBox.shrink();
    }
    return KvColumn(
      child: Padding(
        padding: const EdgeInsets.only(top: KvSpace.sm, bottom: KvSpace.m),
        child: Row(
          children: [
            // **Two pills of equal width** (`S9` measures 167 each on a 391 dp
            // screen with a 10 dp gap — one row of two halves at the gutter).
            // `SizedBox(width: infinity)` gives the exit's own container a
            // tight width so it fills its half, while the run inside stays
            // centred: the compact register is `mainAxisSize.min` because the
            // receipt seats it beside *Copy ID*, and that seat is untouched.
            if (explorer != null)
              Expanded(
                child: SizedBox(width: double.infinity, child: explorer),
              ),
            if (explorer != null && to != null && again != null)
              const SizedBox(width: KvSpace.s10),
            if (to != null && again != null)
              Expanded(
                child: KvAction.raised(
                  label: 'Send again',
                  mark: KvGlyph.arrowOut,
                  onTap: () => again(to),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The row left the feed while the screen was open — the list arrives already
/// truncated by Rust, so this is reachable and is a state, not an error.
class _Gone extends StatelessWidget {
  const _Gone({required this.txid});

  final String txid;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(KvSpace.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This transaction is no longer in your recent activity.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 20 / 15,
              color: KvColor.inkDim,
            ),
          ),
          const SizedBox(height: KvSpace.s),
          const Text(
            'The wallet keeps only the most recent; nothing about the '
            'transaction itself has changed.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMeta,
            ),
          ),
          const SizedBox(height: KvSpace.m),
          Text(
            txid,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ),
    ),
  );
}
