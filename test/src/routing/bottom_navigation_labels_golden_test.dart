import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pumpNavigationBar(
    WidgetTester tester, {
    required NavigationDestinationLabelBehavior labelBehavior,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(defaultColorSchemeSeedColor),
        home: Scaffold(
          body: const ColoredBox(color: Color(0xFF101010)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 1,
            labelBehavior: labelBehavior,
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('current mobile navigation hides destination names', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpNavigationBar(
      tester,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
    );

    await expectLater(
      find.byType(NavigationBar),
      matchesGoldenFile('goldens/bottom_navigation_labels_hidden.png'),
    );
  });

  testWidgets('updated mobile navigation names the selected destination', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpNavigationBar(
      tester,
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
    );

    await expectLater(
      find.byType(NavigationBar),
      matchesGoldenFile('goldens/bottom_navigation_selected_label.png'),
    );
  });
}
