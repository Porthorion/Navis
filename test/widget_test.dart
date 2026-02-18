import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:navis/src/app.dart';

void main() {
  testWidgets('shows bootstrap placeholder', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: NavisApp(),
      ),
    );

    expect(find.text('Navis Phase 0 Bootstrap'), findsOneWidget);
  });
}
