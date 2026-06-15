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
