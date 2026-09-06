import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **Reading room: how a section takes more of the screen when someone starts
/// reading it, and gives it back when they stop.**
///
/// The founder asked for this as a house behaviour rather than a screen's
/// (2026-09-06): *"i want expansive scrolls to behave this way… so basically if
/// the section has more space above it, scrolling to see more expands and
/// pushes whatever is above it up whilst keeping the above thing in view… but
/// if there is more space below, it pushes what's below down, keeping a little
/// view of what it pushed down… and a scroll the other way snaps things back."*
///
/// ## The three parts, and which one you need
///
/// * [KvReadingArea] wraps the **scrollable**. It is the only thing that
///   decides someone is reading, and the only thing that decides they have
///   stopped.
/// * [KvYields] wraps content that **gives way** — for a section with room
///   ABOVE it. The yielder collapses and the section rises into what it left.
/// * [KvExpands] wraps the **section itself** — for a section with room BELOW
///   it. Its cap grows and everything under it is pushed down.
///
/// A screen uses one or both. `T4 · Wallet`'s address card expands downward
/// (Tools is pushed and stays half in view); the home feed makes the money
/// plate yield upward (the balance stays, the chain clock goes).
///
/// ## The gesture contract, which is the part that must not vary
///
/// **Forward drag inside the section advances it. Resting at the section's own
/// top returns it.** Not "any upward drag" — a section that shrank halfway
/// through a list would move rows out from under the thumb reading them, and
/// the top is the one position a user unambiguously means *done*. The
/// threshold is small enough to feel immediate and large enough that a thumb
/// resting on a row while tapping it does not resize the screen underneath.
///
/// **Only the section's own scroll counts.** A page scroll bubbles through the
/// same listener, and a page drag must never resize a card inside it.
///
/// ## The two stops
///
/// [KvReadingLevel.reading] is what a **scroll** reaches — one step, enough to
/// be worth the gesture and never so much that the screen reorganises itself
/// under a thumb. [KvReadingLevel.full] is what an explicit **control**
/// reaches, and only a control: it is a bigger change than a drag should be
/// able to make by accident. On the home screen `All` is that control.
///
/// Reduced motion collapses every duration here to zero and changes no
/// behaviour (BG-9).
enum KvReadingLevel {
  /// Nothing has been read yet: every yielder is open, every cap is at rest.
  rest,

  /// Someone is scrolling the section. Yielders marked `reading` have closed.
  reading,

  /// A control asked for the section outright. Every yielder has closed.
  full;

  /// Whether this level has reached [at] — so a yielder can say the one level
  /// it closes at and be right at every level above it.
  bool reaches(KvReadingLevel at) => index >= at.index;
}

/// Carries the level for one screen. Read it with [KvReadingScope.of].
class KvReadingController extends ValueNotifier<KvReadingLevel> {
  KvReadingController() : super(KvReadingLevel.rest);

  /// A scroll advances **one** step and never past it — see the class doc.
  void read() {
    if (value == KvReadingLevel.rest) value = KvReadingLevel.reading;
  }

  /// A control asks for the whole thing.
  void openFully() => value = KvReadingLevel.full;

  /// The section came back to rest at its top.
  void done() => value = KvReadingLevel.rest;
}

/// Puts a [KvReadingController] over a subtree.
class KvReadingScope extends StatefulWidget {
  const KvReadingScope({
    super.key,
    required this.builder,
    this.controller,
    this.onChanged,
  });

  final Widget Function(BuildContext context, KvReadingController reading)
  builder;

  /// A controller the screen owns, when it needs to reach the level from
  /// outside the builder — the home screen's `All` does. Null ⇒ the scope owns
  /// one, which is the ordinary case.
  final KvReadingController? controller;

  /// Told whenever the level changes — for a screen that has to do something
  /// besides rebuild, such as scrolling its rows back to the top.
  final ValueChanged<KvReadingLevel>? onChanged;

  static KvReadingController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_KvReadingInherited>();
    assert(scope != null, 'no KvReadingScope above this KvYields / KvExpands');
    return scope!.controller;
  }

  @override
  State<KvReadingScope> createState() => _KvReadingScopeState();
}

class _KvReadingScopeState extends State<KvReadingScope> {
  late final KvReadingController _controller =
      widget.controller ?? KvReadingController();
  KvReadingLevel _last = KvReadingLevel.rest;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onLevel);
  }

  void _onLevel() {
    if (_controller.value == _last) return;
    _last = _controller.value;
    widget.onChanged?.call(_last);
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onLevel);
    // Only what this scope made. A controller the screen owns outlives the
    // scope and is disposed by the state that holds it.
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _KvReadingInherited(
    controller: _controller,
    level: _controller.value,
    child: Builder(builder: (context) => widget.builder(context, _controller)),
  );
}

class _KvReadingInherited extends InheritedWidget {
  const _KvReadingInherited({
    required this.controller,
    required this.level,
    required super.child,
  });

  final KvReadingController controller;

  /// Held separately so `updateShouldNotify` compares a VALUE. Comparing the
  /// controller compares one identity against itself and never notifies.
  final KvReadingLevel level;

  @override
  bool updateShouldNotify(_KvReadingInherited old) => old.level != level;
}

/// **The system back gesture undoes a reading level before it leaves the
/// screen.**
///
/// A section that has taken the screen is a state the user got into, so it is
/// a state back should get them out of — and on Android that is the gesture
/// people reach for first. Wrap the screen (not the section) in this.
///
/// It returns to [KvReadingLevel.rest] in one step, whatever level it was at,
/// because that is what every other way back does; and it changes **nothing
/// else**, so whichever tab or filter the section was showing is still showing
/// when the band comes back. The founder asked for exactly that: *"using the
/// phone's back button goes back to the less but still showing where the user
/// is, whether tokens or activity."*
class KvReadingBackGesture extends StatelessWidget {
  const KvReadingBackGesture({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reading = KvReadingScope.of(context);
    final atRest = reading.value == KvReadingLevel.rest;
    return PopScope(
      // At rest there is nothing to undo, so back means back and the route
      // pops as it always did.
      canPop: atRest,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) reading.done();
      },
      child: child,
    );
  }
}

/// Wraps the scrollable whose reading drives the screen.
///
/// It reports; it decides nothing about layout. What gives way, and by how
/// much, belongs to [KvYields] and [KvExpands].
class KvReadingArea extends StatelessWidget {
  const KvReadingArea({super.key, required this.child});

  final Widget child;

  /// How far the section must be dragged before it counts as being read.
  static const double threshold = 6;

  @override
  Widget build(BuildContext context) {
    final reading = KvReadingScope.of(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Only this section's own scroll — a page drag bubbles through here
        // too, and must never resize a card inside it.
        if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
        switch (n) {
          case ScrollUpdateNotification(:final dragDetails, :final scrollDelta):
            if (dragDetails != null &&
                (scrollDelta ?? 0) > 0 &&
                n.metrics.pixels > threshold) {
              reading.read();
            }
            if (n.metrics.pixels <= 0) reading.done();
          case OverscrollNotification(:final dragDetails, :final overscroll):
            if (dragDetails != null && overscroll > 0) reading.read();
          case ScrollEndNotification():
            if (n.metrics.pixels <= 0) reading.done();
          default:
            break;
        }
        return false;
      },
      child: child,
    );
  }
}

/// Content that **gives way** so the section below it can rise.
///
/// `keep` is what stays visible when it closes — the founder's *"keeping the
/// above thing in view, even if its a little view"*. Zero means it goes
/// entirely, which is what the home plate does at [KvReadingLevel.full].
class KvYields extends StatelessWidget {
  const KvYields({
    super.key,
    required this.child,
    this.from = KvReadingLevel.reading,
    this.keep = 0,
  });

  final Widget child;

  /// The level at which this closes. It stays closed at every level above.
  final KvReadingLevel from;

  /// Height left behind when closed.
  final double keep;

  @override
  Widget build(BuildContext context) {
    final closed = KvReadingScope.of(context).value.reaches(from);
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : KvMotion.calm,
      curve: KvMotion.out,
      // From the top, so the collapse runs upward and whatever sits ABOVE this
      // never moves — only what is below rises.
      alignment: Alignment.topCenter,
      child: closed
          // `double.infinity` for D-263's reason: a start-aligned column lays
          // a width-less box out at zero and the animation snaps.
          ? SizedBox(width: double.infinity, height: keep)
          : child,
    );
  }
}

/// A section that **grows into the room below it**, under a stated cap.
///
/// The cap is what keeps the founder's *"a little view of what it pushed
/// down"* true: the section takes more, never all, so whatever follows stays
/// on the screen as a hint that there is more page.
class KvExpands extends StatelessWidget {
  const KvExpands({
    super.key,
    required this.child,
    required this.rest,
    required this.reading,
    double? full,
  }) : _full = full;

  final Widget child;

  /// The cap before anyone has read it.
  final double rest;

  /// The cap while it is being scrolled.
  final double reading;

  final double? _full;

  /// The cap a control can ask for; defaults to [reading].
  double get full => _full ?? reading;

  @override
  Widget build(BuildContext context) {
    final level = KvReadingScope.of(context).value;
    final cap = switch (level) {
      KvReadingLevel.rest => rest,
      KvReadingLevel.reading => reading,
      KvReadingLevel.full => full,
    };
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : KvMotion.calm,
      curve: KvMotion.out,
      constraints: BoxConstraints(maxHeight: cap),
      child: child,
    );
  }
}

/// **A fade at the edge of a scroll, and only while there is more past it.**
///
/// The founder asked for it (2026-09-06): *"what can we do to signify when a
/// scrollable container has more contents below to scroll? … it's just a bottom
/// part that signifies more scrollable contents below."*
///
/// ## Why a gradient is lawful here — BG-4, as narrowed (D-290 · D-292)
///
/// BG-4 reads **no gradient as DECORATION**, ratified 2026-09-06 after this
/// part was proposed as a divergence rather than slipped in. The clause always
/// meant decoration — every example it gives is a surface treatment faking
/// depth the tone ladder already carries — and the rule now carries its own
/// test:
///
/// > *Would this mark still be drawn if the content changed so that it were
/// > false?* If yes, it is decoration and BG-4 forbids it. If it would
/// > disappear, it is a reading and **BG-8** owns it.
///
/// This disappears: it is the only mark on the screen that answers *is there
/// more?*, it is painted in the container's **own ground colour** so it adds no
/// hue, no light and no material, and a list with nothing below it has none.
///
/// **The blur clause is untouched** and a blur stays refused: its objections are
/// cost and legibility inside a moving list, and neither depended on the
/// gradient clause.
///
/// ## Honest, or absent
///
/// It is driven by the scroll's own metrics and eased in and out (BG-24), so a
/// list with nothing below it has no fade, a list scrolled to its end loses it,
/// and a list that grows under a live update gains one. A permanent fade
/// painted "because lists scroll" would be the decoration BG-4 forbids and a
/// claim BG-8 forbids — it would say *there is more* over the last row.
class KvScrollEdge extends StatefulWidget {
  const KvScrollEdge({
    super.key,
    required this.child,
    required this.ground,
    this.height = 28,
  });

  final Widget child;

  /// The colour the fade resolves to — **the container's own ground**, passed
  /// rather than guessed, because a card is `plate` and a page is `abyss` and
  /// a fade to the wrong one is a smear.
  final Color ground;

  /// How tall the fade is. 28 dp is a little under half a row: enough to read
  /// as an edge, not enough to hide the row it sits over.
  final double height;

  /// Below this many dp left to scroll, the edge is gone — a couple of pixels
  /// of remaining extent is the end of the list, not more content.
  static const double _slack = 4;

  @override
  State<KvScrollEdge> createState() => _KvScrollEdgeState();
}

class _KvScrollEdgeState extends State<KvScrollEdge> {
  bool _more = false;

  bool _update(ScrollMetrics m) {
    final more =
        m.axis == Axis.vertical &&
        m.maxScrollExtent - m.pixels > KvScrollEdge._slack;
    if (more != _more) {
      // The metrics arrive during layout, so the rebuild waits for the frame
      // to finish rather than setting state inside it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && more != _more) setState(() => _more = more);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _update(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => n.depth == 0 ? _update(n.metrics) : false,
        child: Stack(
          children: [
            widget.child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: widget.height,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : KvMotion.fast,
                  curve: KvMotion.curve,
                  opacity: _more ? 1 : 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          widget.ground.withValues(alpha: 0),
                          widget.ground,
                        ],
                        // Weighted late, so the row under it stays readable
                        // for most of the band and only the last few dp go.
                        stops: const [0, 0.85],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
