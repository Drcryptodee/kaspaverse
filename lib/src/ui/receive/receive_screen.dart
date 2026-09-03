import 'package:flutter/material.dart';

import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_chrome.dart';
import 'qr_tile.dart';

/// **Receive** — the QR a sender scans, and the address in full for a person
/// who is checking it character by character.
///
/// An address is public data (INV-1 governs secrets, not addresses), so
/// showing, scanning and copying it are all safe. It shows the **static**
/// receive address (index 0) for the alpha; next-unused rotation is deferred
/// (D-045a). A pure consumer — the address arrives through an injected [fetch]
/// — so the screen renders in a widget test with no native library.
///
/// ## Two compositions changed at UX-5, and both are laws
///
/// **The compact address is gone (BG-19).** This screen used to render the
/// compact form sixteen density-pixels above the same address in full. D-223
/// weighted the chunked form's first and last groups — the exact head and tail
/// the compact line showed — so the full form gained its own glance and nobody
/// went back for the line it replaced. Nothing is stated twice on one surface:
/// the eye lands on the weighted groups, and the rest of the address is there
/// to be read when it is being read.
///
/// **Every state keeps the tile's footprint.** Loading, failed and ready all
/// reserve [QrTile.side], because the layout must not jump under a hand that is
/// already holding a camera over it. Only the ready state paints the light
/// tile: a blank white square would be a QR-shaped object that no scanner can
/// read, which is worse than an honest empty slot (BG-20).
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({required this.fetch, super.key});

  /// Resolves the receive address (derived in Rust from the account xpub).
  final Future<String> Function() fetch;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  late Future<String> _address = widget.fetch();

  /// The retry exists because *"could not load"* with no way forward is an
  /// error message that does not say what to do (BG-11). The future is held in
  /// state rather than called in `build` so a rebuild cannot silently re-fetch
  /// and a tap genuinely can.
  ///
  /// **The fetch happens OUTSIDE `setState`**, and the block body is not
  /// style: `setState(() => _address = widget.fetch())` returns the assigned
  /// `Future` out of the closure, which Flutter asserts on — so the control
  /// threw on every tap and did nothing. Caught by the guard below, which is
  /// why the guard taps it rather than only looking at it.
  void _retry() {
    final next = widget.fetch();
    setState(() {
      _address = next;
    });
  }

  Future<void> _copy(BuildContext context, String address) async {
    KvHaptic.selection();
    // **`copyFull` is the one copy path**, and it copies all 67 characters by
    // construction rather than by habit (BG-15). This screen used to call
    // `Clipboard.setData` itself, which is a second implementation of a rule
    // that has already been corrected in one place and not another (L143).
    await KvAddress.copyFull(address);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied'), duration: KvMotion.toast),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // BG-14: the top 52dp belongs to the real system status bar.
            const SizedBox(height: KvSpace.statusBarReserve),
            KvTopBar(
              title: 'Receive',
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
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
                  );
                },
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
  });

  /// Null while the address has not arrived — waiting or failed.
  final String? address;

  /// The reason it failed, in Rust's own words. Null while waiting.
  final String? error;

  final VoidCallback onRetry;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final full = address;
    // Scroll-safe: a QR plus 67 characters must not overflow at 1.3x text
    // scale or on a short screen (the P1.6 keyboard-overflow scar).
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.m),
        Entrance(
          child: Center(
            // **The footprint is the constant.** Whichever face is inside it,
            // the slot is the same square, so nothing under a raised camera
            // moves when the address lands or fails to.
            //
            // **And the face inside it crosses rather than cuts** (BG-24). The
            // footprint held from the first version, but the QR still appeared
            // in one frame — `Entrance` plays once on mount and had already
            // played by the time the address landed, so nothing accounted for
            // the arrival (`ux-auditor`, UX-5). The outgoing child is
            // `Positioned` so it sizes nothing: a crossfade whose layout jumps
            // has only relocated the cut into the layout (D-229's finding on
            // the burial mark).
            child: AnimatedSwitcher(
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
              child: SizedBox.square(
                // Keyed on the STATE, so a rebuild inside one state updates in
                // place and only a real change animates.
                key: ValueKey(full != null ? 'qr' : (error ?? 'waiting')),
                dimension: QrTile.side,
                child: switch ((full, error)) {
                  (final a?, _) => QrTile(data: a, onTap: onCopy),
                  (_, final e?) => _Failed(reason: e, onRetry: onRetry),
                  _ => const _Waiting(),
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: KvSpace.m),
        // The caption belongs to the QR, so it arrives with it. Its line box is
        // reserved either way, which keeps the block below from moving as well.
        AnimatedOpacity(
          opacity: full == null ? 0 : 1,
          duration: KvMotion.fast,
          curve: KvMotion.out,
          child: const Center(
            child: Text(
              // Shipped copy, verbatim (D-196: the redesign is a change of
              // form, not of voice).
              'Scan to send KAS to this wallet',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 11,
                height: 15 / 11,
                color: KvColor.inkMeta,
              ),
            ),
          ),
        ),
        if (full != null) ...[
          const SizedBox(height: KvSpace.xl),
          Entrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const KvRuledLabel('Your address'),
                const SizedBox(height: KvSpace.s),
                // The one renderer of a chunked address (D-225): selectable,
                // because comparing against a source is exactly this surface's
                // job, and weighted at the head and tail either way — selection
                // is never bought by giving up the thing the form exists for.
                // Tapping copies; a long press still selects. Both routes end
                // at `copyFull`, so the button is no longer the only way to
                // take an address off a screen whose whole job is handing it
                // over — and neither route can narrow what "copy" means.
                KvAddress(
                  full,
                  form: KvAddressForm.chunked,
                  selectable: true,
                  onTap: onCopy,
                ),
              ],
            ),
          ),
          const SizedBox(height: KvSpace.l),
          Entrance(
            index: 2,
            child: KvAction(
              label: 'Copy address',
              primary: true,
              onTap: onCopy ?? () {},
            ),
          ),
        ],
        const SizedBox(height: KvSpace.xxl),
      ],
    );
  }
}

/// The address has not arrived yet. The cadence is the app's one loading
/// indicator and it runs only while something is genuinely happening (§4).
class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) =>
      const Center(child: KvCadence(running: true));
}

/// The address could not be derived. It keeps the tile's footprint, states the
/// reason Rust gave, and offers the one thing worth doing about it (BG-11).
class _Failed extends StatelessWidget {
  const _Failed({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(KvSpace.m),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Could not load the receive address.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 20 / 15,
              color: KvColor.ink,
            ),
          ),
          const SizedBox(height: KvSpace.s),
          Text(
            reason,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMetaLow,
            ),
          ),
          const SizedBox(height: KvSpace.m),
          KvAction(label: 'Try again', primary: false, onTap: onRetry),
        ],
      ),
    ),
  );
}
