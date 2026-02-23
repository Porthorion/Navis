import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/login_screen.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlists_screen.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/about_screen.dart';
import 'package:navis/src/features/settings/presentation/cache_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/routing/app_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final serverConfig = ref.watch(serverConfigStateProvider);

  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final isLoginRoute = state.matchedLocation == '/login';
      if (serverConfig.isLoading) {
        return null;
      }

      final isLoggedIn = serverConfig.asData?.value != null;

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
                    builder: (context, state) {
                      final artistId = state.pathParameters['id']!;
                      return ArtistDetailScreen(artistId: artistId);
                    },
                  ),
                  GoRoute(
                    path: 'albums/:id',
                    builder: (context, state) {
                      final albumId = state.pathParameters['id']!;
                      return AlbumDetailScreen(albumId: albumId);
                    },
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
                path: '/playlists',
                builder: (context, state) => const PlaylistsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: ':id',
                    builder: (context, state) {
                      final playlistId = state.pathParameters['id']!;
                      return PlaylistDetailScreen(playlistId: playlistId);
                    },
                  ),
                ],
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
                    builder: (context, state) => const ServerSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'cache',
                    builder: (context, state) => const CacheSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'downloads',
                    builder: (context, state) => const DownloadsScreen(),
                  ),
                  GoRoute(
                    path: 'playback',
                    builder: (context, state) => const PlaybackSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'sync',
                    builder: (context, state) => const SyncSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'appearance',
                    builder: (context, state) =>
                        const AppearanceSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'about',
                    builder: (context, state) => const AboutScreen(),
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
