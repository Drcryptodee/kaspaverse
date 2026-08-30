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
    'Inter': 'assets/fonts/Inter-Variable.ttf',
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
  const PreviewSize(this.label, this.size, this.textScale);

  /// The design's reference geometry.
  static const reference = PreviewSize('393dp', Size(393, 851), 1.0);

  /// The floor the design must survive: the narrowest supported width at the
  /// largest type step the app honours.
  static const floor = PreviewSize('320dp @ 1.3x', Size(320, 720), 1.3);

  static const all = [reference, floor];

  final String label;
  final Size size;
  final double textScale;

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
      data: MediaQueryData(textScaler: TextScaler.linear(size.textScale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: kvDarkTheme(),
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
      data: MediaQueryData(textScaler: TextScaler.linear(size.textScale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: kvDarkTheme(),
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
