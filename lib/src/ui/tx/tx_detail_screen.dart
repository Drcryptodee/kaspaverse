import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/wallet.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_activity.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_burial_gauge.dart';
import '../widgets/kv_burial_mark.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_explorer_exit.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_surface.dart';
import '../widgets/tx_status_chip.dart';

/// **Transaction detail** — one transaction, at full size, with the burial
/// gauge the money screen has no room for (§5, D-191/D-192).
///
/// The ledger row answers *what happened*; this answers *how settled is it*.
/// Kaspa runs at about ten blocks a second, so the hundred confirmations that
/// make a payment safe are a ten-second event and the thousand that make it
/// final are about a hundred seconds — both watchable, which is why the gauge
/// here is a live instrument rather than a static mark. The ceremony already
/// hands off to this screen in words (*"you can follow it in your activity"*);
/// this is the thing it was pointing at.
///
/// **It stays live.** The record is looked up out of the activity feed on every
/// tick rather than captured at push time: a screen opened on a send that is
/// four blocks deep is a screen the user is watching precisely because the
/// number is going to change. Everything is injected as listenables, so the
/// surface renders in a widget test with no native library.
///
/// **A row can leave the feed** — the list arrives already truncated by Rust —
/// so "this transaction is no longer in the recent activity" is a state with a
/// face of its own (BG-20) rather than an empty screen.
class TxDetailScreen extends StatelessWidget {
  const TxDetailScreen({
    super.key,
    required this.txid,
    required this.activity,
    required this.virtualDaaScore,
    required this.stale,
    this.explorerUrl,
    this.openUrl,
  });

  /// The transaction this screen is about. The identity, not the snapshot.
  final String txid;

  final ValueListenable<List<ActivityRecord>> activity;

  /// The live DAA the burial depth is measured against.
  final ValueListenable<BigInt?> virtualDaaScore;

  /// The link is not live, so nothing counts (BG-8).
  final ValueListenable<bool> stale;

  /// Resolves a txid to the exact URL the user's chosen explorer would open.
  /// Null hides the exit entirely — a control with nowhere to go is worse than
  /// no control (BG-12).
  final Future<String> Function(String txid)? explorerUrl;

  final Future<bool> Function(String url)? openUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // BG-14: the top 52dp belongs to the real system status bar and
            // nothing is painted there.
            const SizedBox(height: KvSpace.statusBarReserve),
            KvRail(
              title: 'Transaction',
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([activity, virtualDaaScore, stale]),
                builder: (context, _) => _body(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    ActivityRecord? found;
    for (final record in activity.value) {
      if (record.txid == txid) {
        found = record;
        break;
      }
    }
    final record = found;
    if (record == null) return _Gone(txid: txid);

    final dim = stale.value;
    final depth = KvBurial.depthOf(record, virtualDaaScore.value, stale: dim);
    final (:mark, :direction, :title) = kvActivityFace(record);
    final at = record.unixtimeMsec;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.m),
        // **Nothing here dims, and that is the correction.** The head used to
        // sit under `Opacity(0.45)` while the link was stale — dimming the one
        // datum on the screen that CANNOT go stale, the amount the chain
        // already recorded, while the depth that genuinely is unknown stayed at
        // full brightness. BG-8's dimmed-plus-an-age treatment is for a cached
        // reading still being shown; the depth here is not cached but
        // **unknown**, so it takes the dash and says why below
        // (`ux-auditor`, UX-5).
        Entrance(
          child: _Head(
            mark: mark,
            title: title,
            direction: direction,
            record: record,
          ),
        ),
        const SizedBox(height: KvSpace.xl),
        Entrance(
          index: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const KvRuledLabel('Burial'),
              const SizedBox(height: KvSpace.sm),
              KvBurialGauge(
                state: gateByDepth(
                  chipStateOf(record.maturity, stalled: record.stalled),
                  depth,
                ),
                confirmations: depth,
                maturity: record.maturity,
                stalled: dim,
              ),
              // **The dash says there is no reading; this says why.** A user
              // watching a gauge that has stopped is owed the reason, and the
              // reason is knowable here — it is the same bit the money plate
              // folds into its trust line (BG-11/BG-20).
              //
              // **Its slot is always reserved and only the ink fades** — the
              // same mechanism Receive's caption uses. Built as a bare
              // conditional it cut in with no transition AND took the three
              // blocks below it 23 dp down the screen in one frame, every time
              // the link flapped, on a surface whose whole purpose is watching
              // a number that is not moving (BG-24; measured, `ux-auditor`,
              // UX-5). Reserved, the layout never moves at all, which is the
              // stronger property here.
              const SizedBox(height: KvSpace.s),
              AnimatedOpacity(
                opacity: dim ? 1 : 0,
                duration: KvMotion.fast,
                curve: KvMotion.out,
                child: const Text(
                  'The link is not live, so the depth cannot be read.',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 11,
                    height: 15 / 11,
                    color: KvColor.inkMetaLow,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KvSpace.xl),
        Entrance(
          index: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // **`Recorded`, not `Accepted`, and the distinction is the one
              // `ffi-leak-auditor` already made once on this project.**
              // `ActivityRecord.unixtimeMsec` is wallet-core's own
              // `TransactionRecord::unixtime_msec` — for a row observed live it
              // is `unixtime_as_millis_u64()`, the WALLET's clock at the moment
              // it recorded the transaction, and for a discovered row it is the
              // node's `get_daa_score_timestamp_estimate`, which is an
              // estimate. Neither is the accepting block's header timestamp.
              // The ceremony's `Accepted` line has that (`acceptedUnixMs`,
              // carried across the FFI for exactly this reason at UX-4B); this
              // field does not, so it does not borrow the word.
              const KvRuledLabel('Recorded'),
              const SizedBox(height: KvSpace.xs),
              Text(
                // **The wallet's own recording moment, or a node's DAA→time
                // estimate — never the accepting block's header timestamp**
                // (see the label above, and the pin: `record.rs` sets this from
                // `unixtime_as_millis_u64()` at every constructor, and
                // `set_unixtime` from `get_daa_score_timestamp_estimate`).
                // Absent, it renders the dash rather than a stamp the wallet
                // invented (BG-5).
                at == null
                    ? '—'
                    : formatStamp(
                        DateTime.fromMillisecondsSinceEpoch(at.toInt()),
                      ),
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 13,
                  height: 20 / 13,
                  color: KvColor.inkDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KvSpace.xl),
        Entrance(index: 3, child: _TxId(txid: record.txid)),
        if (explorerUrl case final resolve?) ...[
          const SizedBox(height: KvSpace.xl),
          Entrance(
            index: 4,
            child: KvExplorerExit(
              subject: record.txid,
              resolve: resolve,
              open: openUrl ?? (_) async => false,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.xxl),
      ],
    );
  }
}

/// The verb and the money, which is what the screen is about.
class _Head extends StatelessWidget {
  const _Head({
    required this.mark,
    required this.title,
    required this.direction,
    required this.record,
  });

  final KvMark mark;
  final String title;
  final KvMoneyDirection direction;
  final ActivityRecord record;

  @override
  Widget build(BuildContext context) {
    final tone = switch (direction) {
      KvMoneyDirection.incoming => KvColor.ok,
      KvMoneyDirection.outgoing => KvColor.risk,
      KvMoneyDirection.internal => KvColor.inkDim,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            KvGlyphIcon(mark, tone: tone),
            const SizedBox(width: KvSpace.s),
            Text(
              title,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w500,
                color: KvColor.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: KvSpace.s),
        // **`hero`, one ramp step down — a magnitude, not a commitment.**
        //
        // With `emphasis: significant`, because the role's default is the wrong
        // half of D-230's split here. A *balance* keeps the weight on its
        // integer even when it is `0` — it is the magnitude you own. A record
        // can be 0.005 KAS, and then `hero`'s default spends the one bright
        // 32 dp character on a leading zero while the digits that are the
        // amount sit at 15 dp: §8's named anti-pattern, and the identical
        // defect D-231 corrected for the live fee one commit earlier
        // (`ux-auditor`, UX-5). At or above 1 the two rules agree exactly, so
        // this changes only the case that was wrong.
        //
        // This was `screen`, which pads to eight decimals because BG-6 restates
        // what is about to be SIGNED in full. Nothing is being signed here: it
        // is a record of what already happened, so D-210's precision law
        // applies unexceptioned and `12.40000000` was eight characters of ink
        // spent on nothing — the identical line D-231 drew for the live fee one
        // commit earlier. The role also decides the SPOKEN form, so the screen
        // reader was reading the padding out loud (`ux-auditor`, UX-5).
        KvAmount(
          record.valueSompi,
          role: KvAmountRole.hero,
          emphasis: KvAmountEmphasis.significant,
          size: 32,
          direction: direction,
        ),
      ],
    );
  }
}

/// The reference number, at the foot of the record where a reference number
/// goes — and tappable, because the one string on this screen a user wants to
/// take somewhere else should not need a long-press-and-drag.
class _TxId extends StatelessWidget {
  const _TxId({required this.txid});

  final String txid;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const KvRuledLabel('Transaction id'),
      const SizedBox(height: KvSpace.xs),
      Semantics(
        button: true,
        label: 'Copy the transaction id',
        child: InkWell(
          onTap: () async {
            // The tap copies ALL of it — a truncated txid is as useless as a
            // truncated address — and says so, because a copy with no
            // acknowledgement leaves the user tapping twice.
            await Clipboard.setData(ClipboardData(text: txid));
            KvHaptic.selection();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Transaction id copied'),
                  duration: KvMotion.toast,
                ),
              );
            }
          },
          borderRadius: BorderRadius.circular(KvRadius.plate),
          // **Grey, not teal** — the ledger row that navigates here presses in
          // `keyPressed` and there is no ripple in this language, so a teal
          // splash one tap later is two vocabularies for one gesture (BG-21).
          // The theme's `glow` default is what supplies the teal.
          highlightColor: KvColor.keyPressed,
          splashFactory: NoSplash.splashFactory,
          child: KvSurface(
            tone: KvSurfaceTone.well,
            width: double.infinity,
            padding: const EdgeInsets.all(KvSpace.sm),
            child: Text(
              txid,
              style: const TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 20 / 13,
                color: KvColor.ink,
              ),
            ),
          ),
        ),
      ),
    ],
  );
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
              color: KvColor.inkMetaLow,
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
