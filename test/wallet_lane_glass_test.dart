import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'package:kaspaverse/src/ui/widgets/kv_streaming_count.dart';
import 'support/maturity.dart';

/// PRE3-LANE (KM4) — the money plate reads the WALLET lane, not only the link.
///
/// Run 4's F1: the pinned wallet processor died behind a socket that kept
/// ticking, and the plate — which dimmed only on the link's clock — kept the
/// last balance at full brightness, live-looking, with deposits invisible.
/// BG-8's floor: never a stale reading shown as live. So a lane being repaired
/// or held dark dims the balance, turns the trust lamp amber and says so, with
/// the age of the wallet's last live balance — over a link that is fine.
void main() {
  final now = DateTime(2026, 10, 1, 21, 0);

  Widget host({
    required ValueListenable<WalletLaneState> lane,
    required ValueListenable<DateTime?> walletLastUpdate,
    ValueListenable<bool>? osOffline,
    bool socketUp = true,
    List<ActivityRecord> activity = const [],
    Widget Function(BuildContext, String, ValueListenable<bool>)? detailRoute,
    DateTime? linkLastUpdate,
  }) => MaterialApp(
    theme: kvDarkTheme(),
    builder: (context, page) => KvWindow(child: page!),
    home: HomeScreen(
      chain: ChainScope(
        connected: ValueNotifier<bool>(socketUp),
        virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(552700000)),
        error: ValueNotifier<String?>(null),
        // The link ticks: fresh to the second, unless a test says otherwise.
        lastUpdate: ValueNotifier<DateTime?>(linkLastUpdate ?? now),
        osOffline: osOffline,
      ),
      wallet: WalletScope(
        maturity: kTestMaturity,
        mature: ValueNotifier<BigInt?>(BigInt.from(2742903450)),
        pending: ValueNotifier<BigInt?>(null),
        activity: ValueNotifier<List<ActivityRecord>>(activity),
        syncing: ValueNotifier<bool>(false),
        utxoIndexMissing: ValueNotifier<bool>(false),
        lane: lane,
        lastUpdate: walletLastUpdate,
      ),
      clock: () => now,
      detailRoute: detailRoute,
    ),
  );

  bool balanceDimmed(WidgetTester tester) =>
      tester.widget<KvAmount>(find.byType(KvAmount).first).stale;

  KvLampTone trustLampTone(WidgetTester tester) =>
      tester.widgetList<KvLamp>(find.byType(KvLamp)).last.tone!;

  testWidgets('a live lane over a live link is silent and bright', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        lane: ValueNotifier(WalletLaneState.live),
        walletLastUpdate: ValueNotifier<DateTime?>(now),
      ),
    );
    await tester.pump();
    expect(balanceDimmed(tester), isFalse);
    expect(find.textContaining('wallet updates'), findsNothing);
  });

  testWidgets(
    'a lane being repaired dims the balance and says so, with the wallet\'s age',
    (tester) async {
      final lane = ValueNotifier(WalletLaneState.live);
      await tester.pumpWidget(
        host(
          lane: lane,
          walletLastUpdate: ValueNotifier<DateTime?>(
            now.subtract(const Duration(seconds: 42)),
          ),
        ),
      );
      await tester.pump();
      expect(balanceDimmed(tester), isFalse);

      lane.value = WalletLaneState.recovering;
      await tester.pump();
      expect(
        balanceDimmed(tester),
        isTrue,
        reason: 'a link that ticks may not keep a dead lane bright (F1)',
      );
      expect(
        find.text(
          'restarting wallet updates… · last\u00A0update\u00A042\u00A0s\u00A0ago',
        ),
        findsOneWidget,
      );
      expect(trustLampTone(tester), KvLampTone.warn);
      expect(
        tester.widget<KvLoader>(find.byType(KvLoader)).running,
        isTrue,
        reason: 'a rebuild is work',
      );

      // Rebuilt: silence and brightness come back.
      lane.value = WalletLaneState.live;
      await tester.pump();
      expect(balanceDimmed(tester), isFalse);
      expect(find.textContaining('wallet updates'), findsNothing);
    },
  );

  testWidgets('a lane held dark stops the loader and names the pull', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        lane: ValueNotifier(WalletLaneState.dark),
        walletLastUpdate: ValueNotifier<DateTime?>(
          now.subtract(const Duration(minutes: 3)),
        ),
      ),
    );
    await tester.pump();
    expect(balanceDimmed(tester), isTrue);
    expect(
      find.text(
        'wallet updates paused — pull to retry · '
        'last\u00A0update\u00A03\u00A0m\u00A0ago',
      ),
      findsOneWidget,
    );
    expect(trustLampTone(tester), KvLampTone.warn);
    expect(
      tester.widget<KvLoader>(find.byType(KvLoader)).running,
      isFalse,
      reason: 'nothing is happening until the user pulls or a new socket comes',
    );
  });

  testWidgets('the link outranks the lane when the link itself is down', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        lane: ValueNotifier(WalletLaneState.recovering),
        walletLastUpdate: ValueNotifier<DateTime?>(now),
        osOffline: ValueNotifier<bool>(true),
        socketUp: false,
      ),
    );
    await tester.pump();
    expect(balanceDimmed(tester), isTrue);
    // A lane that cannot reach a node is the link's consequence: the phone
    // being offline is the one fact to say.
    expect(find.textContaining('wallet updates'), findsNothing);
    expect(find.textContaining('phone offline'), findsOneWidget);
  });

  testWidgets(
    'a lane dark longer than the link has been down owes the older age',
    (tester) async {
      // The lane went dark three minutes ago; the network dropped just now.
      // The link keeps the words, and the older clock gives the age: a
      // balance last vouched three minutes ago never reads "0 s ago"
      // (`ux-auditor`, PRE3-LANE).
      await tester.pumpWidget(
        host(
          lane: ValueNotifier(WalletLaneState.dark),
          walletLastUpdate: ValueNotifier<DateTime?>(
            now.subtract(const Duration(minutes: 3)),
          ),
          osOffline: ValueNotifier<bool>(true),
          socketUp: false,
        ),
      );
      await tester.pump();
      expect(balanceDimmed(tester), isTrue);
      expect(
        find.text(
          'phone offline — no network · '
          'last\u00A0update\u00A03\u00A0m\u00A0ago',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'the transaction detail reads the link, not the lane: its depth is the link\'s',
    (tester) async {
      // The detail plots a burial depth from the link's live DAA for a record
      // already known, and its stopped gauge says "the link is not live" — so
      // it takes the link's bit. Over a live link with the lane being
      // repaired, that sentence would be false (`ux-auditor`, PRE3-LANE).
      ValueListenable<bool>? detailStale;
      await tester.pumpWidget(
        host(
          lane: ValueNotifier(WalletLaneState.recovering),
          walletLastUpdate: ValueNotifier<DateTime?>(now),
          activity: [
            ActivityRecord(
              txid: 'aa' * 32,
              valueSompi: BigInt.from(2500000000),
              unixtimeMsec: BigInt.from(
                now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
              ),
              blockDaaScore: BigInt.from(552690000),
              acceptedDaaScore: BigInt.from(552690100),
              direction: ActivityDirection.incoming,
              isCoinbase: false,
              maturity: MaturityState.confirmed,
              stalled: false,
            ),
          ],
          detailRoute: (context, txid, stale) {
            detailStale = stale;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pump();
      expect(balanceDimmed(tester), isTrue, reason: 'the plate reads the lane');
      await tester.tap(find.text('Received'));
      await tester.pumpAndSettle();
      expect(detailStale, isNotNull, reason: 'the row opened its detail');
      expect(
        detailStale!.value,
        isFalse,
        reason: 'the link is live: the depth can be read',
      );
    },
  );

  testWidgets(
    "the link's DAA counter keeps the link's clock while the lane is repaired",
    (tester) async {
      // The counter is the link's reading: a lane being rebuilt must not change
      // how the link's own counter moves (`ux-auditor`, PRE3-LANE).
      await tester.pumpWidget(
        host(
          lane: ValueNotifier(WalletLaneState.recovering),
          walletLastUpdate: ValueNotifier<DateTime?>(now),
        ),
      );
      await tester.pump();
      expect(balanceDimmed(tester), isTrue);
      expect(
        tester.widget<KvStreamingCount>(find.byType(KvStreamingCount)).stalled,
        isFalse,
        reason: 'the link is live, so its counter streams',
      );
    },
  );

  ActivityRecord received() => ActivityRecord(
    txid: 'bb' * 32,
    valueSompi: BigInt.from(2500000000),
    unixtimeMsec: BigInt.from(
      now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    ),
    // 47 under the host's DAA: an `Accepted` depth the link can read, under
    // the ceiling, as the preview's ledger shows one.
    blockDaaScore: BigInt.from(552699953),
    acceptedDaaScore: BigInt.from(552699960),
    direction: ActivityDirection.incoming,
    isCoinbase: false,
    maturity: MaturityState.accepted,
    stalled: false,
  );

  testWidgets(
    "a ledger row's depth is the link's, as the detail beside it reads it",
    (tester) async {
      // The row and the detail read one depth from one bit: with the lane
      // being repaired and the link live, the row counts `Accepted N` exactly
      // as the detail does — never `Accepted —` beside a detail that counts
      // (`ux-auditor` delta, PRE3-LANE). The row's amount and age still mute
      // on the lane: the list is the lane's.
      await tester.pumpWidget(
        host(
          lane: ValueNotifier(WalletLaneState.recovering),
          walletLastUpdate: ValueNotifier<DateTime?>(now),
          activity: [received()],
        ),
      );
      await tester.pump();
      expect(balanceDimmed(tester), isTrue);
      expect(
        tester.widget<KvBurialMark>(find.byType(KvBurialMark)).confirmations,
        47,
        reason: 'the link is live: the row counts the depth the detail counts',
      );
      expect(find.text('Accepted 47'), findsOneWidget);
      expect(
        tester
            .widgetList<KvAmount>(find.byType(KvAmount))
            .where((amount) => amount.role == KvAmountRole.row)
            .single
            .muted,
        isTrue,
        reason: 'the list is the lane\'s: its rows mute while it is repaired',
      );
    },
  );

  testWidgets('inside the hold window a lane down still owes the older age', (
    tester,
  ) async {
    // The lamp holds live through a 7 s silence while the data dims (D-331(b)),
    // and the lane is being repaired with its last balance 2 s old: the
    // older clock gives the age (`ux-auditor` delta, PRE3-LANE).
    await tester.pumpWidget(
      host(
        lane: ValueNotifier(WalletLaneState.recovering),
        walletLastUpdate: ValueNotifier<DateTime?>(
          now.subtract(const Duration(seconds: 2)),
        ),
        linkLastUpdate: now.subtract(const Duration(seconds: 7)),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'restarting wallet updates… · '
        'last\u00A0update\u00A07\u00A0s\u00A0ago',
      ),
      findsOneWidget,
    );
  });
}
