import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/kv_qr.dart';
import 'package:kaspaverse/src/ui/address_order.dart';
import 'package:kaspaverse/src/ui/widgets/kv_reading.dart';
import 'package:kaspaverse/src/ui/widgets/kv_rows.dart';
import 'package:kaspaverse/src/ui/receive/receive_picker.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart' show WalletAddressDto;
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:qr/qr.dart';

import 'support/preview_harness.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

/// `KvWindow` above the `Navigator`, exactly as `main.dart` mounts it —
/// **and `fromView`, never a bare `MediaQueryData`**, which replaces the whole
/// data and leaves `size` at zero (the UX-R1 harness defect, §9).
Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: kvDarkTheme(),
  builder: (context, page) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: KvWindow(child: page!),
  ),
  home: child,
);

void main() {
  setUpAll(loadBundledFonts);

  group('KvQr', () {
    test('the encoder produces a non-empty matrix for an address', () {
      final image = QrImage(
        QrCode(
          payload: QrPayload.fromString(_addr),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );
      expect(image.moduleCount, greaterThan(0));
      var anyDark = false;
      outer:
      for (var r = 0; r < image.moduleCount; r++) {
        for (var c = 0; c < image.moduleCount; c++) {
          if (image.isDark(r, c)) {
            anyDark = true;
            break outer;
          }
        }
      }
      expect(anyDark, isTrue, reason: 'a real QR has dark modules');
    });

    test('the quiet zone is four modules, computed from the real matrix', () {
      // **The spec is four MODULES, and 16 dp is only the floor** — a longer
      // payload means more modules and smaller cells, and a fixed margin would
      // silently stop being four of them. This asserts the geometry rather
      // than the constant (item 0 / L121).
      final modules = QrImage(
        QrCode(
          payload: QrPayload.fromString(_addr),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      ).moduleCount;
      // **Four modules at ANY tile side**, because the painter divides the
      // side into `modules + 8` cells and spends four a side. That is the
      // property a fixed dp margin cannot have: `S5` draws an 18 dp pad on a
      // 256 dp tile, which for this address is 3.03 modules — under spec.
      for (final side in [KvQrFrame.maxSide, 180.0, 120.0]) {
        final quiet = KvQr.quietZone(modules, side);
        final cell = (side - 2 * quiet) / modules;
        expect(
          quiet,
          closeTo(4 * cell, 1e-9),
          reason: 'a QR with less than four modules of margin fails scanners',
        );
      }

      // And it holds for a matrix denser than any address produces.
      const dense = 101;
      final denseQuiet = KvQr.quietZone(dense, KvQrFrame.maxSide);
      expect(
        denseQuiet,
        closeTo(4 * (KvQrFrame.maxSide - 2 * denseQuiet) / dense, 1e-9),
      );
    });

    testWidgets('renders on a light tile regardless of the dark theme (DS-8)', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const Center(child: KvQr(data: _addr))));
      // The tile is the deliberately-out-of-palette light colour, never themed.
      final lightTile = find.descendant(
        of: find.byType(KvQr),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == KvColor.qrTile,
        ),
      );
      expect(lightTile, findsOneWidget);
    });
  });

  group('ReceiveScreen', () {
    testWidgets('shows the QR and the full chunked address', (tester) async {
      await tester.pumpWidget(_host(ReceiveScreen(fetch: () async => _addr)));
      await tester.pumpAndSettle();

      expect(find.byType(KvQr), findsOneWidget);
      expect(tester.widget<KvTopBar>(find.byType(KvTopBar)).title, 'Receive');

      // The verification surface shows the FULL address, chunked, and it is
      // rendered by KvAddress rather than by a local copy of the rule. Both
      // halves of that sentence were false on the device: this screen built the
      // string itself, so the founder's ratified five-character tail never
      // reached it AND a flat string carried no weighting at all.
      final full = tester.widget<SelectableText>(find.byType(SelectableText));
      final span = full.textSpan!;
      // **One run, no spaces** (BG-15 as amended, landed at UX-R2): the
      // address reads exactly as it is, so a line break that moves with the
      // text scale cannot make the same address look different twice.
      expect(span.toPlainText(), _addr);
      // The tail is five characters, together — never a stranded final char.
      expect(span.toPlainText(), endsWith('cd692'));

      // And the eye is steered: first and last groups carry the weight, the
      // middle does not. This is the assertion the sitting was missing — the
      // grouping was right and every character still rendered at one weight.
      final spans = <InlineSpan>[];
      span.visitChildren((c) {
        spans.add(c);
        return true;
      });
      final groups = spans
          .whereType<TextSpan>()
          .where((t) => !(t.text ?? '').startsWith('kaspa:'))
          .toList();
      expect(groups.length, KvAddress.groupsOf(_addr).length);
      // §2's checkpoints are **700**, and the merged axis is what the
      // rasteriser reads (L150) — never the enum alone.
      expect(groups.first.style?.fontWeight, FontWeight.w700);
      expect(groups.first.style?.fontVariations, KvWeight.w700);
      expect(groups.last.style?.fontWeight, FontWeight.w700);
      expect(groups.last.style?.fontVariations, KvWeight.w700);
      expect(groups[groups.length ~/ 2].style?.fontWeight, FontWeight.w500);
    });

    testWidgets('BG-19 · the address is not stated twice', (tester) async {
      await tester.pumpWidget(_host(ReceiveScreen(fetch: () async => _addr)));
      await tester.pumpAndSettle();

      // The compact form used to sit sixteen density-pixels above the same
      // address in full. D-223 weighted the chunked form's first and last
      // groups — the exact head and tail the compact line showed — so the full
      // form gained its own glance and the line it replaced stayed.
      expect(
        find.textContaining('…'),
        findsNothing,
        reason: 'the compact form is a summary shown beside its own expansion',
      );
      expect(
        find.byType(KvAddress),
        findsOneWidget,
        reason: 'one address, one rendering of it',
      );
    });

    testWidgets('every state keeps the tile s footprint', (tester) async {
      // A layout that jumps when the address lands moves the tile out from
      // under a hand already holding a camera over it.
      final gate = Completer<String>();
      await tester.pumpWidget(_host(ReceiveScreen(fetch: () => gate.future)));
      await tester.pump();
      // The tile itself, not the `Center` that holds it: the frame takes the
      // width it is given up to [KvQrFrame.maxSide] and is square inside it.
      double slot() => tester
          .getSize(
            find
                .descendant(
                  of: find.byType(KvQrFrame),
                  matching: find.byType(AspectRatio),
                )
                .first,
          )
          .width;
      expect(find.byType(KvQr), findsNothing);
      final waiting = slot();

      gate.complete(_addr);
      await tester.pumpAndSettle();
      expect(find.byType(KvQr), findsOneWidget);
      expect(
        slot(),
        waiting,
        reason: 'the slot the QR lands in is the slot that was already there',
      );
      expect(waiting, KvQrFrame.maxSide);
    });

    testWidgets('BG-24 · the QR arrives through a transition', (tester) async {
      // The footprint was right from the first cut and the CONTENT still
      // hard-cut: `Entrance` plays once on mount, so by the time the address
      // landed nothing accounted for its arrival (`ux-auditor`, UX-5).
      final gate = Completer<String>();
      await tester.pumpWidget(_host(ReceiveScreen(fetch: () => gate.future)));
      // Not `pumpAndSettle`: the waiting face runs the cadence meter, which is
      // the app's one loading indicator and never settles by design.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      double tileOpacity() => tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.byType(KvQr),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;

      gate.complete(_addr);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // The switch's first tick is the frame after the child appears, so the
      // crossfade is read one frame in rather than on the mounting frame.
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tileOpacity(),
        allOf(greaterThan(0.0), lessThan(1.0)),
        reason: 'the tile appeared in one frame with nothing explaining it',
      );
      await tester.pumpAndSettle();
      expect(tileOpacity(), 1.0);
    });

    testWidgets(
      'a failure keeps the footprint, says why, and offers a way on',
      (tester) async {
        var attempts = 0;
        await tester.pumpWidget(
          _host(
            ReceiveScreen(
              fetch: () async {
                attempts++;
                if (attempts == 1) {
                  throw const AppError(message: 'the vault is locked');
                }
                return _addr;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Could not load the receive address.'),
          findsOneWidget,
        );
        // Rust's own words, not the type name — `displayError`, not toString.
        expect(find.text('the vault is locked'), findsOneWidget);
        expect(find.byType(KvQr), findsNothing);
        // Still the same square: a failed state must not be a shorter screen.
        expect(
          tester
              .getSize(
                find
                    .descendant(
                      of: find.byType(KvQrFrame),
                      matching: find.byType(AspectRatio),
                    )
                    .first,
              )
              .width,
          KvQrFrame.maxSide,
        );

        // BG-11: an error that does not say what to do is not an error message.
        // The tile is 300 now, so on the 800x600 default surface the control
        // sits below the fold — scroll to it the way a thumb would.
        await tester.ensureVisible(find.text('Try again'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(find.byType(KvQr), findsOneWidget);
      },
    );

    testWidgets('Copy puts the FULL address on the clipboard', (tester) async {
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

      await tester.pumpWidget(_host(ReceiveScreen(fetch: () async => _addr)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy address'));
      await tester.pump();
      expect(copied, _addr, reason: 'never the truncated compact form');
      await tester.pumpAndSettle(); // let the confirmation SnackBar timer clear
    });

    // The button was the ONE way to take an address off the screen whose whole
    // job is handing it over. Both of these route to `copyFull` too, so a
    // second copy path cannot drift narrower than the sanctioned one (L143).
    for (final (name, target) in <(String, Finder Function())>[
      ('the QR tile', () => find.byType(KvQr)),
      ('the address itself', () => find.byType(KvAddress)),
    ]) {
      testWidgets('tapping $name copies the FULL address', (tester) async {
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

        await tester.pumpWidget(_host(ReceiveScreen(fetch: () async => _addr)));
        await tester.pumpAndSettle();

        await tester.tap(target());
        await tester.pump();
        expect(copied, _addr, reason: 'never the truncated compact form');
        await tester.pumpAndSettle();
      });
    }

    testWidgets('nothing renders under the readable floor at 1.3x / 320dp', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(ReceiveScreen(fetch: () async => _addr), textScale: 1.3),
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
  });

  // ── The picker (UX-R4b) ────────────────────────────────────────────────
  //
  // The one thing every test here is really about: **`FRESH` is a claim about
  // this phone, never about the chain.** A node cannot say whether an address
  // has ever received (INV-8 forbids asking an indexer), so the only honest
  // source is the wallet's own record of what it displayed — and these pin
  // both halves of that: what the record says, and that it is written.

  /// `funded` maps index → sompi; `given` are the indices this phone has
  /// already shown. Everything else is fresh and empty.
  /// `funded` maps index → sompi; `settling` names indices with something on
  /// the way. Everything else has a zero balance and is therefore FRESH.
  List<WalletAddressDto> rowsFor({
    Map<int, int> funded = const {},
    Set<int> settling = const {},
    int count = 12,
  }) => [
    for (var i = 0; i < count; i++)
      WalletAddressDto(
        index: i,
        address:
            'kaspa:q${'abcdefghjklmnpqrstuvwxyz023456789'[i % 33]}'
            'r7mzv4dka9tep0lxh2wnfscjg8y5u3e6vddwm0s3jnp4khce2mua'
            '${i.toString().padLeft(2, '0')}',
        balanceSompi: BigInt.from(funded[i] ?? 0),
        lockedSompi: BigInt.zero,
        settling: settling.contains(i),
        coinCount: funded.containsKey(i) ? 1 : 0,
      ),
  ];

  // ── The picker (UX-R4b, re-scoped at D-295) ────────────────────────────
  //
  // **`FRESH` is an address with a zero balance**, and nothing more subtle.
  // It was "not handed out from this phone" for one sitting, over a record the
  // app wrote when it displayed an address; the founder replaced it on glass
  // and the record went with it. Balance is answerable from the node, says the
  // same thing on a restored wallet, and needs no local state at all.

  group('the receive picker', () {
    test('what puts an address under USED, and what does not', () {
      final rows = rowsFor(funded: {0: 2772000000}, settling: {7});
      // Holding coins.
      expect(ReceivePicker.isUsed(rows[0]), isTrue);
      // Empty now, but something is on its way — money the wallet must not
      // file under "nothing here" (the L92 scar).
      expect(ReceivePicker.isUsed(rows[7]), isTrue);
      // Everything else.
      expect(ReceivePicker.isUsed(rows[3]), isFalse);
      expect(ReceivePicker.isUsed(rows[5]), isFalse);
      // And the law is `AddressOrder`'s, so the two cannot drift apart.
      for (final row in rows) {
        expect(ReceivePicker.isUsed(row), AddressOrder.holdsSomething(row));
      }
    });

    test('money floats above zero balances, index order within each', () {
      final rows = rowsFor(funded: {2: 40000000, 9: 100}, settling: {5});
      final order = AddressOrder.sorted(rows).map((a) => a.index).toList();
      expect(
        order.take(3),
        [2, 5, 9],
        reason:
            'the ones with balance float against the ones with zero '
            '(founder, on glass 2026-09-07) — settling counts as balance',
      );
      expect(order.skip(3), [0, 1, 3, 4, 6, 7, 8, 10, 11]);
    });

    test('the caption states one checkable fact, never a history', () {
      final rows = rowsFor(funded: {0: 2772000000, 2: 40000000}, settling: {3});
      expect(ReceivePicker.captionFor(rows[0]).spoken, 'Default · 1 coin here');
      expect(ReceivePicker.captionFor(rows[2]).spoken, 'Used · 1 coin here');
      expect(
        ReceivePicker.captionFor(rows[3]).spoken,
        'Used · something on its way',
      );
      expect(
        ReceivePicker.captionFor(rows[5]).spoken,
        'Fresh · zero balance',
        reason: 'never "never seen on the chain" — nothing here can know that',
      );
      expect(ReceivePicker.captionFor(rows[5]).fresh, isTrue);
      expect(ReceivePicker.captionFor(rows[0]).isDefault, isTrue);
    });

    testWidgets('no address seam ⇒ the caps label, and no dead control', (
      tester,
    ) async {
      await tester.pumpWidget(_host(ReceiveScreen(fetch: () async => _addr)));
      await tester.pumpAndSettle();
      expect(find.text('YOUR ADDRESS'), findsOneWidget);
      expect(find.text('Main'), findsNothing, reason: 'no pill with no list');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pill names the address and the caption follows it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => _addr,
            addresses: () async => rowsFor(funded: {0: 2772000000}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Main'), findsOneWidget);
      expect(find.text('YOUR ADDRESS'), findsNothing);
      // The caption is one `Text.rich` with a chip inside it, so read it off
      // the semantics the pill publishes rather than hunting for split spans.
      expect(
        find.bySemanticsLabel('Main, Default · 1 coin here. Change address'),
        findsOneWidget,
      );
      // And `Default` is the green badge, not a word in the sentence — the
      // same object the row beside `Main` wears (founder, on glass).
      expect(find.byType(KvDefaultChip), findsOneWidget);
    });

    testWidgets('a coin arriving re-reads the caption where it stands', (
      tester,
    ) async {
      // **The rule (D-295): a screen that prints money re-reads the instant
      // money moves.** The founder found the opposite on glass — a deposit
      // landed, the figure did not move, and only leaving the screen and
      // coming back showed it.
      final coins = ValueNotifier(0);
      addTearDown(coins.dispose);
      var reads = 0;
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => _addr,
            coinsChanged: coins,
            addresses: () async {
              reads++;
              return rowsFor(funded: reads == 1 ? {} : {0: 2772000000});
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Main, Default · zero balance. Change address'),
        findsOneWidget,
      );

      coins.value++;
      await tester.pumpAndSettle();
      expect(reads, 2, reason: 'a coin move re-reads');
      expect(
        find.bySemanticsLabel('Main, Default · 1 coin here. Change address'),
        findsOneWidget,
      );
    });

    test('the offer stops where this app can still find the money again', () {
      // The picker offers only what a restore of this very wallet reaches:
      // `MANUAL_DISCOVERY_DEPTH` probes 0…2047, while the watch window is
      // `mark + GAP_LIMIT` and can run past it. Handing out an address is a
      // promise the money will be findable again.
      expect(ReceivePicker.deepestOffer, 2048);
    });

    testWidgets('an address past the offer depth is never offered as fresh, '
        'and money at one is still shown', (tester) async {
      final deep = [
        ...rowsFor(funded: {0: 2772000000}, count: 3),
        WalletAddressDto(
          index: ReceivePicker.deepestOffer,
          address: 'kaspa:qdeep7mzv4dka9tep0lxh2wnfscjg8y5u3e6vddwm0s3jnp4khce',
          balanceSompi: BigInt.zero,
          lockedSompi: BigInt.zero,
          settling: false,
          coinCount: 0,
        ),
        WalletAddressDto(
          index: ReceivePicker.deepestOffer + 1,
          address: 'kaspa:qdeeq7mzv4dka9tep0lxh2wnfscjg8y5u3e6vddwm0s3jnp4khce',
          balanceSompi: BigInt.from(500000000),
          lockedSompi: BigInt.zero,
          settling: false,
          coinCount: 1,
        ),
      ];
      await tester.pumpWidget(
        _host(
          ReceiveScreen(fetch: () async => _addr, addresses: () async => deep),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      expect(
        find.text('Receive 2048'),
        findsNothing,
        reason: 'past the depth this app rediscovers — never offered',
      );
      expect(
        find.text('Receive 2049'),
        findsOneWidget,
        reason: 'it HOLDS money, so hiding it would hide money',
      );
    });

    testWidgets('choosing a row swaps the QR to THAT address', (tester) async {
      final rows = rowsFor(funded: {0: 2772000000});
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => rows[0].address,
            addresses: () async => rows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      expect(find.text('Receive at'), findsOneWidget);

      await tester.tap(find.text('Receive 03'));
      await tester.pumpAndSettle();
      expect(find.text('Receive at'), findsNothing, reason: 'the sheet closes');
      expect(find.text('Receive 03'), findsOneWidget, reason: 'the pill moved');
      // The address on the glass is the row's own, never a re-derivation.
      expect(tester.widget<KvQr>(find.byType(KvQr)).data, rows[3].address);
    });

    testWidgets('cancelling leaves the address exactly where it was', (
      tester,
    ) async {
      final rows = rowsFor(funded: {0: 2772000000});
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => rows[0].address,
            addresses: () async => rows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Main'), findsOneWidget);
    });

    testWidgets('the fresh card is the reading room, and Show asks it for the '
        'whole thing', (tester) async {
      // **`Show` asks for ROOM, not for rows** (founder, on glass 2026-09-07:
      // *"clicking on 'show' literally does what 'All' does in wallet
      // settings, where it pushes used below a little"*). Every fresh address
      // is already in the list; the control changes the cap it lives under, and
      // a scroll does the same one step at a time.
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => _addr,
            addresses: () async => rowsFor(funded: {0: 2772000000}, count: 24),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();

      final card = find.ancestor(
        of: find.text('Receive 01'),
        matching: find.byType(KvExpands),
      );
      expect(card, findsOneWidget);
      final atRest = tester.getSize(card).height;

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(card).height,
        greaterThan(atRest),
        reason: 'Show gives the fresh card more room, it does not filter',
      );
      expect(
        find.text('Show'),
        findsNothing,
        reason: 'a control that has nothing left to ask for is not drawn',
      );
    });

    testWidgets('a failed list states its three beats and does not touch the '
        'address behind it', (tester) async {
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => _addr,
            addresses: () async =>
                throw const AppError(message: 'the vault is locked'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The screen itself says nothing about it — the QR is fine.
      expect(find.byType(KvQr), findsOneWidget);
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't read this wallet's addresses."),
        findsOneWidget,
      );
      expect(find.text('the vault is locked'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the caption line grows with the reader\'s text scale', (
      tester,
    ) async {
      // **A fixed reserve is a clip, and nothing throws on one.** The caption's
      // own line box scales with the text scaler; the `SizedBox` that reserves
      // it must too, or `overflow: ellipsis` shears the descenders off — five
      // dp of them at 1.3×, found in a preview frame because `takeException`
      // never fires and no finder can see a clipped glyph (L131's class).
      for (final scale in [1.0, 1.3]) {
        await tester.pumpWidget(
          _host(
            ReceiveScreen(
              fetch: () async => _addr,
              index: 4,
              addresses: () async => rowsFor(),
            ),
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        final caption = find.textContaining('zero balance');
        expect(caption, findsOneWidget, reason: 'the caption is drawn');
        final box = tester
            .renderObject<RenderBox>(caption)
            .getDryLayout(const BoxConstraints(maxWidth: 300));
        final reserved = tester
            .widgetList<SizedBox>(
              find.ancestor(of: caption, matching: find.byType(SizedBox)),
            )
            .map((s) => s.height)
            .whereType<double>()
            .reduce((a, b) => a < b ? a : b);
        expect(
          reserved,
          greaterThanOrEqualTo(box.height),
          reason: 'the reserve is smaller than the line at ${scale}x — a clip',
        );
      }
    });

    testWidgets('the sheet survives 1.3x at 320dp with nothing overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          ReceiveScreen(
            fetch: () async => _addr,
            // The `Default` badge beside a title, a balance AND a check in one
            // row is what overflowed `KvRow` by 5.2 dp at this frame.
            addresses: () async => rowsFor(funded: {0: 2772000000}),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
