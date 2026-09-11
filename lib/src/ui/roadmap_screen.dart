import 'package:flutter/material.dart';

import 'theme/tokens.dart';
import 'widgets/kv_chrome.dart';

/// **What a `PLANNED` destination says when you tap it.**
///
/// The withdrawn nav panel (D-190) drew four unbuilt destinations as one
/// milled block wearing engraved `PLANNED` tags, and the compact shape the
/// founder chose at D-193 dropped the one-line blurbs that explained them.
/// That decision carried a recorded dissent: *"agreements with no admin key"*
/// is the entire pitch of Contracts to someone who has never heard of a
/// covenant, and without it four of six destinations become words a stranger
/// cannot evaluate. The mitigation logged against UX-3 was that a `PLANNED`
/// destination, when tapped, is the right home for the explanation anyway.
///
/// This is that home, and it outlives the nav: the panel is void and a
/// Twitter-style push nav is coming from Claude Design, so the blurbs live on
/// a surface that no navigation shape can delete. When the push nav lands, its
/// roadmap block routes here rather than re-inventing the copy.
///
/// **It promises nothing.** Everything on this page is unbuilt, and the page
/// says so first, at the top, before naming a single one — a roadmap that
/// reads like a feature list is how a wallet ends up advertising things it
/// cannot do.
class RoadmapScreen extends StatelessWidget {
  const RoadmapScreen({super.key});

  /// The four seats the nav leaves open (§2 UX-3; P4+ in the phase index).
  /// One line each, in the voice of the person who has never heard of a
  /// covenant — that is the whole reason this page exists.
  static const List<({String name, String line})> destinations = [
    (
      name: 'Games',
      line: 'Play for stakes that settle on the chain. No house holds the pot.',
    ),
    (
      name: 'Contracts',
      line:
          'Agreements with no admin key. Nobody can change the terms — '
          'including us.',
    ),
    (
      name: 'Finance',
      line: 'Swaps and yield without handing your coins to a company first.',
    ),
    (
      name: 'Assets',
      line: 'Tokens and collectibles, held the way your KAS is held.',
    ),
  ];

  /// **Which one is actually being built.** `P3` is the covenant engine and
  /// the first covenant games on L1 are what it exists for (D-008/D-019), so
  /// Games is `Next` and everything else is `Planned`. A name, not a date:
  /// the project can keep an order and cannot keep a quarter, and `T6`'s
  /// status column may not carry a promise this repo cannot honour.
  static const String next = 'Games';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: "What's coming",
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  KvSpace.m,
                  KvSpace.gutter,
                  KvSpace.xxl,
                ),
                children: [
                  const Text(
                    'None of these exist yet. They are what this wallet is '
                    'being built toward, and they are here so you can see '
                    'where it is going — not so you can wait for them.',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 19 / 13,
                      color: KvColor.inkDim,
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),
                  // **One milled block, not four dead buttons** — the surviving
                  // constraint from the withdrawn panel (D-190). Four separate
                  // plates would read as four controls that do not work; one
                  // block with engraved tags reads as information about a
                  // shape, which is what it is.
                  Container(
                    decoration: BoxDecoration(
                      color: KvColor.plate,
                      borderRadius: BorderRadius.circular(KvRadius.plate),
                      border: Border.all(color: KvColor.plateEdge),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < destinations.length; i++) ...[
                          if (i > 0)
                            Container(height: 1, color: KvColor.hairline),
                          _Destination(destinations[i]),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination(this.destination);

  final ({String name, String line}) destination;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(KvSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  destination.name,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.inkDim,
                  ),
                ),
              ),
              const SizedBox(width: KvSpace.s),
              // Engraved, not badged: tracked caps in the smallest meta tone,
              // sitting IN the plate rather than on a pill above it. *"Not
              // yet" reads as information rather than as damage* (D-190).
              const Text(
                'PLANNED',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 11,
                  height: 16 / 11,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  letterSpacing: 1.6,
                  color: KvColor.inkMeta,
                ),
              ),
            ],
          ),
          const SizedBox(height: KvSpace.xs),
          Text(
            destination.line,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 17 / 12,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ),
    );
  }
}
