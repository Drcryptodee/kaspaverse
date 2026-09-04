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
    this.selectable = false,
    this.onTap,
    this.plated = true,
  });

  /// The full address, scheme included.
  final String address;

  final KvAddressForm form;

  /// §2 gives the `address` role mono 13/22. Larger is legitimate on a surface
  /// whose whole job is reading it; smaller is not — 11dp is the floor.
  final double fontSize;

  /// Render the chunked form as selectable text, so it can also be copied by
  /// hand and compared against a source. Weighting is identical either way —
  /// selection is never bought by giving up the thing the form exists for.
  /// Ignored by the compact form. `copyFull` remains the sanctioned copy path.
  final bool selectable;

  /// **Whether the chunked form paints its own plate.**
  ///
  /// True is the shipped behaviour and what every surface built before UX-R2
  /// expects. The three Deep V6 surfaces that show an address in full — Receive
  /// inside its `chip` row, the ceremony inside its inner card, Send inside its
  /// field — place it in a container they already own, and a plate inside a
  /// plate is a second boundary saying nothing (BG-4).
  final bool plated;

  /// Tapping the rendered address fires this. It rides `SelectableText`'s own
  /// `onTap` in the selectable form rather than a wrapping `GestureDetector`,
  /// which would compete with the selection gestures for the same pointer —
  /// a tap copies, a long press still selects, and neither costs the other.
  /// The callback is expected to route through [copyFull]; this widget never
  /// narrows what a copy means. **Chunked form only** — the compact form is a
  /// one-line glance, not a control, and it is unwired on purpose.
  final VoidCallback? onTap;

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
  static const int tailGroup = addressTailGroup;

  /// The payload's groups, from [addressPayloadGroups] — the one implementation
  /// of the founder's ratified tail rule (D-223), which lives in the format
  /// layer because it governs **every** surface that chunks an address, not
  /// just this widget. This used to be a second copy of that logic, and while
  /// it carried the fix the Receive screen did not.
  @visibleForTesting
  static List<String> groupsOf(String address) => addressPayloadGroups(address);

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

  /// **Which groups carry the weight**, and it is one rule with two renderers.
  ///
  /// An address-poisoning attack has to buy a convincing *prefix* and a
  /// convincing *suffix*; the middle is where a mismatch is cheapest to hide
  /// and hardest to notice. So the first and last groups are the ones the eye
  /// is steered to, and they are the reason the tail keeps five characters
  /// instead of stranding one (D-223).
  static bool isWeightedGroup(int i, int count) => i == 0 || i == count - 1;

  /// **Both channels, and this one is a security affordance** ([[L150]]'s
  /// original victim, measured again 2026-09-04).
  ///
  /// D-223's head-and-tail weighting is the address-poisoning steer: an
  /// attacker must buy a convincing prefix *and* a convincing suffix, so the
  /// eye is pointed at both ends. On a variable face `fontWeight` is a hint and
  /// `FontVariation('wght', …)` is the ink, and an inline style merges over the
  /// ambient `DefaultTextStyle` — inheriting its axis. **So only the colour
  /// half ever rendered**, and the apparent bold was `ink` against `inkDim`:
  /// one channel doing the work of two, on the control that exists to make
  /// substitution visible.
  ///
  /// §2 and `ux-auditor` item 17 ask for **700** on the checkpoints and **500**
  /// on the middle, and **UX-R2 landed it** — the sitting §9 parked it for. The
  /// renders `S5`, `S6b` and `S7` all draw the two ends heavier than the run
  /// between them, and the merged axis is asserted rather than the enum.
  TextStyle _groupStyle(TextStyle base, int i, int count) => base.copyWith(
    fontWeight: isWeightedGroup(i, count) ? FontWeight.w700 : FontWeight.w500,
    fontVariations: isWeightedGroup(i, count) ? KvWeight.w700 : KvWeight.w500,
    color: isWeightedGroup(i, count) ? KvColor.ink : KvColor.inkDim,
  );

  /// **One mono run, wrapping — never spaced fours** (BG-15 as amended,
  /// D-223).
  ///
  /// The spaced-four rendering this replaces was the *v3* full form: on a phone
  /// width 61 payload characters in groups of four wrap into a ragged block
  /// whose line breaks move with the text scale, so the same address looks
  /// different every time it is shown — which is the one thing a form for
  /// **comparing against a source** may not do. A continuous run breaks at
  /// whatever character the width allows and the two weighted ends stay where
  /// the eye was taught to look. `S5`, `S6b` and `S7` all draw it this way.
  ///
  /// The groups survive as the *weighting* boundaries and as what a screen
  /// reader speaks; they simply no longer print a space.
  Widget _chunked() {
    final groups = groupsOf(address);
    final base = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: fontSize,
      height: 19 / 13,
    );
    // **The scheme takes `inkDim` when the caller owns the container**, and
    // that is §1.4's one standing obligation rather than a preference: the
    // unplated form is placed inside someone else's card, and every card that
    // hosts it is `chip`, where `inkMeta` measures **4.30** — under AA. The
    // labels beside it were moved for exactly this reason and the scheme was
    // the line left behind (`ux-auditor`, UX-R2).
    final schemeTone = plated ? KvColor.inkMeta : KvColor.inkDim;
    final spans = <TextSpan>[
      if (_scheme.isNotEmpty)
        TextSpan(
          text: _scheme,
          style: base.copyWith(color: schemeTone),
        ),
      for (var i = 0; i < groups.length; i++)
        TextSpan(text: groups[i], style: _groupStyle(base, i, groups.length)),
    ];
    final Widget body = selectable
        // `SelectableText.rich` rather than `Text.rich`, because a surface
        // whose job is comparing against a source wants hand-selection — and
        // it must not have to give up the weighting to keep it. A plain
        // `SelectableText` over a flat string cannot carry per-group weight,
        // which is how this screen once rendered all 67 characters at one
        // weight. Tapping copies; a long press still selects.
        ? SelectableText.rich(TextSpan(children: spans), onTap: onTap)
        : Text.rich(TextSpan(children: spans));
    final wrapped = Semantics(
      label: _spokenFull,
      button: onTap != null,
      excludeSemantics: true,
      // The non-selectable form has no gesture of its own to compete with, so
      // it takes the tap on its whole footprint rather than on the glyphs.
      // **The selectable form is excluded deliberately** — `SelectableText`
      // carries the tap above, and wrapping it too would put two recognisers
      // on one pointer.
      child: (onTap == null || selectable)
          ? body
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: body,
            ),
    );
    if (!plated) return wrapped;
    return KvSurface(
      tone: KvSurfaceTone.well,
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.m),
      child: wrapped,
    );
  }
}
