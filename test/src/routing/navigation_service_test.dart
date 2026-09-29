import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../helpers/adaptive_test_harness.dart';
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
        final router = _createRouter(heroTag: 'source-album-art');
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
  testWidgets('album drill-in from search returns to search on system back', (
    tester,
  ) async {
    final router = _createRouter(initialLocation: '/search');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('SearchScreen'), findsOneWidget);
  });

  testWidgets('artist drill-in from search returns to search on system back', (
    tester,
  ) async {
    final router = _createRouter(initialLocation: '/search');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open artist'));
    await tester.pumpAndSettle();
    expect(find.text('Artist artist-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('SearchScreen'), findsOneWidget);
  });

  testWidgets('home album drill-in returns to home', (tester) async {
    final router = _createRouter();
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('HomeScreen'), findsOneWidget);
  });

  testWidgets('library album drill-in returns to library root', (tester) async {
    final router = _createRouter(initialLocation: '/library');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('LibraryScreen'), findsOneWidget);
  });

  testWidgets('artist detail album drill-in returns to artist detail', (
    tester,
  ) async {
    final router = _createRouter(initialLocation: '/library/artists/artist-1');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Artist artist-1'), findsOneWidget);
  });

  testWidgets('album detail artist drill-in returns to album detail', (
    tester,
  ) async {
    final router = _createRouter(initialLocation: '/library/albums/album-1');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open artist'));
    await tester.pumpAndSettle();
    expect(find.text('Artist artist-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);
  });

  testWidgets('playlist detail entity drill-in returns to playlist detail', (
    tester,
  ) async {
    final router = _createRouter(
      initialLocation: '/library/playlists/playlist-1',
    );
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Playlist playlist-1'), findsOneWidget);
  });

  testWidgets('replacement detail navigation does not preserve source route', (
    tester,
  ) async {
    final router = _createRouter(initialLocation: '/search');
    await _pumpRouter(tester, router);

    await tester.tap(find.text('Replace album'));
    await tester.pumpAndSettle();
    expect(find.text('Album album-1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('SearchScreen'), findsNothing);
  });
}

GoRouter _createRouter({String initialLocation = '/', String? heroTag}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => _HomePage(heroTag: heroTag),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const _SearchPage(),
      ),
      GoRoute(
        path: '/library',
        builder: (context, state) => const _LibraryPage(),
        routes: <RouteBase>[
          GoRoute(
            path: 'albums/:id',
            builder: (context, state) =>
                _AlbumPage(albumId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: 'artists/:id',
            builder: (context, state) =>
                _ArtistPage(artistId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: 'playlists/:id',
            builder: (context, state) =>
                _PlaylistPage(playlistId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  );
}

Future<void> _pumpRouter(WidgetTester tester, GoRouter router) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        theme: testTheme(),
        routerConfig: router,
      ),
    ),
  );
}

class _HomePage extends ConsumerWidget {
  const _HomePage({this.heroTag});

  final String? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'HomeScreen',
      onOpenAlbum: () =>
          NavService.openAlbumDetail(context, ref, 'album-1', heroTag: heroTag),
    );
  }
}

class _SearchPage extends ConsumerWidget {
  const _SearchPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'SearchScreen',
      onOpenAlbum: () => NavService.openAlbumDetail(context, ref, 'album-1'),
      onOpenArtist: () => NavService.openArtistDetail(context, ref, 'artist-1'),
      onReplaceAlbum: () =>
          NavService.replaceWithAlbumDetail(context, ref, 'album-1'),
    );
  }
}

class _LibraryPage extends ConsumerWidget {
  const _LibraryPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'LibraryScreen',
      onOpenAlbum: () => NavService.openAlbumDetail(context, ref, 'album-1'),
    );
  }
}

class _AlbumPage extends ConsumerWidget {
  const _AlbumPage({required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'Album $albumId',
      onOpenArtist: () => NavService.openArtistDetail(context, ref, 'artist-1'),
    );
  }
}

class _ArtistPage extends ConsumerWidget {
  const _ArtistPage({required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'Artist $artistId',
      onOpenAlbum: () => NavService.openAlbumDetail(context, ref, 'album-1'),
    );
  }
}

class _PlaylistPage extends ConsumerWidget {
  const _PlaylistPage({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ScaffoldWithActions(
      title: 'Playlist $playlistId',
      onOpenAlbum: () => NavService.openAlbumDetail(context, ref, 'album-1'),
    );
  }
}

class _ScaffoldWithActions extends StatelessWidget {
  const _ScaffoldWithActions({
    required this.title,
    this.onOpenAlbum,
    this.onOpenArtist,
    this.onReplaceAlbum,
  });

  final String title;
  final VoidCallback? onOpenAlbum;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onReplaceAlbum;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          Text(title),
          if (onOpenAlbum != null)
            TextButton(onPressed: onOpenAlbum, child: const Text('Open album')),
          if (onOpenArtist != null)
            TextButton(
              onPressed: onOpenArtist,
              child: const Text('Open artist'),
            ),
          if (onReplaceAlbum != null)
            TextButton(
              onPressed: onReplaceAlbum,
              child: const Text('Replace album'),
            ),
        ],
      ),
    );
  }
}
