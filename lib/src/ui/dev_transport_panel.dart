import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../rust/api/send.dart' as send_api;
import '../rust/api/transport.dart' as transport_api;
import '../rust/api/vault.dart' show vaultReceiveAddress;
import '../services/transport_service.dart';
import 'format.dart';

/// THROWAWAY dev panel for the P2.1 payload-spine acceptance pass — drives the
/// transport send (plaintext `bcast`, the one pre-crypto wire-valid kind) and
/// shows the live `ciph_msg:` scan, before any product transport UI exists
/// (P2.3/P2.4 replace this; DevVaultPanel precedent). Deliberately ugly;
/// nothing here is product UI. Debug builds only (caged in main.dart, D5).
///
/// The "prepare" flow measures the acceptance fee-delta honestly: it first
/// builds the SAME send with no payload (prepare → read fee → abandon), then
/// builds the payload send — both fees are the pinned Generator's own numbers.
class DevTransportPanel extends StatefulWidget {
  const DevTransportPanel({super.key});

  @override
  State<DevTransportPanel> createState() => _DevTransportPanelState();
}

class _DevTransportPanelState extends State<DevTransportPanel> {
  final _destination = TextEditingController();
  final _amountKas = TextEditingController();
  final _channel = TextEditingController(text: 'kv-dev');
  final _message = TextEditingController(text: 'hello from the payload spine');
  String _log = '';
  BigInt? _nonce;

  void _say(String line) => setState(() => _log = '$line\n$_log');

  String _kas(BigInt sompi) {
    final parts = kasParts(sompi);
    return '${parts.integer}.${parts.fraction}';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_prefill());
  }

  /// Self-send defaults: own receive address + the computed floor (D-054 —
  /// never a hardcoded amount).
  Future<void> _prefill() async {
    try {
      _destination.text = await vaultReceiveAddress();
    } catch (e) {
      _say('receive address: ERROR $e');
    }
    try {
      final min = await send_api.sendMinimum();
      if (min != null) _amountKas.text = _kas(min);
    } catch (e) {
      _say('minimum: ERROR $e');
    }
  }

  Future<void> _run(String name, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      _say('$name: ERROR $e');
    }
  }

  /// Prepare the bcast send, measuring the fee delta vs an identical
  /// no-payload send first (both numbers are Rust's decode of built txs).
  Future<void> _prepare() => _run('prepare', () async {
    final amount = sompiFromKas(_amountKas.text);
    if (amount == null) {
      _say('prepare: bad amount "${_amountKas.text}"');
      return;
    }
    final destination = _destination.text.trim();

    // Baseline: the identical send with no payload (prepared, never signed).
    final plain = await send_api.sendPrepare(
      destination: destination,
      amountSompi: amount,
    );
    await send_api.sendAbandon();

    final summary = await transport_api.transportPrepareBcast(
      destination: destination,
      amountSompi: amount,
      channel: _channel.text,
      message: _message.text,
    );
    _nonce = summary.nonce;
    _say(
      'PREPARED nonce=${summary.nonce} kind=${summary.payloadKind} '
      'payload=${summary.payloadLen}B\n'
      '  to ${truncateAddressPayload(summary.destination)} '
      'amount=${_kas(summary.amountSompi)} KAS\n'
      '  fee=${_kas(summary.feeSompi)} (no-payload fee=${_kas(plain.feeSompi)} '
      '→ payload delta=${_kas(summary.feeSompi - plain.feeSompi)} KAS)\n'
      // Overall mass (max incl. KIP-9 storage) — NOT the fee basis; the fee
      // floor excludes storage, so these two lines never reconcile.
      '  overall-mass=${summary.mass} (no-payload ${plain.mass}; ≠ fee basis) '
      'txs=${summary.txCount} utxos=${summary.utxoCount}',
    );
  });

  Future<void> _commit() => _run('commit', () async {
    final nonce = _nonce;
    if (nonce == null) {
      _say('commit: nothing prepared');
      return;
    }
    final outcome = await transport_api.transportCommit(nonce: nonce);
    _nonce = null;
    _say(
      'COMMIT ${outcome.submitted}/${outcome.total}'
      '${outcome.partial ? ' PARTIAL' : ''}'
      '${outcome.error != null ? ' error=${outcome.error}' : ''}\n'
      '  txid=${outcome.finalTxid ?? '-'}',
    );
  });

  Future<void> _abandon() => _run('abandon', () async {
    await transport_api.transportAbandon();
    _nonce = null;
    _say('abandoned');
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DEV transport panel (P2.1 pass)')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _destination,
            decoration: const InputDecoration(
              labelText: 'destination (prefilled: own receive address)',
            ),
          ),
          TextField(
            controller: _amountKas,
            decoration: const InputDecoration(
              labelText: 'amount KAS (prefilled: computed minimum)',
            ),
          ),
          TextField(
            controller: _channel,
            decoration: const InputDecoration(labelText: 'bcast channel'),
          ),
          TextField(
            controller: _message,
            decoration: const InputDecoration(
              labelText: 'message (plaintext!)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ElevatedButton(
                onPressed: _prepare,
                child: const Text('prepare (+fee delta)'),
              ),
              ElevatedButton(
                onPressed: _commit,
                child: const Text('commit (sign+broadcast)'),
              ),
              ElevatedButton(onPressed: _abandon, child: const Text('abandon')),
            ],
          ),
          const Divider(),
          ValueListenableBuilder(
            valueListenable: TransportService.instance.events,
            builder: (_, List<transport_api.TransportEventDto> events, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'live ciph_msg matches: ${events.length}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final e in events)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '[${e.kind}] tx=${e.txid ?? '-'}\n'
                      '  body(${e.body.length}B)='
                      '${utf8.decode(e.body.take(80).toList(), allowMalformed: true)}\n'
                      '  to ${e.addresses.map(truncateAddressPayload).join(', ')}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          Text(_log, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
