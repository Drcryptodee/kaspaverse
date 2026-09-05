import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The tones a lamp is allowed to take (§4, BG-7).
///
/// It is an enum rather than a [Color] on purpose: **teal is never a status**
/// (BG-2), and a lamp that could be handed [KvColor.primary] freely would
/// become one by accident. [live] is the single, named exception — BG-2 lists
/// *the live dot* among `primary`'s permitted appearances, and it says
/// "the link is up right now", which is not a state of the user's money.
/// There is no informational hue and no fourth accent.
enum KvLampTone {
  /// **The live dot.** [KvColor.primary] on a [KvColor.tealTint] ring, and the
  /// one lamp that pulses (BG-9's first ambient loop). It counts against
  /// BG-2's cap of three.
  live,

  /// Money arriving, accepted on chain, switched on by the user, **link
  /// healthy** (BG-7 as amended v4.3 — the D-200 narrowing that took link
  /// health away from `ok` is gone).
  ok,

  /// Not yet certain: pending, stale, syncing, degraded, or blocked. Every
  /// validation block is amber — red on a validation nit claims money is at
  /// risk when none is.
  warn,

  /// Money leaving, or money at risk.
  risk,
}

extension KvLampToneTokens on KvLampTone {
  Color get color => switch (this) {
    KvLampTone.live => KvColor.primary,
    KvLampTone.ok => KvColor.ok,
    KvLampTone.warn => KvColor.warn,
    KvLampTone.risk => KvColor.risk,
  };

  /// The ring the disc sits in — the hue's own tint (§4). **Not a bloom**:
  /// BG-32 seats exactly two glowing things and a lamp is neither of them.
  Color get ring => switch (this) {
    KvLampTone.live => KvColor.tealTint,
    KvLampTone.ok => KvColor.okTint,
    KvLampTone.warn => KvColor.warnTint,
    KvLampTone.risk => KvColor.riskTint,
  };
}

/// **A lamp is a disc, not a bloom** (BG-32).
///
/// An 8 dp disc of the tone inside a 3 dp ring of its tint (§4) — 14 dp
/// overall. Under Black Glass it was a 6 dp dot under an 8 dp blur; BG-32 now
/// seats exactly two glowing things in the whole app (the orb's halo and an
/// armed control's edge) and a lamp is neither, so the bloom is gone and the
/// ring carries the presence it was doing badly.
///
/// It is never alone — the words beside it carry the meaning, so every state
/// survives greyscale, colour-blindness and a screen reader (BG-7). Decorative
/// to semantics for exactly that reason.
class KvLamp extends StatelessWidget {
  const KvLamp(KvLampTone this.tone, {super.key}) : _color = null, _ring = null;

  /// **A lamp in a hue the three-signal vocabulary does not carry** — the
  /// burial ladder's `settled` blue, and a rung's hue mid-crossfade. D-248
  /// fences that hue out of [KvLampTone] on purpose (a fourth member is how
  /// a fenced hue escapes), so the lamp takes a colour and its ring directly
  /// rather than the ladder drawing a second lamp of its own (item 33).
  const KvLamp.hued({super.key, required Color color, required Color ring})
    : tone = null,
      _color = color,
      _ring = ring;

  final KvLampTone? tone;
  final Color? _color;
  final Color? _ring;

  /// The disc's colour.
  Color get color => _color ?? tone!.color;

  /// The ring's colour.
  Color get ringColor => _ring ?? tone!.ring;

  /// The disc (§4).
  static const double size = 8;

  /// The ring around it.
  static const double ring = 3;

  /// The whole lamp's footprint — what a caller reserves space for.
  static const double extent = size + ring * 2;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: extent,
        height: extent,
        decoration: BoxDecoration(shape: BoxShape.circle, color: ringColor),
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
      ),
    );
  }
}

/// **Lamp plus words, always both** (§4). Information is colourless: the words
/// are [KvColor.inkDim] whatever the lamp is doing, which is what holds every
/// string at AA and makes a fault read as *an indicator coming on* rather than
/// as coloured text (§1.5).
///
/// [plated] wraps the row in an earned container for a state that must persist
/// rather than pass — money in flight, a degraded link. The plate stays plain
/// with only its edge tinted to the hue, and **only amber has a tinted plate**:
/// §1.6 names exactly four tinted surfaces in the whole system and
/// `noticeWarnFill`/`noticeWarnEdge` is the only value-hued pair among them.
/// An `ok` or `risk` plate is therefore neutral and the lamp carries the hue
/// alone — inventing a green or red plate would break BG-3.
class KvStatusChip extends StatelessWidget {
  const KvStatusChip({
    super.key,
    required this.tone,
    required this.words,
    this.trailing,
    this.plated = false,
    this.maxLines = 1,
  });

  final KvLampTone tone;

  /// Plain English. Never a code, never a hue's name.
  final String words;

  /// Sits at the end of the row — a [KvCadence] on a trust line, an amount on
  /// an in-flight line.
  final Widget? trailing;

  final bool plated;

  /// One line for a status line; unbounded (null) for a notice that explains.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        KvLamp(tone),
        const SizedBox(width: KvSpace.s),
        Expanded(
          child: Text(
            words,
            maxLines: maxLines,
            overflow: maxLines == null
                ? TextOverflow.clip
                : TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkDim,
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: KvSpace.s), trailing!],
      ],
    );

    if (!plated) return row;

    // Amber gets the one named warm plate; everything else stays neutral.
    final warm = tone == KvLampTone.warn;
    return Container(
      width: double.infinity,
      // **Slim** (founder, on glass 2026-09-04: *"that chip height is kinda
      // fat but i would rather want it slim so there isnt unnecessary space in
      // the backgound of the text"*). 10 dp of air around a 19 dp line is a
      // notice; 12 with a 28 dp radius was a plate wearing a notice's job —
      // and on Send it was pushing the amber line toward the keypad.
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s14,
        vertical: KvSpace.s10,
      ),
      decoration: BoxDecoration(
        color: warm ? KvColor.noticeWarnFill : KvColor.chip,
        // §4's notice radius, not the plate's — the shape follows the box.
        borderRadius: BorderRadius.circular(KvRadius.notice),
        border: Border.all(
          color: warm ? KvColor.noticeWarnEdge : KvColor.plateDivider,
        ),
      ),
      child: row,
    );
  }
}
