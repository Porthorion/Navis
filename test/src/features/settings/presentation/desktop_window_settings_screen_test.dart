import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/presentation/desktop_window_settings_screen.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';

void main() {
  testWidgets('desktop window screen shows unavailable state outside desktop', (
    tester,
  ) async {
    const nonDesktopContext = AdaptiveContext(
      desktopRuntime: false,
      desktopWide: false,
      desktopLayoutClass: DesktopLayoutClass.compactDesktop,
      adaptiveLayoutClass: AdaptiveLayoutClass.tabletExpanded,
      adaptiveShellMode: AdaptiveShellMode.standardRail,
      isPhoneFormFactor: false,
      useDesktopShell: false,
      useStandardRailNavigation: true,
      useCompactWideLandscape: false,
      useRailNavigation: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AdaptiveContextScope(
            adaptiveContext: nonDesktopContext,
            child: const DesktopWindowSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Desktop window controls are only available in the desktop app.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('desktop window screen toggles focus mode', (tester) async {
    final controller = DesktopWindowController.fallback(desktopRuntime: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWindowControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: DesktopWindowSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Focus Player Mode'), findsOneWidget);
    expect(controller.isFocusPlayerMode, isFalse);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(controller.isFocusPlayerMode, isTrue);
  });
}
