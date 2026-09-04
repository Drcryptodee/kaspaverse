import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/tx_status_chip.dart';
import 'support/finders.dart';

/// Builds a [HomeScreen] from loose notifiers via the V5 scope objects —
/// keeps the pre-V5 test shape while proving the scopes construct from
/// hand-built [ValueNotifier]s (the no-native-library seam, V4 law).
HomeScreen homeScreen({
  required ValueListenable<bool> connected,
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

/// The runs [KvAmount] actually paints.
///
/// The figure is split into integer, fraction and unit so the fraction can be
/// subordinate **by scale** rather than by a second family (§2) — so
/// `find.textContaining('1,234.5678 KAS')` looks for a string no widget in the
/// tree ever produces. Asserting the runs is asserting what is on the glass.
///
/// **The hero floors at four decimals** (§2): 46dp of mono cannot wear eight
/// with dignity, and all eight live one tap away on Send and always at
/// signing (BG-6). A row trims trailing zeros to two instead.
/// **The hero trims** (D-210): every significant decimal, no trailing zeros.
/// A whole balance therefore reads `.00`, not `.0000` and not `.00000000`.
void expectFigure(String integer, String fraction) {
  expect(find.text(integer), findsWidgets, reason: 'integer "$integer"');
  expect(
    find.text('.$fraction'),
    findsWidgets,
    reason: 'fraction ".$fraction"',
  );
}

void main() {
  testWidgets('wallet home: connecting → live empty zero → funds → stale', (
    tester,
  ) async {
    final connected = ValueNotifier<bool>(false);
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
        builder: (context, page) => KvWindow(child: page!),
        home: homeScreen(
          connected: connected,
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
    // The screen names itself; the wordmark moved to the drawer's header
    // (§4/§5) — this surface is mounted bare, without `KvNav`, so what is
    // asserted here is the page title rather than the brand.
    // `Wallet` bold with `Main` beside it in the meta grey — one rich text,
    // no separator (render `S1`, D-261).
    expect(find.text('Wallet Main'), findsOneWidget);
    expect(find.text('finding a node…'), findsOneWidget); // C7 copy
    // The balance's own dash; the chain clock now prints a second `—` of
    // its own beneath it (D-256, D-261), so the finder is scoped.
    expect(
      find.descendant(of: find.byType(KvAmount), matching: find.text('—')),
      findsOneWidget,
    );
    expect(find.text('No recent activity'), findsOneWidget);

    // A live, EMPTY synced wallet: a real 0.00000000 KAS, never `—`/skeleton.
    connected.value = true;
    daa.value = BigInt.parse('458174109');
    mature.value = BigInt.zero;
    pending.value = BigInt.zero;
    lastUpdate.value = now;
    await tester.pump();
    expectFigure('0', '00');
    expect(find.text('—'), findsNothing);
    // **The chain clock reads under the balance** (A4, founder ruling D-256).
    // BG-8 is amended to seat it: a chain counter that stops IS the stale
    // signal, so its motion is the reading rather than decoration.
    expect(find.text('458,174,109'), findsOneWidget);

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
    expectFigure('1,234', '56789012');
    expect(find.text('No recent activity'), findsNothing);
    // V2 counter (founder request): an immature deposit streams its DAA
    // distance instead of a static "Pending".
    // The burial mark: under 100 the WORD TRAVELS WITH THE NUMBER (founder, on
    // glass 2026-08-30, revising the earlier density call). `Seen` used to step
    // aside the moment a count arrived, so a row read `Seen` and then a bare
    // `50` — the label vanishing exactly when it became meaningful, and a bare
    // number does not say what it counts.
    expect(find.text('Seen 50'), findsOneWidget);
    expect(find.textContaining('confirmations'), findsNothing);

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
    // **The burial vocabulary replaced the lifecycle words** (founder, on
    // glass): a row now reads its DEPTH under 100, `Confirmed` from 100, and
    // `final` from 1,000. `Accepted` is retired, and a terminal row is no
    // longer silent — it says which side of the thresholds it is on.
    expect(find.text('Accepted'), findsNothing);
    expect(find.text('Not accepted yet'), findsOneWidget); // stalled, honest
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == 'Confirmed' ||
                w.data == 'Confirmed —' ||
                w.data == 'final'),
      ),
      findsWidgets,
      reason: 'a settled row states its burial rather than going quiet',
    );
    // **And it does not overstate what it knows** (BG-20, UX-5). Both `b` and
    // `d` are outgoing sends with no acceptance DAA, so a depth cannot be
    // computed for either: `Confirmed` is what wallet-core's maturity flag
    // justifies, and the dash is the measurement nobody has. Before UX-5 these
    // rendered identically to a row measured at three hundred blocks — two
    // states that demand different actions wearing one face, and the face was
    // the stronger of the two.
    expect(find.text('Confirmed —'), findsNWidgets(2));
    expect(
      find.text('Confirmed'),
      findsNothing,
      reason: 'nothing here has a depth, so nothing may claim a measured one',
    );

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
    // The plate has the room the 320dp header did not, so the trust line
    // wears the network sheet's fuller phrasing (D-196: shipped strings).
    expect(find.text('as of 12 s ago'), findsOneWidget);
    // DS-1: a stale link never streams a counter — the frozen last-known DAA
    // must not tick at full presence; the chip falls back to its static word.
    // **And the word says which one it is** (BG-20, UX-5): a stale link has no
    // depth to report, so the row reads `Seen —` rather than a bare `Seen`
    // that a reader could take for a measurement of zero.
    expect(find.textContaining('confirmations'), findsNothing);
    expect(find.text('Seen —'), findsOneWidget);
    expectFigure('1,234', '56789012'); // retained, dimmed — never blanked

    await tester.pumpWidget(const SizedBox()); // cancel the ticker
  });

  testWidgets('no UTXO index degrades honestly — never a silent zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        builder: (context, page) => KvWindow(child: page!),
        home: homeScreen(
          connected: ValueNotifier(true),
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
        builder: (context, page) => KvWindow(child: page!),
        home: homeScreen(
          connected: ValueNotifier(true),
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
    // The time rides the sub-line after the lifecycle word (`Final · 2 m
    // ago`, render `S1`, D-261).
    expect(find.textContaining('2 m ago'), findsOneWidget);

    // A minute passes on the wall clock, but the 1 s ticker never fires
    // (zero-duration pumps) — only the balance notifies.
    now = now.add(const Duration(minutes: 1));
    mature.value = BigInt.from(300000000);
    await tester.pump();
    await tester.pump();

    // The panel repainted (new number), the feed did not (old age line).
    expectFigure('3', '00');
    expect(find.textContaining('2 m ago'), findsOneWidget);
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
          builder: (context, page) => KvWindow(child: page!),
          home: homeScreen(
            connected: ValueNotifier(true),
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
      // Accepted 7 DAA ago (1000 − 993) → streams a depth of 7, NOT the 500 the
      // submit-time blockDaaScore would have given. The word rides along.
      expect(find.text('Seen 7'), findsOneWidget);

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
          builder: (context, page) => KvWindow(child: page!),
          home: ValueListenableBuilder<int>(
            valueListenable: rebuild,
            builder: (_, _, _) => HomeScreen(
              // FRESH scope objects on every build — deliberately.
              chain: ChainScope(
                connected: connected,
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
      expectFigure('3', '00');
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
        builder: (context, page) => KvWindow(child: page!),
        home: homeScreen(
          connected: ValueNotifier(true),
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
    expect(find.text('Seen'), findsNothing);
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
        builder: (context, page) => KvWindow(child: page!),
        home: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(true),
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
    // The hero shows every significant decimal now (D-210), so it and the
    // in-flight row below agree digit for digit.
    expectFigure('16', '36694716');
    expect(findCapsLabel('in flight'), findsNothing);

    // The send lands. mature collapses to a real zero and the value moves into
    // the outgoing bucket.
    mature.value = BigInt.zero;
    outgoing.value = BigInt.parse('1636694716');
    await tester.pump();

    expectFigure('0', '00');
    expect(
      findCapsLabel('in flight'),
      findsOneWidget,
      reason:
          'but a wallet with value in flight must say so — a bare 0 here reads '
          'as "your money is gone" (F4)',
    );
    expect(
      find.text('.36694716'),
      findsOneWidget,
      reason: 'the in-flight amount keeps every digit — it is money',
    );
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
        builder: (context, page) => KvWindow(child: page!),
        home: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(true),
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

    expectFigure('70', '00');
    expect(findCapsLabel('in flight'), findsOneWidget);
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
        builder: (context, page) => KvWindow(child: page!),
        home: homeScreen(
          connected: ValueNotifier(true),
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
    expect(find.text('Activity'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Showing the $kActivityFeedCap most recent.'),
      300,
      // The rows' own scrollable — the band above the card scrolls too now
      // (D-262), so the finder must say which.
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
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
    expect(find.text('Activity'), findsOneWidget);
    expect(find.textContaining('most recent.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
