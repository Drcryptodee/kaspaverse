import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/kv_loader.dart';
import 'confirm_send_sheet.dart';

/// Send entry (P1.6 · T3): amount (BG-5 floor) + destination (BG-15 paste →
/// full-form review). "Review" builds the transaction(s) in Rust and opens the
/// anti-blind-signing confirm ([ConfirmSendSheet]) — the amount/fee the user
/// approves are Rust's decode of the actual txs, never this form's echo (B7).
///
/// A pure consumer (injected fns + the live mature balance) so widget tests run
/// without the native library; `main.dart` wires it to [WalletService].
class SendScreen extends StatefulWidget {
  const SendScreen({
    super.key,
    required this.mature,
    required this.prepare,
    required this.commit,
    required this.abandon,
    this.minimumSendable,
    this.prepareSweep,
  });

  /// Spendable (mature) balance, for the informational "available" line. The
  /// authoritative check (incl. the KIP-9 fee) is Rust's `prepare`.
  final ValueListenable<BigInt?> mature;

  final Future<SignableSummaryDto> Function(
    String destination,
    BigInt amountSompi,
  )
  prepare;
  final Future<SendOutcomeDto> Function(BigInt nonce) commit;
  final Future<void> Function() abandon;

  /// Send max — the sweep builder (Rust solves the amount: it depends on the
  /// fee of the transaction spending it, so the field's number can never be
  /// right). Null hides the affordance (tests that only exercise payments).
  final Future<SignableSummaryDto> Function(String destination)? prepareSweep;

  /// The smallest currently-sendable amount (sompi), probed from the pinned
  /// Generator over the live coin shape (D-054) — advisory display only; the
  /// Generator on `prepare` stays the single authority. Null provider or null
  /// result ⇒ no hint line.
  final Future<BigInt?> Function()? minimumSendable;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _amount = TextEditingController();
  final _address = TextEditingController();
  bool _building = false;
  String? _error;
  BigInt? _minSompi;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_onChanged);
    _address.addListener(_onChanged);
    // Fetch the live floor once per screen-open. Advisory: failures (engine
    // not ready, probe error) simply mean no hint — never a blocked send.
    final probe = widget.minimumSendable;
    if (probe != null) {
      probe()
          .then((min) {
            if (mounted) setState(() => _minSompi = min);
          })
          .catchError((Object _) {
            /* no hint — prepare stays authoritative */
          });
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _address.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Any edit rebuilds (Review enablement) and clears a prior error.
    setState(() => _error = null);
  }

  BigInt? get _amountSompi => sompiFromKas(_amount.text);

  /// Light shape check for enabling Review — the real validation (checksum,
  /// network) is Rust's, surfaced on Review (BG-15: reject before signing).
  bool get _addressLooksValid {
    final a = _address.text.trim();
    return a.startsWith('kaspa:') && a.length > 'kaspa:'.length + 10;
  }

  bool get _canReview =>
      !_building &&
      _amountSompi != null &&
      _amountSompi! > BigInt.zero &&
      _addressLooksValid;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _address.text = text;
    }
  }

  Future<void> _review() async {
    final amountSompi = _amountSompi;
    if (amountSompi == null || amountSompi <= BigInt.zero) return;
    await _reviewWith(() => widget.prepare(_address.text.trim(), amountSompi));
  }

  /// "Send everything": the sweep flow — same address field, same confirm
  /// sheet, no amount (Rust solves it). The affordance stays TAPPABLE even
  /// before an address is entered, and answers with words instead of a
  /// silently greyed door (the dust-trapped user it exists for must never
  /// meet a control that won't say what it needs).
  Future<void> _reviewSweep() async {
    final prepareSweep = widget.prepareSweep;
    if (prepareSweep == null) return;
    if (!_addressLooksValid) {
      setState(
        () => _error =
            'Enter the destination address first — no amount is needed to '
            'send everything.',
      );
      return;
    }
    await _reviewWith(() => prepareSweep(_address.text.trim()));
  }

  Future<void> _reviewWith(
    Future<SignableSummaryDto> Function() prepare,
  ) async {
    setState(() {
      _building = true;
      _error = null;
    });
    try {
      final summary = await prepare();
      if (!mounted) return;
      // The confirm renders Rust's decode (summary), not the form (B7).
      final outcome = await showModalBottomSheet<SendOutcomeDto?>(
        context: context,
        backgroundColor: KvColor.surface,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ConfirmSendSheet(
          summary: summary,
          commit: widget.commit,
          abandon: widget.abandon,
        ),
      );
      if (!mounted) return;
      // A fully-broadcast send returns to home; the new balance + outgoing row
      // arrive via the live sync (no manual refresh).
      if (outcome != null && !outcome.partial && outcome.error == null) {
        Navigator.of(context).pop();
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Scrollable so the keyboard never overflows the column; Review
              // stays pinned below it.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('AMOUNT', style: theme.textTheme.labelLarge),
                      const SizedBox(height: KvSpace.s),
                      TextField(
                        controller: _amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        // The amount is the screen's subject — screen-level
                        // mono role (§4), tabular so digits never jiggle (BG-5).
                        style: theme.textTheme.displaySmall,
                        decoration: const InputDecoration(
                          hintText: '0.00000000',
                          suffixText: 'KAS',
                        ),
                      ),
                      const SizedBox(height: KvSpace.s),
                      _AvailableLine(mature: widget.mature),
                      if (_minSompi != null) ...[
                        const SizedBox(height: KvSpace.xs),
                        _MinimumLine(minSompi: _minSompi!),
                      ],
                      const SizedBox(height: KvSpace.xl),
                      Text('TO', style: theme.textTheme.labelLarge),
                      const SizedBox(height: KvSpace.s),
                      TextField(
                        controller: _address,
                        minLines: 1,
                        maxLines: 2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: KvFont.mono,
                        ),
                        decoration: InputDecoration(
                          hintText: 'kaspa:…',
                          suffixIcon: IconButton(
                            tooltip: 'Paste',
                            icon: const Icon(Icons.content_paste, size: 18),
                            onPressed: _paste,
                          ),
                        ),
                      ),
                      if (_address.text.trim().isNotEmpty) ...[
                        const SizedBox(height: KvSpace.s),
                        _AddressReview(address: _address.text.trim()),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: KvSpace.m),
                        Text(
                          _error!,
                          // `KvColor.error` is reserved for fund risk and
                          // destruction (tokens.dart) — a refusal to BUILD is
                          // neither, and red made a neutral sentence read as
                          // blame (§13; same call as create_screen.dart).
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: KvColor.warning,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: KvSpace.m),
              FilledButton(
                onPressed: _canReview ? _review : null,
                child: _building
                    ? const KvLoader.inline()
                    : const Text('Review'),
              ),
              if (widget.prepareSweep != null) ...[
                const SizedBox(height: KvSpace.xs),
                TextButton(
                  onPressed: _building ? null : _reviewSweep,
                  child: const Text('Send everything'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "Available: N KAS" — the spendable (mature) balance, informational only.
class _AvailableLine extends StatelessWidget {
  const _AvailableLine({required this.mature});

  final ValueListenable<BigInt?> mature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<BigInt?>(
      valueListenable: mature,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        final parts = kasParts(value);
        return Text(
          'Available: ${parts.integer}.${parts.fraction} KAS',
          style: theme.textTheme.bodySmall?.copyWith(
            color: KvColor.textTertiary,
          ),
        );
      },
    );
  }
}

/// "Minimum right now: ≈ N KAS" — the probed KIP-9 floor for the wallet's
/// current coin shape (D-054). Honest teaching line, not an enforcement point:
/// the Generator on Review remains the single authority.
class _MinimumLine extends StatelessWidget {
  const _MinimumLine({required this.minSompi});

  final BigInt minSompi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = kasParts(minSompi);
    return Text(
      'Minimum right now: ≈ ${parts.integer}.${parts.fraction} KAS '
      '(network anti-dust rule for your current coins)',
      style: theme.textTheme.bodySmall?.copyWith(color: KvColor.textTertiary),
    );
  }
}

/// The pasted address chunked in fours for a full-form review (BG-15) before it
/// is ever signed — the user can read it back against the source.
class _AddressReview extends StatelessWidget {
  const _AddressReview({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.sm),
      decoration: BoxDecoration(
        color: KvColor.surfaceAlt,
        borderRadius: BorderRadius.circular(KvRadius.data),
      ),
      child: Text(
        chunkAddress(address),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: KvFont.mono),
      ),
    );
  }
}
