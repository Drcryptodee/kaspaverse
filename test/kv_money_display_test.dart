import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';

import 'support/preview_harness.dart';

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

/// Every `Text` inside the amount, in order, concatenated — so an assertion is
/// about the FIGURE the user reads rather than about how many runs it took to
/// draw it.
String _joinedFigure(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byType(KvAmount), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .where((t) => t != 'KAS') // the unit is beside the figure, not in it
    .join();

void main() {
  // **The bundled faces, or every width here is a lie** (L139): the test
  // fallback's glyphs are square em-boxes, so a weight difference measures as
  // zero whether it was painted or not.
  setUpAll(loadBundledFonts);

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

    testWidgets('the hero shows every significant decimal, and no more', (
      tester,
    ) async {
      // D-210, the precision law. Each digit that carries value is shown; a
      // trailing zero is noise the eye reads past to find where the number
      // ends, and a fixed-width truncation is worse — it hides value held.
      for (final (sompi, integer, fraction) in const [
        // 21.12345678 — the last digit is a digit, so all eight stay.
        ('2112345678', '21', '.12345678'),
        // 21.12345600 — the zeros carry nothing.
        ('2112345600', '21', '.123456'),
        ('2112340000', '21', '.1234'),
        // A whole balance stops at the two-decimal minimum money keeps.
        ('2100000000', '21', '.00'),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_host(KvAmount(BigInt.parse(sompi))));
        expect(find.text(integer), findsOneWidget, reason: sompi);
        expect(find.text(fraction), findsOneWidget, reason: sompi);
      }

      // And it still FLOORS: 1284.50279999 never becomes .5028.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(KvAmount(BigInt.from(128450279999))));
      expect(find.text('1,284'), findsOneWidget);
      expect(find.text('.50279999'), findsOneWidget);
    });

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

      // A real zero is still a real zero: the significant-digit rule shows
      // what is there, and what is there is nothing.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(KvAmount(BigInt.zero)));
      expect(find.text('.00'), findsOneWidget);
    });

    testWidgets('a row trims to two, a signing surface shows all eight', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(50000000), role: KvAmountRole.row)),
      );
      expect(find.text('.50'), findsOneWidget);

      // **Concatenated across runs, not matched as one string.** A signing
      // surface takes `significant` emphasis (D-230), so `0.50000000` renders
      // as a quiet `0.` and a strong `50000000` — the eight decimals BG-6
      // requires are all present, in two `Text`s instead of one. Asserting the
      // joined figure is what the law actually says; asserting a single run was
      // asserting an implementation detail, which is why this went red on a
      // change that shows every digit it always did (L143's sibling: a string
      // comparison cannot testify about a render).
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(50000000), role: KvAmountRole.screen)),
      );
      expect(_joinedFigure(tester), '0.50000000');
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
      // **The figure takes the direction's hue, and weight carries what hue
      // used to** (BG-7 as amended in Deep V6 v4.2 — it *reverses* BG-26's
      // colour channel; a neutral ledger figure is now the finding). Both
      // channels are still present and both are still asserted; which object
      // carries which has swapped.
      expect(_styleOf(tester, '+12').color, KvColor.ok);
      expect(_styleOf(tester, '+12').fontWeight, FontWeight.w700);

      await tester.pumpWidget(
        _host(
          KvAmount(
            BigInt.from(1240000000),
            role: KvAmountRole.row,
            direction: KvMoneyDirection.outgoing,
          ),
        ),
      );
      expect(_styleOf(tester, '−12').color, KvColor.risk);
      expect(_styleOf(tester, '−12').fontWeight, FontWeight.w500);

      // A figure with no direction — a balance, a fee, a self-send — carries
      // no hue: BG-7 colours *value in motion*, and information is colourless.
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(1240000000), role: KvAmountRole.row)),
      );
      expect(_styleOf(tester, '12').color, KvColor.ink);
    });

    testWidgets('the weight channel is PAINTED, not merely declared (BG-26)', (
      tester,
    ) async {
      // **The defect this is written against, measured 2026-09-04.** Both faces
      // are variable, so `fontWeight:` is a hint and `FontVariation('wght', …)`
      // is what the rasteriser uses — and an inline `TextStyle` merges over the
      // ambient `DefaultTextStyle`, **inheriting its axis**. An incoming row
      // declared at `w700` and an outgoing row declared at `w500` therefore
      // rendered at **identical width, both at axis 400**: BG-26 says direction
      // rides four channels and only three existed.
      //
      // **Asserted on the rendered width**, never on `style.fontWeight` — a
      // guard that read the declaration back to itself is exactly what let this
      // survive (L150). It runs inside a real `Scaffold` under `kvDarkTheme()`,
      // because the ambient axis is the whole mechanism and a bare host has
      // none.
      // **Width cannot be the probe here, and that is not a shortcut.**
      // JetBrains Mono is monospaced: every glyph has the same advance at every
      // weight, so a figure measures identically whether the axis was applied
      // or not. What the rasteriser actually receives is the **merged** style's
      // `fontVariations` — the ambient axis is what was overwriting it — so
      // that is what is asserted, and the proportional half is proved below on
      // a Jakarta run where width *is* a valid measurement.
      Future<List<FontVariation>?> axisFor(KvMoneyDirection direction) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: kvDarkTheme(),
            home: Scaffold(
              body: Center(
                child: KvAmount(
                  BigInt.from(2400000000),
                  role: KvAmountRole.row,
                  direction: direction,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester
            .renderObject<RenderParagraph>(find.textContaining('24'))
            .text
            .style!
            .fontVariations;
      }

      expect(await axisFor(KvMoneyDirection.incoming), KvWeight.w700);
      expect(await axisFor(KvMoneyDirection.outgoing), KvWeight.w500);

      // The proportional half, measured as ink: the same word at 600 and at
      // 400 in Plus Jakarta Sans, inside a real theme so the ambient axis is
      // present. Before the fix these measured identically.
      Future<double> jakartaWidth(FontWeight weight) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: kvDarkTheme(),
            home: Scaffold(
              body: Center(
                child: Text(
                  'Received',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    fontWeight: weight,
                    fontVariations: KvWeight.of(weight),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.getSize(find.text('Received')).width;
      }

      expect(
        await jakartaWidth(FontWeight.w600),
        greaterThan(await jakartaWidth(FontWeight.w400)),
        reason: 'a heavier word must actually be wider, or nothing was painted',
      );
      await tester.pumpWidget(const SizedBox());
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
      // 12.4 KAS. Under the precision law (D-210) the hero shows `.40` — money
      // keeps two decimals as its floor even when the second carries nothing,
      // so a column of figures still lines up. Read aloud even that zero is
      // noise, and §4's example is "1,284.5 KAS".
      await tester.pumpWidget(_host(KvAmount(BigInt.from(1240000000))));
      expect(find.bySemanticsLabel('12.4 KAS'), findsOneWidget);
      expect(find.text('.40'), findsOneWidget);

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
        // `primaryMuted` — teal, by the founder's ruling on glass (D-262),
        // over the render's meta grey (S1). It shipped grey once because the
        // revert was noticed and not made (D-263); this pin is why not twice.
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

    testWidgets('chunked reads in fours with the LAST FIVE together and the '
        'ends weighted', (tester) async {
      await tester.pumpWidget(
        _host(const KvAddress(_address, form: KvAddressForm.chunked)),
      );
      final groups = KvAddress.groupsOf(_address);
      expect(groups.first, _address.substring(6, 10));
      // **D-223, founder-ratified.** Chunking purely in fours left a 61-char
      // payload ending `… c6jz qunt h`: a ONE-character final group, weighted
      // bold, standing alone. The weighting exists so the eye lands where an
      // address-poisoning attack has to succeed, and a single stranded
      // character is the weakest possible place to put it — there is almost
      // nothing there to compare against. The tail keeps five now.
      expect(groups.last, hasLength(KvAddress.tailGroup));
      expect(groups.last, _address.substring(_address.length - 5));
      // Nothing is lost in the chunking: this form is the one a user checks
      // character by character, so it must be the WHOLE payload.
      expect(groups.join(), _address.substring(_address.indexOf(':') + 1));

      // **One run, not spaced fours** (BG-15 as amended; landed at UX-R2).
      // The groups survive as the weighting boundary and as what a screen
      // reader speaks — they simply no longer print a space, because line
      // breaks that move with the text scale make the same address look
      // different every time it is shown.
      final spans = <InlineSpan>[];
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(KvAddress),
                  matching: find.byType(Text),
                )
                .first,
          )
          .textSpan!
          .visitChildren((span) {
            spans.add(span);
            return true;
          });
      expect(
        spans.map((s) => (s as TextSpan).text).join(),
        _address,
        reason: 'every character, in order, with nothing inserted',
      );
      final scheme = spans.first as TextSpan;
      expect(scheme.text, 'kaspa:');
      expect(scheme.style!.color, KvColor.inkMeta);
      // §2's checkpoints are 700, and the MERGED axis is the ink (L150).
      final head = spans[1] as TextSpan;
      expect(head.text, groups.first);
      expect(head.style!.fontWeight, FontWeight.w700);
      expect(head.style!.fontVariations, KvWeight.w700);
      expect(head.style!.color, KvColor.ink);
      final middle = spans[2] as TextSpan;
      expect(middle.style!.fontWeight, FontWeight.w500);
      expect(middle.style!.fontVariations, KvWeight.w500);
      expect(middle.style!.color, KvColor.inkDim);
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
