/// **Tier 2 of the review ladder: render a real surface to a PNG, with no
/// device** (D-228).
///
/// The ladder already had its top and bottom and was missing the middle rung:
///
/// | Tier | Cost | Catches | Blind to |
/// |:--|:--|:--|:--|
/// | 1 · measurement guards | seconds | clipping, floors, weight, overflow | how it LOOKS |
/// | **2 · this** | ~seconds, no phone | composition, hierarchy, spacing, colour, before/after | feel, motion, the real panel |
/// | 3 · device sitting | minutes + a phone | press feel, motion under a thumb, true colour, haptics | — |
///
/// The point is to spend judgement before code: propose, render, look, approve
/// or redirect — **then** build. Discovering a bad call on the Android build is
/// the expensive place to discover it.
///
/// ## Why this renders REAL widgets and never a mockup
///
/// A hand-drawn mockup is a picture of an app that does not exist. Approving one
/// moves the gap between picture and build earlier and makes it harder to see —
/// which is the opposite of the point, and it is [[L125]]'s shape (a fixture is
/// a claim) at the design layer. Everything here goes through the real widget
/// tree, the real theme and the real tokens, so an approved preview is a
/// promise the build can keep.
///
/// ## Two limits, stated because a preview that overstates itself is worse
/// than none
///
/// - **A still cannot judge motion.** BG-18's streaming and the 800 ms ring need
///   [renderFrames], which is an approximation of movement and is not feel.
///   Motion is still settled on glass.
/// - **Rendered is not the panel.** True black, refresh rate and brightness on
///   the device are not decided by a PNG on a monitor.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';

/// The bundled faces, loaded exactly once per run.
///
/// **Load these or every preview lies about type.** The test fallback's glyphs
/// are square em-boxes, so an unloaded run renders text as grey blocks and
/// overstates every width by roughly two — L139, which cost three false reds
/// before it was written down, and which this harness reproduced on its very
/// first probe.
///
/// Called from `setUpAll`, NEVER from inside `testWidgets`: the test body runs
/// in a fake-async zone where real file I/O never completes.
Future<void> loadBundledFonts() async {
  for (final font in const {
    'PlusJakartaSans': 'assets/fonts/PlusJakartaSans-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final bytes = await File(font.value).readAsBytes();
    await (FontLoader(
      font.key,
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
}

/// A geometry a surface must survive, by name.
///
/// **Both, always.** The reference is what the design is drawn for; the floor is
/// where it breaks, and every geometry defect this project has found on glass
/// was found at the floor rather than the reference.
class PreviewSize {
  const PreviewSize(this.label, this.size, this.textScale, [this.expect]);

  /// The design's reference geometry.
  static const reference = PreviewSize('393dp', Size(393, 851), 1.0);

  /// The floor the design must survive: the narrowest supported width at the
  /// largest type step the app honours.
  static const floor = PreviewSize('320dp @ 1.3x', Size(320, 720), 1.3);

  static const all = [reference, floor];

  // ── BG-33's four spec frames (§3a.1, D-247) ──────────────────────────────
  //
  // **A screen is not done until it has been seen in all four.** They are not
  // "tablet support": they are four window CLASSES, each of which the design
  // has already decided a different answer for. Drawn without a status bar
  // (BG-14).

  /// `compact` — the design's own frame.
  static const compact = PreviewSize('393 compact', Size(393, 851), 1.0, (
    KvWindowClass.compact,
    KvHeightClass.tall,
  ));

  /// `medium` — unfolded foldable / 8" tablet portrait. One centred column,
  /// standing rail.
  static const medium = PreviewSize('700 medium', Size(700, 900), 1.0, (
    KvWindowClass.medium,
    KvHeightClass.tall,
  ));

  /// `expanded` — tablet landscape. Two panes, standing drawer.
  static const expanded = PreviewSize('1180 expanded', Size(1180, 800), 1.0, (
    KvWindowClass.expanded,
    KvHeightClass.tall,
  ));

  /// `expanded short` — **the V60 on its side**, which is the frame this
  /// project will actually be looked at in most often after portrait. The
  /// money plate collapses to `KvMoneyBar` here and nothing else does.
  static const expandedShort = PreviewSize(
    '915x412 expanded short',
    Size(915, 412),
    1.0,
    (KvWindowClass.expanded, KvHeightClass.short),
  );

  /// The four-frame set BG-33 requires before a screen is called done.
  static const frames = [compact, medium, expanded, expandedShort];

  /// Every geometry a fully-migrated screen is rendered at: the four classes
  /// plus the 320 dp / 1.3× floor, which is where geometry defects are
  /// actually found.
  static const allFrames = [compact, medium, expanded, expandedShort, floor];

  final String label;
  final Size size;
  final double textScale;

  /// The window class this frame **is**, when the frame is named for one.
  ///
  /// It exists so the harness can check itself. A bare
  /// `MediaQueryData(textScaler:)` silently zeroed `size` for the whole of
  /// UX-R0, so every "window class" frame rendered as `compact short` and the
  /// contact sheet was four pictures of a phone. Nothing read the size then,
  /// so nothing could tell. Now [renderSurface] asserts the resolved class
  /// against this, and an instrument that lies about the thing it exists to
  /// show fails instead (L157).
  final (KvWindowClass, KvHeightClass)? expect;

  /// Filesystem-safe form of [label].
  String get slug => label.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
}

/// Where previews are written, as a path **relative to the preview test file**
/// (`matchesGoldenFile` resolves against the test's own directory).
///
/// `build/` is already gitignored, so previews never reach `git status`. That
/// is deliberate: a preview is something you look at once and act on, not a
/// tracked artifact, and a directory of PNGs showing up as untracked noise is
/// how a reviewer learns to ignore the very thing they were meant to review.
const String previewOut = '../../build/preview';

/// The same location from the repo root, for tooling that writes the contact
/// sheet rather than the images.
const String previewDirFromRoot = 'build/preview';

/// True only when a preview run was explicitly asked for.
///
/// The gate runs `flutter test` over everything, and a generator that fires
/// there would write files and burn time on every gate for nobody. Preview
/// tests skip unless `KV_PREVIEW=1`, so the gate sees a no-op.
bool get previewRequested => Platform.environment['KV_PREVIEW'] == '1';

/// Render [child] at [size] and write it to `<previewDir>/<name>__<size>.png`.
///
/// `debugShowCheckedModeBanner` is off: the banner is a corner of every
/// screenshot that is not the app, and it was the second thing this harness's
/// first probe caught.
Future<void> renderSurface(
  WidgetTester tester, {
  required String name,
  required Widget child,
  PreviewSize size = PreviewSize.reference,
  Future<void> Function(WidgetTester tester)? act,
}) async {
  tester.view.physicalSize = size.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      // **Derived from the view, then scaled** — never a bare
      // `MediaQueryData(textScaler:)`.
      //
      // A bare one REPLACES the whole data, so `size` becomes `Size.zero` and
      // `MaterialApp` does not re-derive it because a `MediaQuery` already
      // exists above. Nothing read the size until BG-33 landed, at which point
      // every frame in the catalogue silently resolved to `compact short` and
      // the money plate collapsed to `KvMoneyBar` at 320 dp — where it
      // overflowed, which is how this was found. L139's shape exactly: the
      // harness lied about the thing it was built to show.
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: TextScaler.linear(size.textScale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: kvDarkTheme(),
        // **The same mount point the app uses** (`main.dart`'s `builder`), so
        // a preview reads the window class the device would (BG-33). Without
        // it every frame would render the `compact` fallback and a contact
        // sheet of four window classes would be four pictures of a phone.
        builder: (context, page) => KvWindow(child: page!),
        home: child,
      ),
    ),
  );
  // **Bounded pumps, never `pumpAndSettle`.** A live surface does not quiesce:
  // the cadence meter breathes on a repeating controller and the streaming
  // counters run whenever a reading changes, so waiting for stillness waits
  // forever — the home preview timed out on exactly this. Pump far enough for
  // entrance motion to land and then take the frame as it is, which is also
  // closer to what a user actually sees.
  await tester.pump();
  await tester.pump(KvMotion.enter);
  await tester.pump(KvMotion.enter);
  _assertFrameResolved(tester, size);
  // **A catalogue of first frames is a catalogue of empty screens.** Most of
  // what a surface is FOR only exists after someone has touched it — the send
  // screen's fee line, its address review and an enabled Review button are all
  // invisible until an amount and a destination are in. [act] drives the real
  // widget the way a thumb would, so the shot is a state rather than a start.
  if (act != null) {
    await act(tester);
    await tester.pump();
    await tester.pump(KvMotion.enter);
    await tester.pump(KvMotion.enter);
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('$previewOut/${name}__${size.slug}.png'),
  );
}

/// The harness checking itself: the surface really did resolve to the window
/// class its frame is named for (L157).
void _assertFrameResolved(WidgetTester tester, PreviewSize size) {
  final want = size.expect;
  if (want == null) return;
  final metrics = KvWindow.of(tester.element(find.byType(Navigator)));
  expect(
    (metrics.widthClass, metrics.heightClass),
    want,
    reason:
        '${size.label} rendered as ${metrics.widthClass.name} '
        '${metrics.heightClass.name} — the frame is not the frame it says it '
        'is, and every render under it is a picture of the wrong window',
  );
}

/// Render a moving surface as a **strip of frames**, because a still cannot
/// judge motion.
///
/// This is an approximation and is labelled as one wherever it is shown: it
/// tells you the shape of a transition, not how it feels under a thumb. A
/// motion call is still settled on glass (BG-18, and the 800 ms hold's whole
/// point is what it feels like to hold).
Future<void> renderFrames(
  WidgetTester tester, {
  required String name,
  required Widget child,
  required Duration over,
  int frames = 5,
  PreviewSize size = PreviewSize.reference,
}) async {
  tester.view.physicalSize = size.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      // **Derived from the view, then scaled** — never a bare
      // `MediaQueryData(textScaler:)`.
      //
      // A bare one REPLACES the whole data, so `size` becomes `Size.zero` and
      // `MaterialApp` does not re-derive it because a `MediaQuery` already
      // exists above. Nothing read the size until BG-33 landed, at which point
      // every frame in the catalogue silently resolved to `compact short` and
      // the money plate collapsed to `KvMoneyBar` at 320 dp — where it
      // overflowed, which is how this was found. L139's shape exactly: the
      // harness lied about the thing it was built to show.
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: TextScaler.linear(size.textScale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: kvDarkTheme(),
        // **The same mount point the app uses** (`main.dart`'s `builder`), so
        // a preview reads the window class the device would (BG-33). Without
        // it every frame would render the `compact` fallback and a contact
        // sheet of four window classes would be four pictures of a phone.
        builder: (context, page) => KvWindow(child: page!),
        home: child,
      ),
    ),
  );
  final step = Duration(microseconds: over.inMicroseconds ~/ (frames - 1));
  for (var i = 0; i < frames; i++) {
    if (i > 0) await tester.pump(step);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$previewOut/${name}__frame${i}__${size.slug}.png'),
    );
  }
}
