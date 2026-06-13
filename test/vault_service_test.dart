import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/vault.dart';
import 'package:kaspaverse/src/services/vault_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The L9 property under its WORST case: on the host there is no native
  // library, so the bridge call throws — and the finally-wipe must fire
  // anyway. A wipe that only runs on the success path is the exact leak
  // class L9 records (a throw between use and wipe).
  test(
    'passphrase buffer is zeroed even when the bridge call throws',
    () async {
      final passphrase = Uint8List.fromList(List.filled(32, 0x42));

      await expectLater(
        VaultService.instance.unlockWithPassphrase(passphrase),
        throwsA(anything),
      );

      expect(
        passphrase.every((b) => b == 0),
        isTrue,
        reason: 'finally-wipe must zero the caller buffer on the throw path',
      );
    },
  );

  test('createVault wipes its buffer on the throw path too', () async {
    final passphrase = Uint8List.fromList(List.filled(16, 0x7A));

    await expectLater(
      VaultService.instance.createVault(
        passphrase,
        // Explicit params: the startingGrid() fetch is itself a bridge call
        // that would throw on host BEFORE createVault runs — passing params
        // makes the createVault call the one under test.
        params: const VaultKdfParams(mCostKib: 65536, tCost: 3, pCost: 1),
      ),
      throwsA(anything),
    );

    expect(passphrase.every((b) => b == 0), isTrue);
  });
}
