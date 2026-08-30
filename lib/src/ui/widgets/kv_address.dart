import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../theme/tokens.dart';
import 'kv_surface.dart';

/// Two forms of one address, for two different jobs (D-198).
enum KvAddressForm {
  /// For a glance: scheme + first 8 + last 8 of the **payload**.
  compact,

  /// For checking character by character: the whole address in groups of four,
  /// first and last weighted.
  chunked,
}

/// BG-15 identity: **verified, not vibed.**
///
/// The widget takes the **full** address and computes the form it renders. It
/// does not trust a caller to hand it a pre-truncated string, because the
/// device caught exactly that: a compact address re-ellipsized by the row it
/// sat in, leaving `kaspa:q…` — the shape that spends the entire truncation
/// budget on the scheme and is a gift to address-poisoning. A debug assert
/// makes the mistake loud rather than subtle.
///
/// Truncation counts *payload* entropy, so the eye lands where an attack has
/// to succeed: a poisoned address buys a prefix and a suffix that look right,
/// and the first and last groups are the ones weighted for that reason.
///
/// An address is public data — INV-1 governs secrets — so rendering, chunking
/// and copying it are all safe. [copyFull] is the only copy path, and it exists
/// so that "copy copies all 67 characters" is structural rather than a habit.
class KvAddress extends StatelessWidget {
  const KvAddress(
    this.address, {
    super.key,
    this.form = KvAddressForm.compact,
    this.fontSize = 13,
  });

  /// The full address, scheme included.
  final String address;

  final KvAddressForm form;

  /// §2 gives the `address` role mono 13/22. Larger is legitimate on a surface
  /// whose whole job is reading it; smaller is not — 11dp is the floor.
  final double fontSize;

  /// **The one copy path for an address**: it copies the whole string, always.
  /// A surface that offers "copy" calls this and cannot narrow it.
  static Future<void> copyFull(String address) {
    assert(
      !address.contains('…'),
      'Copy copies all 67 characters (BG-15) — a truncated address must never '
      'reach the clipboard.',
    );
    return Clipboard.setData(ClipboardData(text: address));
  }

  /// How many characters the FINAL group keeps, whole (D-223, founder,
  /// ratified 2026-08-30).
  static const int tailGroup = 5;

  /// The payload, split into groups of four — **except the last, which keeps
  /// five characters together.**
  ///
  /// Chunking purely in fours left a 61-character payload ending
  /// `… c6jz qunt h`: a one-character final group, weighted bold, sitting
  /// alone. The weighting exists so the eye lands where an address-poisoning
  /// attack has to succeed, and a single stranded character is the weakest
  /// possible place to put it — there is almost nothing there to compare. The
  /// tail is now `… c6jz qunth`, five characters, bold as one piece.
  ///
  /// The remainder is chunked from the LEFT so the short group, when a payload
  /// length produces one, falls next to the tail rather than splitting it: a
  /// 61-character payload gives fourteen fours and the five; a 63-character
  /// ECDSA payload gives fourteen fours, a two, and the five.
  @visibleForTesting
  static List<String> groupsOf(String address) {
    final payload = address.substring(address.indexOf(':') + 1);
    if (payload.length <= tailGroup) return [payload];
    final head = payload.substring(0, payload.length - tailGroup);
    final out = <String>[];
    for (var i = 0; i < head.length; i += 4) {
      out.add(head.substring(i, math.min(i + 4, head.length)));
    }
    out.add(payload.substring(payload.length - tailGroup));
    return out;
  }

  String get _scheme {
    final sep = address.indexOf(':');
    return sep >= 0 ? address.substring(0, sep + 1) : '';
  }

  /// "address ending 3 f 4 a 2" — spaced so a screen reader names each
  /// character instead of guessing at a word (§4's Address row; BG-14 requires
  /// every meaning to survive being spoken).
  String get _spokenTail {
    final sep = address.indexOf(':');
    final payload = sep >= 0 ? address.substring(sep + 1) : address;
    final tail = payload.length >= 5
        ? payload.substring(payload.length - 5)
        : payload;
    return 'address ending ${tail.split('').join(' ')}';
  }

  /// The chunked form's job is character-by-character comparison, so it speaks
  /// the whole thing: the scheme, then each group of four spelt out.
  String get _spokenFull {
    final groups = groupsOf(
      address,
    ).map((g) => g.split('').join(' ')).join(', ');
    return 'address ${_scheme.replaceAll(':', '')}, $groups';
  }

  @override
  Widget build(BuildContext context) {
    // The guard lives here rather than in the (const) constructor because a
    // const initializer cannot call `contains`. It fires in debug all the
    // same, which is where a doubly-truncated address gets caught.
    assert(
      !address.contains('…'),
      'KvAddress computes the compact form itself — pass the full address, '
      'never one already truncated (BG-15: a doubly-truncated address is the '
      'kaspa:q… shape the law forbids).',
    );
    return switch (form) {
      KvAddressForm.compact => _compact(),
      KvAddressForm.chunked => _chunked(),
    };
  }

  Widget _compact() {
    final compact = truncateAddressPayload(address);
    final sep = compact.indexOf(':');
    final scheme = sep >= 0 ? compact.substring(0, sep + 1) : '';
    final payload = sep >= 0 ? compact.substring(sep + 1) : compact;
    final base = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: fontSize,
      height: 22 / 13,
    );
    // It SCALES DOWN rather than losing characters, exactly as an amount
    // does — because the characters a narrow box would take are the last
    // eight of the payload, which is the entropy the compact form exists
    // to keep. Clipping loses them silently; an ellipsis loses them and
    // looks correct doing it. Neither is acceptable, so neither happens.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: [
            if (scheme.isNotEmpty)
              TextSpan(
                text: scheme,
                style: base.copyWith(color: KvColor.inkMeta),
              ),
            TextSpan(
              text: payload,
              style: base.copyWith(color: KvColor.ink),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
        softWrap: false,
        semanticsLabel: _spokenTail,
      ),
    );
  }

  Widget _chunked() {
    final groups = groupsOf(address);
    final base = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: fontSize,
      height: 20 / 13,
    );
    return Semantics(
      label: _spokenFull,
      excludeSemantics: true,
      child: KvSurface(
        tone: KvSurfaceTone.well,
        width: double.infinity,
        padding: const EdgeInsets.all(KvSpace.m),
        child: Wrap(
          spacing: KvSpace.s,
          runSpacing: KvSpace.xs,
          children: [
            if (_scheme.isNotEmpty)
              Text(_scheme, style: base.copyWith(color: KvColor.inkMeta)),
            for (var i = 0; i < groups.length; i++)
              Text(
                groups[i],
                style: base.copyWith(
                  fontWeight: (i == 0 || i == groups.length - 1)
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: (i == 0 || i == groups.length - 1)
                      ? KvColor.ink
                      : KvColor.inkDim,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
