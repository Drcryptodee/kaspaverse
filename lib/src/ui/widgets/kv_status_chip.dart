import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The three tones a lamp is allowed to take (BG-7).
///
/// It is an enum rather than a [Color] on purpose: **teal is never a status**
/// (BG-2), and a lamp that cannot be handed [KvColor.primary] cannot become
/// one by accident. There is no informational hue and no fourth accent.
enum KvLampTone {
  /// Money arriving, and things confirmed, final, or switched on by the user
  /// (D-200).
  ok,

  /// Not yet certain: stale, syncing, settling, degraded, or blocked. Every
  /// validation block is amber — red on a validation nit claims money is at
  /// risk when none is.
  warn,

  /// Money leaving, or money at risk.
  risk,
}

extension KvLampToneTokens on KvLampTone {
  Color get color => switch (this) {
    KvLampTone.ok => KvColor.ok,
    KvLampTone.warn => KvColor.warn,
    KvLampTone.risk => KvColor.risk,
  };

  Color get bloom => switch (this) {
    KvLampTone.ok => KvColor.okBloom,
    KvLampTone.warn => KvColor.warnBloom,
    KvLampTone.risk => KvColor.riskBloom,
  };
}

/// A lamp: a 6dp dot under an 8dp blur with **no spread** (§1.5).
///
/// One of the only three things in the system that emit at all, and the only
/// one that is not teal. It is never alone — the words beside it carry the
/// meaning, so every state survives greyscale, colour-blindness and a screen
/// reader (BG-7). Decorative to semantics for exactly that reason.
class KvLamp extends StatelessWidget {
  const KvLamp(this.tone, {super.key});

  final KvLampTone tone;

  static const double size = 6;
  static const double blur = 8;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tone.color,
          // No spread. A lamp glows; it does not light the plate it sits on,
          // and a spread would be elevation wearing an emission's clothes.
          boxShadow: [BoxShadow(color: tone.bloom, blurRadius: blur)],
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
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: warm ? KvColor.noticeWarnFill : KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(
          color: warm ? KvColor.noticeWarnEdge : KvColor.plateDivider,
        ),
      ),
      child: row,
    );
  }
}
