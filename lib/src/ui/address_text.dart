import 'package:flutter/material.dart';

import 'format.dart';
import 'theme/tokens.dart';

/// Renders a Kaspa address in the BG-15 **compact** form: the `kaspa:` scheme in
/// [KvColor.textTertiary], the payload in mono [KvColor.textPrimary], truncated
/// payload-aware ([truncateAddressPayload] — first 8 + … + last 8 of the
/// payload, never the scheme). For the full reviewable form, use
/// [chunkAddress] inside a `SelectableText`; a compact address should reveal
/// that form on tap (BG-15).
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
              style: base.copyWith(color: KvColor.textTertiary),
            ),
          TextSpan(
            text: payload,
            style: base.copyWith(color: KvColor.textPrimary),
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
