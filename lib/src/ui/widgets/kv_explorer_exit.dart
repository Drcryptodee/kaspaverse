import 'package:flutter/material.dart';

import '../error_text.dart';
import '../theme/tokens.dart';
import 'haptics.dart';
import 'kv_glyph.dart';
import 'kv_surface.dart';

/// **The explorer exit, and it discloses what it hands over** (§5, D-192 as
/// amended D-207).
///
/// This is the only place in the wallet that deliberately sends a user's
/// business to a third party, so *"view in an explorer"* cannot be the whole
/// sentence. Two things are on the glass **before** the tap, never after it:
///
///  * **the destination, by name.** "An explorer" is not a sovereignty
///    decision — the user chose a host in Settings, and the exit says which one
///    they chose. The template is user-editable (`{txid}` / `{address}`) with
///    two audited defaults, because a list only we can edit is not a
///    sovereignty decision either.
///  * **what it will see**: the identifier being looked up, and the user's own
///    network address — which they hand over simply by asking. The wallet never
///    phones home (INV-8); this is the one egress the user fires themselves,
///    and it is worth saying out loud that firing it is not free.
///
/// **No URL is built here.** The link comes back from Rust, where
/// `validate_template` requires `https://`, refuses credentials in the
/// authority, and requires the placeholder to sit in the **path** — a template
/// like `https://{txid}.example` would post the identifier as a DNS query to
/// whoever runs that suffix, which is a leak invisible in the string the user
/// typed. The host below is read off the resolved URL for display and nothing
/// else.
///
/// **A refused template is a state with its own face** (BG-20/BG-12): if the
/// stored link no longer validates, Rust keeps it rather than silently
/// substituting ours — a user who replaced the vendor must never be quietly
/// returned to it — so the control disables itself and prints the reason Rust
/// gave, which names what to fix.
class KvExplorerExit extends StatefulWidget {
  const KvExplorerExit({
    super.key,
    required this.subject,
    required this.resolve,
    required this.open,
  });

  /// The identifier being looked up — a txid or an address. Public chain data
  /// either way; the disclosure is about who gets to watch you ask.
  final String subject;

  /// Resolves [subject] to the exact URL this wallet would open. Injected so
  /// the widget renders in a test without the native library, and so nothing
  /// on this side is tempted to build one.
  final Future<String> Function(String subject) resolve;

  /// Hands a resolved URL to the platform. `false` means the phone has no
  /// browser at all — a fact about the device, said plainly.
  final Future<bool> Function(String url) open;

  @override
  State<KvExplorerExit> createState() => _KvExplorerExitState();
}

class _KvExplorerExitState extends State<KvExplorerExit> {
  String? _url;
  String? _refusal;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(KvExplorerExit old) {
    super.didUpdateWidget(old);
    if (old.subject != widget.subject) _resolve();
  }

  Future<void> _resolve() async {
    try {
      final url = await widget.resolve(widget.subject);
      if (!mounted) return;
      // **A destination it cannot NAME is refused here, not rendered as a
      // half-state.** `validate_template` requires https and a non-empty
      // authority and refuses credentials, but never checks the authority
      // parses as a host: `https://:8080/txs/{txid}` passes Rust and arrives
      // with an empty host. Resolved-but-nameless is a refusal, so it takes the
      // refusal face rather than falling through to the still-resolving one
      // (`consensus-auditor`, UX-5). Tightening `validate_template` to reject
      // an unparseable authority is the better layer; this end fails closed
      // regardless.
      final named = (Uri.tryParse(url)?.host ?? '').isNotEmpty;
      setState(() {
        _url = named ? url : null;
        _refusal = named ? null : 'it does not name a site';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _url = null;
        _refusal = displayError(e);
      });
    }
  }

  Future<void> _go() async {
    final url = _url;
    if (url == null) return;
    KvHaptic.selection();
    // **The platform can throw, and an unhandled throw out of `onTap` is a
    // control that visibly does nothing** — the exact BG-12 shape this widget
    // exists to eliminate. `openUrl` answers `false` for a phone with no
    // browser, which is handled; a `SecurityException` takes the channel's
    // generic error branch and arrives here as a `PlatformException`
    // (`consensus-auditor`, UX-5).
    var threw = false;
    try {
      if (await widget.open(url)) return;
    } catch (_) {
      // The platform's own code and message are not actionable for a user —
      // what they can act on is that the link did not open. They are not
      // swallowed silently either: the channel logs, and the alternative was an
      // unhandled zone error out of `onTap` and a control that visibly does
      // nothing.
      threw = true;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          threw
              ? 'The link could not be opened.'
              : 'This phone has no browser to open the link with.',
        ),
        duration: KvMotion.toast,
      ),
    );
  }

  /// The destination, by name. Read off the resolved URL rather than off the
  /// template, so what is shown is the authority the intent will actually
  /// reach.
  String get _host => Uri.tryParse(_url ?? '')?.host ?? '';

  @override
  Widget build(BuildContext context) {
    final refusal = _refusal;
    final url = _url;
    // Three states, three faces (BG-20). Resolving is not a control yet: a
    // card that looked live and did nothing when tapped would teach the user
    // that controls on this screen are unreliable.
    final (String head, String body, bool live) = switch ((url, refusal)) {
      // A destination the exit cannot name is never live: `_resolve` has
      // already turned that into a refusal (D-192 — a departure you cannot
      // name is not one you consented to).
      (final u?, _) when u.isNotEmpty && _host.isNotEmpty => (
        'View on $_host',
        'Shares the transaction ID and your IP address',
        true,
      ),
      (_, final r?) => (
        'The explorer link cannot be used',
        '$r — set it in Settings',
        false,
      ),
      _ => ('View in an explorer', 'reading your explorer choice…', false),
    };

    final card = KvSurface(
      tone: KvSurfaceTone.chip,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  head,
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 19 / 13,
                    fontWeight: FontWeight.w500,
                    color: live ? KvColor.ink : KvColor.inkMeta,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 11,
                    height: 15 / 11,
                    color: KvColor.inkMetaLow,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          // The chevron says "this goes somewhere", and it is drawn rather than
          // borrowed (BG-25). `etch` while there is nowhere to go, because a
          // dead affordance must not look live — the words carry the reason.
          KvGlyphIcon(
            KvGlyph.chevron,
            tone: live ? KvColor.inkNav : KvColor.etch,
            size: 20,
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: live,
      label: '$head. $body',
      excludeSemantics: true,
      child: live
          ? InkWell(
              onTap: _go,
              borderRadius: BorderRadius.circular(KvRadius.chip),
              // Grey press, no ripple — the house gesture language (BG-21).
              // The theme's default splash is `glow`, which is teal, and teal
              // is light rather than paint (BG-2).
              highlightColor: KvColor.keyPressed,
              splashFactory: NoSplash.splashFactory,
              child: card,
            )
          : card,
    );
  }
}
