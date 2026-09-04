import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';

/// **The pin's mainnet thresholds, as a fixture** — `user_transaction_
/// maturity_period_daa` 100 and `coinbase_transaction_maturity_period_daa`
/// 1,000, read from `wallet/core/src/utxo/settings.rs` at rev `cfafeb4c`.
///
/// It lives in `test/` on purpose. D-249's rule is that no such number is typed
/// into **`lib/`** — production reads them across the FFI from `NetworkParams`
/// — but a widget test has no native library, so a fixture is the only way to
/// exercise the ladder at all. Naming it once means the suite cannot drift into
/// two sets of thresholds, and a re-pin that moves the library's numbers shows
/// up here as one edit rather than forty.
const kTestMaturity = KvMaturity(userDaa: 100, coinbaseDaa: 1000);

/// The devnet pair (`10 / 100`), for the tests that prove the ladder reads its
/// thresholds rather than remembering them. D-249's third finding was that
/// `10 / 100` is verbatim wallet-core's devnet pair — so a gauge that still
/// lands `Settled` at 100 under these numbers is one that ignored what it was
/// handed.
const kTestDevnetMaturity = KvMaturity(userDaa: 10, coinbaseDaa: 100);
