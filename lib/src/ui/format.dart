/// Render-layer number formatting (L3). Money is `BigInt` (sompi) end-to-end;
/// the ONLY sompi→KAS conversion in the app happens here, at the render
/// boundary (design_system §5). No floating point ever touches money.
library;

/// Group digits in threes for a node-status readout: 458174109 →
/// "458,174,109". Scores arrive as [BigInt] (L3); formatted only here, at
/// render.
///
/// Lives here rather than on the home screen because two surfaces render the
/// same value — the money plate's chain clock and the node surface's DAA
/// reading — and a formatter two surfaces share belongs with the other
/// formatters, not inside one of its callers.
String formatScore(BigInt? value) =>
    value == null ? '—' : groupThousands(value.toString());

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
/// **Floors toward zero — never rounds a balance up** (BG-5): a user must never
/// see more spendable than they hold. e.g. `199999999` → `("1", "99999999")`,
/// `0` → `("0", "00000000")`.
({String integer, String fraction}) kasParts(BigInt sompi) {
  final kas = sompi ~/ _sompiPerKas;
  final fraction = (sompi % _sompiPerKas).toString().padLeft(8, '0');
  return (integer: groupThousands(kas.toString()), fraction: fraction);
}

/// Trim trailing zeros from an 8-digit KAS fraction, keeping at least [min]
/// digits — the §5 feeds/lists rule (`"50000000"` → `"50"`, `"00000000"` →
/// `"00"`). **Never** used on a signing surface: there the full 8 digits are
/// the truth at the moment of commitment (BG-5/BG-6).
String trimFraction(String fraction, {int min = 2}) {
  var end = fraction.length;
  while (end > min && fraction[end - 1] == '0') {
    end--;
  }
  return fraction.substring(0, end);
}

/// Parse a user-typed KAS amount into sompi (`BigInt`) — the inverse of
/// [kasParts], for the send screen (BG-5). **String math only, never a
/// `double`** (custody: a float can't represent 8-decimal sompi exactly).
///
/// Returns `null` for anything not a clean non-negative amount: empty, signs,
/// grouping commas, more than one dot, non-digits, **more than 8 fractional
/// digits** (sompi can't hold finer than 1e-8 KAS — rejected, never silently
/// floored away), or **more sompi than a `u64` can carry**.
///
/// That last bound is the one that would fail silently. `amount_sompi` crosses
/// the FFI as a `u64`, and flutter_rust_bridge's encoder ends in
/// `ByteData.setUint64`, which **truncates mod 2⁶⁴ and throws nothing**:
/// `184467440737.09551616` KAS would cross as **0**. A number quietly becoming
/// a different number is BG-5's exact prohibition, and the refusal belongs
/// here — at the boundary every caller already trusts — rather than in one
/// screen's validation (`consensus-auditor`, UX-4).
///
/// `"12.4"` → `1_240_000_000`; `".5"` → `50_000_000`; `"0"` → `0`.
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
  final sompi = whole * _sompiPerKas + frac;
  return sompi > maxSompi ? null : sompi;
}

/// The largest value the `u64` sompi wire can carry — `2⁶⁴ − 1`. Not a policy
/// number: it is the width of the field, and above it the encoder wraps in
/// silence. (Kaspa's whole supply is ~28.7e9 KAS, six orders of magnitude
/// under it, so no real amount is ever near this.)
final BigInt maxSompi = BigInt.parse('18446744073709551615');

/// Trim trailing zeros from a **fiat** figure — the precision law (D-210)
/// applied to a unit that is not KAS: every significant digit, no padding,
/// up to the unit's own precision.
///
/// **This is the one formatter here that takes a `double`, and the exception
/// is narrow.** The file's rule — *no floating point ever touches money* —
/// is about value that settles: a balance, an amount, a fee, all `BigInt`
/// sompi from Rust to paint. A fiat restatement settles nothing. It is a
/// convenience beside the unit of account (BG-5 as amended, D-191), it never
/// prices a fee or sizes a spend, and INV-8's carve-out permits it precisely
/// because nothing depends on it. A `BigInt` here would be false rigour on a
/// number a vendor made up.
///
/// `0.0712` → `"0.0712"`; `0.02864504` → `"0.02864504"`; `1.0` → `"1"`.
/// [max] is the unit's precision, not KAS's: a source that answers more digits
/// than that is reporting noise. A value finer than [max] floors to `"0"` —
/// bounded upstream rather than here, where `prefs::check_price` refuses a
/// price that is not positive and believable before one can reach a screen.
String trimTrailingZeros(double value, {int max = 8}) {
  var text = value.toStringAsFixed(max);
  if (!text.contains('.')) return text;
  text = text.replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}

/// Group an address payload in fours for a full-form review (BG-15): keep the
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

/// Compact, payload-aware address form for non-actionable contexts (BG-15): keep
/// the `kaspa:` scheme intact, then first 8 + `…` + last 8 of the *payload*. The
/// distinguishing entropy lives in the payload, so we spend the truncation
/// budget there and never on `kaspa:q…` — eliding the scheme would leave
/// near-zero identifying bits, a gift to address-poisoning. Example:
/// `kaspa:qrxk2f9p…wmx3f4a2`. Payloads of 16 chars or fewer are returned whole
/// (nothing to elide). The full review form is [chunkAddress]; a tap on a
/// compact address should reveal it.
String truncateAddressPayload(String address) {
  final sep = address.indexOf(':');
  final prefix = sep >= 0 ? address.substring(0, sep + 1) : '';
  final payload = sep >= 0 ? address.substring(sep + 1) : address;
  if (payload.length <= 16) return address;
  final head = payload.substring(0, 8);
  final tail = payload.substring(payload.length - 8);
  return '$prefix$head…$tail';
}

/// Apply one amount-keypad press to the amount being typed, returning the new
/// string. Pure, so the grammar of money entry is testable without a widget.
///
/// The rules are [sompiFromKas]'s, enforced at the keystroke instead of at the
/// parse — a keypad that lets you type a ninth decimal and then refuses the
/// whole amount teaches nothing:
///
///  * **at most one decimal point**, and a leading `.` becomes `0.`;
///  * **at most 8 fractional digits** — sompi cannot hold finer, so the ninth
///    press is simply not taken (never silently floored away);
///  * a digit pressed against a lone leading `0` REPLACES it, so `05` cannot
///    be typed.
///
/// [key] is a single character: `0`–`9` or `.`. Backspace is the caller's
/// [amountBackspace].
String amountKeyPress(String current, String key) {
  if (key == '.') {
    if (current.contains('.')) return current;
    return current.isEmpty ? '0.' : '$current.';
  }
  if (key.length != 1 || key.codeUnitAt(0) < 0x30 || key.codeUnitAt(0) > 0x39) {
    return current;
  }
  final dot = current.indexOf('.');
  if (dot >= 0 && current.length - dot - 1 >= 8) return current;
  final next = current == '0' ? key : '$current$key';
  // The `u64` ceiling, refused at the keystroke rather than at the parse for
  // the same reason as the ninth decimal: an amount that becomes unparseable
  // several keys after the one that did it teaches nothing.
  return sompiFromKas(next) == null && next != '0.' ? current : next;
}

/// Remove the last character of a typed amount. A trailing lone `0.` goes back
/// to empty in one press rather than leaving a bare `0` the user did not type.
String amountBackspace(String current) {
  if (current.isEmpty) return current;
  final next = current.substring(0, current.length - 1);
  return next == '0' ? '' : next;
}

/// Group the integer part of a **typed** amount for display, leaving the
/// fraction exactly as typed.
///
/// The canonical string stays ungrouped — [sompiFromKas] rejects grouping
/// commas — so this is display only, and the value that gets parsed is never
/// the one that was grouped.
String groupTypedAmount(String typed) {
  final dot = typed.indexOf('.');
  if (dot < 0) return groupThousands(typed);
  return '${groupThousands(typed.substring(0, dot))}${typed.substring(dot)}';
}

/// A wall-clock stamp for a receipt — `30 Aug 2026, 02:48`.
///
/// **Local time, from the chain's own moment.** The caller passes the unix
/// milliseconds the ACCEPTANCE was recorded (`TxStatusDto.acceptedUnixMs`),
/// never `DateTime.now()`: the device's observation of an acceptance is a
/// different fact from the acceptance, and a receipt that labelled one as the
/// other would be a wallet claim wearing a chain's clothes.
///
/// **To the MINUTE, not the second, and that is a consensus fact rather than a
/// taste.** A block's timestamp is miner-set within the pin's
/// `TIMESTAMP_DEVIATION_TOLERANCE` of 132 seconds, so it may sit over two
/// minutes ahead of the user's own clock on a send that landed in a second,
/// and consecutive sends can stamp out of order — the DAG orders by blue
/// score, never by time. Rendering seconds off a value with ±132 s of slack
/// claims a precision consensus does not give (`consensus-auditor`, UX-4B).
String formatStamp(DateTime at) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.day)} ${months[at.month - 1]} ${at.year}, '
      '${two(at.hour)}:${two(at.minute)}';
}

/// Whether a pasted destination carries whitespace anywhere inside it.
///
/// Worth its own answer because the wallet's generic refusal — *"that doesn't
/// look like a valid Kaspa address"* — leaves a user staring at an address
/// that looks perfectly right, with an invisible character as the only thing
/// wrong (founder, on glass 2026-08-30). Leading and trailing space is trimmed
/// long before here; this is the one in the middle.
bool hasInnerWhitespace(String s) => RegExp(r'\s').hasMatch(s.trim());
