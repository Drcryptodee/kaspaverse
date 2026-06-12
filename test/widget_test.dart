import 'package:flutter_test/flutter_test.dart';

import 'package:kaspaverse/main.dart';

void main() {
  testWidgets('renders the rust bridge proof string', (tester) async {
    await tester.pumpWidget(const KaspaVerseApp(bridgeProof: 'bridge-ok'));

    expect(find.text('KaspaVerse'), findsOneWidget);
    expect(find.text('bridge-ok'), findsOneWidget);
  });
}
