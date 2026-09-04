import 'package:flutter/material.dart';

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

/// **Receive** (`S5`) — the QR a sender scans, and the address in full for a
/// person checking it character by character.
///
/// An address is public data (INV-1 governs secrets, not addresses), so
/// showing, scanning, copying and sharing it are all safe. It shows the
/// **static** receive address (index 0) for the alpha; next-unused rotation is
/// deferred (D-045a). A pure consumer — the address arrives through an injected
/// [fetch] — so the screen renders in a widget test with no native library.
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
  const ReceiveScreen({required this.fetch, super.key, this.share});

  /// Resolves the receive address (derived in Rust from the account xpub).
  final Future<String> Function() fetch;

  /// Hands the address to another app. **Null hides the control** rather than
  /// showing one that goes nowhere (BG-12) — which is what a widget test and a
  /// desktop build both get.
  final Future<bool> Function(String address)? share;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  late Future<String> _address = widget.fetch();

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
              title: 'Receive',
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
    required this.address,
    required this.error,
    required this.onRetry,
    required this.onCopy,
    required this.onShare,
  });

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
                  padding: const EdgeInsets.all(cardPad),
                  decoration: BoxDecoration(
                    color: KvColor.plate,
                    borderRadius: BorderRadius.circular(KvRadius.plateHero),
                  ),
                  child: Column(
                    children: [
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
                      const SizedBox(height: KvSpace.s22),
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
                  'Receives KAS on Mainnet. Anyone with this address can send '
                  'to you. Nobody can take from it.',
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
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
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
              onTap: onCopy,
            ),
          ),
          const SizedBox(width: KvSpace.sm),
          const KvGlyphIcon(KvGlyph.copy, size: 18, tone: KvColor.inkMeta),
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
