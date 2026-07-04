import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../address_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import 'qr_tile.dart';

/// Receive screen (P1.7 · T1): the QR a sender scans, plus the address in full
/// for careful verification. An address is public data — INV-1 governs secrets,
/// not addresses — so it is safe to display, scan and copy.
///
/// Shows the **static** receive address (index 0) for the alpha; next-unused
/// rotation is deferred (D-045a). A pure consumer (injected [fetch]) so widget
/// tests run without the native library; `main.dart` wires it to
/// `vaultReceiveAddress`.
class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen({required this.fetch, super.key});

  /// Resolves the receive address (derived in Rust from the account xpub).
  final Future<String> Function() fetch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: SafeArea(
        child: FutureBuilder<String>(
          future: fetch(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _ErrorBody(error: snapshot.error);
            }
            return _ReceiveBody(address: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class _ReceiveBody extends StatelessWidget {
  const _ReceiveBody({required this.address});

  final String address;

  Future<void> _copy(BuildContext context) async {
    // Copy the FULL string (DS-8) — never the truncated compact form. The
    // confirmation stays neutral (§3: success is rationed to chain events).
    KvHaptic.selection();
    await Clipboard.setData(ClipboardData(text: address));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Address copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scroll-safe: a QR + full address must not overflow at 1.3× text scale or
    // on a short screen (the P1.6 keyboard-overflow scar).
    return SingleChildScrollView(
      padding: const EdgeInsets.all(KvSpace.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Entrance(
            child: Center(child: QrTile(data: address)),
          ),
          const SizedBox(height: KvSpace.m),
          Center(
            child: Text(
              'Scan to send KAS to this wallet',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textTertiary,
                fontFamily: KvFont.ui,
              ),
            ),
          ),
          const SizedBox(height: KvSpace.xl),
          Entrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Your address', style: theme.textTheme.labelLarge),
                const SizedBox(height: KvSpace.s),
                // Glanceable identity (DS-8 compact); the full form below is
                // the character-by-character verification surface.
                Center(
                  child: AddressText(address, style: theme.textTheme.bodyLarge),
                ),
                const SizedBox(height: KvSpace.m),
                _FullAddress(address: address),
              ],
            ),
          ),
          const SizedBox(height: KvSpace.l),
          Entrance(
            index: 2,
            child: FilledButton.icon(
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy address'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The full address chunked in fours (DS-8 confirm form), selectable so it can
/// also be copied by hand and compared against the source.
class _FullAddress extends StatelessWidget {
  const _FullAddress({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.sm),
      decoration: BoxDecoration(
        color: KvColor.surfaceAlt,
        borderRadius: BorderRadius.circular(KvRadius.data),
      ),
      child: SelectableText(
        chunkAddress(address),
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: KvFont.mono),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(KvSpace.gutter),
        child: Text(
          'Could not load the receive address.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: KvColor.error),
        ),
      ),
    );
  }
}
