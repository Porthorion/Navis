import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';

void main() {
  testWidgets('shows phase 0 bootstrap shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: NavisApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Navis Phase 0 Bootstrap'), findsOneWidget);
  });
}
