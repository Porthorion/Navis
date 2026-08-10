import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/login_screen.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_screen.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_screen.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_playlist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_screen.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_song_search_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/about_screen.dart';
import 'package:navis/src/features/settings/presentation/cache_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/desktop_shortcuts_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/desktop_window_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/privacy_screen.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/routing/app_shell.dart';

/// Returns a [CustomTransitionPage] with a subtle slide-up + fade-in entry
/// (and slide-down + fade-out on pop). Used for all list-to-detail and
/// settings sub-route pushes so navigation feels snappy and polished.
CustomTransitionPage<T> _slideFadePage<T>({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.65, curve: Curves.easeOut),
        reverseCurve: const Interval(0.35, 1, curve: Curves.easeIn),
      );
      final slide =
          Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.fastEaseInToSlowEaseOut,
              reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
            ),
          );
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

final appRouterProvider = Provider<GoRouter>((ref) {
  // Keep the router instance stable. A sync completion updates the server
  // configuration timestamp and briefly re-evaluates the session phase while
  // its persisted first-sync safety check resolves. Recreating GoRouter during
  // that transient state restarts it at [initialLocation], which can turn a
  // later ready redirect into an unwanted trip to Home.
  //
  // A refresh listenable lets redirects react to real auth/first-sync changes
  // without replacing the current router or its location.
  final sessionPhase = ValueNotifier<SessionRoutePhase>(
    ref.read(sessionRoutePhaseProvider),
  );
  ref.listen<SessionRoutePhase>(sessionRoutePhaseProvider, (_, next) {
    sessionPhase.value = next;
  });
  ref.onDispose(sessionPhase.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: sessionPhase,
    redirect: (context, state) {
      final isLoginRoute = state.matchedLocation == '/login';
      final isInitialSyncRoute = state.matchedLocation == '/initial-sync';
      if (sessionPhase.value == SessionRoutePhase.loading) {
        return null; // still loading
      }

      return switch (sessionPhase.value) {
        SessionRoutePhase.unauthenticated => isLoginRoute ? null : '/login',
        // A first catalog sync is resilient background work.  Do not trap a
        // newly authenticated user behind it: Home can render its normal sync
        // state and remains useful while the initial candidate is collected.
        SessionRoutePhase.initialSyncRequired =>
          (isLoginRoute || isInitialSyncRoute) ? '/' : null,
        SessionRoutePhase.ready =>
          (isLoginRoute || isInitialSyncRoute) ? '/' : null,
        SessionRoutePhase.loading => null,
      };
    },
    routes: <RouteBase>[
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/initial-sync',
        builder: (context, state) => const InitialServerSyncScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/library',
                builder: (context, state) => const LibraryScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'artists/:id',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: ArtistDetailScreen(
                        artistId: state.pathParameters['id']!,
                      ),
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'top-tracks',
                        pageBuilder: (context, state) => _slideFadePage(
                          key: state.pageKey,
                          child: ArtistTopTracksPlaylistDetailScreen(
                            artistId: state.pathParameters['id']!,
                          ),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'albums/:id',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: AlbumDetailScreen(
                        albumId: state.pathParameters['id']!,
                        likedOnly:
                            state.uri.queryParameters['likedOnly'] == '1',
                      ),
                    ),
                  ),
                  GoRoute(
                    path: 'playlists/:id',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: PlaylistDetailScreen(
                        playlistId: state.pathParameters['id']!,
                      ),
                    ),
                  ),
                  GoRoute(
                    path: 'listenbrainz/:sourcePatch',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: ListenBrainzWeeklyDetailScreen(
                        sourcePatch: state.pathParameters['sourcePatch']!,
                      ),
                    ),
                  ),
                  GoRoute(
                    path: 'liked-albums',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const LikedAlbumsAllScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/search',
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'server',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const ServerSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'cache',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const CacheSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'downloads',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const DownloadsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'group-listening',
                    redirect: (context, state) => '/settings/server',
                  ),
                  GoRoute(
                    path: 'external-services',
                    redirect: (context, state) => '/settings/server',
                  ),
                  GoRoute(
                    path: 'playback',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const PlaybackSettingsScreen(),
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'match-flow',
                        pageBuilder: (context, state) => _slideFadePage(
                          key: state.pageKey,
                          child: const MatchFlowScreen(),
                        ),
                        routes: <RouteBase>[
                          GoRoute(
                            path: ':flowId/search',
                            pageBuilder: (context, state) => _slideFadePage(
                              key: state.pageKey,
                              child: MatchFlowSongSearchScreen(
                                flowId: state.pathParameters['flowId']!,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'sync',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const SyncSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'appearance',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const AppearanceSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'about',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const AboutScreen(),
                    ),
                    routes: [
                      GoRoute(
                        path: 'changelog',
                        pageBuilder: (context, state) => _slideFadePage(
                          key: state.pageKey,
                          child: const ChangelogScreen(),
                        ),
                      ),
                      GoRoute(
                        path: 'privacy',
                        pageBuilder: (context, state) => _slideFadePage(
                          key: state.pageKey,
                          child: const PrivacyScreen(),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'desktop-window',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const DesktopWindowSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'shortcuts',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const DesktopShortcutsSettingsScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
