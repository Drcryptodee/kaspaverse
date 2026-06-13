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
