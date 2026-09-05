import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';

import 'support/maturity.dart';
import 'support/preview_harness.dart';
import 'support/rebuilds.dart';

const _txid =
    'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34';

ActivityRecord _sent() => ActivityRecord(
  txid: _txid,
  valueSompi: BigInt.from(1240000000),
  unixtimeMsec: BigInt.from(1788058080000),
  blockDaaScore: BigInt.from(458173900),
  acceptedDaaScore: BigInt.from(458174000),
  direction: ActivityDirection.outgoing,
  isCoinbase: false,
  counterpartyAddress:
      'kaspa:qr7m4h6xk2f9v0s8d3n5t1w7y2b4c6e8g0j2l4n6p8r0t2v4x6z8a0c2e4g6',
  feeSompi: BigInt.from(10000),
  maturity: MaturityState.confirmed,
  stalled: false,
);

Widget _app(Widget home) => MaterialApp(
  theme: kvDarkTheme(),
  builder: (context, page) => KvWindow(child: page!),
  home: home,
);

void main() {
  setUpAll(loadBundledFonts);

  group('rebuild scope — the V4 seam law, measured', () {
    testWidgets('transaction detail: one DAA tick', (tester) async {
      tester.view.physicalSize = const Size(1080, 2460);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final activity = ValueNotifier<List<ActivityRecord>>([_sent()]);
      final daa = ValueNotifier<BigInt?>(BigInt.from(458174042));
      final stale = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        _app(
          TxDetailScreen(
            txid: _txid,
            activity: activity,
            virtualDaaScore: daa,
            stale: stale,
            maturity: kTestMaturity,
            explorerUrl: (id) async => 'https://explorer.example/txs/$id',
            onSendAgain: (_) {},
            onShare: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      final counts = await rebuildsDuring(
        tester,
        () => daa.value = daa.value! + BigInt.one,
      );
      final total = counts.values.fold(0, (a, b) => a + b);
      // **Measured 2026-09-05, before the scope pass: 184 elements** — the
      // head, both `KvAmount`s, the fiat line, five fact rows, the id, the fee,
      // the counterparty and the action bar, ten times a second. After: the
      // chip and the depth plate, and nothing that does not move.
      expect(total, lessThanOrEqualTo(40), reason: '$counts');
      for (final still in [
        '_Head',
        'KvAmount',
        'KvFiatLine',
        '_FactsPlate',
        '_IdLine',
        '_FeeLine',
        '_CounterpartyLine',
        '_ActionBar',
        'KvExplorerExit',
        'KvTopBar',
      ]) {
        expect(counts[still] ?? 0, 0, reason: '$still rebuilt on a DAA tick');
      }
      expect(counts['_DepthPlate'], 1, reason: 'the depth plate is the region');
      expect(counts['_LifecycleChip'], 1, reason: 'the chip reads the rung');
    });

    testWidgets('node screen: one DAA tick, one probe result', (tester) async {
      tester.view.physicalSize = const Size(1080, 2460);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final daa = ValueNotifier<BigInt?>(BigInt.from(523216421));
      final scope = NodeScope(
        connected: ValueNotifier<bool>(true),
        activeEndpoint: ValueNotifier<String?>('wss://isla.kaspa.red'),
        virtualDaaScore: daa,
        pinnedNode: ValueNotifier<String?>(null),
        pinDropped: ValueNotifier<bool>(false),
        setPinnedNode: (_) async {},
        lastUpdate: ValueNotifier<DateTime?>(DateTime(2026, 9, 5)),
        searching: ValueNotifier<bool>(false),
        osOffline: ValueNotifier<bool>(false),
        reconnecting: ValueNotifier<bool>(false),
        onReconnect: () async {},
        blockAgeSecs: () async => 1,
        probeLink: ({required bool peers}) async =>
            (latencyMs: 151, peers: 14, synced: true),
      );
      await tester.pumpWidget(_app(NodeScreen(scope: scope)));
      await tester.pump(const Duration(seconds: 1));
      final tick = await rebuildsDuring(
        tester,
        () => daa.value = daa.value! + BigInt.one,
      );
      // **Before: 84** — the serving plate (cadence, status chip, glow pill,
      // readings) and the whole latency instrument, for a score they never
      // render. After: the chain-clock row alone.
      expect(
        tick.values.fold(0, (a, b) => a + b),
        lessThanOrEqualTo(16),
        reason: '$tick',
      );
      for (final still in [
        'KvLatency',
        'KvLatencyWord',
        'KvRollingText',
        '_NodeDisc',
        '_SwitchNode',
        'KvCadence',
        '_Reading',
        'KvToggle',
        'TextField',
        '_UrlField',
        '_Action',
      ]) {
        expect(tick[still] ?? 0, 0, reason: '$still rebuilt on a DAA tick');
      }
      expect(tick['_CardValue'], 1, reason: 'the DAA reading is the region');
      final probe = await rebuildsDuring(
        tester,
        () => tester.pump(const Duration(seconds: 2)),
      );
      // **Before: 205** — `NodeScreen` itself, the scaffold, the top bar,
      // the toggle and every text field, through a whole-screen `setState`.
      // After: the instrument, the peers row, and the chain-clock row (whose
      // age is read against the poll's own clock).
      expect(
        probe.values.fold(0, (a, b) => a + b),
        lessThanOrEqualTo(40),
        reason: '$probe',
      );
      for (final still in [
        'NodeScreen',
        'Scaffold',
        'KvTopBar',
        'KvToggle',
        'TextField',
        '_UrlField',
        '_Action',
        '_NodeDisc',
        '_SwitchNode',
        'KvCadence',
        '_Reading',
      ]) {
        expect(probe[still] ?? 0, 0, reason: '$still rebuilt on a probe');
      }
      expect(probe['KvLatency'], 1, reason: 'the instrument is the region');
    });
  });
}
