import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/secret/secret_byte_buffer.dart';

// The INV-3-clean secret input primitive: a passphrase/extra word is assembled
// here as bytes and NEVER as a Dart String. These pin the byte semantics + the
// wipe discipline the secret screens depend on.
void main() {
  test('appends bytes and reports length', () {
    final b = SecretByteBuffer();
    'abc'.split('').forEach(b.appendChar);
    expect(b.length.value, 3);
    expect(b.snapshot(), utf8.encode('abc'));
    b.dispose();
  });

  test('backspace removes the last character', () {
    final b = SecretByteBuffer();
    'hi'.split('').forEach(b.appendChar);
    b.backspace();
    expect(b.length.value, 1);
    expect(b.snapshot(), utf8.encode('h'));
    b.dispose();
  });

  test('backspace drops all bytes of a multi-byte character', () {
    final b = SecretByteBuffer();
    b.appendChar('é'); // 2 UTF-8 bytes
    expect(b.length.value, 2);
    b.backspace();
    expect(b.length.value, 0);
    b.dispose();
  });

  test(
    'snapshot is an independent copy — wiping it never touches the buffer',
    () {
      final b = SecretByteBuffer();
      'abc'.split('').forEach(b.appendChar);
      final snap = b.snapshot();
      snap.fillRange(0, snap.length, 0); // simulate the lane's finally-wipe
      expect(b.snapshot(), utf8.encode('abc'));
      b.dispose();
    },
  );

  test('grows past the initial capacity without loss', () {
    final b = SecretByteBuffer(initialCapacity: 4);
    final s = 'x' * 100;
    s.split('').forEach(b.appendChar);
    expect(b.length.value, 100);
    expect(b.snapshot(), utf8.encode(s));
    b.dispose();
  });

  test('wipe resets to empty', () {
    final b = SecretByteBuffer();
    'secret'.split('').forEach(b.appendChar);
    b.wipe();
    expect(b.length.value, 0);
    expect(b.snapshot(), isEmpty);
    b.dispose();
  });

  // ── matches: the confirm-repeat gate on the seed-determining extra word ──

  SecretByteBuffer of(String s, {int initialCapacity = 64}) {
    final b = SecretByteBuffer(initialCapacity: initialCapacity);
    s.split('').forEach(b.appendChar);
    return b;
  }

  test('matches is true for identical bytes', () {
    final a = of('correct horse');
    final b = of('correct horse');
    expect(a.matches(b), isTrue);
    expect(b.matches(a), isTrue);
    a.dispose();
    b.dispose();
  });

  test('matches is false for one wrong character — including case', () {
    final a = of('Battery');
    for (final wrong in ['battery', 'Bettery', 'Batterz']) {
      final b = of(wrong);
      expect(a.matches(b), isFalse, reason: wrong);
      b.dispose();
    }
    a.dispose();
  });

  test('matches is false on a length mismatch either way', () {
    final a = of('staple');
    final short = of('stapl');
    final long = of('staples');
    expect(a.matches(short), isFalse);
    expect(a.matches(long), isFalse);
    expect(short.matches(a), isFalse);
    expect(long.matches(a), isFalse);
    a.dispose();
    short.dispose();
    long.dispose();
  });

  test('matches compares the live length, not the backing store', () {
    // The store is over-allocated and reused across a wipe, so a stale tail
    // must not decide the comparison — and two buffers that grew to different
    // capacities must still compare equal on the same content.
    final a = of('zzzzzzzzzz', initialCapacity: 4); // forced two growths
    a.wipe();
    'ab'.split('').forEach(a.appendChar);
    final b = of('ab', initialCapacity: 64);
    expect(a.matches(b), isTrue);
    expect(b.matches(a), isTrue);
    a.dispose();
    b.dispose();
  });

  test('two empty buffers match — the Skip path is not a mismatch', () {
    final a = SecretByteBuffer();
    final b = SecretByteBuffer();
    expect(a.matches(b), isTrue);
    a.dispose();
    b.dispose();
  });

  test('matches handles multi-byte characters', () {
    final a = of('café');
    final b = of('café');
    final c = of('cafe');
    expect(a.matches(b), isTrue);
    expect(a.matches(c), isFalse); // 5 bytes vs 4
    a.dispose();
    b.dispose();
    c.dispose();
  });
}
