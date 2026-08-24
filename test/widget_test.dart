import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/tx_status_chip.dart';

/// Builds a [HomeScreen] from loose notifiers via the V5 scope objects —
/// keeps the pre-V5 test shape while proving the scopes construct from
/// hand-built [ValueNotifier]s (the no-native-library seam, V4 law).
HomeScreen homeScreen({
  required ValueListenable<bool> connected,
  required ValueListenable<String?> endpoint,
  required ValueListenable<BigInt?> virtualDaaScore,
  required ValueListenable<String?> error,
  required ValueListenable<DateTime?> lastUpdate,
  required ValueListenable<BigInt?> mature,
  required ValueListenable<BigInt?> pending,
  required ValueListenable<List<ActivityRecord>> activity,
  required ValueListenable<bool> syncing,
  required ValueListenable<bool> utxoIndexMissing,
  required DateTime Function() clock,
}) => HomeScreen(
  chain: ChainScope(
    connected: connected,
    endpoint: endpoint,
    virtualDaaScore: virtualDaaScore,
    error: error,
    lastUpdate: lastUpdate,
  ),
  wallet: WalletScope(
    mature: mature,
    pending: pending,
    activity: activity,
    syncing: syncing,
    utxoIndexMissing: utxoIndexMissing,
  ),
  clock: clock,
);

void main() {
  testWidgets('wallet home: connecting → live empty zero → funds → stale', (
    tester,
  ) async {
    final connected = ValueNotifier<bool>(false);
    final endpoint = ValueNotifier<String?>(null);
    final daa = ValueNotifier<BigInt?>(null);
    final error = ValueNotifier<String?>(null);
    final lastUpdate = ValueNotifier<DateTime?>(null);
    final mature = ValueNotifier<BigInt?>(null);
    final pending = ValueNotifier<BigInt?>(null);
    final activity = ValueNotifier<List<ActivityRecord>>(const []);
    final syncing = ValueNotifier<bool>(false);
    final utxoMissing = ValueNotifier<bool>(false);
    var now = DateTime(2026, 6, 14, 12);

    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: homeScreen(
          connected: connected,
          endpoint: endpoint,
          virtualDaaScore: daa,
          error: error,
          lastUpdate: lastUpdate,
          mature: mature,
          pending: pending,
          activity: activity,
          syncing: syncing,
          utxoIndexMissing: utxoMissing,
          clock: () => now,
        ),
      ),
    );

    // Connecting: no data yet → balance unknown `—`, connecting beacon, empty
    // activity (never a forever-skeleton).
    expect(find.text('KaspaVerse'), findsOneWidget);
    expect(find.text('finding a node…'), findsOneWidget); // C7 copy
    expect(find.text('—'), findsOneWidget);
    expect(find.text('No recent activity'), findsOneWidget);

    // A live, EMPTY synced wallet: a real 0.00000000 KAS, never `—`/skeleton.
    connected.value = true;
    endpoint.value = 'wss://node.example/borsh';
    daa.value = BigInt.parse('458174109');
    mature.value = BigInt.zero;
    pending.value = BigInt.zero;
    lastUpdate.value = now;
    await tester.pump();
    expect(find.textContaining('0.00000000 KAS'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('DAA 458,174,109'), findsOneWidget);

    // Funds arrive (matured + pending) with an incoming, still-pending row.
    mature.value = BigInt.parse('123456789012'); // 1,234.56789012 KAS
    pending.value = BigInt.from(50000000); // 0.5 KAS pending
    activity.value = [
      ActivityRecord(
        txid: 'a' * 64,
        valueSompi: BigInt.from(50000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 120000),
        blockDaaScore: BigInt.parse('458174059'), // 50 DAA below the live tip
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: false,
      ),
    ];
    await tester.pump();
    expect(find.textContaining('1,234.56789012 KAS'), findsOneWidget);
    expect(find.text('No recent activity'), findsNothing);
    // V2 counter (founder request): an immature deposit streams its DAA
    // distance instead of a static "Pending".
    expect(find.text('50 confirmations'), findsOneWidget);

    // V2 chip walk: acceptance lands (V1 overlay) → 'Accepted'; a settled
    // (confirmed) row goes quiet — no permanent label (founder-nodded).
    activity.value = [
      ActivityRecord(
        txid: 'b' * 64,
        valueSompi: BigInt.from(20000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 5000),
        blockDaaScore: BigInt.from(20),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.accepted,
        stalled: false,
      ),
      ActivityRecord(
        txid: 'c' * 64,
        valueSompi: BigInt.from(30000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 90000),
        blockDaaScore: BigInt.from(5),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: true, // 60 s with no acceptance — the V1 stall signal
      ),
      ActivityRecord(
        txid: 'd' * 64,
        valueSompi: BigInt.from(10000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 900000),
        blockDaaScore: BigInt.from(1),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.confirmed,
        stalled: false,
      ),
    ];
    await tester.pump(const Duration(milliseconds: 400)); // chip crossfade
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Not accepted yet'), findsOneWidget); // stalled, honest
    expect(find.text('Pending'), findsNothing);
    expect(find.text('Confirmed'), findsNothing); // terminal = quiet

    // Back to the pending-deposit shape for the staleness beat below.
    activity.value = [
      ActivityRecord(
        txid: 'a' * 64,
        valueSompi: BigInt.from(50000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 120000),
        blockDaaScore: BigInt.from(10),
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: false,
      ),
    ];
    await tester.pump(const Duration(milliseconds: 400));

    // The link goes quiet: advance past the stale threshold. The beacon ages
    // (the balance dims — opacity is unit-tested in amount_text_test).
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1)); // the 1 s ticker fires
    expect(find.text('12 s ago'), findsOneWidget);
    // DS-1: a stale link never streams a counter — the frozen last-known DAA
    // must not tick at full presence; the chip falls back to its static word.
    expect(find.textContaining('confirmations'), findsNothing);
    expect(find.text('Pending'), findsOneWidget);
    expect(
      find.textContaining('1,234.56789012 KAS'),
      findsOneWidget,
    ); // retained

    await tester.pumpWidget(const SizedBox()); // cancel the ticker
  });

  testWidgets('no UTXO index degrades honestly — never a silent zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: homeScreen(
          connected: ValueNotifier(true),
          endpoint: ValueNotifier('wss://node.example/borsh'),
          virtualDaaScore: ValueNotifier(BigInt.from(1)),
          error: ValueNotifier(null),
          lastUpdate: ValueNotifier(DateTime(2026, 6, 14, 12)),
          mature: ValueNotifier(null), // no balance — but NOT a fake zero
          pending: ValueNotifier(null),
          activity: ValueNotifier(const []),
          syncing: ValueNotifier(false),
          utxoIndexMissing: ValueNotifier(true),
          clock: () => DateTime(2026, 6, 14, 12),
        ),
      ),
    );

    expect(find.textContaining('no UTXO index'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // unknown, never a fabricated 0
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('V4 scoping: a balance tick repaints the panel, NOT the feed', (
    tester,
  ) async {
    // The discriminator: the feed renders relative ages from the SCOPED 1 s
    // clock notifier. Advance the test clock WITHOUT letting the ticker fire,
    // then tick only the balance — a mega-rebuild (the pre-V4 shape) would
    // re-read the clock and walk the age line; the scoped feed must not.
    final mature = ValueNotifier<BigInt?>(BigInt.from(100000000));
    var now = DateTime(2026, 7, 11, 12);
    final row = ActivityRecord(
      txid: 'a' * 64,
      valueSompi: BigInt.from(50000000),
      unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 120000),
      blockDaaScore: BigInt.from(1),
      direction: ActivityDirection.incoming,
      isCoinbase: false,
      maturity: MaturityState.confirmed,
      stalled: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: homeScreen(
          connected: ValueNotifier(true),
          endpoint: ValueNotifier('wss://node.example/borsh'),
          virtualDaaScore: ValueNotifier(BigInt.from(1)),
          error: ValueNotifier(null),
          lastUpdate: ValueNotifier(now),
          mature: mature,
          pending: ValueNotifier(BigInt.zero),
          activity: ValueNotifier([row]),
          syncing: ValueNotifier(false),
          utxoIndexMissing: ValueNotifier(false),
          clock: () => now,
        ),
      ),
    );
    expect(find.text('2 m ago'), findsOneWidget);

    // A minute passes on the wall clock, but the 1 s ticker never fires
    // (zero-duration pumps) — only the balance notifies.
    now = now.add(const Duration(minutes: 1));
    mature.value = BigInt.from(300000000);
    await tester.pump();
    await tester.pump();

    // The panel repainted (new number), the feed did not (old age line).
    expect(find.textContaining('3.00000000 KAS'), findsOneWidget);
    expect(find.text('2 m ago'), findsOneWidget);
    expect(find.text('3 m ago'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'finding 18: a confirmed send streams its acceptance-depth, then quiets',
    (tester) async {
      // wallet-core confirms a send at acceptance (maturity Confirmed), so its
      // base chip is the quiet terminal. The fix revives a streaming counter
      // from acceptedDaaScore (NOT blockDaaScore, which is submit time and
      // would overstate) until the depth gate quiets it.
      final daa = ValueNotifier<BigInt?>(BigInt.from(1000));
      final now = DateTime(2026, 7, 11, 12);
      ActivityRecord send(int acceptedDaa) => ActivityRecord(
        txid: 's' * 64,
        valueSompi: BigInt.from(20000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 3000),
        blockDaaScore: BigInt.from(500), // submit time — must NOT be the anchor
        acceptedDaaScore: BigInt.from(acceptedDaa),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.confirmed,
        stalled: false,
      );
      final activity = ValueNotifier<List<ActivityRecord>>([send(993)]);

      await tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          home: homeScreen(
            connected: ValueNotifier(true),
            endpoint: ValueNotifier('wss://node.example/borsh'),
            virtualDaaScore: daa,
            error: ValueNotifier(null),
            lastUpdate: ValueNotifier(now),
            mature: ValueNotifier(BigInt.from(100000000)),
            pending: ValueNotifier(BigInt.zero),
            activity: activity,
            syncing: ValueNotifier(false),
            utxoIndexMissing: ValueNotifier(false),
            clock: () => now,
          ),
        ),
      );
      // Accepted 7 DAA ago (1000 − 993) → streams "7 confirmations", NOT the
      // 500 the submit-time blockDaaScore would have given.
      expect(find.text('7 confirmations'), findsOneWidget);

      // Deep past the ceiling (200 > 100) → the chip dissolves (Rams #5). The
      // AnimatedSwitcher out-transition takes `normal`; pump past it (a
      // repeating breath controller forbids pumpAndSettle).
      activity.value = [send(800)];
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('confirmations'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rebuilding with fresh scope objects over the same notifiers keeps the '
    'V4 identity contract',
    (tester) async {
      // The V5 wiring law: ChainScope/WalletScope are pure groupings — a
      // parent rebuild may mint NEW scope instances freely, because the
      // didUpdateWidget assert pins the identity of the INNER notifiers
      // (the derived notifiers subscribed to them at mount). This fails if
      // the assert ever compares scope-object identity, or if a refactor
      // swaps the notifier instances mid-life.
      final connected = ValueNotifier<bool>(true);
      final endpoint = ValueNotifier<String?>('wss://node.example/borsh');
      final daa = ValueNotifier<BigInt?>(BigInt.one);
      final error = ValueNotifier<String?>(null);
      final lastUpdate = ValueNotifier<DateTime?>(DateTime(2026, 7, 14, 12));
      final mature = ValueNotifier<BigInt?>(BigInt.zero);
      final pending = ValueNotifier<BigInt?>(BigInt.zero);
      final activity = ValueNotifier<List<ActivityRecord>>(const []);
      final syncing = ValueNotifier<bool>(false);
      final utxoMissing = ValueNotifier<bool>(false);
      final rebuild = ValueNotifier<int>(0);

      await tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          home: ValueListenableBuilder<int>(
            valueListenable: rebuild,
            builder: (_, _, _) => HomeScreen(
              // FRESH scope objects on every build — deliberately.
              chain: ChainScope(
                connected: connected,
                endpoint: endpoint,
                virtualDaaScore: daa,
                error: error,
                lastUpdate: lastUpdate,
              ),
              wallet: WalletScope(
                mature: mature,
                pending: pending,
                activity: activity,
                syncing: syncing,
                utxoIndexMissing: utxoMissing,
              ),
              clock: () => DateTime(2026, 7, 14, 12),
            ),
          ),
        ),
      );

      rebuild.value = 1; // parent rebuild → didUpdateWidget with new scopes
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'same inner notifiers ⇒ the seam-identity assert holds',
      );
      // And the screen still renders from the SAME notifiers.
      mature.value = BigInt.from(300000000);
      await tester.pump();
      expect(find.textContaining('3.00000000 KAS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('formatScore groups digits and handles null', () {
    expect(formatScore(null), '—');
    expect(formatScore(BigInt.from(0)), '0');
    expect(formatScore(BigInt.from(1000)), '1,000');
    expect(formatScore(BigInt.parse('458174109')), '458,174,109');
  });

  test(
    'chip honesty: unknown is quiet, the depth gate extinguishes at 100',
    () {
      // Finding 13 upstream half: a cold-start fold with no live DAA yields
      // maturity `unknown` — the chip claims nothing (and a stall still shows).
      expect(
        chipStateOf(MaturityState.unknown, stalled: false),
        TxChipState.none,
      );
      expect(
        chipStateOf(MaturityState.unknown, stalled: true),
        TxChipState.stalled,
      );

      // Finding 13 display half (founder-ruled ceiling 100): a counter at or
      // above the ceiling renders NO chip, whatever the state; below it the
      // state stands; stalled never gates (it carries no depth).
      expect(gateByDepth(TxChipState.pending, 19000), TxChipState.none);
      expect(gateByDepth(TxChipState.accepted, 100), TxChipState.none);
      expect(gateByDepth(TxChipState.accepted, 99), TxChipState.accepted);
      expect(gateByDepth(TxChipState.pending, null), TxChipState.pending);
      expect(gateByDepth(TxChipState.stalled, 19000), TxChipState.stalled);
    },
  );

  testWidgets('cold start: settled history streams NO counters (finding 13)', (
    tester,
  ) async {
    // The founder-reported storm: on restart, hours-old rows briefly streamed
    // ">19,000 confirmations". Reproduce the exact pre-fix conditions — the
    // Dart-side DAA is live while the first fold classified the old rows —
    // and pin both halves of the fix: an `unknown` row (the fixed first fold)
    // shows nothing, and even a stale-classified `pending` row (any other
    // path to a huge counter) is extinguished by the depth gate.
    final daa = ValueNotifier<BigInt?>(BigInt.from(458174109));
    final now = DateTime(2026, 7, 10, 12);
    final activity = ValueNotifier<List<ActivityRecord>>([
      // The fixed cold-start fold: maturity unknown (no DAA at fold time).
      ActivityRecord(
        txid: 'e' * 64,
        valueSompi: BigInt.from(500000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 7200000),
        blockDaaScore: BigInt.from(458154109), // 20,000 DAA old
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.unknown,
        stalled: false,
      ),
      // Defense in depth: were an old row ever to classify Pending with the
      // live DAA far ahead, the gate still renders nothing at ≥100.
      ActivityRecord(
        txid: 'f' * 64,
        valueSompi: BigInt.from(100000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 7200000),
        blockDaaScore: BigInt.from(458154109),
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: false,
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: homeScreen(
          connected: ValueNotifier(true),
          endpoint: ValueNotifier('wss://node.example/borsh'),
          virtualDaaScore: daa,
          error: ValueNotifier(null),
          lastUpdate: ValueNotifier(now),
          mature: ValueNotifier(BigInt.from(600000000)),
          pending: ValueNotifier(BigInt.zero),
          activity: activity,
          syncing: ValueNotifier(false),
          utxoIndexMissing: ValueNotifier(false),
          clock: () => now,
        ),
      ),
    );

    // Neither old row wears ANY chip: no streamed counter, no static word.
    expect(find.textContaining('confirmations'), findsNothing);
    expect(find.text('Pending'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  // ── F4 / F20: money in flight is not an empty wallet ──

  testWidgets('a wallet that has spent everything says so, not just "0"', (
    tester,
  ) async {
    // The window this exists for: the spendable set is genuinely empty because
    // our own transaction consumed it, and the change has not come back. Every
    // balance field the pin publishes is a real number, and `mature` really is
    // zero — so `AmountText` renders a confident `0.00000000 KAS`, which to the
    // user is indistinguishable from "your money is gone".
    //
    // `WalletService.outgoing` had carried this truth since it was written and
    // NOTHING in lib/ read it (F20): WalletScope did not carry the field at all.
    final mature = ValueNotifier<BigInt?>(BigInt.parse('1636694716'));
    final outgoing = ValueNotifier<BigInt?>(BigInt.zero);
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(true),
            endpoint: ValueNotifier('wss://node.example/borsh'),
            virtualDaaScore: ValueNotifier(BigInt.from(2000)),
            error: ValueNotifier(null),
            lastUpdate: ValueNotifier(DateTime(2026, 8, 24)),
          ),
          wallet: WalletScope(
            mature: mature,
            pending: ValueNotifier(BigInt.zero),
            outgoing: outgoing,
            activity: ValueNotifier(const []),
            syncing: ValueNotifier(false),
            utxoIndexMissing: ValueNotifier(false),
          ),
          clock: () => DateTime(2026, 8, 24),
        ),
      ),
    );
    await tester.pump();

    // Before: a normal wallet, nothing in flight, no settling line.
    expect(find.textContaining('16.36694716 KAS'), findsOneWidget);
    expect(find.text('  in flight'), findsNothing);

    // The send lands. mature collapses to a real zero and the value moves into
    // the outgoing bucket.
    mature.value = BigInt.zero;
    outgoing.value = BigInt.parse('1636694716');
    await tester.pump();

    expect(
      find.textContaining('0.00000000 KAS'),
      findsOneWidget,
      reason: 'the spendable balance really is zero — that stays honest',
    );
    expect(
      find.text('  in flight'),
      findsOneWidget,
      reason:
          'but a wallet with value in flight must say so — a bare 0 here reads '
          'as "your money is gone" (F4)',
    );
    expect(find.textContaining('16.36694716'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the in-flight line is a memo, never a second subtraction', (
    tester,
  ) async {
    // The partial-send case, which the sweep test above cannot see: there the
    // hero collapses to 0 and "already deducted" and "still to deduct" read the
    // same, so the suite was structurally blind to the grammar
    // (consensus-auditor, this sitting).
    //
    // At the pin the hero is ALREADY net of the send —
    // `mature = (mature_utxos + consumed).saturating_sub(fees + payment)`
    // (`wallet/core/src/utxo/context.rs:506-547 @ cfafeb4`) — so a signed
    // `− 30.00000000` under `70.00000000 KAS` would invite 70 − 30, and on a
    // self-send frame the value is travelling back to this wallet anyway.
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(true),
            endpoint: ValueNotifier('wss://node.example/borsh'),
            virtualDaaScore: ValueNotifier(BigInt.from(2000)),
            error: ValueNotifier(null),
            lastUpdate: ValueNotifier(DateTime(2026, 8, 24)),
          ),
          wallet: WalletScope(
            // 100 KAS held, 30 KAS of it already spent and in flight.
            mature: ValueNotifier(BigInt.from(7000000000)),
            pending: ValueNotifier(BigInt.zero),
            outgoing: ValueNotifier(BigInt.from(3000000000)),
            activity: ValueNotifier(const []),
            syncing: ValueNotifier(false),
            utxoIndexMissing: ValueNotifier(false),
          ),
          clock: () => DateTime(2026, 8, 24),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('70.00000000 KAS'), findsOneWidget);
    expect(find.text('  in flight'), findsOneWidget);
    expect(
      find.textContaining('− '),
      findsNothing,
      reason:
          'a minus sign here reads as "subtract this too" against a hero that '
          'has already had it subtracted',
    );
    await tester.pumpWidget(const SizedBox());
  });

  // ── F29 / D-175: the bound discloses itself, and only when it binds ──

  ActivityRecord row(int i) => ActivityRecord(
    txid: i.toRadixString(16).padLeft(64, '0'),
    valueSompi: BigInt.from(1000),
    unixtimeMsec: BigInt.from(DateTime(2026, 8, 24).millisecondsSinceEpoch),
    blockDaaScore: BigInt.from(1000 - i),
    direction: ActivityDirection.incoming,
    isCoinbase: false,
    maturity: MaturityState.confirmed,
    stalled: false,
  );

  Future<void> pumpFeed(WidgetTester tester, int rows) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: homeScreen(
          connected: ValueNotifier(true),
          endpoint: ValueNotifier('wss://node.example/borsh'),
          virtualDaaScore: ValueNotifier(BigInt.from(2000)),
          error: ValueNotifier(null),
          lastUpdate: ValueNotifier(DateTime(2026, 8, 24)),
          mature: ValueNotifier(BigInt.from(1000)),
          pending: ValueNotifier(BigInt.zero),
          activity: ValueNotifier([for (var i = 0; i < rows; i++) row(i)]),
          syncing: ValueNotifier(false),
          utxoIndexMissing: ValueNotifier(false),
          clock: () => DateTime(2026, 8, 24),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a full feed says it is showing only the most recent', (
    tester,
  ) async {
    // Rust hands over at most ACTIVITY_CAP rows, so "the list is full" is the
    // ONLY signal the glass gets that anything was cut. Before D-175 a user at
    // the bound saw a flat 'Activity' header and no hint at all — the feed's
    // honesty depended on nobody ever reaching it.
    await pumpFeed(tester, kActivityFeedCap);
    expect(find.text('Recent activity'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Showing the $kActivityFeedCap most recent.'),
      300,
    );
    expect(
      find.text('Showing the $kActivityFeedCap most recent.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a feed below the bound says nothing about it', (tester) async {
    // The other half: a caption that always showed would be noise on the
    // overwhelming majority of wallets, and would state a bound the user has
    // not met. It appears only where it is true of them.
    await pumpFeed(tester, 3);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(find.textContaining('most recent.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
