/// Render-layer number formatting (L3). Money is `BigInt` (sompi) end-to-end;
/// the ONLY sompi→KAS conversion in the app happens here, at the render
/// boundary (design_system §5). No floating point ever touches money.
library;

/// Group digits in threes: `"1234567"` → `"1,234,567"`. (Lifted from the shipped
/// `formatScore` so [AmountText] and the DAA readout share one grouping.)
String groupThousands(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// 1 KAS = 1e8 sompi (verified against the pinned crates; `kaspium_analysis.md`).
final BigInt _sompiPerKas = BigInt.from(100000000);

/// Split a non-negative `sompi` balance into KAS display parts: a
/// thousands-grouped integer and the 8-digit fractional remainder.
///
/// **Floors toward zero — never rounds a balance up** (DS-2): a user must never
/// see more spendable than they hold. e.g. `199999999` → `("1", "99999999")`,
/// `0` → `("0", "00000000")`.
({String integer, String fraction}) kasParts(BigInt sompi) {
  final kas = sompi ~/ _sompiPerKas;
  final fraction = (sompi % _sompiPerKas).toString().padLeft(8, '0');
  return (integer: groupThousands(kas.toString()), fraction: fraction);
}

/// Parse a user-typed KAS amount into sompi (`BigInt`) — the inverse of
/// [kasParts], for the send screen (DS-2). **String math only, never a
/// `double`** (custody: a float can't represent 8-decimal sompi exactly).
///
/// Returns `null` for anything not a clean non-negative amount: empty, signs,
/// grouping commas, more than one dot, non-digits, or **more than 8 fractional
/// digits** (sompi can't hold finer than 1e-8 KAS — rejected, never silently
/// floored away). `"12.4"` → `1_240_000_000`; `".5"` → `50_000_000`; `"0"` → `0`.
BigInt? sompiFromKas(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final parts = text.split('.');
  if (parts.length > 2) return null;
  final intPart = parts[0];
  final fracPart = parts.length == 2 ? parts[1] : '';
  if (intPart.isEmpty && fracPart.isEmpty) return null; // a lone "."
  // Finer than sompi (1e-8 KAS) — reject, never silently floor it away.
  if (fracPart.length > 8) return null;
  final digits = RegExp(r'^[0-9]*$');
  if (!digits.hasMatch(intPart) || !digits.hasMatch(fracPart)) return null;
  final whole = intPart.isEmpty ? BigInt.zero : BigInt.parse(intPart);
  final frac = BigInt.parse(fracPart.padRight(8, '0')); // '' → '00000000' → 0
  return whole * _sompiPerKas + frac;
}

/// Group an address payload in fours for a full-form review (DS-8): keep the
/// `kaspa:` prefix intact (never spend the review budget on it), space the
/// payload every 4 chars so it can be read/compared aloud. Full address — no
/// truncation (this is the confirm-the-recipient surface).
String chunkAddress(String address) {
  final sep = address.indexOf(':');
  final prefix = sep >= 0 ? address.substring(0, sep + 1) : '';
  final payload = sep >= 0 ? address.substring(sep + 1) : address;
  final buffer = StringBuffer(prefix);
  for (var i = 0; i < payload.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(payload[i]);
  }
  return buffer.toString();
}
