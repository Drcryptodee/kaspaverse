import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../rust/api/vault.dart' as vault_api;
import '../services/vault_service.dart';

/// THROWAWAY dev panel for the P1.2 on-device acceptance pass — drives the
/// vault mechanisms before the real ceremony screens exist (P1.4 replaces
/// this; P1.3 gives the shell it dies in). Deliberately ugly; nothing here is
/// product UI. The passphrase field uses a TextField, which is FORBIDDEN for
/// real ceremonies (§0.7 — no system IME on secrets); acceptable here only
/// because this panel exercises a dev passphrase on a dev wallet, never real
/// funds and never seed words.
class DevVaultPanel extends StatefulWidget {
  const DevVaultPanel({super.key});

  @override
  State<DevVaultPanel> createState() => _DevVaultPanelState();
}

class _DevVaultPanelState extends State<DevVaultPanel> {
  final _passphrase = TextEditingController(text: 'dev-pass-phrase');
  String _log = '';
  bool _secure = false;

  void _say(String line) => setState(() => _log = '$line\n$_log');

  Uint8List _pwBytes() => Uint8List.fromList(_passphrase.text.codeUnits);

  Future<void> _run(String name, Future<void> Function() body) async {
    try {
      await body();
      _say('$name: ok');
    } catch (e) {
      _say('$name: ERROR $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = VaultService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('DEV vault panel (P1.2 pass)')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ValueListenableBuilder(
            valueListenable: vault.status,
            builder: (_, vault_api.VaultStatus? s, _) => Text(
              s == null
                  ? 'status: (none yet)'
                  : 'status: exists=${s.exists} unlocked=${s.unlocked} '
                        'failed=${s.failedAttempts} '
                        'lockedOutUntil=${s.lockedOutUntilUnix ?? "-"}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: vault.error,
            builder: (_, String? e, _) =>
                e == null ? const SizedBox.shrink() : Text('lane error: $e'),
          ),
          TextField(
            controller: _passphrase,
            decoration: const InputDecoration(labelText: 'dev passphrase'),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ElevatedButton(
                onPressed: () => _run('create', () async {
                  // Two-step create with the reveal skipped (dev only): begin →
                  // seal. The real onboarding adds the native reveal/verify
                  // between these (create_vault retired, D-038).
                  await vault.beginCreate();
                  await vault.sealAndPersist(_pwBytes(), Uint8List(0));
                }),
                child: const Text('create (Path B)'),
              ),
              ElevatedButton(
                onPressed: () => _run(
                  'unlock-pw',
                  () => vault.unlockWithPassphrase(_pwBytes()),
                ),
                child: const Text('unlock (passphrase)'),
              ),
              ElevatedButton(
                onPressed: () => _run('lock', vault_api.lockVault),
                child: const Text('lock'),
              ),
              ElevatedButton(
                onPressed: () => _run('enroll-bio', () async {
                  final ok = await VaultService.ceremony.invokeMethod<bool>(
                    'enrollBiometric',
                  );
                  if (ok != true) throw Exception('enroll returned $ok');
                }),
                child: const Text('enroll biometric (Path A)'),
              ),
              ElevatedButton(
                onPressed: () => _run('unlock-bio', () async {
                  final ok = await VaultService.ceremony.invokeMethod<bool>(
                    'unlockBiometric',
                  );
                  if (ok != true) throw Exception('unlock returned $ok');
                }),
                child: const Text('unlock (biometric)'),
              ),
              ElevatedButton(
                onPressed: () => _run('flag-secure', () async {
                  _secure = !_secure;
                  await VaultService.ceremony.invokeMethod(
                    'setSecure',
                    _secure,
                  );
                  _say('FLAG_SECURE now $_secure — try a screenshot');
                }),
                child: const Text('toggle FLAG_SECURE'),
              ),
              ElevatedButton(
                onPressed: () => _run('a11y?', () async {
                  final active = await VaultService.ceremony.invokeMethod<bool>(
                    'isAccessibilityActive',
                  );
                  _say('a11y service active: $active');
                }),
                child: const Text('a11y gate query'),
              ),
              ElevatedButton(
                onPressed: () => _run('kdf bench', () async {
                  for (final m in [64, 96, 128, 192, 256]) {
                    final ms = await vault_api.kdfBenchMs(
                      params: vault_api.VaultKdfParams(
                        mCostKib: m * 1024,
                        tCost: 3,
                        pCost: 1,
                      ),
                    );
                    _say('argon2id m=${m}MiB t=3 p=1 → $ms ms');
                  }
                }),
                child: const Text('KDF bench (tuning grid)'),
              ),
            ],
          ),
          const Divider(),
          Text(_log, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
