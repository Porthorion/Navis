import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pumpMenu(WidgetTester tester, {required bool improved}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDesktopContextMenu<void>(
                  context: context,
                  anchor: const Offset(450, 190),
                  items: <PopupMenuEntry<void>>[
                    const PopupMenuItem<void>(child: Text('Play now')),
                    const PopupMenuItem<void>(child: Text('Change quality')),
                    const PopupMenuItem<void>(child: Text('Add to Queue')),
                    const PopupMenuItem<void>(child: Text('Open folder')),
                    if (improved) const PopupMenuDivider(),
                    PopupMenuItem<void>(
                      textStyle: improved
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            )
                          : null,
                      child: const Text('Remove download'),
                    ),
                  ],
                ),
                child: const Text('More'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }

  testWidgets('downloaded track menu before treats remove as routine', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpMenu(tester, improved: false);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/downloaded_track_menu_before.png'),
    );
  });

  testWidgets('downloaded track menu after separates destructive removal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpMenu(tester, improved: true);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/downloaded_track_menu_after.png'),
    );
  });
}
