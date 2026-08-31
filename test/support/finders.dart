import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';

/// Finds a [KvRuledLabel] by the text it was **given**, not the text it draws.
///
/// Section labels are set in capitals (UX-5 device sitting). Asserting the
/// rendered string would restate the typography in a dozen test files and go
/// stale the next time it changes — and worse, every `findsNothing` written
/// against the old casing would start passing for the wrong reason. A finder
/// that reads the widget's own field cannot rot that way.
Finder findRuledLabel(String text) => find.byWidgetPredicate(
  (w) => w is KvRuledLabel && w.text == text,
  description: 'KvRuledLabel("$text")',
);

/// Finds a label the app sets in **capitals**, written here in the words the
/// design speaks. Section headings, table labels and status rows are all cased
/// by the widget rather than by the caller, so a test that spelled out
/// `'PENDING'` would be restating typography — and every `findsNothing` written
/// against the old casing would start passing for the wrong reason.
Finder findCapsLabel(String text) => find.text(text.toUpperCase());
