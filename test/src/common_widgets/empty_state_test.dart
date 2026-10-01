import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/empty_state.dart';

void main() {
  testWidgets('renders an optional user-controlled action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            title: 'Unavailable',
            action: OutlinedButton(
              key: ValueKey<String>('return-to-library'),
              onPressed: null,
              child: Text('Back to Library'),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('return-to-library')),
      findsOneWidget,
    );
  });
}
