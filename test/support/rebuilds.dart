import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// **Counts which widgets Flutter actually rebuilt** between two frames.
///
/// The V4 seam law — *each region listens only to what it renders* — is a claim
/// about rebuild scope, and until UX-R3's second beat nothing in the suite could
/// measure it: a screen that rebuilt its whole body on every chain tick passed
/// every finder-based test exactly as well as one that rebuilt one row. This
/// hooks the framework's own `debugOnRebuildDirtyWidget` (the same callback the
/// widget inspector's rebuild counter rides) and records, per widget type, how
/// many elements were rebuilt while an action ran.
///
/// It measures builds, not paints: a `RepaintBoundary` question is a different
/// instrument. And it is debug-only by construction, which every widget test is.
class RebuildLog {
  final Map<String, int> _counts = <String, int>{};
  RebuildDirtyWidgetCallback? _previous;

  /// Per-type rebuild counts recorded since the last [clear].
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// Total rebuilt elements, across every type.
  int get total => _counts.values.fold(0, (a, b) => a + b);

  /// How many elements of [type] (the widget's `runtimeType` name, private
  /// classes included, e.g. `_Head`) were rebuilt.
  int of(String type) => _counts[type] ?? 0;

  void install() {
    _previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
      _previous?.call(e, builtOnce);
      final name = e.widget.runtimeType.toString();
      _counts[name] = (_counts[name] ?? 0) + 1;
    };
  }

  void uninstall() {
    debugOnRebuildDirtyWidget = _previous;
    _previous = null;
  }

  void clear() => _counts.clear();
}

/// Run [act] and return the rebuilds it caused, **after** the tree has settled
/// from its own first build — so the numbers are the action's alone.
///
/// [frames] pumps that many frames after the action; one is enough for a
/// notifier-driven rebuild, an animation needs its duration pumped by the
/// caller instead.
Future<Map<String, int>> rebuildsDuring(
  WidgetTester tester,
  FutureOr<void> Function() act, {
  int frames = 1,
}) async {
  final log = RebuildLog()..install();
  try {
    await act();
    for (var i = 0; i < frames; i++) {
      await tester.pump();
    }
    return log.counts;
  } finally {
    log.uninstall();
  }
}
