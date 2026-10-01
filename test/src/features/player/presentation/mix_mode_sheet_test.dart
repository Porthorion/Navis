import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mix action helper no longer opens a chooser sheet', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(database),
        child: MaterialApp(
          theme: testTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showMixModeSheet(context, seedSongId: 'seed'),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
