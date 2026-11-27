import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/desktop_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';

import '../../../../helpers/adaptive_test_harness.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets(
    'desktop settings screen shows unavailable state outside desktop',
    (tester) async {
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
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AdaptiveContextScope(
              adaptiveContext: nonDesktopContext,
              child: const DesktopSettingsScreen(),
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
    },
  );

  testWidgets('desktop settings screen has Window, Navigation and Keyboard '
      'Shortcuts sections, and the shortcuts row opens the shortcuts page', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 1000));
    final controller = DesktopWindowController.fallback(desktopRuntime: true);
    final desktopContext = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(1280, 1000),
      safePadding: EdgeInsets.zero,
    );
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => AdaptiveContextScope(
            adaptiveContext: desktopContext,
            child: const DesktopSettingsScreen(),
          ),
        ),
        GoRoute(
          path: SettingsPage.shortcuts.location,
          builder: (context, state) => const Text('shortcuts page'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWindowControllerProvider.overrideWith((ref) => controller),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
        child: MaterialApp.router(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text(l10n.desktopSettingsTitle), findsOneWidget); // AppBar
    expect(find.text(l10n.desktopSettingsWindowSection), findsOneWidget);
    expect(find.text('Mini Player'), findsOneWidget);
    expect(find.text('Keep Mini Player on Top'), findsOneWidget);
    expect(find.text(l10n.desktopNavbarSectionLabel), findsOneWidget);
    expect(find.text(l10n.desktopNavbarStyleLarge), findsOneWidget);
    expect(find.text(l10n.desktopNavbarAutohideLabel), findsOneWidget);
    expect(controller.isMiniPlayerMode, isFalse);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(
      top(l10n.desktopNavbarSectionLabel),
      greaterThan(top(l10n.desktopSettingsWindowSection)),
    );
    expect(
      top(l10n.settingsDesktopShortcutsTitle),
      greaterThan(top(l10n.desktopNavbarSectionLabel)),
    );
    await expectLater(
      find.byType(DesktopSettingsScreen),
      matchesGoldenFile('goldens/desktop_settings_workspace.png'),
    );

    await tester.tap(find.text(l10n.settingsDesktopShortcutsSubtitle));
    await tester.pumpAndSettle();
    expect(find.text('shortcuts page'), findsOneWidget);
  });
}
