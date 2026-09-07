import 'dart:async';

import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart' show WalletAddressDto;
import '../error_text.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_two_pane.dart';
import '../widgets/kv_qr.dart';
import '../widgets/kv_rows.dart';
import 'receive_picker.dart';

/// **Receive** (`S5`) — the QR a sender scans, and the address in full for a
/// person checking it character by character.
///
/// An address is public data (INV-1 governs secrets, not addresses), so
/// showing, scanning, copying and sharing it are all safe. A pure consumer —
/// the address arrives through an injected [fetch] — so the screen renders in a
/// widget test with no native library.
///
/// **It shows whichever address it is given, and it can now change its own
/// mind.** Until `T4`'s address list it was only ever handed `receive/0`; the
/// list then opened it over any address in the watch window, and UX-R4b put the
/// choice on the screen itself — the pill above the QR names the address and
/// opens [ReceivePicker]. Automatic next-unused rotation is still deferred
/// (D-045a): choosing an address is a different question from the wallet
/// choosing one for you.
///
/// **It re-reads when money moves** ([coinsChanged]). The line under the pill
/// counts coins, so this is a surface that prints money and it obeys the same
/// rule as every other one (D-295).
///
/// ## Three laws hold this composition together
///
/// **The compact address is gone (BG-19).** This screen used to render the
/// compact form sixteen pixels above the same address in full. Nothing is
/// stated twice on one surface: the eye lands on the weighted first and last
/// groups, and the rest is there to be read when it is being read.
///
/// **Every state keeps the tile's footprint** (BG-20). Loading, failed and
/// ready all reserve the same square, because a layout that jumps when the
/// address lands moves the target out from under a hand already holding a
/// camera over it. Only the ready state paints a light tile: a blank white
/// square is a QR-shaped object no scanner can read, which is worse than an
/// honest empty slot.
///
/// **Request amount is not here yet, so its seat is not drawn.** `S5` seats a
/// third action beside Share, and the founder's ruling (2026-09-04) pairs it
/// with the scanner: a QR that carries an amount is only useful once something
/// can read one back, and the pair lands together in the scanner sitting with
/// the URI format decided rather than invented. §8 forbids a control that
/// answers a tap and does nothing, so until then Share stands alone.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({
    required this.fetch,
    super.key,
    this.share,
    this.title = 'Receive',
    this.index = 0,
    this.addresses,
    this.coinsChanged,
  });

  /// Resolves the receive address (derived in Rust from the account xpub).
  final Future<String> Function() fetch;

  /// How long the handout record waits for the address list before going in
  /// anyway. The seam is a local read with no network in it, so a wait this
  /// long already means it is never answering.
  static const Duration recordAfter = Duration(seconds: 3);

  /// Which `receive/N` slot [fetch] answers with. It names the pill, marks the
  /// picker's current row, and is what [onGivenOut] records.
  final int index;

  /// The wallet's receive window. **Null draws no pill** — the screen falls
  /// back to the caps label it shipped before the picker existed, so a widget
  /// test and any build without the seam still render a working Receive rather
  /// than a control that opens nothing (§8).
  final Future<List<WalletAddressDto>> Function()? addresses;

  /// Fires whenever anything that can move a balance moved
  /// (`WalletService.coins`). The caption under the pill counts coins, so it is
  /// a balance surface and obeys the same rule every other one does: **a screen
  /// that prints money re-reads the instant money moves** (founder, 2026-09-07;
  /// D-295).
  final Listenable? coinsChanged;

  /// What the top bar calls this screen. It stays `Receive` even when a
  /// particular address is open: the **pill** names the address, and saying it
  /// twice on one surface is BG-19. The parameter survives for a caller that
  /// opens this screen with no pill at all.
  final String title;

  /// Hands the address to another app. **Null hides the control** rather than
  /// showing one that goes nowhere (BG-12) — which is what a widget test and a
  /// desktop build both get.
  final Future<bool> Function(String address)? share;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  late Future<String> _address = widget.fetch();
  late int _index = widget.index;
  late String _label = ReceivePicker.labelFor(widget.index);
  ReceiveCaption? _caption;

  @override
  void initState() {
    super.initState();
    widget.coinsChanged?.addListener(_readCaption);
    _readCaption();
  }

  @override
  void dispose() {
    widget.coinsChanged?.removeListener(_readCaption);
    super.dispose();
  }

  /// Re-read the line under the pill. Called on mount and on every coin move,
  /// because a caption that says *"1 coin here"* over an address that now holds
  /// two is a figure the screen is asserting and the chain has already
  /// contradicted.
  void _readCaption() {
    final seam = widget.addresses;
    if (seam == null) return;
    // **A sequence token, because answers can land out of order.** Two coin
    // moves in quick succession start two reads, and the slower one may finish
    // last carrying the older truth. Only the newest ask may paint.
    final ask = ++_captionAsk;
    seam()
        .then((rows) {
          if (mounted && ask == _captionAsk) {
            setState(() => _caption = _captionOf(rows, _index));
          }
        })
        // A caption is an extra; the address is not. A failure is silent here
        // and stated in the sheet, which is where someone went looking for the
        // list.
        .catchError((Object _) {});
  }

  int _captionAsk = 0;

  static ReceiveCaption? _captionOf(List<WalletAddressDto> rows, int index) {
    for (final a in rows) {
      if (a.index == index) return ReceivePicker.captionFor(a);
    }
    return null;
  }

  /// Open the picker and take what it hands back.
  ///
  /// The chosen row carries its own address, so nothing is re-derived between
  /// the row a user tapped and the QR they get — the same rule `T4`'s list
  /// already follows.
  Future<void> _pick() async {
    final seam = widget.addresses;
    if (seam == null) return;
    KvHaptic.selection();
    final chosen = await ReceivePicker.open(
      context,
      addresses: seam,
      selected: _index,
      coinsChanged: widget.coinsChanged,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _index = chosen.index;
      _label = ReceivePicker.labelFor(chosen.index);
      _caption = ReceivePicker.captionFor(chosen);
      _address = Future.value(chosen.address);
    });
  }

  /// The retry exists because *"could not load"* with no way forward is an
  /// error message that does not say what to do (BG-11). The future is held in
  /// state rather than called in `build`, so a rebuild cannot silently re-fetch
  /// and a tap genuinely can.
  ///
  /// **The fetch happens OUTSIDE `setState`**, and the block body is not
  /// style: `setState(() => _address = widget.fetch())` returns the assigned
  /// `Future` out of the closure, which Flutter asserts on — so the control
  /// threw on every tap and did nothing.
  void _retry() {
    final next = widget.fetch();
    setState(() {
      _address = next;
    });
  }

  Future<void> _copy(BuildContext context, String address) async {
    KvHaptic.selection();
    // **`copyFull` is the one copy path**, and it copies all 67 characters by
    // construction rather than by habit (BG-15).
    await KvAddress.copyFull(address);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied'), duration: KvMotion.toast),
    );
  }

  Future<void> _share(BuildContext context, String address) async {
    final share = widget.share;
    if (share == null) return;
    final bool ok;
    try {
      ok = await share(address);
    } catch (e) {
      // **A native failure is an answer, and it has to reach the glass**
      // (`wallet-security-auditor`, UX-R2 — item 15, F4's scar). The platform
      // side reports `CODE_SAVE_FAILED` on a throw; uncaught it became an
      // unhandled async error and the control answered a tap by doing
      // nothing. `displayError`, never `e.toString()`.
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(displayError(e)), duration: KvMotion.toast),
      );
      return;
    }
    if (!context.mounted || ok) return;
    // A phone with nothing that takes text is a fact about the device, not a
    // failure — and the honest answer names the thing that still works.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Nothing on this phone takes text. Copy it instead.'),
        duration: KvMotion.toast,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      // **The system inset, and nothing more** (§9.22, D-262). The flat 52 dp
      // reserve left a band of ground above the title on the V60.
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: widget.title,
              onBack: () => Navigator.of(context).pop(),
            ),
            // **One column, clamped at 560 and centred** (BG-33).
            Expanded(
              child: KvColumn(
                gutter: false,
                child: FutureBuilder<String>(
                  future: _address,
                  builder: (context, snapshot) {
                    final waiting =
                        snapshot.connectionState != ConnectionState.done;
                    final address = snapshot.data;
                    return _Body(
                      head: widget.addresses == null
                          ? null
                          : _AddressPill(
                              label: _label,
                              caption: _caption,
                              onTap: _pick,
                            ),
                      address: waiting ? null : address,
                      error: waiting || address != null
                          ? null
                          : displayError(snapshot.error ?? 'no address'),
                      onRetry: _retry,
                      onCopy: address == null
                          ? null
                          : () => _copy(context, address),
                      onShare: address == null || widget.share == null
                          ? null
                          : () => _share(context, address),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.head,
    required this.address,
    required this.error,
    required this.onRetry,
    required this.onCopy,
    required this.onShare,
  });

  /// The pill that names this address and opens the picker. Null when there is
  /// no address seam, and then the card wears the caps label instead.
  final Widget? head;

  /// Null while the address has not arrived — waiting or failed.
  final String? address;

  /// The reason it failed, in Rust's own words. Null while waiting.
  final String? error;

  final VoidCallback onRetry;
  final VoidCallback? onCopy;
  final VoidCallback? onShare;

  /// The card's inner padding (`S5`, measured: 22 on all four sides).
  static const double cardPad = KvSpace.s22;

  @override
  Widget build(BuildContext context) {
    final full = address;
    final gutter = KvWindow.of(context).gutter;
    return Column(
      children: [
        Expanded(
          // Scroll-safe: a QR plus 67 characters must not overflow at 1.3×
          // text scale or on a short screen (the P1.6 keyboard-overflow scar).
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            children: [
              const SizedBox(height: KvSpace.s),
              Entrance(
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    cardPad,
                    // **The pill's target overhangs the card's padding.** The
                    // render seats the pill 18 dp below the card's top edge
                    // (94 → 112, measured at 2×) and draws it 35.5 tall — under
                    // BG-12's floor. So the control keeps a 52 dp box and the
                    // padding gives back the 8.25 that box adds above the ink:
                    // the visual lands exactly where the picture puts it and
                    // the target is still legal. The same trade `KvSegmented`
                    // makes with its 36 dp track.
                    head == null
                        ? cardPad
                        : 18 - (_AddressPill.target - _AddressPill.pill) / 2,
                    cardPad,
                    cardPad,
                  ),
                  decoration: BoxDecoration(
                    color: KvColor.plate,
                    borderRadius: BorderRadius.circular(KvRadius.plateHero),
                  ),
                  child: Column(
                    children: [
                      if (head case final head?)
                        head
                      else
                        const Text(
                          'YOUR ADDRESS',
                          style: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 11,
                            height: 16 / 11,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w600,
                            fontVariations: KvWeight.w600,
                            color: KvColor.inkMeta,
                          ),
                        ),
                      // The render puts 14 dp between the caption's line box
                      // and the QR (caption ink to 168, QR at 188); the caps
                      // label keeps the 22 it always had.
                      SizedBox(
                        height: head == null ? KvSpace.s22 : KvSpace.s14,
                      ),
                      // **The footprint is the constant** — and the face
                      // inside it crosses rather than cuts (BG-24). The
                      // outgoing child is `Positioned` so it sizes nothing: a
                      // crossfade whose layout jumps has only moved the cut
                      // into the layout.
                      AnimatedSwitcher(
                        duration: KvMotion.fast,
                        switchInCurve: KvMotion.out,
                        switchOutCurve: KvMotion.out,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topCenter,
                          clipBehavior: Clip.none,
                          children: [
                            for (final old in previous)
                              Positioned(left: 0, right: 0, top: 0, child: old),
                            ?current,
                          ],
                        ),
                        child: KeyedSubtree(
                          // Keyed on the STATE, so a rebuild inside one state
                          // updates in place and only a real change animates.
                          key: ValueKey(
                            full != null ? 'qr' : (error ?? 'waiting'),
                          ),
                          child: switch ((full, error)) {
                            (final a?, _) => KvQr(data: a, onTap: onCopy),
                            (_, final _?) => const KvQrFailed(),
                            _ => const KvQrWaiting(),
                          },
                        ),
                      ),
                      const SizedBox(height: KvSpace.s20),
                      if (full != null)
                        _AddressRow(address: full, onCopy: onCopy)
                      else
                        _Unavailable(error: error, onRetry: onRetry),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: KvSpace.l),
              // The house sentence (§7.1): three short statements, each
              // carrying one fact the reader did not have. It is the whole
              // trust story of a receive address, and it is why no warning
              // belongs on this screen.
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: KvSpace.s),
                child: Text(
                  // Two statements, not three. *"Nobody can take from it"*
                  // was the third beat of §7.1's house sentence and the
                  // founder cut it on glass (2026-09-07): it answers a fear
                  // nobody arrives with, on the one screen where the user is
                  // trying to hand a string to someone.
                  'Receives KAS on Mainnet. Anyone with this address can send '
                  'to you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    color: KvColor.inkMeta,
                  ),
                ),
              ),
              const SizedBox(height: KvSpace.l),
            ],
          ),
        ),
        // **The actions are fixed** — the card scrolls under them. A copy
        // control that scrolls away on a screen whose whole job is handing an
        // address over is a control in the wrong place.
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, KvSpace.l),
          child: Column(
            children: [
              KvAction(
                label: 'Copy address',
                primary: true,
                mark: KvGlyph.copy,
                disabledReason: onCopy == null ? 'No address yet' : null,
                onTap: onCopy ?? () {},
              ),
              if (onShare != null) ...[
                const SizedBox(height: KvSpace.s10),
                KvAction.raised(
                  label: 'Share',
                  mark: KvGlyph.share,
                  onTap: onShare!,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The address in full, in the `chip` row that copies on tap (`S5`, §5).
///
/// The copy mark rides the row rather than sitting beside it: the row **is**
/// the control, and a mark that only decorates would be a second thing to aim
/// at for one action (BG-19).
class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.address, required this.onCopy});

  final String address;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // **The horizontal inset is `s`, not `m`** — sixteen dp a side was
      // sixteen dp the address could not use, and 67 mono characters at 13 dp
      // wanted three lines for the want of them (founder, on glass 2026-09-07:
      // *"i want it so the full address showing is displayed at at most 2
      // lines"*). The vertical inset is unchanged.
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s,
        vertical: KvSpace.s14,
      ),
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.inner),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // Selectable, because comparing against a source is exactly this
            // surface's job — and the weighting survives selection.
            child: KvAddress(
              address,
              form: KvAddressForm.chunked,
              selectable: true,
              plated: false,
              // 12, not the house 13: the difference between two lines and
              // three for a 67-character payload in the width this row has.
              // Above BG-14's floor of 11, and the weighted head and tail are
              // what the eye is aimed at anyway (BG-15).
              fontSize: 12,
              onTap: onCopy,
            ),
          ),
          const SizedBox(width: KvSpace.sm),
          // **The mark is a control, so it answers a tap** (founder, on glass
          // 2026-09-06: *"the copy icon doesn't work, tapping the address card
          // works"*). It was drawn as decoration beside a tappable address —
          // which is the one arrangement guaranteed to be tried: a copy glyph
          // is the most recognisable control on the surface, and it was the
          // only thing here that did nothing. Its own 44 dp target (BG-12),
          // not the row's, so selecting the address by dragging across it
          // still belongs to `KvAddress`.
          Semantics(
            button: true,
            label: 'Copy address',
            child: ExcludeSemantics(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCopy,
                // 24, not the 44 it first got — **founder's call on glass
                // 2026-09-06**, and it is his to make: this is a convenience
                // beside an address that is already tappable across its whole
                // card, so the cost of a miss is a second tap and never a
                // wrong send. The honest trade is written here rather than
                // argued: 24 is under BG-12's 52, so on a small screen this
                // glyph is the harder of the two ways to copy.
                child: const SizedBox(
                  width: KvSpace.l,
                  height: KvSpace.l,
                  child: Center(
                    child: KvGlyphIcon(
                      KvGlyph.copy,
                      size: 18,
                      tone: KvColor.inkMeta,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The address could not be derived. It states the reason Rust gave and offers
/// the one thing worth doing about it (BG-11's three beats), inside the same
/// card the address would have filled.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const Text(
        'Deriving your address…',
        style: TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 14,
          height: 20 / 14,
          color: KvColor.inkMeta,
        ),
      );
    }
    // **Three beats** (BG-11): what happened, what it means, what to do.
    return Column(
      children: [
        const Text(
          'Could not load the receive address.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 15,
            height: 21 / 15,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: KvColor.ink,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        Text(
          error!,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 14,
            height: 20 / 14,
            color: KvColor.inkDim,
          ),
        ),
        const SizedBox(height: KvSpace.sm),
        KvAction.raised(label: 'Try again', onTap: onRetry),
      ],
    );
  }
}

/// **The address's own name, and the door to the others** (`Receive Address ·
/// Main (default)`, measured at 2×: a 81 × 35.5 pill centred at the card's top,
/// its caption 11 dp below).
///
/// The pill is the only place this screen names the address, which is why the
/// top bar stays `Receive` (BG-19). Under it sits one line about the address —
/// which state it is in and one checkable fact — and that line **reserves its
/// height before it arrives**, so the QR below never moves under a hand already
/// on its way to it (BG-24).
class _AddressPill extends StatefulWidget {
  const _AddressPill({
    required this.label,
    required this.caption,
    required this.onTap,
  });

  final String label;

  /// Null until the address list lands, and null for good if it fails. The
  /// address is not in doubt either way — only the sentence about it.
  final ReceiveCaption? caption;

  final VoidCallback onTap;

  /// The visual, measured (35.5, drawn at 36 — the round `KvSegmented` took
  /// from its own 36.75 track).
  static const double pill = 36;

  /// BG-12's floor. The extra 16 is transparent overhang, and the card's top
  /// padding gives back the half of it that sits above the ink.
  static const double target = KvSpace.touchTarget;

  /// The caption's line box **at 1.0×**, reserved whether or not there is a
  /// caption.
  ///
  /// Reserving it as a constant was a clip: the caption's own line height
  /// scales with the text scaler while a fixed box does not, so at 1.3× a
  /// 23 dp line was painted into an 18 dp box and `overflow: ellipsis` cut
  /// five dp off the bottom — *"not handed out yet"* rendered with its
  /// descenders sheared. `takeException` never fires on that and no finder can
  /// see it (L131's class); it was found in a preview frame at the floor. Use
  /// [captionBox], never this number directly.
  static const double captionLine = 18;

  /// [captionLine] under the reader's own text scale.
  static double captionBox(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(captionLine);

  @override
  State<_AddressPill> createState() => _AddressPillState();
}

class _AddressPillState extends State<_AddressPill> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _AddressPill.target,
          child: Center(
            child: Semantics(
              button: true,
              label: caption == null
                  ? '${widget.label}. Change address'
                  : '${widget.label}, ${caption.spoken}. Change address',
              child: ExcludeSemantics(
                // `GestureDetector`, not `InkWell` — the house rule: there is
                // no ripple in this language and an ink response would only
                // add a `Material` dependency.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onTapDown: (_) => setState(() => _down = true),
                  onTapUp: (_) => setState(() => _down = false),
                  onTapCancel: () => setState(() => _down = false),
                  child: Container(
                    height: _AddressPill.pill,
                    padding: const EdgeInsets.only(
                      left: KvSpace.m,
                      right: KvSpace.s14,
                    ),
                    decoration: BoxDecoration(
                      color: _down ? KvColor.chipPressed : KvColor.chip,
                      borderRadius: BorderRadius.circular(
                        _AddressPill.pill / 2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: KvFont.ui,
                            // Cap 10.5 dp off the render ÷ Jakarta's 0.773.
                            fontSize: 14,
                            height: 20 / 14,
                            fontWeight: FontWeight.w600,
                            fontVariations: KvWeight.w600,
                            color: KvColor.ink,
                          ),
                        ),
                        const SizedBox(width: KvSpace.xs),
                        // §2a's one chevron, turned a quarter — the same mark
                        // `back` uses the other way round. "This opens."
                        const RotatedBox(
                          quarterTurns: 1,
                          child: KvGlyphIcon(
                            KvGlyph.chevron,
                            size: KvSpace.m,
                            tone: KvColor.inkMeta,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: _AddressPill.captionBox(context),
          // **The footprint is the constant and the face crosses** (BG-24):
          // the line arrives a frame or two after the address, and a caption
          // that snapped in would be the only thing on the screen that moved
          // without being touched.
          child: AnimatedSwitcher(
            duration: KvMotion.fast,
            switchInCurve: KvMotion.out,
            switchOutCurve: KvMotion.out,
            child: caption == null
                ? const SizedBox.shrink()
                : ExcludeSemantics(
                    key: ValueKey(caption.spoken),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          // The render marks a fresh address with the same ring
                          // the sheet seats beside every fresh row — one mark,
                          // one meaning, on both surfaces (BG-21).
                          if (caption.fresh)
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(right: KvSpace.xs),
                                child: KvGlyphIcon(
                                  KvGlyph.circleDashed,
                                  size: 14,
                                  tone: KvColor.inkMeta,
                                ),
                              ),
                            ),
                          // **`Default` wears the badge, not the sentence**
                          // (founder, on glass 2026-09-07: *"let the 'Default'
                          // be the normal green in pill chip that we already
                          // use"*). The same `KvDefaultChip` the row beside
                          // `Main` wears in both address lists — one object for
                          // one fact on all three surfaces (BG-21).
                          if (caption.isDefault)
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(right: KvSpace.s),
                                child: KvDefaultChip(),
                              ),
                            )
                          else
                            TextSpan(text: '${caption.state} · ', style: _meta),
                          if (caption.isDefault)
                            TextSpan(text: '· ', style: _meta),
                          // BG-30: the figure is mono, the words are not. The
                          // space belongs to the WORDS — a mono space is wider
                          // than the UI face's and put the count adrift.
                          if (caption.figure case final n?)
                            TextSpan(
                              text: '$n',
                              style: _meta.copyWith(fontFamily: KvFont.mono),
                            ),
                          TextSpan(
                            text: caption.figure == null
                                ? caption.words
                                : ' ${caption.words}',
                            style: _meta,
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  static const TextStyle _meta = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 13,
    height: _AddressPill.captionLine / 13,
    color: KvColor.inkMeta,
  );
}
