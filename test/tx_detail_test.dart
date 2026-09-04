import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_explorer_exit.dart';

import 'support/preview_harness.dart';
import 'support/finders.dart';
import 'support/maturity.dart';
import 'package:kaspaverse/src/rust/api/transport.dart' show ContactDto;
import 'package:kaspaverse/src/ui/widgets/kv_contact.dart';

const _txid =
    'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34';

/// 2026-08-30 02:48 UTC — the moment wallet-core RECORDED this transaction
/// (its own clock, or a node's DAA→time estimate on a discovered row). It is
/// **not** the accepting block's header timestamp; that field is
/// `TxStatusDto.acceptedUnixMs` and it reaches the ceremony, not this screen.
const int _recordedMs = 1788058080000;

/// A counterparty the fixture can name.
const _payee =
    'kaspa:qr7m4h6xk2f9v0s8d3n5t1w7y2b4c6e8g0j2l4n6p8r0t2v4x6z8a0c2e4g6';

/// A one-entry address book.
ContactsScope _book(String address, String name) => ContactsScope(
  contacts: ValueNotifier<List<ContactDto>>([
    ContactDto(address: address, name: name),
  ]),
  refresh: () async {},
  save: (_, _) async {},
);

/// What `S9` prints for the id — first eight, ellipsis, last eight.
final String _shownTxid = '${_txid.substring(0, 8)}…${_txid.substring(56)}';

/// A send accepted at DAA 458,174,000.
/// **`confirmed`, because that is what the chain layer actually emits for it.**
/// `wallet_sync.rs` derives a spend's maturity from `accepted_daa_score
/// .is_some()`, and this record carries one — so `pending` here would be a
/// fixture the production path can never produce, and every assertion built on
/// it would be proving something about a state that does not exist.
ActivityRecord _sent({
  MaturityState maturity = MaturityState.confirmed,
  BigInt? value,
  String? counterparty,
  BigInt? fee,
}) => ActivityRecord(
  txid: _txid,
  valueSompi: value ?? BigInt.from(1240000000),
  unixtimeMsec: BigInt.from(_recordedMs),
  blockDaaScore: BigInt.from(458173900),
  acceptedDaaScore: BigInt.from(458174000),
  direction: ActivityDirection.outgoing,
  isCoinbase: false,
  counterpartyAddress: counterparty,
  feeSompi: fee,
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

  /// The default test surface is 800x600 — wider and shorter than a phone.
  /// The transaction detail is a `ListView`, so anything past that boundary is
  /// never BUILT and every finder returns nothing, which reads exactly like a
  /// missing widget. These tests reach the bottom of the screen, so they are
  /// given the reference device's real geometry (360x820dp at 3.0).
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2460);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

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
    ContactsScope? contacts,
  }) => MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: MaterialApp(
      theme: kvDarkTheme(),
      // The screen clamps its column with `KvColumn`, which reads the window
      // class — so the window has to be mounted here exactly as the app mounts
      // it at its root (UX-R1's law; `KvWindow.of` asserts rather than falling
      // back, so a missing one is a failure and not a silent phone layout).
      builder: (context, page) => KvWindow(child: page!),
      home: TxDetailScreen(
        txid: _txid,
        activity: s.activity,
        virtualDaaScore: s.daa,
        stale: s.stale,
        maturity: kTestMaturity,
        contacts: contacts,
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

    expect(tester.widget<KvTopBar>(find.byType(KvTopBar)).title, 'Transaction');
    // The verb comes from the shared `kvActivityFace`, so this screen and the
    // ledger row cannot name one transaction two ways (BG-21).
    expect(find.text('Sent'), findsOneWidget);
    // The gauge is the register the balance gave up, and it is the ONE thing
    // on this surface that states the burial.
    expect(find.byType(KvBurialGauge), findsOneWidget);
    // **The chip carries the word, the gauge carries the number** (`S9`,
    // BG-19). Two registers of one fact; one printing of the count.
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('of ${kTestMaturity.userDaa} DAA'), findsOneWidget);
    // The axis is named by the `DEPTH` heading, not beside the reading
    // (founder, device sitting). BG-22 asks for a named axis, not an inline
    // one; the spoken form carries the ceiling, asserted in
    // `burial_gauge_test`.
    expect(findRuledLabel('Depth'), findsOneWidget);
    // **The record's own moment, under a label that does not overclaim it.**
    // `unixtimeMsec` is wallet-core's recording time (or a node's DAA→time
    // estimate) — never the accepting block's header timestamp — so the label
    // is `Time` and not `Accepted`, which is the ceremony's word for the field
    // that genuinely carries the chain's moment. Asserted against the record's
    // OWN unix ms, so a screen that reached for `DateTime.now()` fails here
    // rather than looking plausible.
    // A `_Fact` row, not a ruled heading — the lower half of this screen is a
    // table now, so the labels are set in caps by the row itself.
    // **The verb IS the label** (`S9`): the plate opens by naming what
    // happened rather than repeating a generic `Time`, and the word comes from
    // the shared `kvActivityFace` so this screen and the ledger row cannot name
    // one transaction two ways (BG-21).
    expect(find.text('ACCEPTED'), findsNothing);
    // The accepting score is on the glass beside it, so a reader can check the
    // gauge's arithmetic rather than trust it.
    expect(find.text('DAA score'), findsOneWidget);
    expect(
      find.text(formatStamp(DateTime.fromMillisecondsSinceEpoch(_recordedMs))),
      findsOneWidget,
    );
    // **Recognition on the glass, the whole thing on the clipboard** (`S9`
    // truncates it). The copy is asserted below.
    expect(find.text(_shownTxid), findsOneWidget);
  });

  testWidgets('BG-23 · a sub-1 record does not light its leading zero', (
    tester,
  ) async {
    // `KvAmountRole.hero` defaults to `magnitude`, which is right for a
    // balance — the integer is what you own, even at `0`. A record can be
    // 0.005 KAS, and then the one bright 44 dp character is a `0` that is `0`
    // for every such record while the digits that ARE the amount sit at 15 dp:
    // §8's named anti-pattern, and the identical defect D-231 corrected for
    // the live fee. At or above 1 the two rules agree exactly.
    final dust = _sent(value: BigInt.from(500000)); // 0.005 KAS
    await tester.pumpWidget(host(seams(records: [dust])));
    await tester.pumpAndSettle();

    final runs = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.fontFamily == KvFont.mono)
        .where((t) => (t.style?.fontSize ?? 0) >= 44)
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
      expect(printed, ['42']);
    },
  );

  testWidgets('it stays live: the chain moves and the reading moves with it', (
    tester,
  ) async {
    final s = seams(depth: 42);
    await tester.pumpWidget(host(s));
    await tester.pumpAndSettle();
    expect(find.text('42'), findsOneWidget);

    // The screen is opened precisely because the number is going to change.
    s.daa.value = BigInt.from(458174000 + 90);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the streamed interval
    expect(find.text('90'), findsOneWidget);

    // And across the pin's own threshold the word changes with it — the chip
    // says `Settled` while the fill lands on the ceiling in the same frame.
    s.daa.value = BigInt.from(458174000 + 400);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Settled'), findsOneWidget);
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
      find.text('—'),
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
    phone(tester);
    await tester.pumpWidget(host(seams()));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_shownTxid));
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
      phone(tester);
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
      // **The compact register** (`S9` draws it as one of two buttons on a
      // fixed bar). D-192's disclosure moved to where the explorer is actually
      // chosen — the Network screen's Explorer section — and the spoken label
      // still carries the host and the IP in full.
      expect(find.text('Explorer'), findsOneWidget);
      expect(
        find.text('Shares the transaction ID and your IP address'),
        findsNothing,
      );
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, 'https://kaspa.stream/transactions/$_txid');
    });

    testWidgets('a link it cannot NAME is refused, not opened', (tester) async {
      phone(tester);
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
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
    });

    testWidgets('a platform throw is said out loud, never swallowed', (
      tester,
    ) async {
      phone(tester);
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
      phone(tester);
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
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
    });
  });

  testWidgets('every tap target on the record clears 52 dp (BG-12)', (
    tester,
  ) async {
    // **Measured, not asserted.** All three of these shipped under the floor —
    // `Explorer` at 34.0, "Copy the address" at 22.0, "Copy the transaction id"
    // at 20.0 — and one of them carried a comment claiming "52 dp (BG-12)"
    // while painting `8 + 18 + 8` (`ux-auditor`, UX-R3). A comment is not a
    // measurement; this is.
    phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        seams(records: [_sent(counterparty: _payee)]),
        explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
        openUrl: (_) async => true,
      ),
    );
    await tester.pumpAndSettle();

    for (final label in const ['Copy the address', 'Copy the transaction id']) {
      // The `Semantics` widget itself, not the merged node — the node's label
      // absorbs its descendants, so a lookup by the exact string finds nothing.
      final finder = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == label,
      );
      expect(finder, findsOneWidget, reason: '$label is not on the screen');
      expect(
        tester.getSize(finder).height,
        greaterThanOrEqualTo(KvSpace.touchTarget),
        reason: '"$label" is a ${tester.getSize(finder).height} dp target',
      );
    }
    expect(
      tester.getSize(find.byType(KvExplorerExit)).height,
      greaterThanOrEqualTo(KvSpace.touchTarget),
      reason:
          'the explorer exit is the third one, and it claimed 52 in a '
          'comment while painting 34',
    );
    handle.dispose();
  });

  testWidgets('the counterparty name is stated ONCE, in the chip (BG-19)', (
    tester,
  ) async {
    // `S9`'s `To` row is the address and a copy glyph — no name. Rendering the
    // name there too put it twice above the fold, and the address is what that
    // row is for (BG-15).
    phone(tester);
    await tester.pumpWidget(
      host(
        seams(records: [_sent(counterparty: _payee)]),
        contacts: _book(_payee, 'Mara'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Mara'), findsOneWidget);
    expect(find.textContaining('sent to Mara'), findsOneWidget);
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
