import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';

// A real mainnet address shape (same payload used across the send/receive
// tests). The function never validates — it only truncates payload-aware.
const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

void main() {
  group('truncateAddressPayload (DS-8)', () {
    test('keeps the scheme intact, truncates only the payload', () {
      // first 4 = qrqr · last 8 = 3pmcd692 (of the PAYLOAD, not the string).
      // 4 + 8 since 2026-09-07 (founder), where it was 8 + 8 — one compact form
      // on every screen, and the same numbers the full form weights.
      expect(truncateAddressPayload(_addr), 'kaspa:qrqr…3pmcd692');
    });

    test('never spends the budget on the scheme (no kaspa:q… elision)', () {
      final out = truncateAddressPayload(_addr);
      expect(out.startsWith('kaspa:'), isTrue, reason: 'full scheme preserved');
      // The char after the scheme is real payload, never an ellipsis.
      expect(out.substring('kaspa:'.length).startsWith('…'), isFalse);
      expect(out.contains('…'), isTrue);
    });

    test('payloads of 12 chars or fewer are returned whole', () {
      // The budget is head + tail = 4 + 8, so twelve is the boundary: a
      // payload that short has nothing to elide.
      const whole = 'kaspa:0123456789ab'; // 12-char payload — boundary
      expect(truncateAddressPayload(whole), whole);
      expect(truncateAddressPayload('kaspa:qrqr'), 'kaspa:qrqr');
      expect(truncateAddressPayload(''), '');
    });

    test(
      '13-char payload is the first truncation step (elides the middle)',
      () {
        expect(
          truncateAddressPayload('kaspa:0123456789abc'),
          'kaspa:0123…56789abc',
        );
      },
    );

    test('a string with no scheme is treated as all-payload', () {
      expect(
        truncateAddressPayload('abcdefghijklmnopqrstuvwxyz'),
        'abcd…stuvwxyz',
      );
    });
  });
}
