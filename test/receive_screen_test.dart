import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/receive/qr_tile.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:qr/qr.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

Widget _host(Widget child) => MaterialApp(theme: kvDarkTheme(), home: child);

void main() {
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

      await tester.tap(find.widgetWithText(FilledButton, 'Copy address'));
      await tester.pump();
      expect(copied, _addr, reason: 'never the truncated compact form');
      await tester.pumpAndSettle(); // let the confirmation SnackBar timer clear
    });
  });
}
