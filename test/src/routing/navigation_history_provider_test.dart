import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';
import 'package:navis/src/routing/navigation_service.dart';

import '../../helpers/navigation_shell_harness.dart';
import '../../helpers/test_theme.dart';

void main() {
  testWidgets('records from launch, without waiting for a Back press', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);

    expect(harness.history.stack, <String>[AppRoutes.home]);
    await harness.tap('Open Album');
    expect(harness.history.stack, <String>[
      AppRoutes.home,
      AppRoutes.album('album-1'),
    ]);
    expect(harness.history.canGoBack, isTrue);
  });

  testWidgets(
    'back and forward across tabs keep each tab stack and route extras',
    (tester) async {
      final harness = await _pumpHistoryHarness(tester);
      await harness.tap('Open Album');
      await harness.tap('go:search');
      expect(find.text('SearchScreen'), findsOneWidget);

      await harness.back();
      expect(find.text('tab:home'), findsOneWidget);
      expect(find.text('Album album-1'), findsOneWidget);
      expect(harness.router.state.extra, isA<AlbumDetailRouteRequest>());

      await harness.back();
      expect(find.text('HomeScreen'), findsOneWidget);
      expect(harness.history.canGoBack, isFalse);

      await harness.forward();
      expect(find.text('Album album-1'), findsOneWidget);
      expect(harness.router.state.extra, isA<AlbumDetailRouteRequest>());

      await harness.forward();
      expect(find.text('SearchScreen'), findsOneWidget);
      expect(find.text('tab:search'), findsOneWidget);

      // The restored album page can still be popped normally.
      await harness.back();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('HomeScreen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a page pop moves back through history instead of adding', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);
    await harness.tap('Open Album');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(harness.history.index, 0);
    expect(harness.history.entries, hasLength(2));
    expect(harness.history.canGoForward, isTrue);
  });

  testWidgets('new navigation after going back discards forward history', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);
    await harness.tap('go:search');
    await harness.back();

    await harness.tap('go:settings');

    expect(harness.history.stack, <String>[AppRoutes.home, AppRoutes.settings]);
    expect(harness.history.canGoForward, isFalse);
  });

  testWidgets('library sections are ordinary history entries', (tester) async {
    final harness = await _pumpHistoryHarness(tester);
    harness.router.go(AppRoutes.librarySection('artists'));
    await tester.pumpAndSettle();
    harness.router.go(AppRoutes.librarySection('playlists'));
    await tester.pumpAndSettle();
    await harness.tap('go:search');

    await harness.back();
    expect(
      harness.router.state.uri.toString(),
      AppRoutes.librarySection('playlists'),
    );
    await harness.back();
    expect(
      harness.router.state.uri.toString(),
      AppRoutes.librarySection('artists'),
    );
  });

  testWidgets('history keeps at most its capacity', (tester) async {
    final harness = await _pumpHistoryHarness(tester);
    for (var i = 0; i < NavigationHistoryNotifier.capacity + 10; i++) {
      harness.router.go(i.isEven ? AppRoutes.search : AppRoutes.settings);
      await tester.pump();
    }

    expect(
      harness.history.entries,
      hasLength(NavigationHistoryNotifier.capacity),
    );
    expect(harness.history.index, NavigationHistoryNotifier.capacity - 1);
  });

  testWidgets('signing out clears history', (tester) async {
    final harness = await _pumpHistoryHarness(tester);
    await harness.tap('go:search');
    expect(harness.history.canGoBack, isTrue);

    harness.container
        .read(_sessionPhaseProvider.notifier)
        .set(SessionRoutePhase.unauthenticated);
    await tester.pump();

    expect(harness.history.entries, isEmpty);
    expect(harness.history.canGoBack, isFalse);
  });
}

class _SessionPhase extends Notifier<SessionRoutePhase> {
  @override
  SessionRoutePhase build() => SessionRoutePhase.ready;

  void set(SessionRoutePhase phase) => state = phase;
}

final _sessionPhaseProvider =
    NotifierProvider<_SessionPhase, SessionRoutePhase>(_SessionPhase.new);

Future<_HistoryHarness> _pumpHistoryHarness(WidgetTester tester) async {
  final router = createNavigationShellHarnessRouter();
  final container = ProviderContainer(
    overrides: [
      appRouterProvider.overrideWithValue(router),
      sessionRoutePhaseProvider.overrideWith(
        (ref) => ref.watch(_sessionPhaseProvider),
      ),
    ],
  );
  addTearDown(() {
    container.dispose();
    router.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: testTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  // The app listens from launch on desktop; mirror that here.
  container.listen(navigationHistoryProvider, (_, _) {});
  return _HistoryHarness(tester, container, router);
}

class _HistoryHarness {
  const new(this.tester, this.container, this.router);

  final WidgetTester tester;
  final ProviderContainer container;
  final GoRouter router;

  NavigationHistoryState get history =>
      container.read(navigationHistoryProvider);

  Future<void> tap(String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> back() async {
    container.read(navigationHistoryProvider.notifier).navigateBack();
    await tester.pumpAndSettle();
  }

  Future<void> forward() async {
    container.read(navigationHistoryProvider.notifier).navigateForward();
    await tester.pumpAndSettle();
  }
}
