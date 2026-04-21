import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/login_screen.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_screen.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/about_screen.dart';
import 'package:navis/src/features/settings/presentation/cache_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/desktop_shortcuts_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/desktop_window_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
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
          Tween<Offset>(
            begin: const Offset(0, 0.05),
            end: Offset.zero,
          ).animate(
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
  // Only watch auth state (logged-in vs not), not the full config which
  // changes on every sync timestamp update.  Rebuilding GoRouter resets
  // the location to initialLocation, so we must avoid spurious rebuilds.
  final isLoggedIn = ref.watch(
    serverConfigStateProvider.select((cfg) {
      if (cfg.isLoading) return null; // still loading
      return cfg.asData?.value != null;
    }),
  );

  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final isLoginRoute = state.matchedLocation == '/login';
      if (isLoggedIn == null) {
        return null; // still loading
      }

      if (!isLoggedIn && !isLoginRoute) {
        return '/login';
      }

      if (isLoggedIn && isLoginRoute) {
        return '/';
      }

      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
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
                    path: 'playback',
                    pageBuilder: (context, state) => _slideFadePage(
                      key: state.pageKey,
                      child: const PlaybackSettingsScreen(),
                    ),
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
