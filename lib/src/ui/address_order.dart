import '../rust/api/wallet.dart' show WalletAddressDto;

/// **How the wallet's own addresses are ordered and grouped, everywhere they
/// are shown** — `T4 · Wallet`'s list and the `Receive at` sheet, and anything
/// that draws them next.
///
/// Founder's ruling, 2026-09-07, on glass: *"i want that law embedded so
/// wherever we view addresses, the ones with balance float against the ones
/// with zero balance."* It lives here rather than in either screen because two
/// copies is how two surfaces start disagreeing about which address matters
/// (BG-21) — and because a rule stated once can be tested once.
abstract final class AddressOrder {
  /// **Holding something is what makes an address used.** Coins now, coins the
  /// wallet refuses to move (D-211), or coins on their way to it — any of the
  /// three, and nothing else.
  ///
  /// It was *"handed out from this phone"* for one sitting, backed by a record
  /// the app wrote when it displayed an address. The founder replaced it on
  /// glass: *"'fresh' address simply mean an address with zero balance."*
  /// Simpler, and strictly better: it needs no local record at all, so it says
  /// the same thing on a restored wallet as on the one that earned the coins —
  /// and every word of it is answerable from the node's own UTXO set.
  static bool holdsSomething(WalletAddressDto a) =>
      a.balanceSompi > BigInt.zero || a.lockedSompi > BigInt.zero || a.settling;

  /// The order: **money first, then index**.
  ///
  /// Within each group the index order stands, because an index is a slot in a
  /// derivation path and a user scanning for `Receive 14` expects it after
  /// `Receive 13`. Sorting *funded* rows by size instead would reorder the list
  /// under someone every time a coin arrived.
  static int compare(WalletAddressDto a, WalletAddressDto b) {
    final funded = holdsSomething(b) ? 1 : 0;
    final mine = holdsSomething(a) ? 1 : 0;
    if (funded != mine) return funded - mine;
    return a.index.compareTo(b.index);
  }

  /// A copy of [addresses] in that order. The input is left alone: it is the
  /// seam's own list and something else may be holding it.
  static List<WalletAddressDto> sorted(Iterable<WalletAddressDto> addresses) =>
      addresses.toList()..sort(compare);
}
