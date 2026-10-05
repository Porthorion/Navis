import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/login_screen.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_screen.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/home/presentation/trending_detail_screen.dart';
import 'package:navis/src/features/integrations/presentation/integrations_settings_screen.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_playlist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_screen.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_screen.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_song_search_screen.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
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
import 'package:navis/src/features/library/presentation/unavailable_review_screen.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/app_shell.dart';
import 'package:navis/src/routing/route_not_found_screen.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/motion_policy.dart';

/// Returns a [CustomTransitionPage] with a subtle slide-up + fade-in entry
/// (and slide-down + fade-out on pop). Used for all list-to-detail and
/// settings sub-route pushes so navigation feels snappy and polished.
///
/// A Hero-driven route deliberately has no route-level transition: fading the
/// whole destination also fades the Hero's landing artwork, which produces a
/// visible brightness jump as Flutter hands the flight back to that widget.
///
/// On iOS, routes without a Hero use [CupertinoPage] so the edge-swipe back
/// gesture works; a custom transition page has no gesture.
Page<T> buildSlideFadePage<T>({
  required BuildContext context,
  required LocalKey key,
  required Widget child,
  bool heroDriven = false,
  bool fadeOnly = false,
}) {
  if (!heroDriven && Theme.of(context).platform == TargetPlatform.iOS) {
    return CupertinoPage<T>(key: key, child: child);
  }
  final motion = MotionPolicy.of(context);
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionDuration: fadeOnly ? motion.surface : motion.navigationForward,
    reverseTransitionDuration: fadeOnly
        ? motion.surface
        : motion.navigationReverse,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (heroDriven || motion.reduceMotion) {
        return child;
      }
      if (fadeOnly) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          child: child,
        );
      }
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

/// Desktop-only Settings pages are not reachable on phones and tablets.
String? _desktopOnlyRedirect(BuildContext context, GoRouterState state) =>
    isDesktopRuntime ? null : AppRoutes.settings;

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
  final onboardingRequired = ValueNotifier<bool?>(
    ref.read(onboardingRequiredProvider),
  );
  ref.listen<bool?>(onboardingRequiredProvider, (_, next) {
    onboardingRequired.value = next;
  });
  ref.onDispose(onboardingRequired.dispose);
  final cacheSystemUpgradeRequired = ValueNotifier<bool?>(
    ref.read(cacheSystemUpgradeRequiredProvider),
  );
  ref.listen<bool?>(cacheSystemUpgradeRequiredProvider, (_, next) {
    cacheSystemUpgradeRequired.value = next;
  });
  ref.onDispose(cacheSystemUpgradeRequired.dispose);

  return GoRouter(
    initialLocation: AppRoutes.login,
    refreshListenable: Listenable.merge(<Listenable>[
      sessionPhase,
      cacheSystemUpgradeRequired,
      onboardingRequired,
    ]),
    errorBuilder: (context, state) => const RouteNotFoundScreen(),
    redirect: (context, state) {
      final isLoginRoute = state.matchedLocation == AppRoutes.login;
      final isInitialSyncRoute = state.matchedLocation == AppRoutes.initialSync;
      final isOnboardingRoute = state.matchedLocation == AppRoutes.onboarding;
      final isOnboardingReview =
          state.uri.queryParameters[AppRoutes.onboardingReviewParam] == '1';
      final hasHomeWarmupEligibility =
          state.uri.queryParameters['homeWarmupEligible'] == '1';
      final isCacheUpgradeRoute =
          state.matchedLocation == AppRoutes.libraryRebuild &&
          state.uri.queryParameters['reason'] ==
              RequiredLibraryRebuildReason.cacheUpgrade.routeValue;
      if (sessionPhase.value == SessionRoutePhase.loading) {
        return null; // still loading
      }

      if (sessionPhase.value == SessionRoutePhase.unauthenticated) {
        return isLoginRoute ? null : AppRoutes.login;
      }

      if (cacheSystemUpgradeRequired.value == null) {
        return null;
      }
      if (cacheSystemUpgradeRequired.value == true) {
        final shouldCarryHomeWarmup = onboardingRequired.value == true;
        final target = requiredLibraryRebuildRoute(
          RequiredLibraryRebuildReason.cacheUpgrade,
          homeWarmupEligible: shouldCarryHomeWarmup,
        );
        return isCacheUpgradeRoute &&
                hasHomeWarmupEligibility == shouldCarryHomeWarmup
            ? null
            : target;
      }
      if (sessionPhase.value == SessionRoutePhase.initialSyncRequired) {
        if (onboardingRequired.value == null) {
          return isInitialSyncRoute ? null : AppRoutes.initialSync;
        }
        final shouldCarryHomeWarmup = onboardingRequired.value == true;
        final target = shouldCarryHomeWarmup
            ? '${AppRoutes.initialSync}?homeWarmupEligible=1'
            : AppRoutes.initialSync;
        return isInitialSyncRoute &&
                hasHomeWarmupEligibility == shouldCarryHomeWarmup
            ? null
            : target;
      }
      if (onboardingRequired.value == null) {
        return null;
      }
      if (onboardingRequired.value == true) {
        if (isOnboardingRoute) {
          return null;
        }
        return hasHomeWarmupEligibility
            ? '${AppRoutes.onboarding}?homeWarmup=1'
            : AppRoutes.onboarding;
      }

      return switch (sessionPhase.value) {
        SessionRoutePhase.unauthenticated => null,
        SessionRoutePhase.initialSyncRequired =>
          isInitialSyncRoute ? null : AppRoutes.initialSync,
        SessionRoutePhase.ready =>
          (isLoginRoute ||
                  isInitialSyncRoute ||
                  (isOnboardingRoute && !isOnboardingReview))
              ? AppRoutes.home
              : null,
        SessionRoutePhase.loading => null,
      };
    },
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.initialSync,
        builder: (context, state) => RequiredLibraryRebuildScreen(
          reason: RequiredLibraryRebuildReason.initialLogin,
          homeWarmupEligible:
              state.uri.queryParameters['homeWarmupEligible'] == '1',
        ),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        pageBuilder: (context, state) => buildSlideFadePage(
          context: context,
          key: state.pageKey,
          fadeOnly: true,
          child: OnboardingScreen(
            reviewMode:
                state.uri.queryParameters[AppRoutes.onboardingReviewParam] ==
                '1',
            homeWarmupAfterRebuild:
                state.uri.queryParameters['homeWarmup'] == '1',
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.libraryRebuild,
        builder: (context, state) {
          final reason = RequiredLibraryRebuildReason.parse(
            state.uri.queryParameters['reason'],
          );
          if (reason == null ||
              reason == RequiredLibraryRebuildReason.initialLogin) {
            return const RequiredLibraryRebuildScreen(
              reason: RequiredLibraryRebuildReason.manualCacheReset,
            );
          }
          return RequiredLibraryRebuildScreen(
            reason: reason,
            allowMeteredBroadOverride:
                state.uri.queryParameters['metered'] == '1',
            homeWarmupEligible:
                state.uri.queryParameters['homeWarmupEligible'] == '1',
          );
        },
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.home,
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.library,
                builder: (context, state) => const LibraryScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.artistSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: ArtistDetailScreen(
                        artistId: state.pathParameters['id']!,
                      ),
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: AppRoutes.artistTopTracksSegment,
                        pageBuilder: (context, state) => buildSlideFadePage(
                          context: context,
                          key: state.pageKey,
                          child: ArtistTopTracksPlaylistDetailScreen(
                            artistId: state.pathParameters['id']!,
                          ),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: AppRoutes.albumSegment,
                    pageBuilder: (context, state) {
                      // Links without a request (restored history entries,
                      // diagnostics) use the calm composed-page fade.
                      final request = state.extra is AlbumDetailRouteRequest
                          ? state.extra! as AlbumDetailRouteRequest
                          : const AlbumDetailRouteRequest(fadeOnly: true);
                      return buildSlideFadePage(
                        context: context,
                        key: state.pageKey,
                        heroDriven: request.openingHeroTag != null,
                        fadeOnly: request.fadeOnly,
                        child: AlbumDetailScreen(
                          albumId: state.pathParameters['id']!,
                          openingHeroTag: request.openingHeroTag,
                        ),
                      );
                    },
                  ),
                  GoRoute(
                    path: AppRoutes.playlistSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: PlaylistDetailScreen(
                        playlistId: state.pathParameters['id']!,
                      ),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.listenBrainzSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: ListenBrainzWeeklyDetailScreen(
                        sourcePatch: state.pathParameters['sourcePatch']!,
                      ),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.trendingSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const TrendingDetailScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.likedArtistsSegment,
                    pageBuilder: (context, state) => buildSlideFadePage<void>(
                      context: context,
                      key: state.pageKey,
                      child: const LikedArtistsAllScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.likedAlbumsSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
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
                path: AppRoutes.search,
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.settingsServerSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const ServerSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsIntegrationsSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const IntegrationsSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsUnavailableItemsSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const UnavailableReviewScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsCacheSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const CacheSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsDownloadsSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const DownloadsScreen(),
                    ),
                  ),
                  for (final retired
                      in AppRoutes.retiredSettingsSegments.entries)
                    GoRoute(
                      path: retired.key,
                      redirect: (context, state) => retired.value.location,
                    ),
                  GoRoute(
                    path: AppRoutes.settingsEqualizerSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const EqualizerScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsPlaybackSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const PlaybackSettingsScreen(),
                    ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: AppRoutes.matchFlowSegment,
                        pageBuilder: (context, state) => buildSlideFadePage(
                          context: context,
                          key: state.pageKey,
                          child: const MatchFlowScreen(),
                        ),
                        routes: <RouteBase>[
                          GoRoute(
                            path: AppRoutes.matchFlowSearchSegment,
                            pageBuilder: (context, state) => buildSlideFadePage(
                              context: context,
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
                    path: AppRoutes.settingsSyncSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const SyncSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsAppearanceSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const AppearanceSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsAboutSegment,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const AboutScreen(),
                    ),
                    routes: [
                      GoRoute(
                        path: AppRoutes.changelogSegment,
                        pageBuilder: (context, state) => buildSlideFadePage(
                          context: context,
                          key: state.pageKey,
                          child: ChangelogScreen(
                            initialVersion:
                                state.uri.queryParameters['version'],
                          ),
                        ),
                      ),
                      GoRoute(
                        path: AppRoutes.privacySegment,
                        pageBuilder: (context, state) => buildSlideFadePage(
                          context: context,
                          key: state.pageKey,
                          child: const PrivacyScreen(),
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: AppRoutes.settingsDesktopWindowSegment,
                    redirect: _desktopOnlyRedirect,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
                      key: state.pageKey,
                      child: const DesktopWindowSettingsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsShortcutsSegment,
                    redirect: _desktopOnlyRedirect,
                    pageBuilder: (context, state) => buildSlideFadePage(
                      context: context,
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
