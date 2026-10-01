import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Widget content() => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(title: Text('Download Quality')),
      ListTile(title: Text('Original')),
      ListTile(title: Text('320 kbps')),
      ListTile(title: Text('192 kbps')),
      ListTile(title: Text('128 kbps')),
    ],
  );
  Future<void> pump(WidgetTester tester, {required bool desktop}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(Colors.deepPurple),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    if (desktop) {
                      showDialog<void>(
                        context: context,
                        builder: (_) => Dialog(
                          child: SizedBox(width: 440, child: content()),
                        ),
                      );
                    } else {
                      showModalBottomSheet<void>(
                        context: context,
                        builder: (_) => content(),
                      );
                    }
                  },
                  child: const Text('Choose quality'),
                ),
              ),
            ),
          ),
        ),
      );
  testWidgets('quality before sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, desktop: false);
    await tester.tap(find.text('Choose quality'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/download_quality_before.png'),
    );
  });
  testWidgets('quality after dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, desktop: true);
    await tester.tap(find.text('Choose quality'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/download_quality_after.png'),
    );
  });
}
