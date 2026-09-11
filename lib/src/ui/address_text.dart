import 'package:flutter/material.dart';

import 'format.dart';
import 'theme/tokens.dart';

/// Renders a Kaspa address in the BG-15 **compact** form: the `kaspa:` scheme in
/// [KvColor.inkMeta], the payload in mono [KvColor.ink], truncated
/// payload-aware ([truncateAddressPayload] — never the scheme). For the full
/// reviewable form, use [chunkAddress] inside a `SelectableText`; a compact
/// address should reveal that form on tap (BG-15).
///
/// **Two widths, and the narrow one is measured off `T4`.** A line of its own
/// takes the house 8 … 8. A line it SHARES with a figure takes [tight], which
/// is the render's own 4 … 5 — and that tail is not a guess: it is exactly the
/// five characters §11's spoken label reads out, so eye and screen reader
/// check the same characters. Without it, `T4`'s widest balance
/// (`0.00905522`) squeezed the address onto two lines at 393 dp.
///
/// **Deliberately not `maxLines: 1`.** At BG-14's 1.3× floor even the tight
/// form can run out of room, and an ellipsis there would eat the TAIL — the
/// one part of an address a person actually checks. A second line costs
/// nothing but height, which [KvRow] already grows for.
///
/// An address is public data — INV-1 governs secrets, not addresses — so it is
/// safe to render, truncate and copy. The a11y label speaks the tail the way
/// §11 prescribes ("address ending 3 f 4 a 2").
class AddressText extends StatelessWidget {
  const AddressText(this.address, {this.style, super.key});

  final String address;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base =
        (style ?? Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
            .copyWith(fontFamily: KvFont.mono);
    // **One compact form everywhere** — `kaspa:` + four + `…` + eight. The
    // narrow `tight` variant that used to live here (4 + 5) made the same
    // address read as two different strings on two screens; the law is
    // `format.dart`'s and it has no per-caller dial (founder, 2026-09-07).
    final compact = truncateAddressPayload(address);
    final sep = compact.indexOf(':');
    final scheme = sep >= 0 ? compact.substring(0, sep + 1) : '';
    final payload = sep >= 0 ? compact.substring(sep + 1) : compact;
    return Text.rich(
      TextSpan(
        children: [
          if (scheme.isNotEmpty)
            TextSpan(
              text: scheme,
              style: base.copyWith(color: KvColor.inkMeta),
            ),
          TextSpan(
            text: payload,
            style: base.copyWith(color: KvColor.ink),
          ),
        ],
      ),
      semanticsLabel: _spoken(address),
    );
  }
}

/// "address ending 3 f 4 a 2" — the §11 spoken form (the tail, spaced so a
/// screen reader names each character rather than guessing a word).
String _spoken(String address) {
  final sep = address.indexOf(':');
  final payload = sep >= 0 ? address.substring(sep + 1) : address;
  final tail = payload.length >= 5
      ? payload.substring(payload.length - 5)
      : payload;
  return 'address ending ${tail.split('').join(' ')}';
}
