import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// A lightweight router with the same branch and route shape as the app's
/// [StatefulShellRoute], rendering placeholder pages.
///
/// Placeholder pages show their title and expose buttons that call the real
/// [NavService] helpers, so tests exercise production navigation semantics
/// (cross-branch pushes, tab switches, back fallbacks) without the full shell.
GoRouter createNavigationShellHarnessRouter({
  String initialLocation = AppRoutes.home,
  String? heroTag,
}) {
  GoRoute page(String path, String Function(GoRouterState) title) => GoRoute(
    path: path,
    builder: (context, state) =>
        HarnessPage(title: title(state), heroTag: heroTag),
  );

  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HarnessShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[page(AppRoutes.home, (_) => 'HomeScreen')],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.library,
                builder: (context, state) =>
                    HarnessPage(title: 'LibraryScreen', heroTag: heroTag),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.artistSegment,
                    builder: (context, state) => HarnessPage(
                      title: 'Artist ${state.pathParameters['id']}',
                    ),
                    routes: <RouteBase>[
                      page(
                        AppRoutes.artistTopTracksSegment,
                        (state) => 'Top tracks ${state.pathParameters['id']}',
                      ),
                    ],
                  ),
                  page(
                    AppRoutes.albumSegment,
                    (state) => 'Album ${state.pathParameters['id']}',
                  ),
                  page(
                    AppRoutes.playlistSegment,
                    (state) => 'Playlist ${state.pathParameters['id']}',
                  ),
                  page(
                    AppRoutes.listenBrainzSegment,
                    (state) => 'Weekly ${state.pathParameters['sourcePatch']}',
                  ),
                  page(AppRoutes.likedAlbumsSegment, (_) => 'Liked albums'),
                  page(AppRoutes.likedArtistsSegment, (_) => 'Liked artists'),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[page(AppRoutes.search, (_) => 'SearchScreen')],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) =>
                    const HarnessPage(title: 'SettingsScreen'),
                routes: <RouteBase>[
                  for (final settingsPage in SettingsPage.values)
                    page(settingsPage.segment, (_) => settingsPage.name),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// The shell used by [createNavigationShellHarnessRouter].
class HarnessShell extends ConsumerWidget {
  const new({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Wrap(
        children: <Widget>[
          Text(
            'tab:${ShellBranch.fromIndex(navigationShell.currentIndex).name}',
          ),
          for (final branch in ShellBranch.values)
            TextButton(
              onPressed: () => NavService.switchTab(
                context,
                ref,
                navigationShell,
                branch,
                initialLocation: branch.index == navigationShell.currentIndex,
              ),
              child: Text('go:${branch.name}'),
            ),
        ],
      ),
    );
  }
}

/// A placeholder page with buttons for common [NavService] actions.
class HarnessPage extends ConsumerWidget {
  const new({required this.title, this.heroTag, super.key});

  final String title;
  final String? heroTag;

  /// Album id used by the "Open album" button.
  static const albumId = 'album-1';

  /// Artist id used by the "Open artist" button.
  static const artistId = 'artist-1';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      child: ListView(
        children: <Widget>[
          Text(title),
          TextButton(
            onPressed: () => NavService.openAlbumDetail(
              context,
              ref,
              albumId,
              heroTag: heroTag,
            ),
            child: const Text('Open album'),
          ),
          TextButton(
            onPressed: () =>
                NavService.openArtistDetail(context, ref, artistId),
            child: const Text('Open artist'),
          ),
          TextButton(
            onPressed: () => NavService.returnToLibrary(context, ref),
            child: const Text('Return to library'),
          ),
          TextButton(
            onPressed: () => NavService.back(context),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}
