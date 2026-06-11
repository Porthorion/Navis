import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';

void main() {
  testWidgets('mouse back and forward mirror normalized routes', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);

    harness.router.go('/search');
    await tester.pump();
    harness.router.go('/library/albums/album-1');
    await tester.pump();

    expect(
      harness.container.read(navigationHistoryProvider).stack,
      containsAllInOrder(<String>['/search', '/library/albums/album-1']),
    );

    harness.container
        .read(navigationHistoryProvider.notifier)
        .navigateBack(harness.router);
    await tester.pump();
    expect(harness.router.state.uri.toString(), '/search');

    harness.container
        .read(navigationHistoryProvider.notifier)
        .navigateForward(harness.router);
    await tester.pump();
    expect(harness.router.state.uri.toString(), '/library/albums/album-1');
  });

  testWidgets('new navigation after mouse back truncates forward history', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);

    harness.router.go('/search');
    await tester.pump();
    harness.router.go('/library/albums/album-1');
    await tester.pump();

    harness.container
        .read(navigationHistoryProvider.notifier)
        .navigateBack(harness.router);
    await tester.pump();
    expect(
      harness.container.read(navigationHistoryProvider).canGoForward,
      true,
    );

    harness.router.go('/library/artists/artist-1');
    await tester.pump();

    final history = harness.container.read(navigationHistoryProvider);
    expect(history.canGoForward, false);
    expect(history.stack.last, '/library/artists/artist-1');
  });

  testWidgets('library section virtual history restores selected section', (
    tester,
  ) async {
    final harness = await _pumpHistoryHarness(tester);

    harness.router.go('/library');
    await tester.pump();
    harness.container
        .read(librarySectionProvider.notifier)
        .setSection(LibrarySection.artists);
    await tester.pump();

    expect(
      harness.container.read(navigationHistoryProvider).stack,
      containsAllInOrder(<String>['/library#albums', '/library#artists']),
    );

    harness.container
        .read(navigationHistoryProvider.notifier)
        .navigateBack(harness.router);
    await tester.pump();
    expect(
      harness.container.read(librarySectionProvider),
      LibrarySection.albums,
    );

    harness.container
        .read(navigationHistoryProvider.notifier)
        .navigateForward(harness.router);
    await tester.pump();
    expect(
      harness.container.read(librarySectionProvider),
      LibrarySection.artists,
    );
  });
}

Future<_HistoryHarness> _pumpHistoryHarness(WidgetTester tester) async {
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (context, state) => const Text('Home')),
      GoRoute(
        path: '/search',
        builder: (context, state) => const Text('Search'),
      ),
      GoRoute(
        path: '/library',
        builder: (context, state) => const Text('Library'),
        routes: <RouteBase>[
          GoRoute(
            path: 'albums/:id',
            builder: (context, state) =>
                Text('Album ${state.pathParameters['id']}'),
          ),
          GoRoute(
            path: 'artists/:id',
            builder: (context, state) =>
                Text('Artist ${state.pathParameters['id']}'),
          ),
        ],
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      appRouterProvider.overrideWithValue(router),
    ],
  );
  addTearDown(() {
    container.dispose();
    router.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  container.read(navigationHistoryProvider);
  await tester.pump();
  return _HistoryHarness(container: container, router: router);
}

class _HistoryHarness {
  const _HistoryHarness({required this.container, required this.router});

  final ProviderContainer container;
  final GoRouter router;
}
