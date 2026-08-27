import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';

/// A real mainnet address shape: `kaspa:` + a 61-character payload = 67
/// characters, taken from the Rust transport-store fixtures rather than typed.
///
/// **The prototype's own confirm fixture is 68** — a synthetic string one
/// character long, under a comment asserting it is 67 and yields "a
/// one-character weighted last group". A 62-character payload yields a
/// TWO-character one, so the ceremony's most identity-critical group was
/// judged on glass at the wrong width. Using a real address is the fix, and
/// asserting the length here is what stops the next fixture drifting.
const _address =
    'kaspa:qp408svlz585vyvj50yaljm8xdxrkcmmed8vxlx0wf0cl5wpt3vzyh74xs46e';

Widget _host(Widget child, {double width = 360, double textScale = 1}) =>
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, 640),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: KvColor.abyss,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  group('KvAmount — BG-5 money', () {
    testWidgets('unknown is `—`, never a fabricated zero', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const KvAmount(null)));
      expect(find.text('—'), findsOneWidget);
      expect(_styleOf(tester, '—').color, KvColor.inkDim);
      // **The unit stays.** A bare dash at hero size is a small glyph adrift in
      // a 48dp line box, and on glass it read as a rendering glitch rather than
      // as an unknown balance (founder, device sitting). `— KAS` is a value
      // nobody has yet; `—` alone is a mark.
      expect(find.text('KAS'), findsOneWidget);
      expect(find.bySemanticsLabel('balance unknown'), findsOneWidget);
      semantics.dispose();

      // A row carries no unit — the column it sits in does — so the dash is
      // alone there and that is correct.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(const KvAmount(null, role: KvAmountRole.row)),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('KAS'), findsNothing);
    });

    testWidgets('a real zero is a real zero', (tester) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.zero, role: KvAmountRole.screen)),
      );
      expect(find.text('0'), findsOneWidget);
      expect(find.text('.00000000'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('it FLOORS toward zero — never rounds a balance up', (
      tester,
    ) async {
      // 1.99999999 KAS. A wallet that rounds this to "2" shows more spendable
      // than the user holds.
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(199999999), role: KvAmountRole.screen)),
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('.99999999'), findsOneWidget);
    });

    testWidgets(
      'the hero floors at four decimals, and truncates never rounds',
      (tester) async {
        // 1284.50279999 → ".5027", not ".5028".
        await tester.pumpWidget(_host(KvAmount(BigInt.from(128450279999))));
        expect(find.text('1,284'), findsOneWidget);
        expect(find.text('.5027'), findsOneWidget);
      },
    );

    testWidgets('the floor never erases a balance that exists', (tester) async {
      // 5,000 sompi. Floored to four decimals this is `0.0000` — the exact
      // glyphs a real zero gets, so a wallet holding dust would read as a
      // wallet holding nothing. Reachable at the pin only through a legacy
      // pre-KIP-9 UTXO or a coinbase (`STORAGE_MASS_PARAMETER` puts any
      // post-Crescendo output above it), which is narrow — and "narrow" is not
      // one of BG-5's exemptions (`consensus-auditor`, UX-2).
      await tester.pumpWidget(_host(KvAmount(BigInt.from(5000))));
      expect(find.text('0'), findsOneWidget);
      expect(find.text('.00005'), findsOneWidget);
      expect(find.text('.0000'), findsNothing);

      // The boundary: one sompi over the floor keeps the floor, because four
      // decimals still carry the money.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(KvAmount(BigInt.from(10001))));
      expect(find.text('.0001'), findsOneWidget);

      // And a real zero is still a real zero — the lift is for balances that
      // EXIST, never a licence to pad one that does not.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(KvAmount(BigInt.zero)));
      expect(find.text('.0000'), findsOneWidget);
    });

    testWidgets('a row trims to two, a signing surface shows all eight', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(50000000), role: KvAmountRole.row)),
      );
      expect(find.text('.50'), findsOneWidget);

      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(50000000), role: KvAmountRole.screen)),
      );
      expect(find.text('.50000000'), findsOneWidget);
    });

    testWidgets('direction rides sign, colour and weight at once (BG-7)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          KvAmount(
            BigInt.from(1240000000),
            role: KvAmountRole.row,
            direction: KvMoneyDirection.incoming,
          ),
        ),
      );
      expect(_styleOf(tester, '+ 12').color, KvColor.ok);
      expect(_styleOf(tester, '+ 12').fontWeight, FontWeight.w600);

      await tester.pumpWidget(
        _host(
          KvAmount(
            BigInt.from(1240000000),
            role: KvAmountRole.row,
            direction: KvMoneyDirection.outgoing,
          ),
        ),
      );
      expect(_styleOf(tester, '− 12').color, KvColor.risk);
      expect(_styleOf(tester, '− 12').fontWeight, FontWeight.w400);

      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(1240000000), role: KvAmountRole.row)),
      );
      expect(_styleOf(tester, '12').color, KvColor.ink);
    });

    testWidgets('it speaks naturally — the sign is a WORD (§11)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          KvAmount(
            BigInt.from(128450270000),
            direction: KvMoneyDirection.outgoing,
          ),
        ),
      );
      // `−` is U+2212; no screen reader can be relied on to speak it, and a
      // sign nobody hears is not one of BG-7's four channels.
      expect(find.bySemanticsLabel('minus 1,284.5027 KAS'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('it speaks the number, not the padding (§4)', (tester) async {
      final handle = tester.ensureSemantics();
      // 12.4 KAS. The hero SHOWS ".4000" so a column of digits lines up; read
      // aloud those zeros are noise, and §4's example is "1,284.5 KAS".
      await tester.pumpWidget(_host(KvAmount(BigInt.from(1240000000))));
      expect(find.bySemanticsLabel('12.4 KAS'), findsOneWidget);
      expect(find.text('.4000'), findsOneWidget);

      // A signing surface is the exception: BG-6 restates the built
      // transaction in full, spoken included.
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(1240000000), role: KvAmountRole.screen)),
      );
      expect(find.bySemanticsLabel('12.40000000 KAS'), findsOneWidget);

      // A whole number says nothing after the point at all.
      await tester.pumpWidget(_host(KvAmount(BigInt.from(300000000))));
      expect(find.bySemanticsLabel('3 KAS'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the fraction is floored at 11dp too, not just the unit', (
      tester,
    ) async {
      // `size` exists so a composition can drop below the ramp — the D-191
      // plated balance does. Money decimals are the last thing that should go
      // under the readable floor when it does.
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(128450270000), size: 18)),
      );
      expect(
        _styleOf(tester, '.5027').fontSize,
        greaterThanOrEqualTo(KvAmount.readableFloor),
      );
      expect(
        _styleOf(tester, 'KAS').fontSize,
        greaterThanOrEqualTo(KvAmount.readableFloor),
      );
    });

    testWidgets('the unit is ambient teal and never falls below 11dp', (
      tester,
    ) async {
      for (final role in [KvAmountRole.hero, KvAmountRole.screen]) {
        await tester.pumpWidget(
          _host(KvAmount(BigInt.from(100000000), role: role)),
        );
        final unit = _styleOf(tester, 'KAS');
        expect(unit.color, KvColor.primaryMuted, reason: '$role');
        expect(
          unit.fontSize,
          greaterThanOrEqualTo(KvAmount.readableFloor),
          reason:
              '$role — 11dp is the floor for anything a user must read, '
              'and 33% of the screen ramp lands under it',
        );
      }
      // A ledger row's column heading carries the unit; the row does not.
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(100000000), role: KvAmountRole.row)),
      );
      expect(find.text('KAS'), findsNothing);
    });

    testWidgets('every run is mono and tabular', (tester) async {
      await tester.pumpWidget(_host(KvAmount(BigInt.from(128450270000))));
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.style!.fontFamily, KvFont.mono, reason: text.data);
        // Tabular figures on every run that HAS figures, so a value that ticks
        // does not jiggle. The unit is letters and carries none.
        if (RegExp(r'[0-9]').hasMatch(text.data!)) {
          expect(
            text.style!.fontFeatures,
            contains(const FontFeature.tabularFigures()),
            reason: text.data,
          );
        }
      }
    });

    testWidgets('it scales down before it clips — at 320dp and 1.3x', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // A big number in a narrow box at a large text scale: the case where a
      // fixed size would either wrap or ellipsize, both of which BG-5 forbids.
      await tester.pumpWidget(
        _host(
          KvAmount(BigInt.parse('98765432100000000')),
          width: 320,
          textScale: 1.3,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(FittedBox), findsOneWidget);
      expect(find.text('987,654,321'), findsOneWidget);
    });

    testWidgets('stale dims it, and nothing else', (tester) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(100000000), stale: true)),
      );
      await tester.pumpAndSettle();
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, KvFreshness.opacityStale);
      // The digits are unchanged: dimmed cached truth, never a shimmer (BG-8).
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('KvAddress — BG-15 identity, verified not vibed', () {
    test('the fixture is the real 67-character shape', () {
      expect(_address, hasLength(67));
      expect(_address.substring(_address.indexOf(':') + 1), hasLength(61));
    });

    testWidgets('compact = scheme + first 8 + last 8 of the payload', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvAddress(_address)));
      final rendered = tester
          .widget<Text>(find.byType(Text))
          .textSpan!
          .toPlainText();
      final payload = _address.substring(_address.indexOf(':') + 1);
      expect(
        rendered,
        'kaspa:${payload.substring(0, 8)}…'
        '${payload.substring(payload.length - 8)}',
      );
      expect(rendered, isNot(startsWith('kaspa:q…')));
    });

    testWidgets('compact keeps its TAIL in a narrow box — it scales down', (
      tester,
    ) async {
      // The device caught the ellipsis version of this: a compact address
      // re-ellipsized by its row, deleting the eight characters that identify
      // it. Clipping loses exactly the same eight, just without the tell — so
      // the answer is neither, and the text shrinks instead.
      await tester.pumpWidget(_host(const KvAddress(_address), width: 80));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.overflow, TextOverflow.clip);
      expect(text.softWrap, isFalse);
      expect(text.maxLines, 1);
      expect(find.byType(FittedBox), findsOneWidget);
      // The whole compact string is laid out; the box scales it, and the last
      // eight payload characters are still in it.
      final laid = tester.renderObject<RenderBox>(find.byType(Text));
      expect(laid.size.width, greaterThan(80));
      expect(
        text.textSpan!.toPlainText(),
        endsWith(_address.substring(_address.length - 8)),
      );
    });

    testWidgets('a caller that pre-truncates is caught, not accommodated', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const KvAddress('kaspa:qp408svl…yh74xs46e')),
      );
      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('chunked reads in fours with the ends weighted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const KvAddress(_address, form: KvAddressForm.chunked)),
      );
      final groups = KvAddress.groupsOf(_address);
      expect(groups.first, _address.substring(6, 10));
      // 61 is not a multiple of 4, so the last group is ONE character — which
      // is exactly where BG-15 puts the eye.
      expect(groups.last, hasLength(1));
      // Nothing is lost in the chunking: this form is the one a user checks
      // character by character, so it must be the WHOLE payload.
      expect(groups.join(), _address.substring(_address.indexOf(':') + 1));

      expect(_styleOf(tester, groups.first).fontWeight, FontWeight.w600);
      expect(_styleOf(tester, groups.first).color, KvColor.ink);
      expect(_styleOf(tester, groups[1]).fontWeight, FontWeight.w400);
      expect(_styleOf(tester, groups[1]).color, KvColor.inkDim);
      expect(find.text('kaspa:'), findsOneWidget);
    });

    testWidgets('copy copies all 67 characters — there is one copy path', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      await KvAddress.copyFull(_address);
      expect(copied, _address);
      expect(copied, hasLength(67));
    });

    testWidgets('it survives 1.3x at 320dp in both forms', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final form in KvAddressForm.values) {
        await tester.pumpWidget(
          _host(KvAddress(_address, form: form), width: 320, textScale: 1.3),
        );
        expect(tester.takeException(), isNull, reason: '$form');
      }
    });
  });
}
