import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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

  testWidgets('desktop window screen exposes Mini Player controls', (
    tester,
  ) async {
    final controller = DesktopWindowController.fallback(desktopRuntime: true);
    final desktopContext = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(1008, 640),
      safePadding: EdgeInsets.zero,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWindowControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: desktopContext,
            child: const DesktopWindowSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mini Player'), findsOneWidget);
    expect(find.text('Keep Mini Player on top'), findsOneWidget);
    expect(controller.isMiniPlayerMode, isFalse);
  });
}
