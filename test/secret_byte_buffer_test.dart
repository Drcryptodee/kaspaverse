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
}
