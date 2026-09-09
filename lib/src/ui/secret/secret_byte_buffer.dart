import 'dart:convert';

import 'package:flutter/foundation.dart';

/// An append-only secret byte buffer that NEVER becomes a Dart `String`
/// (INV-3). This is the one place a passphrase or extra word is assembled on the
/// Dart side: each keystroke appends raw bytes; [snapshot] hands a throwaway
/// copy to a bridge call (the [VaultService] lane wipes it in `finally`);
/// [wipe] zeroes the backing store on dispose.
///
/// A `TextEditingController` cannot be used for a secret — its `.text` is a Dart
/// `String` (INV-3) and the system IME would see every keystroke (§0.7). The
/// backing store is over-allocated and grown in chunks; a growth copies then
/// zeroes the old store, so no un-wiped fragment lingers in the heap. Only the
/// [length] (an `int`) is observable — the UI renders masked dots from it and
/// never reads the bytes.
class SecretByteBuffer {
  SecretByteBuffer({int initialCapacity = 64})
    : _store = Uint8List(initialCapacity);

  Uint8List _store;
  int _len = 0;

  /// Observable LENGTH only — never the bytes. The UI masks to dots from this.
  final ValueNotifier<int> length = ValueNotifier<int>(0);

  bool get isEmpty => _len == 0;

  /// Append the UTF-8 bytes of one typed character. The custom keyboard offers
  /// ASCII keys (one byte each); multi-byte input is handled correctly anyway.
  void appendChar(String char) {
    final bytes = utf8.encode(char);
    _ensure(_len + bytes.length);
    for (final b in bytes) {
      _store[_len++] = b;
    }
    length.value = _len;
  }

  /// Delete the last character (dropping the whole UTF-8 sequence, not one byte).
  void backspace() {
    if (_len == 0) return;
    // Drop any trailing continuation bytes (0b10xxxxxx) of a multi-byte char…
    while (_len > 0 && (_store[_len - 1] & 0xC0) == 0x80) {
      _store[--_len] = 0;
    }
    // …then the lead byte (or, for ASCII, the single byte).
    if (_len > 0) _store[--_len] = 0;
    length.value = _len;
  }

  /// A throwaway COPY of the current bytes for exactly one bridge call; the
  /// caller wipes it in `finally`. Never hand out [_store] itself — the wipe
  /// would clear the live buffer mid-edit.
  Uint8List snapshot() => _store.sublist(0, _len);

  /// Whether [other] holds exactly the same bytes — the confirm-repeat gate on
  /// the create ceremony's extra word. Compares in-place: neither buffer is
  /// copied out, and nothing here becomes a Dart `String` (INV-1/3). Dart
  /// privacy is per-library, so reaching into `other`'s private store is legal
  /// and keeps the bytes from ever leaving this class.
  ///
  /// Deliberately NOT constant-time, and not claimed to be: it early-returns on
  /// a length mismatch, and both operands are the same user's own bytes on
  /// their own device, so there is no attacker positioned to time it.
  bool matches(SecretByteBuffer other) {
    if (_len != other._len) return false;
    for (var i = 0; i < _len; i++) {
      if (_store[i] != other._store[i]) return false;
    }
    return true;
  }

  /// **The characters, as text, for exactly one paint under a hold** (D-312).
  ///
  /// This is the one method on this class that returns a Dart `String` of the
  /// secret, and it is a **ledgered exception to INV-3, not a hole in it**. The
  /// precedent is D-039 as widened by D-136: the twelve recovery words already
  /// exist as Activity-scoped Java `String`s during the native reveal,
  /// unwipeable by design, *"accepted because the same window has the words on
  /// the physical screen."* The extra word's reveal is the identical bargain on
  /// a smaller secret, and the founder ruled for it after hearing the argument
  /// against (`vault_architecture.md` §7).
  ///
  /// The fence, and every part of it is load-bearing:
  ///
  /// * **Hold, never a sticky toggle.** The caller must drive this from a press
  ///   that ends on release, so the word is on screen only while a finger is
  ///   down and the residual's lifetime is a gesture rather than a screen.
  /// * **Composed at paint, dropped on release.** The returned `String` lives
  ///   in one widget's `Text` and dies with the rebuild that hides it. Dart
  ///   strings are immutable: this one CANNOT be zeroized, and no future
  ///   version of this method will be able to. That is the residual, stated.
  /// * **The byte copy IS wiped**, below — only the `String` cannot be.
  /// * **The screen is already `FLAG_SECURE`** ([SecretScreenGuard]), so the
  ///   exposure is an off-device camera, not a screenshot.
  ///
  /// What it buys: the founder's own finding that a word you cannot see is a
  /// word you cannot check. The double entry stays as well — he asked for both
  /// — so this adds a check rather than replacing one.
  ///
  /// Never call this outside a hold, never on a screen without the guard, and
  /// never hand the result anywhere but a paint.
  String revealWhileHeld() {
    final copy = _store.sublist(0, _len);
    final text = utf8.decode(copy);
    // The bytes we CAN clear, we clear. Immediately, not at some later dispose:
    // this copy has no other reader.
    copy.fillRange(0, copy.length, 0);
    return text;
  }

  /// Zero the backing store and reset to empty. Safe to reuse afterwards.
  void wipe() {
    _store.fillRange(0, _store.length, 0);
    _len = 0;
    length.value = 0;
  }

  /// Wipe the bytes and release the length notifier. Call from screen dispose.
  void dispose() {
    wipe();
    length.dispose();
  }

  void _ensure(int needed) {
    if (needed <= _store.length) return;
    var cap = _store.length;
    while (cap < needed) {
      cap *= 2;
    }
    final grown = Uint8List(cap);
    grown.setRange(0, _len, _store);
    _store.fillRange(0, _store.length, 0); // wipe the old (smaller) store
    _store = grown;
  }
}
