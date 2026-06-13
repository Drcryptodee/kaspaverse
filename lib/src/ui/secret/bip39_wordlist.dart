import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// The canonical BIP39 English wordlist (2048 public words), bundled as an asset
/// (sha256 `2f5eed53…3b24dbda`). This is PUBLIC data — the secret is the ordered
/// SELECTION, not the dictionary. Used only for the restore picker's
/// filter/suggestions; the authoritative validation is Rust-side
/// (`MnemonicCeremony::restore`, the pinned `kaspa_bip32`, INV-9). The Dart side
/// can only ever offer suggestions — it can never declare a phrase valid.
class Bip39Wordlist {
  const Bip39Wordlist._(this.words);

  /// Test-only constructor (avoids bundling the 2048-word asset in unit tests).
  @visibleForTesting
  const Bip39Wordlist.forTest(this.words);

  final List<String> words;

  static Bip39Wordlist? _instance;

  /// Load + cache the asset once. Idempotent.
  static Future<Bip39Wordlist> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/bip39/english.txt');
    final words = raw
        .split('\n')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    final loaded = Bip39Wordlist._(words);
    _instance = loaded;
    return loaded;
  }

  /// Words beginning with [prefix] (case-insensitive), for picker suggestions.
  /// Empty for an empty prefix (the picker shows nothing until the user types).
  List<String> startingWith(String prefix, {int limit = 8}) {
    if (prefix.isEmpty) return const [];
    final p = prefix.toLowerCase();
    final out = <String>[];
    for (final w in words) {
      if (w.startsWith(p)) {
        out.add(w);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// Index of an exact word, or `-1`. The picker stores INDICES (not word
  /// `String`s) as its secret-bearing state — an index is a pointer into a
  /// public list, not the chosen word itself.
  int indexOf(String word) => words.indexOf(word.toLowerCase());

  /// Whether [word] is in the list (an exact, lowercased match).
  bool contains(String word) => indexOf(word) != -1;
}
