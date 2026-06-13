import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/secret/bip39_wordlist.dart';

// The picker's filter helper. Suggestions only — Rust is the validation
// authority (INV-9); these pin the prefix/index behaviour the picker relies on.
void main() {
  const list = Bip39Wordlist.forTest([
    'abandon',
    'ability',
    'able',
    'about',
    'zoo',
  ]);

  test('startingWith filters by prefix; empty prefix yields nothing', () {
    expect(list.startingWith('ab'), ['abandon', 'ability', 'able', 'about']);
    expect(list.startingWith(''), isEmpty);
    expect(list.startingWith('zo'), ['zoo']);
    expect(list.startingWith('xyz'), isEmpty);
  });

  test('startingWith respects the limit', () {
    expect(list.startingWith('ab', limit: 2), ['abandon', 'ability']);
  });

  test('indexOf / contains are case-insensitive exact matches', () {
    expect(list.indexOf('able'), 2);
    expect(list.indexOf('ABLE'), 2);
    expect(list.indexOf('ab'), -1); // a prefix is not a word
    expect(list.contains('zoo'), isTrue);
    expect(list.contains('zo'), isFalse);
  });
}
