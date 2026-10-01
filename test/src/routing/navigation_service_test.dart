import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/navigation_shell_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  for (final scenario in [
    (desktop: true, size: const Size(800, 600), fade: true),
    (desktop: true, size: const Size(1920, 1080), fade: true),
    (desktop: false, size: const Size(390, 844), fade: true),
    (desktop: false, size: const Size(844, 390), fade: false),
  ]) {
    testWidgets(
      'album opening policy at ${scenario.size}, desktop=${scenario.desktop}',
      (tester) async {
        setAdaptiveTestViewport(tester, scenario.size);
        final router = createNavigationShellHarnessRouter(
          heroTag: 'source-album-art',
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp.router(
              theme: testTheme(),
              routerConfig: router,
              builder: (context, child) => AdaptiveContextScope(
                adaptiveContext: resolveAdaptiveContext(
                  desktopRuntime: scenario.desktop,
                  viewportSize: scenario.size,
                  safePadding: EdgeInsets.zero,
                ),
                child: child!,
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open album'));
        await tester.pumpAndSettle();
        final request = router.state.extra! as AlbumDetailRouteRequest;
        expect(request.fadeOnly, scenario.fade);
        expect(
          request.openingHeroTag,
          scenario.fade ? isNull : 'source-album-art',
        );
        expect(find.text('Album album-1'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('HomeScreen'), findsOneWidget);
      },
    );
  }

  for (final origin in [
    (location: AppRoutes.home, title: 'HomeScreen', tab: ShellBranch.home),
    (
      location: AppRoutes.search,
      title: 'SearchScreen',
      tab: ShellBranch.search,
    ),
    (
      location: AppRoutes.library,
      title: 'LibraryScreen',
      tab: ShellBranch.library,
    ),
    (
      location: AppRoutes.artist('artist-1'),
      title: 'Artist artist-1',
      tab: ShellBranch.library,
    ),
    (
      location: AppRoutes.playlist('playlist-1'),
      title: 'Playlist playlist-1',
      tab: ShellBranch.library,
    ),
  ]) {
    testWidgets('album drill-in from ${origin.location} keeps the '
        '${origin.tab.name} tab and back returns there', (tester) async {
      final router = await _pumpHarness(tester, origin.location);

      await tester.tap(find.text('Open album').first);
      await tester.pumpAndSettle();
      expect(find.text('Album album-1'), findsOneWidget);
      expect(find.text('tab:${origin.tab.name}'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(origin.title), findsOneWidget);
      expect(router.state.uri.path, origin.location);
    });
  }

  testWidgets('album detail artist drill-in returns to album detail', (
    tester,
  ) async {
    await _pumpHarness(tester, AppRoutes.album('album-1'));

    await tester.tap(find.text('Open artist'));
    await tester.pumpAndSettle();
    expect(find.text('Artist artist-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);
  });

  testWidgets('switching tabs preserves the stack pushed on another tab', (
    tester,
  ) async {
    await _pumpHarness(tester, AppRoutes.home);
    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go:settings'));
    await tester.pumpAndSettle();
    expect(find.text('SettingsScreen'), findsOneWidget);

    await tester.tap(find.text('go:home'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);
    expect(find.text('tab:home'), findsOneWidget);
  });

  testWidgets(
    'returning to Library from an unavailable page opened on Home does not '
    'leave the page on Home',
    (tester) async {
      await _pumpHarness(tester, AppRoutes.home);
      await tester.tap(find.text('Open album'));
      await tester.pumpAndSettle();

      final albumPage = find.ancestor(
        of: find.text('Album album-1'),
        matching: find.byType(HarnessPage),
      );
      await tester.tap(
        find.descendant(
          of: albumPage,
          matching: find.text('Return to library'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('tab:library'), findsOneWidget);
      expect(find.text('LibraryScreen'), findsOneWidget);

      await tester.tap(find.text('go:home'));
      await tester.pumpAndSettle();
      expect(find.text('HomeScreen'), findsOneWidget);
      expect(find.text('Album album-1'), findsNothing);
    },
  );

  testWidgets('back pops to the parent, then falls back at a tab root', (
    tester,
  ) async {
    final router = await _pumpHarness(tester, SettingsPage.cache.location);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, AppRoutes.settings);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, AppRoutes.home);
    expect(find.text('HomeScreen'), findsOneWidget);
  });

  testWidgets('entity ids are encoded into a single path segment', (
    tester,
  ) async {
    const awkwardId = 'al/bum?one#two three%';
    final router = await _pumpHarness(tester, AppRoutes.home);

    router.go(AppRoutes.album(awkwardId));
    await tester.pumpAndSettle();
    expect(find.text('Album $awkwardId'), findsOneWidget);
  });
}

Future<GoRouter> _pumpHarness(WidgetTester tester, String location) async {
  final router = createNavigationShellHarnessRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(theme: testTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
