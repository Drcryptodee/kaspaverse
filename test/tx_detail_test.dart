import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_explorer_exit.dart';

import 'support/preview_harness.dart';

const _txid =
    'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34';

/// 2026-08-30 02:48 UTC — the moment wallet-core RECORDED this transaction
/// (its own clock, or a node's DAA→time estimate on a discovered row). It is
/// **not** the accepting block's header timestamp; that field is
/// `TxStatusDto.acceptedUnixMs` and it reaches the ceremony, not this screen.
const int _recordedMs = 1788058080000;

/// A send accepted at DAA 458,174,000.
ActivityRecord _sent({
  MaturityState maturity = MaturityState.pending,
  BigInt? value,
}) => ActivityRecord(
  txid: _txid,
  valueSompi: value ?? BigInt.from(1240000000),
  unixtimeMsec: BigInt.from(_recordedMs),
  blockDaaScore: BigInt.from(458173900),
  acceptedDaaScore: BigInt.from(458174000),
  direction: ActivityDirection.outgoing,
  isCoinbase: false,
  maturity: maturity,
  stalled: false,
);

void main() {
  setUpAll(loadBundledFonts);

  ({
    ValueNotifier<List<ActivityRecord>> activity,
    ValueNotifier<BigInt?> daa,
    ValueNotifier<bool> stale,
  })
  seams({int depth = 42, List<ActivityRecord>? records}) => (
    activity: ValueNotifier<List<ActivityRecord>>(records ?? [_sent()]),
    daa: ValueNotifier<BigInt?>(BigInt.from(458174000 + depth)),
    stale: ValueNotifier<bool>(false),
  );

  Widget host(
    ({
      ValueNotifier<List<ActivityRecord>> activity,
      ValueNotifier<BigInt?> daa,
      ValueNotifier<bool> stale,
    })
    s, {
    double textScale = 1,
    Future<String> Function(String txid)? explorerUrl,
    Future<bool> Function(String url)? openUrl,
  }) => MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: MaterialApp(
      theme: kvDarkTheme(),
      home: TxDetailScreen(
        txid: _txid,
        activity: s.activity,
        virtualDaaScore: s.daa,
        stale: s.stale,
        explorerUrl: explorerUrl,
        openUrl: openUrl,
      ),
    ),
  );

  testWidgets('the record reads as one transaction, at full size', (
    tester,
  ) async {
    await tester.pumpWidget(host(seams()));
    await tester.pumpAndSettle();

    expect(tester.widget<KvRail>(find.byType(KvRail)).title, 'Transaction');
    // The verb comes from the shared `kvActivityFace`, so this screen and the
    // ledger row cannot name one transaction two ways (BG-21).
    expect(find.text('Sent'), findsOneWidget);
    // The gauge is the register the balance gave up, and it is the ONE thing
    // on this surface that states the burial.
    expect(find.byType(KvBurialGauge), findsOneWidget);
    expect(find.text('Seen 42'), findsOneWidget);
    expect(find.text('blocks deep'), findsOneWidget);
    // **The record's own moment, under a label that does not overclaim it.**
    // `unixtimeMsec` is wallet-core's recording time (or a node's DAA→time
    // estimate) — never the accepting block's header timestamp — so the label
    // is `Recorded` and not `Accepted`, which is the ceremony's word for the
    // field that genuinely carries the chain's moment. Asserted against the
    // record's OWN unix ms, so a screen that reached for `DateTime.now()`
    // fails here rather than looking plausible.
    expect(find.text('Recorded'), findsOneWidget);
    expect(find.text('Accepted'), findsNothing);
    expect(
      find.text(formatStamp(DateTime.fromMillisecondsSinceEpoch(_recordedMs))),
      findsOneWidget,
    );
    expect(find.text(_txid), findsOneWidget);
  });

  testWidgets('BG-23 · a sub-1 record does not light its leading zero', (
    tester,
  ) async {
    // `KvAmountRole.hero` defaults to `magnitude`, which is right for a
    // balance — the integer is what you own, even at `0`. A record can be
    // 0.005 KAS, and then the one bright 32 dp character is a `0` that is `0`
    // for every such record while the digits that ARE the amount sit at 15 dp:
    // §8's named anti-pattern, and the identical defect D-231 corrected for
    // the live fee. At or above 1 the two rules agree exactly.
    final dust = _sent(value: BigInt.from(500000)); // 0.005 KAS
    await tester.pumpWidget(host(seams(records: [dust])));
    await tester.pumpAndSettle();

    final runs = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.fontFamily == KvFont.mono)
        .where((t) => (t.style?.fontSize ?? 0) >= 32)
        .map((t) => t.data ?? '')
        .toList();
    expect(runs, isNotEmpty, reason: 'no run took the emphasis at all');
    expect(
      runs.any((r) => RegExp(r'[1-9]').hasMatch(r)),
      isTrue,
      reason:
          'the bright weight fell on $runs — ink spent on a character that is '
          'the same in every case (BG-23)',
    );
  });

  testWidgets(
    'BG-19 · the depth is stated once, as a number and as an extent',
    (tester) async {
      await tester.pumpWidget(host(seams(depth: 42)));
      await tester.pumpAndSettle();
      // Two REGISTERS of one fact answering different questions is not a
      // duplicate — a count, and how far along a declared scale it sits. Two
      // printings of the count would be. The txid is excluded by identity, not
      // by luck: it is a 64-character hex string and contains every digit.
      final printed = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((d) => d != _txid && d.contains('42'))
          .toList();
      expect(printed, ['Seen 42']);
    },
  );

  testWidgets('it stays live: the chain moves and the reading moves with it', (
    tester,
  ) async {
    final s = seams(depth: 42);
    await tester.pumpWidget(host(s));
    await tester.pumpAndSettle();
    expect(find.text('Seen 42'), findsOneWidget);

    // The screen is opened precisely because the number is going to change.
    s.daa.value = BigInt.from(458174000 + 90);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the streamed interval
    expect(find.text('Seen 90'), findsOneWidget);

    // And across the safe threshold the words change with it.
    s.daa.value = BigInt.from(458174000 + 400);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Confirmed'), findsOneWidget);
  });

  testWidgets('a stale link stops counting and says so (BG-8/BG-20)', (
    tester,
  ) async {
    final s = seams(depth: 42);
    await tester.pumpWidget(host(s));
    await tester.pumpAndSettle();

    s.stale.value = true;
    await tester.pumpAndSettle();
    expect(
      find.text('Seen —'),
      findsOneWidget,
      reason:
          'a frozen last-known DAA must not read live, and the absence of a '
          'depth is not a depth of zero',
    );
  });

  testWidgets('a row that leaves the feed has a face of its own', (
    tester,
  ) async {
    final s = seams();
    await tester.pumpWidget(host(s));
    await tester.pumpAndSettle();
    // The list arrives already truncated by Rust, so this is reachable while
    // the screen is open — an empty screen would be the wrong answer.
    s.activity.value = const [];
    await tester.pumpAndSettle();
    expect(
      find.textContaining('no longer in your recent activity'),
      findsOneWidget,
    );
    expect(find.byType(KvBurialGauge), findsNothing);
    // It still names the transaction it is about.
    expect(find.text(_txid), findsOneWidget);
  });

  testWidgets('the transaction id copies whole', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(host(seams()));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_txid));
    await tester.pump();
    expect(copied, _txid, reason: 'a truncated txid is as useless as none');
    await tester.pumpAndSettle();
  });

  group('the explorer exit', () {
    testWidgets('is absent when there is nowhere to go', (tester) async {
      await tester.pumpWidget(host(seams()));
      await tester.pumpAndSettle();
      expect(
        find.byType(KvExplorerExit),
        findsNothing,
        reason: 'a control with no destination is worse than no control',
      );
    });

    testWidgets('names the destination and what it hands over', (tester) async {
      String? opened;
      await tester.pumpWidget(
        host(
          seams(),
          explorerUrl: (txid) async =>
              'https://kaspa.stream/transactions/$txid',
          openUrl: (url) async {
            opened = url;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('View on kaspa.stream'), findsOneWidget);
      expect(
        find.text('it will see this transaction id and your network address'),
        findsOneWidget,
      );
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, 'https://kaspa.stream/transactions/$_txid');
    });

    testWidgets('a link it cannot NAME is refused, not opened', (tester) async {
      // `validate_template` requires https and a non-empty authority and
      // refuses credentials — but never checks the authority parses as a host.
      // `https://:8080/txs/{txid}` passes Rust and came back here with an empty
      // host, rendering a live, tappable control reading "View on "
      // (`consensus-auditor`, UX-5). A departure you cannot name is not one you
      // consented to (D-192), so it fails closed.
      var opened = false;
      await tester.pumpWidget(
        host(
          seams(),
          explorerUrl: (txid) async => 'https://:8080/txs/$txid',
          openUrl: (_) async {
            opened = true;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('View on '), findsNothing);
      expect(find.text('The explorer link cannot be used'), findsOneWidget);
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
    });

    testWidgets('a platform throw is said out loud, never swallowed', (
      tester,
    ) async {
      // An unhandled throw out of `onTap` is a control that visibly does
      // nothing — the BG-12 shape this widget exists to eliminate.
      await tester.pumpWidget(
        host(
          seams(),
          explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
          openUrl: (_) async =>
              throw PlatformException(code: 'failed', message: 'denied'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pump();
      expect(find.text('The link could not be opened.'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'an unhandled throw out of onTap is a control that does nothing',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a refused template is disabled and says what to fix', (
      tester,
    ) async {
      var opened = false;
      await tester.pumpWidget(
        host(
          seams(),
          explorerUrl: (_) async => throw const AppError(
            message: 'the explorer link must start with https://',
          ),
          openUrl: (_) async {
            opened = true;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The explorer link cannot be used'), findsOneWidget);
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
    });
  });

  testWidgets('nothing renders under the readable floor at 1.3x / 320dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        seams(),
        textScale: 1.3,
        explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
        openUrl: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(
        text.style?.fontSize ?? 11,
        greaterThanOrEqualTo(11),
        reason: '"${text.data}" renders under the 11dp floor (BG-14)',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
