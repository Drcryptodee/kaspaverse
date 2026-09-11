import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Every glyph the app draws (§2, §2a). The set is **drawn, not imported**:
/// there is no icon package, and Material's `Icons.*` is not the answer either
/// — the call, and the case against it, is **D-205**.
///
/// **The geometry is Lucide's, transcribed** (§2a, founder ruling 2026-09-04,
/// D-259/D-261: *"the icons used as seen in the screenshots, exactly"*). Every
/// mark below carries the Lucide name it was taken from and its path data
/// verbatim, so a reviewer can put it beside lucide.dev and see one shape. The
/// three tweaks §2a names are applied at paint time, never to the data: stroke
/// 2.5 instead of 2, round caps and joins, and no fill — a dot is a zero-length
/// round-capped stroke (`h.01`), exactly as Lucide draws it.
///
/// **`Icons.*` is swept out of `lib/`** (UX-R8, closing `design_system.md`
/// §9.3 divergence 3): every mark the app draws is a case below, and
/// `test/no_material_icons_test.dart` keeps it that way — a new `Icons.` in
/// `lib/` reds the gate, which is BG-25 as a mechanism rather than a review
/// item. The last fifteen retired at UX-R8 (twelve in the thread, three on
/// the debug launchers), seven of them by drawing a mark that had no house
/// shape yet.
///
/// Adding a glyph is one enum case plus one `case` arm in [KvGlyphPainter] —
/// the Lucide outline, pasted — which is deliberately the whole cost: this file
/// is the single place a glyph is chosen, so the decision stays one file wide
/// **in both directions**.
enum KvGlyph {
  /// Money arriving. Lucide `arrow-down-left`.
  arrowIn,

  /// Money leaving. Lucide `arrow-up-right`.
  arrowOut,

  /// A self-send: value that never leaves the wallet. Lucide `repeat`.
  selfSend,

  /// The one empty-state mark. Lucide `gem`.
  diamond,

  /// "This goes somewhere." Lucide `chevron-right`; rotate it for back.
  chevron,

  /// Destination: the wallet. Lucide `wallet` — the billfold with a clasp
  /// (render `S2 · Drawer`).
  money,

  /// Destination: messages. Lucide `message-circle`.
  chat,

  /// Destination: games. Lucide `gamepad-2`.
  games,

  /// Destination: contracts. Lucide `file-text`.
  contracts,

  /// Destination: finance. Lucide `chart-line`.
  finance,

  /// Tokens. Lucide `coins`.
  assets,

  /// Destination: settings. Lucide `sliders-horizontal` — three rails with a
  /// thumb on each, which is what a setting is; a cog is a machine.
  settings,

  /// Destination: identity — **who you are to other people**, as distinct
  /// from [settings], which is how the app behaves. Lucide `user-round`: a
  /// head and a pair of shoulders (render `S2 · Drawer`).
  identity,

  /// Destination: the node and the link. Lucide `radio`.
  network,

  /// Destination: security; a trust statement. Lucide `shield-check`.
  shield,

  /// Destination: help. Lucide `circle-question-mark`.
  help,

  /// "There is more to read about this." Lucide `info` — the circled i the
  /// founder asked for beside a section's caps label (2026-09-05): tapping it
  /// eases the section's explainer in beneath its card.
  info,

  /// Appearance — theme and how the app looks. Lucide `palette`. Its four
  /// wells are zero-radius round-capped strokes, which is how §2a rule 4 draws
  /// a dot inside a mark: nothing here is filled.
  palette,

  /// Notifications. Lucide `bell`.
  bell,

  /// Reveal, and privacy. Lucide `eye`.
  eye,

  /// Look deeper for addresses another wallet may have used. Lucide `layers`.
  layers,

  /// Many coins becoming one. **The one mark in this set with no Lucide
  /// name**: `T4`'s is a two-into-one fork, measured off the render rather
  /// than pasted, because no Lucide icon is that shape. See the painter.
  merge,

  /// The source code. Lucide `github` — the one mark in the set that names a
  /// company rather than an act, because the row it opens names that company
  /// too and a generic `external` there would say less than the words already
  /// do.
  github,

  /// The lock, and locking. Lucide `lock`.
  lock,

  /// Paste into a field. Lucide `clipboard`.
  paste,

  /// Open the camera. Lucide `scan-line` (render `S1 · Home`, top right).
  scan,

  /// History, and anything that reaches backwards in time. Lucide `history`.
  history,

  /// A slot that exists and has not been filled. Lucide `circle-dashed` — a
  /// ring drawn as eight arcs, which is how every interface on earth says
  /// *nothing here yet* without saying *nothing here, ever*. It seats the
  /// receive picker's fresh addresses opposite [history]'s used ones, and the
  /// distinction it draws is deliberately the narrow one: this phone has not
  /// handed the address out. What the chain has seen is a question no node
  /// answers (INV-8; `bridge::api::wallet`, D-293).
  circleDashed,

  /// Overflow. Lucide `ellipsis` — three dots, each a zero-length stroke.
  kebab,

  /// Done. Lucide `check`, drawn at the same weight as every other mark — a
  /// machined tick, not a celebration (§7: the vault register does not cheer).
  check,

  /// Delete the character to the left. Lucide `delete` — the wedge with a
  /// cross, the form every keyboard on earth uses — and **drawn rather than
  /// borrowed** (BG-25, D-229): `JetBrainsMono-Variable.ttf` has no U+232B.
  backspace,

  /// Shift, on the secret keyboard. Lucide `arrow-big-up`, one closed stroke.
  shift,

  /// Copy this — an address, a transaction id. Lucide `copy`.
  copy,

  /// This leaves the app. Lucide `external-link`.
  external,

  /// Hand this out of the app — one mark, app-wide. Lucide `share`: a tray
  /// with the arrow leaving it. `S9`'s own mark at the top right (founder, on
  /// glass 2026-09-05), and the mark `S5 · Receive` draws on its Share pill;
  /// Lucide's `share-2` (the three-node graph) lived beside it as `share` until
  /// UX-R8 read the Receive render and found it was never drawn there (BG-21:
  /// one glyph per meaning).
  share,

  /// The hold's badge, and biometrics. Lucide `fingerprint` (shipped in this
  /// Lucide build under the name `fingerprint-pattern`). **Illustrative**, so
  /// it takes [KvGlyphSpec.strokeIllustrative] rather than the 2.5 default —
  /// nine contours at 2.5 in a 20 dp box read as a smudge (§2a, weights by job).
  fingerprint,

  /// **Face unlock**, the other half of the biometrics pair. Lucide
  /// `scan-face`: four bracket corners around a face, whose two eyes and smile
  /// are the same three strokes [smile] draws — the eyes zero-length and
  /// round-capped, which is how §2a rule 4 puts a dot inside a mark.
  ///
  /// Illustrative like [fingerprint] and for the same reason: `O6` seats the
  /// pair at 104 dp, where 2.5 on a 24 grid reads as wire. It takes
  /// [KvGlyphSpec.strokeIllustrative] at that size.
  ///
  /// **Not [scan]**, which is a scan LINE and means *open the camera*. The
  /// brackets are shared; what is inside them is the whole difference, and a
  /// mark that identified two different acts would have stopped identifying
  /// either (§2a rule 3).
  face,

  /// Dismiss, clear, close. Lucide `x`.
  close,

  /// Find something in a list. Lucide `search` — `M1 · Chats` seats it inside
  /// the search field, which is the only place the app looks anything up.
  search,

  /// Save this to the device. Lucide `download` — the tray with the arrow
  /// coming INTO it, the mirror of [share], which is what an attachment
  /// save is against an attachment share.
  download,

  /// Put this out of sight. Lucide `eye-off` — [eye] with the stroke through
  /// it, which is the pair Lucide draws and not a rotation of one mark.
  eyeOff,

  /// The one irreversible action. Lucide `trash-2` — the bin with two
  /// staves, which is the mark this app's single destructive ceremony had
  /// been borrowing from Material.
  trash,

  /// Open a conversation with someone new. Lucide `user-round-plus` — the
  /// figure shifted left of [identity]'s centre to make room for the plus,
  /// which is Lucide's own geometry and not a reading of it. `M1`'s foot
  /// action, `M2`'s request discs and `M3`'s explainer all carry it.
  userPlus,

  /// Waiting on somebody else. Lucide `clock`.
  ///
  /// **Not [history]**, which is a clock with a rewind arrow around it and
  /// means *what already happened*. This one is the plain dial and means
  /// *not yet* — it badges the contact disc of a handshake the counterparty
  /// has not answered (D-303, founder: *"let the profile icon of contacts
  /// awaiting accept show a time icon in amber"*).
  clock,

  /// Send this message. Lucide `send` — the paper plane, and the whole of the
  /// composer's commit control now that the word beside it is gone (founder,
  /// 2026-09-08: *"The send button can be a send icon only"*).
  send,

  /// **Delivered** — Lucide `check-check`, the double tick every messenger
  /// draws (founder, 2026-09-08). Inside the bubble's bottom-right corner, in
  /// the time's own ink.
  ///
  /// It means *a block accepted this*, which on a public ledger is the moment
  /// the message becomes retrievable by its recipient — the most this app can
  /// honestly claim. It is not *read*; nothing in this protocol says that.
  checkDouble,

  /// Bring the phone's emoji keyboard up. Lucide `smile`.
  smile,

  /// Go back to the letters. Lucide `keyboard` — the pair `smile` toggles to,
  /// so the composer's one trailing control says which way it goes.
  keyboard,

  /// Refuse this person. Lucide `ban` — the ring with the stroke through it;
  /// the Block rows and the Blocked addresses list (D-308).
  ban,

  /// A challenge — the game card's mark. Lucide `swords`: two blades crossed,
  /// which is a duel and not Material's wrestlers (`sports_kabaddi`, retired
  /// at UX-R8).
  duel,

  /// A reported result — a claim, not a verified outcome. Lucide `flag`.
  flag,

  /// An event of no named kind — the safe generic mark `_FrameLightSurface`
  /// draws for a frame kind it does not recognise, the same rule the card's
  /// `_gameTitle` keeps for an unknown game (a hostile sender never gets its
  /// own string on the glass). Lucide `circle`.
  circle,

  /// An attached picture. Lucide `image`.
  image,

  /// An attached file of any other kind. Lucide `file`. Not `contracts`'s
  /// `file-text`, which already means a destination (BG-21: one meaning per
  /// glyph).
  file,

  /// This did not decode. Lucide `circle-alert` — the attachment card's broken
  /// state.
  alert,

  /// Restored from an archive — the thread's authenticity marker above a
  /// history fill (BG-8). Lucide `archive`: the box with its lid.
  archive,
}

/// One glyph, painted.
///
/// **Lucide geometry on the 24 dp grid at 2.5 dp with round caps** (§2, §2a).
/// The stroke scales with [size] because a glyph rendered smaller is a scaled
/// 24 dp glyph, not a thinner one — at the grid size the stroke is exactly the
/// 2.5 dp the law names, and [strokeFor] is where any other size gets its
/// number.
///
/// Decorative by default: without [semanticLabel] the glyph is excluded from
/// the semantics tree, because the control around it is what a screen reader
/// should name (§1.2a — a control is identified by its text, never by its
/// mark). Pass [semanticLabel] only when the glyph is the sole identification
/// of what it sits in, and then BG-14 requires [tone] to clear 3:1 as a
/// graphical object.
class KvGlyphIcon extends StatelessWidget {
  const KvGlyphIcon(
    this.mark, {
    super.key,
    this.size = KvGlyphSpec.grid,
    this.tone = KvColor.inkMeta,
    this.semanticLabel,
    this.stroke,
  });

  final KvGlyph mark;

  /// Side of the square the glyph is painted into, in logical pixels. The
  /// 24dp grid is scaled to it uniformly.
  final double size;

  final Color tone;

  /// Names the glyph to a screen reader. Null (the default) excludes it.
  final String? semanticLabel;

  /// The stroke **on the 24 dp grid**, before [size] scales it. Null takes
  /// [KvGlyphSpec.stroke]; BG-25 names exactly three other values —
  /// [KvGlyphSpec.strokeArrow] for a direction arrow inside a value disc,
  /// [KvGlyphSpec.strokeCheck] for the check, and
  /// [KvGlyphSpec.strokeIllustrative] where a mark is illustration rather than
  /// icon. Anything else is a finding.
  final double? stroke;

  /// The rendered stroke width at a given glyph [size] — [KvGlyphSpec.stroke]
  /// scaled off the 24 dp grid (2.5 dp round-capped since v4.2, BG-25).
  /// Exposed so a caller that must line a glyph up with a rule can ask rather
  /// than guess (item 0: geometry is computed, never asserted).
  static double strokeFor(double size, {double? stroke}) =>
      (stroke ?? KvGlyphSpec.stroke) * (size / KvGlyphSpec.grid);

  @override
  Widget build(BuildContext context) {
    final painted = CustomPaint(
      size: Size.square(size),
      painter: KvGlyphPainter(mark, tone: tone, stroke: stroke),
    );
    final label = semanticLabel;
    return label == null
        ? ExcludeSemantics(child: painted)
        : Semantics(label: label, image: true, child: painted);
  }
}

/// The painter behind [KvGlyphIcon]. Public so a composite surface can paint a
/// glyph into a canvas it already owns; everything else should use the widget.
///
/// Assumes a **square** canvas — the 24dp grid is scaled by `size.width`, so a
/// non-square [Size] crops rather than distorts.
class KvGlyphPainter extends CustomPainter {
  const KvGlyphPainter(this.mark, {this.tone = KvColor.inkMeta, this.stroke});

  final KvGlyph mark;
  final Color tone;

  /// The stroke on the 24 dp grid; null takes [KvGlyphSpec.stroke].
  final double? stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / KvGlyphSpec.grid;
    final p = Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = (stroke ?? KvGlyphSpec.stroke) * s
      ..strokeCap = KvGlyphSpec.cap
      ..strokeJoin = KvGlyphSpec.join;

    // One Lucide `<path d>` (or several, one contour each), stroked.
    void path(List<String> data) {
      for (final d in data) {
        canvas.drawPath(kvSvgPath(d, s), p);
      }
    }

    // A Lucide `<circle>`, stroked — never filled (§2a rule 4).
    void circle(double cx, double cy, double r) =>
        canvas.drawCircle(Offset(cx * s, cy * s), r * s, p);

    // A Lucide `<rect rx>`, stroked.
    void rect(double x, double y, double w, double h, double rx) =>
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x * s, y * s, w * s, h * s),
            Radius.circular(rx * s),
          ),
          p,
        );

    // A Lucide `<line>`.
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1 * s, y1 * s), Offset(x2 * s, y2 * s), p);

    switch (mark) {
      case KvGlyph.arrowIn:
        path(const ['M17 7 7 17', 'M17 17H7V7']);
      case KvGlyph.arrowOut:
        path(const ['M7 7h10v10', 'M7 17 17 7']);
      case KvGlyph.selfSend:
        path(const [
          'm17 2 4 4-4 4',
          'M3 11v-1a4 4 0 0 1 4-4h14',
          'm7 22-4-4 4-4',
          'M21 13v1a4 4 0 0 1-4 4H3',
        ]);
      case KvGlyph.diamond:
        path(const [
          'M10.5 3 8 9l4 13 4-13-2.5-6',
          'M17 3a2 2 0 0 1 1.6.8l3 4a2 2 0 0 1 .013 2.382l-7.99 10.986a2 2 0 '
              '0 1-3.247 0l-7.99-10.986A2 2 0 0 1 2.4 7.8l2.998-3.997A2 2 0 0 '
              '1 7 3z',
          'M2 9h20',
        ]);
      case KvGlyph.chevron:
        path(const ['m9 18 6-6-6-6']);
      case KvGlyph.money:
        path(const [
          'M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 '
              '0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1',
          'M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4',
        ]);
      case KvGlyph.chat:
        path(const [
          'M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 '
              '1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719',
        ]);
      case KvGlyph.games:
        line(6, 11, 10, 11);
        line(8, 9, 8, 13);
        line(15, 12, 15.01, 12);
        line(18, 10, 18.01, 10);
        path(const [
          'M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 '
              '9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 '
              '2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 '
              '3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017'
              '-.151A4 4 0 0 0 17.32 5z',
        ]);
      case KvGlyph.contracts:
        path(const [
          'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 '
              '3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z',
          'M14 2v5a1 1 0 0 0 1 1h5',
          'M10 9H8',
          'M16 13H8',
          'M16 17H8',
        ]);
      case KvGlyph.finance:
        path(const ['M3 3v16a2 2 0 0 0 2 2h16', 'm19 9-5 5-4-4-3 3']);
      case KvGlyph.assets:
        path(const [
          'M13.744 17.736a6 6 0 1 1-7.48-7.48',
          'M15 6h1v4',
          'm6.134 14.768.866-.5 2 3.464',
        ]);
        circle(16, 8, 6);
      case KvGlyph.settings:
        path(const [
          'M10 5H3',
          'M12 19H3',
          'M14 3v4',
          'M16 17v4',
          'M21 12h-9',
          'M21 19h-5',
          'M21 5h-7',
          'M8 10v4',
          'M8 12H3',
        ]);
      case KvGlyph.identity:
        circle(12, 8, 5);
        path(const ['M20 21a8 8 0 0 0-16 0']);
      case KvGlyph.network:
        path(const [
          'M16.247 7.761a6 6 0 0 1 0 8.478',
          'M19.075 4.933a10 10 0 0 1 0 14.134',
          'M4.925 19.067a10 10 0 0 1 0-14.134',
          'M7.753 16.239a6 6 0 0 1 0-8.478',
        ]);
        circle(12, 12, 2);
      case KvGlyph.shield:
        path(const [
          'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 '
              '13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 '
              '0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z',
          'm9 12 2 2 4-4',
        ]);
      case KvGlyph.info:
        circle(12, 12, 10);
        path(const ['M12 16v-4', 'M12 8h.01']);
      case KvGlyph.palette:
        path(const [
          'M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 '
              '1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z',
        ]);
        // Lucide fills these four; §2a rule 4 forbids a fill, so each is the
        // round cap of a zero-length stroke — the same way `kebab`'s three
        // dots are drawn.
        circle(13.5, 6.5, 0);
        circle(17.5, 10.5, 0);
        circle(6.5, 12.5, 0);
        circle(8.5, 7.5, 0);
      case KvGlyph.bell:
        path(const [
          'M10.268 21a2 2 0 0 0 3.464 0',
          'M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 '
              '18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326',
        ]);
      case KvGlyph.eye:
        path(const [
          'M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 '
              '1 0 .696 10.75 10.75 0 0 1-19.876 0',
        ]);
        circle(12, 12, 3);
      case KvGlyph.layers:
        path(const [
          'M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 '
              '2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z',
          'M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 '
              '0 22 12',
          'M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 '
              '0 22 17',
        ]);
      case KvGlyph.merge:
        // **Measured off `T4`, not pasted from Lucide.** Every other mark here
        // carries a Lucide name because the render used one; this one does not
        // match any of them. `T4`'s disc draws ink **11.0 × 17.0 dp** inside
        // the 20 dp glyph box — taller and far narrower than `layers` at
        // 15.5 × 16.25 in the same card — with node rings whose path radius is
        // 1.5 dp against a 2 dp stroke, where Lucide's `git-fork` is square
        // (18 × 18 of 24) with rings half again as fat. Two different shapes,
        // and the founder asked for the one in the picture (2026-09-06:
        // *"change the Merge icon to whats being shown in the screenshot"*),
        // which is the standing order anyway — the render wins where it
        // differs (D-259).
        //
        // So the geometry below is transcribed from the render at 4× and
        // proved by a pixel diff against its own crop, not traced by eye.
        // On the 24 grid: ink 20.1 × 13.2 units, centred; rings at
        // (8.4, 5) · (15.6, 5) · (12, 19) — the ring radius is the render's
        // own (outer 20 px, hole 4 px at 4× ⇒ r 1.8 against the house's 2.5
        // stroke, which does not bend for one glyph); the two stems fold into
        // a bracket
        // at y 12.3 and one stem drops from it. It reads as two-into-one, which
        // is what merging coins is.
        circle(8.4, 5, 1.8);
        circle(15.6, 5, 1.8);
        circle(12, 19, 1.8);
        path(const [
          'M15.6 6.75v3.15c0 1.44-.96 2.4-2.4 2.4H10.8c-1.44 0-2.4-.96-2.4-2.4V6.75',
          'M12 12.3v4.95',
        ]);
      case KvGlyph.github:
        path(const [
          'M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5'
              '.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 '
              '2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 '
              '6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4',
          'M9 18c-4.51 2-5-2-7-2',
        ]);
      case KvGlyph.help:
        circle(12, 12, 10);
        path(const ['M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3', 'M12 17h.01']);
      case KvGlyph.lock:
        // **The render's padlock, measured — not Lucide's** (UX-R7, founder on
        // glass 2026-09-10: *"use the actual padlock icon in the screenshot
        // example (make sure its sleek drawn and nice as the image)"*).
        //
        // Lucide's `lock` is `rect(3,11,18,11,2)` + a 5-unit shackle and **has
        // no keyhole**. `Unlock-selection.png` draws a narrower, taller body
        // with a keyhole in it. Scanned row by row at 4x and converted at
        // 3.8 px per grid unit (x 12 at px 393.5, y 2 at px 559):
        //
        // - body centreline **x 4.4 .. 19.6** (15.2 wide, where Lucide's is
        //   18) and **y 10.0 .. 20.8** (10.8 tall); corner radius 2, which is
        //   the one number Lucide already had right.
        // - shackle legs at **7.8** and **16.2** (Lucide: 7 and 17), arc
        //   radius **4.2**, arc centre y **7.1**, so the arch's ink tops out
        //   at y 2 exactly as the grid intends.
        // - the keyhole at the body's own centre, **(12, 15.5)**.
        //
        // The dot is a **stroked circle of radius 0.4**, never a fill: at any
        // stroke wider than 0.8 the ink closes over the centre and reads
        // solid, which is §2a rule 4's whole trick (`palette` draws its four
        // wells the same way). It therefore thickens and thins WITH the mark
        // instead of being a second, fixed object inside it.
        rect(4.4, 10, 15.2, 10.8, 2);
        path(const ['M7.8 10V7.1a4.2 4.2 0 0 1 8.4 0V10']);
        circle(12, 15.5, 0.4);
      case KvGlyph.paste:
        rect(8, 2, 8, 4, 1);
        path(const [
          'M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 '
              '2-2h2',
        ]);
      case KvGlyph.scan:
        path(const [
          'M3 7V5a2 2 0 0 1 2-2h2',
          'M17 3h2a2 2 0 0 1 2 2v2',
          'M21 17v2a2 2 0 0 1-2 2h-2',
          'M7 21H5a2 2 0 0 1-2-2v-2',
          'M7 12h10',
        ]);
      case KvGlyph.history:
        path(const [
          'M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8',
          'M3 3v5h5',
          'M12 7v5l4 2',
        ]);
      case KvGlyph.circleDashed:
        // Lucide's eight arcs, verbatim — a dashed stroke would give the
        // gaps to the dash phase and move them under every rotation.
        path(const [
          'M10.1 2.18a9.93 9.93 0 0 1 3.8 0',
          'M17.6 3.71a9.95 9.95 0 0 1 2.69 2.7',
          'M21.82 10.1a9.93 9.93 0 0 1 0 3.8',
          'M20.29 17.6a9.95 9.95 0 0 1-2.7 2.69',
          'M13.9 21.82a9.94 9.94 0 0 1-3.8 0',
          'M6.4 20.29a9.95 9.95 0 0 1-2.69-2.7',
          'M2.18 13.9a9.93 9.93 0 0 1 0-3.8',
          'M3.71 6.4a9.95 9.95 0 0 1 2.7-2.69',
        ]);
      case KvGlyph.kebab:
        // Lucide's own r = 1 circles, stroked — the pin, not a reading of it.
        circle(12, 12, 1);
        circle(19, 12, 1);
        circle(5, 12, 1);
      case KvGlyph.check:
        path(const ['M20 6 9 17l-5-5']);
      case KvGlyph.backspace:
        path(const [
          'M10 5a2 2 0 0 0-1.344.519l-6.328 5.74a1 1 0 0 0 0 1.481l6.328 '
              '5.741A2 2 0 0 0 10 19h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2z',
          'm12 9 6 6',
          'm18 9-6 6',
        ]);
      case KvGlyph.shift:
        path(const [
          'M9 13a1 1 0 0 0-1-1H5.061a1 1 0 0 1-.75-1.811l6.836-6.835a1.207 '
              '1.207 0 0 1 1.707 0l6.835 6.835a1 1 0 0 1-.75 1.811H16a1 1 0 0 '
              '0-1 1v6a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1z',
        ]);
      case KvGlyph.copy:
        rect(8, 8, 14, 14, 2);
        path(const ['M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2']);
      case KvGlyph.external:
        path(const [
          'M15 3h6v6',
          'M10 14 21 3',
          'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6',
        ]);
      case KvGlyph.share:
        path(const [
          'M12 2V15',
          'M16 6L12 2L8 6',
          'M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8',
        ]);
      case KvGlyph.fingerprint:
        path(const [
          'M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4',
          'M14 13.12c0 2.38 0 6.38-1 8.88',
          'M17.29 21.02c.12-.6.43-2.3.5-3.02',
          'M2 12a10 10 0 0 1 18-6',
          'M2 16h.01',
          'M21.8 16c.2-2 .131-5.354 0-6',
          'M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2',
          'M8.65 22c.21-.66.45-1.32.57-2',
          'M9 6.8a6 6 0 0 1 9 5.2v2',
        ]);
      case KvGlyph.close:
        path(const ['M18 6 6 18', 'm6 6 12 12']);
      case KvGlyph.download:
        path(const [
          'M12 15V3',
          'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4',
          'm7 10 5 5 5-5',
        ]);
      case KvGlyph.eyeOff:
        path(const [
          'M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 '
              '10.747 10.747 0 0 1-1.444 2.49',
          'M14.084 14.158a3 3 0 0 1-4.242-4.242',
          'M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 '
              '0-.696 10.75 10.75 0 0 1 4.446-5.143',
          'm2 2 20 20',
        ]);
      case KvGlyph.trash:
        path(const [
          'M3 6h18',
          'M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6',
          'M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2',
          'M10 11v6',
          'M14 11v6',
        ]);
      case KvGlyph.search:
        circle(11, 11, 8);
        path(const ['m21 21-4.3-4.3']);
      case KvGlyph.userPlus:
        // Lucide's own arc stops at the plus rather than closing under it —
        // `identity`'s shoulders are a full `a8 8 0 0 0-16 0` and this one is
        // deliberately open on the right.
        path(const ['M2 21a8 8 0 0 1 13.292-6']);
        circle(10, 8, 5);
        path(const ['M19 16v6', 'M22 19h-6']);
      case KvGlyph.clock:
        path(const ['M12 6v6l4 2']);
        circle(12, 12, 10);
      case KvGlyph.checkDouble:
        path(const ['M18 6 7 17l-5-5', 'm22 10-7.5 7.5L13 16']);
      case KvGlyph.smile:
        circle(12, 12, 10);
        path(const ['M8 14s1.5 2 4 2 4-2 4-2']);
        path(const ['M9 9h.01', 'M15 9h.01']);
      case KvGlyph.face:
        // Lucide `scan-face`. The four corners are the frame; the smile and
        // the two dots are `smile`'s own strokes without its ring.
        path(const [
          'M3 7V5a2 2 0 0 1 2-2h2',
          'M17 3h2a2 2 0 0 1 2 2v2',
          'M21 17v2a2 2 0 0 1-2 2h-2',
          'M7 21H5a2 2 0 0 1-2-2v-2',
          'M8 14s1.5 2 4 2 4-2 4-2',
        ]);
        path(const ['M9 9h.01', 'M15 9h.01']);
      case KvGlyph.ban:
        circle(12, 12, 10);
        path(const ['M4.929 4.929 19.07 19.071']);
      case KvGlyph.keyboard:
        path(const [
          'M10 8h.01',
          'M12 12h.01',
          'M14 8h.01',
          'M16 12h.01',
          'M18 8h.01',
          'M6 8h.01',
          'M7 16h10',
          'M8 12h.01',
        ]);
        rect(2, 4, 20, 16, 2);
      case KvGlyph.send:
        path(const [
          'M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635'
              'l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z',
          'm21.854 2.147-10.94 10.939',
        ]);
      case KvGlyph.duel:
        path(const [
          'm13 19 6-6',
          'M14.5 17.5 3.586 6.586A2 2 0 013 5.172V3h2.172a2 2 0 011.414.586'
              'L17.5 14.5',
          'm14.828 6.172 2.586-2.586A2 2 0 0118.828 3H21v2.172a2 2 0 01-.586 '
              '1.414l-2.586 2.586',
          'm16 16 4 4',
          'm19 21 2-2',
          'm5 14 4 4',
          'm5 21-2-2',
          'M7.5 16.5 4 20',
        ]);
      case KvGlyph.flag:
        path(const [
          'M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8'
              'A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2'
              'a6 6 0 0 0-4 1.528',
        ]);
      case KvGlyph.circle:
        circle(12, 12, 10);
      case KvGlyph.image:
        rect(3, 3, 18, 18, 2);
        circle(9, 9, 2);
        path(const ['m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21']);
      case KvGlyph.file:
        path(const [
          'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 '
              '3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z',
          'M14 2v5a1 1 0 0 0 1 1h5',
        ]);
      case KvGlyph.alert:
        circle(12, 12, 10);
        line(12, 8, 12, 12);
        line(12, 16, 12.01, 16);
      case KvGlyph.archive:
        rect(2, 3, 20, 5, 1);
        path(const ['M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8', 'M10 12h4']);
    }
  }

  @override
  bool shouldRepaint(KvGlyphPainter old) =>
      old.mark != mark || old.tone != tone || old.stroke != stroke;
}

/// **SVG path data → [Path]**, scaled by [scale], for the subset Lucide uses:
/// `M L H V C S Q A Z` in absolute and relative forms. It exists so a mark can
/// be carried as the string lucide.dev publishes rather than as a hand
/// re-typed polyline — the transcription is then a copy, not an interpretation
/// (§2a rule 5), and a wrong glyph is a diff against one public string.
///
/// Arcs map onto [Path.arcToPoint] one-to-one (SVG's sweep flag is Flutter's
/// `clockwise`), and the two arc flags may run into each other and into the
/// coordinate after them (`A2 2 0 013 5.172` — SVG 1.1 §8.3.8), which Lucide's
/// `swords` does. `Q` quadratics arrived with Lucide's `flag` (UX-R8); `T` is
/// still unsupported because nothing in the set uses it, and the parser says
/// so rather than guessing.
@visibleForTesting
Path kvSvgPath(String d, double scale) {
  final path = Path();
  final tokens = _svgTokens.allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  // Current point, subpath start and the last cubic control point (for `S`).
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? cx, cy;
  double num() => double.parse(tokens[i++]);
  bool more() => i < tokens.length && !_isCommand(tokens[i]);
  // An arc flag is one digit, and SVG lets it abut the next flag or number:
  // `013` is large-arc 0, sweep 1, then 3. Peel one digit and leave the rest.
  bool flag() {
    final t = tokens[i];
    if (t.length > 1 && (t[0] == '0' || t[0] == '1') && t[1] != '.') {
      tokens[i] = t.substring(1);
      return t[0] == '1';
    }
    i++;
    return t != '0';
  }

  while (i < tokens.length) {
    if (_isCommand(tokens[i])) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase() && cmd != 'z' && cmd != 'Z';
    double ax(double v) => rel ? x + v : v;
    double ay(double v) => rel ? y + v : v;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = ax(num());
        y = ay(num());
        sx = x;
        sy = y;
        path.moveTo(x * scale, y * scale);
        cx = cy = null;
        // Subsequent pairs after a moveto are implicit linetos.
        while (more()) {
          x = ax(num());
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        }
      case 'L':
        do {
          x = ax(num());
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'H':
        do {
          x = ax(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'V':
        do {
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'C':
        do {
          final x1 = ax(num()), y1 = ay(num());
          final x2 = ax(num()), y2 = ay(num());
          final ex = ax(num()), ey = ay(num());
          path.cubicTo(
            x1 * scale,
            y1 * scale,
            x2 * scale,
            y2 * scale,
            ex * scale,
            ey * scale,
          );
          cx = x2;
          cy = y2;
          x = ex;
          y = ey;
        } while (more());
      case 'S':
        do {
          // The first control point reflects the previous cubic's second
          // control point through the current point; absent one, it is the
          // current point (SVG 1.1 §8.3.6).
          final x1 = cx == null ? x : 2 * x - cx;
          final y1 = cy == null ? y : 2 * y - cy;
          final x2 = ax(num()), y2 = ay(num());
          final ex = ax(num()), ey = ay(num());
          path.cubicTo(
            x1 * scale,
            y1 * scale,
            x2 * scale,
            y2 * scale,
            ex * scale,
            ey * scale,
          );
          cx = x2;
          cy = y2;
          x = ex;
          y = ey;
        } while (more());
      case 'Q':
        do {
          final x1 = ax(num()), y1 = ay(num());
          final ex = ax(num()), ey = ay(num());
          path.quadraticBezierTo(
            x1 * scale,
            y1 * scale,
            ex * scale,
            ey * scale,
          );
          x = ex;
          y = ey;
        } while (more());
        cx = cy = null;
      case 'A':
        do {
          final rx = num(), ry = num();
          final rotation = num();
          final large = flag();
          final sweep = flag();
          final ex = ax(num()), ey = ay(num());
          path.arcToPoint(
            Offset(ex * scale, ey * scale),
            radius: Radius.elliptical(rx * scale, ry * scale),
            rotation: rotation,
            largeArc: large,
            clockwise: sweep,
          );
          x = ex;
          y = ey;
        } while (more());
        cx = cy = null;
      case 'Z':
        path.close();
        x = sx;
        y = sy;
        cx = cy = null;
      default:
        throw ArgumentError.value(d, 'd', 'unsupported path command $cmd');
    }
  }
  return path;
}

// Any letter is a command token, so one the switch does not know reaches its
// `default:` and refuses by name. A tokeniser that only matched the known
// letters dropped the rest on the floor, and `M0 0T4 4` drew a line.
final RegExp _svgTokens = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)');

bool _isCommand(String t) => t.length == 1 && RegExp('[A-Za-z]').hasMatch(t);
