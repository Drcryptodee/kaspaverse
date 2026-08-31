import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/receive/qr_tile.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:qr/qr.dart';

import 'support/preview_harness.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

Widget _host(Widget child, {double textScale = 1}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(theme: kvDarkTheme(), home: child),
);

void main() {
  setUpAll(loadBundledFonts);

  group('QrTile', () {
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
      final quiet = QrTile.quietZone(modules, QrTile.side);
      final cell = (QrTile.side - 2 * quiet) / modules;
      expect(
        quiet,
        greaterThanOrEqualTo(4 * cell - 1e-9),
        reason: 'a QR with less than four modules of margin fails scanners',
      );
      expect(quiet, greaterThanOrEqualTo(KvSpace.m), reason: 'BG-15 floor');

      // And it holds for a matrix denser than any address produces, which is
      // the case a fixed 16 dp would have failed.
      const dense = 101;
      final denseQuiet = QrTile.quietZone(dense, QrTile.side);
      expect(
        denseQuiet,
        greaterThanOrEqualTo(4 * (QrTile.side - 2 * denseQuiet) / dense - 1e-9),
      );
    });

    testWidgets('renders on a light tile regardless of the dark theme (DS-8)', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const Center(child: QrTile(data: _addr))));
      // The tile is the deliberately-out-of-palette light colour, never themed.
      final lightTile = find.descendant(
        of: find.byType(QrTile),
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

      expect(find.byType(QrTile), findsOneWidget);
      expect(tester.widget<KvRail>(find.byType(KvRail)).title, 'Receive');

      // The verification surface shows the FULL address, chunked, and it is
      // rendered by KvAddress rather than by a local copy of the rule. Both
      // halves of that sentence were false on the device: this screen built the
      // string itself, so the founder's ratified five-character tail never
      // reached it AND a flat string carried no weighting at all.
      final full = tester.widget<SelectableText>(find.byType(SelectableText));
      final span = full.textSpan!;
      expect(span.toPlainText(), chunkAddress(_addr));
      // The tail is five characters, together — never a stranded final char.
      expect(span.toPlainText(), endsWith(' cd692'));

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
      expect(groups.first.style?.fontWeight, FontWeight.w600);
      expect(groups.last.style?.fontWeight, FontWeight.w600);
      expect(groups[groups.length ~/ 2].style?.fontWeight, FontWeight.w400);
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
      double slot() => tester
          .getSize(
            find.byWidgetPredicate(
              (w) => w is SizedBox && w.width == QrTile.side,
            ),
          )
          .width;
      expect(find.byType(QrTile), findsNothing);
      final waiting = slot();

      gate.complete(_addr);
      await tester.pumpAndSettle();
      expect(find.byType(QrTile), findsOneWidget);
      expect(
        slot(),
        waiting,
        reason: 'the slot the QR lands in is the slot that was already there',
      );
      expect(waiting, QrTile.side);
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
                  of: find.byType(QrTile),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;

      gate.complete(_addr);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
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
        expect(find.byType(QrTile), findsNothing);
        // Still the same square: a failed state must not be a shorter screen.
        expect(
          tester
              .getSize(
                find.byWidgetPredicate(
                  (w) => w is SizedBox && w.width == QrTile.side,
                ),
              )
              .width,
          QrTile.side,
        );

        // BG-11: an error that does not say what to do is not an error message.
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(attempts, 2);
        expect(find.byType(QrTile), findsOneWidget);
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
}
