import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/album_detail_screen.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_screen.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/shell_offline_banner.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  new(this._state);

  final ServerReachabilityState _state;
  int retryCalls = 0;

  @override
  ServerReachabilityState build() => _state;

  @override
  Future<void> retryNow() async {
    retryCalls++;
  }

  void set(ServerReachabilityState next) => state = next;
}

class _TestServerConfigNotifier extends ServerConfigNotifier {
  new(this._initial);

  ServerConfigModel? _initial;

  @override
  Future<ServerConfigModel?> build() async => _initial;

  @override
  Future<void> refresh() async {
    state = AsyncData(_initial);
  }

  @override
  Future<void> save(ServerConfigModel config) async {
    _initial = config;
    state = AsyncData(config);
  }

  Future<void> clear() async {
    _initial = null;
    state = const AsyncData(null);
  }
}

class _CallbackSignOutService implements SignOutService {
  new(this._onSignOut);

  final Future<void> Function({required bool wipeLocalData}) _onSignOut;

  @override
  Future<void> signOut({required bool wipeLocalData}) {
    return _onSignOut(wipeLocalData: wipeLocalData);
  }
}

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

/// Records which artists and albums the detail pages ask to be hydrated.
class _RecordingLibrarySyncController extends _StaticLibrarySyncController {
  static final List<String> requests = <String>[];

  @override
  Future<LibrarySyncState?> hydrateOpenedArtist(String artistId) async {
    requests.add('artist:$artistId');
    return null;
  }

  @override
  Future<LibrarySyncState?> hydrateOpenedAlbum(String albumId) async {
    requests.add('album:$albumId');
    return null;
  }
}

class _StaticRequiredLibraryRebuildController
    extends RequiredLibraryRebuildController {
  new() : super(RequiredLibraryRebuildReason.initialLogin);

  @override
  RequiredLibraryRebuildState build() => const RequiredLibraryRebuildState(
    status: RequiredLibraryRebuildStatus.waitingForNetwork,
  );
}

class _StaticCacheUpgradeRebuildController
    extends RequiredLibraryRebuildController {
  new() : super(RequiredLibraryRebuildReason.cacheUpgrade);

  @override
  RequiredLibraryRebuildState build() => const RequiredLibraryRebuildState(
    status: RequiredLibraryRebuildStatus.waitingForNetwork,
  );
}

class _CompletedCacheUpgradeRebuildController
    extends RequiredLibraryRebuildController {
  new() : super(RequiredLibraryRebuildReason.cacheUpgrade);

  @override
  RequiredLibraryRebuildState build() => const RequiredLibraryRebuildState(
    status: RequiredLibraryRebuildStatus.complete,
  );
}

class _NoopScrobbleDispatchController extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

const _testApp = NavisApp(splashFactory: NoSplash.splashFactory);

ProviderContainer _createContainerWithDatabase({
  List<Override> overrides = const <Override>[],
  bool initialSyncRequired = false,
  int onboardingVersion = currentOnboardingVersion,
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        initialSyncRequiredProvider.overrideWithValue(
          AsyncData(initialSyncRequired),
        ),
        onboardingVersionProvider.overrideWithValue(
          AsyncData(onboardingVersion),
        ),
        ...overrides,
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

void main() {
  for (final extra in <Object?>[
    null,
    'cover_art_album_album-1',
    // NavService never sends a Hero tag on desktop; the route trusts the
    // request it builds.
    const AlbumDetailRouteRequest(fadeOnly: true),
  ]) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'desktop album route fades without source Hero for $extra, reduced=$reduceMotion',
        (tester) async {
          final container = _createContainerWithDatabase(
            overrides: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(null),
              ),
              librarySyncControllerProvider.overrideWith(
                _StaticLibrarySyncController.new,
              ),
            ],
          );
          final router = container.read(appRouterProvider);
          GoRoute? albumRoute;
          void visit(RouteBase route) {
            if (route is GoRoute) {
              if (route.path == 'albums/:id') albumRoute = route;
              route.routes.forEach(visit);
            } else if (route is StatefulShellRoute) {
              for (final branch in route.branches) {
                branch.routes.forEach(visit);
              }
            }
          }

          router.configuration.routes.forEach(visit);
          expect(albumRoute, isNotNull);
          final state = GoRouterState(
            router.configuration,
            uri: Uri.parse('/library/albums/album-1'),
            matchedLocation: '/library/albums/album-1',
            fullPath: '/library/albums/:id',
            pathParameters: const {'id': 'album-1'},
            pageKey: const ValueKey('album-1'),
            extra: extra,
          );
          final clock = AnimationController(vsync: const TestVSync());
          addTearDown(clock.dispose);
          const preview = Center(child: Text('Album destination'));
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(1200, 800),
                disableAnimations: reduceMotion,
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: AdaptiveContextScope(
                  adaptiveContext: resolveAdaptiveContext(
                    desktopRuntime: true,
                    viewportSize: const Size(1200, 800),
                    safePadding: EdgeInsets.zero,
                  ),
                  child: Builder(
                    builder: (context) {
                      final page = albumRoute!.pageBuilder!(
                        context,
                        state,
                      ) as CustomTransitionPage<void>;
                      expect(
                        (page.child as AlbumDetailScreen).openingHeroTag,
                        isNull,
                      );
                      expect(
                        page.transitionDuration,
                        reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                      );
                      expect(
                        page.reverseTransitionDuration,
                        page.transitionDuration,
                      );
                      clock.duration = page.transitionDuration;
                      return AnimatedBuilder(
                        animation: clock,
                        builder: (context, _) => page.transitionsBuilder(
                          context,
                          clock,
                          const AlwaysStoppedAnimation<double>(0),
                          preview,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          clock.forward();
          await tester.pump();
          expect(find.byType(SlideTransition), findsNothing);
          expect(find.byType(Hero), findsNothing);
          if (reduceMotion) {
            expect(find.byType(FadeTransition), findsNothing);
            expect(clock.status, AnimationStatus.completed);
          } else {
            final position = tester.getRect(find.text('Album destination'));
            await tester.pump(const Duration(milliseconds: 90));
            final opacity = tester
                .widget<FadeTransition>(find.byType(FadeTransition))
                .opacity
                .value;
            expect(opacity, allOf(greaterThan(0), lessThan(1)));
            expect(tester.getRect(find.text('Album destination')), position);
            await tester.pump(const Duration(milliseconds: 90));
            expect(clock.value, closeTo(1, 0.000001));
            await tester.pump(const Duration(milliseconds: 1));
            expect(clock.status, AnimationStatus.completed);
            expect(
              tester
                  .widget<FadeTransition>(find.byType(FadeTransition))
                  .opacity
                  .value,
              1,
            );
            clock.reverse();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 180));
            expect(clock.value, closeTo(0, 0.000001));
            await tester.pump(const Duration(milliseconds: 1));
            expect(clock.status, AnimationStatus.dismissed);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets('redirects unauthenticated user to /login', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );
  });

  testWidgets('stays on login while auth state is loading', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncLoading<ServerConfigModel?>(),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );
  });

  testWidgets('shows home shell when authenticated', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
        scrobbleDispatchControllerProvider.overrideWith(
          _NoopScrobbleDispatchController.new,
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktopSidebarRegion')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('desktopPlayerBar')),
      findsOneWidget,
    );
    expect(find.text('Unknown track'), findsNothing);
  });

  testWidgets('fresh authenticated profile stays on required library setup', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      initialSyncRequired: true,
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              id: 1,
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ).overrideWith(_StaticRequiredLibraryRebuildController.new),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Building Your Library'), findsOneWidget);
    expect(find.byKey(const ValueKey('desktopSidebarRegion')), findsNothing);
    expect(find.byKey(const ValueKey('requiredSyncSignOut')), findsOneWidget);
  });

  testWidgets('cache renewal has priority over onboarding', (tester) async {
    final container = _createContainerWithDatabase(
      onboardingVersion: 0,
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          AsyncData(
            ServerConfigModel(
              id: 1,
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
              lastSynced: DateTime(2026, 8, 26),
            ),
          ),
        ),
        cacheSystemUpgradeRequiredProvider.overrideWithValue(true),
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.cacheUpgrade,
        ).overrideWith(_StaticCacheUpgradeRebuildController.new),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final router = container.read(appRouterProvider);
    expect(router.state.matchedLocation, '/library-rebuild');
    expect(
      router.routeInformationProvider.value.uri.queryParameters['reason'],
      'cache-upgrade',
    );
    expect(
      router
          .routeInformationProvider
          .value
          .uri
          .queryParameters['homeWarmupEligible'],
      '1',
    );
    expect(find.byKey(const ValueKey('requiredSyncSignOut')), findsOneWidget);
  });

  testWidgets('initial library build has priority over onboarding', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      initialSyncRequired: true,
      onboardingVersion: 0,
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              id: 1,
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        requiredLibraryRebuildControllerProvider(
          RequiredLibraryRebuildReason.initialLogin,
        ).overrideWith(_StaticRequiredLibraryRebuildController.new),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final router = container.read(appRouterProvider);
    expect(router.state.matchedLocation, '/initial-sync');
    expect(
      router
          .routeInformationProvider
          .value
          .uri
          .queryParameters['homeWarmupEligible'],
      '1',
    );
    expect(find.text('Building Your Library'), findsOneWidget);
  });

  testWidgets('completed cache renewal goes directly to onboarding', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/library-rebuild',
      routes: <RouteBase>[
        GoRoute(
          path: '/library-rebuild',
          builder: (context, state) => const RequiredLibraryRebuildScreen(
            reason: RequiredLibraryRebuildReason.cacheUpgrade,
            homeWarmupEligible: true,
          ),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) =>
              const Scaffold(body: Text('Onboarding destination')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onboardingVersionProvider.overrideWithValue(const AsyncData(0)),
          requiredLibraryRebuildControllerProvider(
            RequiredLibraryRebuildReason.cacheUpgrade,
          ).overrideWith(_CompletedCacheUpgradeRebuildController.new),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
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

    expect(find.text('Onboarding destination'), findsOneWidget);
    expect(
      router.routeInformationProvider.value.uri.queryParameters['homeWarmup'],
      '1',
    );
  });

  testWidgets('shows offline banner when reachability is offline', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.offline,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Server unreachable. Retrying every 30s.'),
      findsOneWidget,
    );
  });

  for (final (name, size, desktopRuntime, topInset)
      in <(String, Size, bool, double)>[
        ('phone', Size(400, 800), false, 24),
        ('tablet rail', Size(1100, 800), false, 24),
        ('desktop', Size(1100, 800), true, 0),
      ]) {
    testWidgets('offline banner owns the status bar inset on a $name', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 2
        ..physicalSize = size * 2
        ..padding = FakeViewPadding(top: topInset * 2)
        ..viewPadding = FakeViewPadding(top: topInset * 2);
      addTearDown(tester.view.reset);
      final reachability = _StaticReachabilityController(
        const ServerReachabilityState(status: ServerReachabilityStatus.offline),
      );
      final container = _createContainerWithDatabase(
        overrides: [
          desktopPresentationRuntimeProvider.overrideWithValue(desktopRuntime),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          serverReachabilityControllerProvider.overrideWith(() => reachability),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeFrequentAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
          artistInfoProvider.overrideWith((ref, artistId) async => null),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _testApp),
      );
      await tester.pumpAndSettle();
      container.read(appRouterProvider).go(AppRoutes.library);
      await tester.pumpAndSettle();

      final banner = find.byKey(ShellOfflineBanner.bannerKey);
      expect(banner, findsOneWidget);
      // The banner fills the status bar strip; its content sits below it.
      expect(tester.getTopLeft(banner).dy, 0);
      expect(
        tester.getSize(banner).height,
        topInset + ShellOfflineBanner.contentHeight,
      );
      expect(
        tester
            .getTopLeft(find.text('Server unreachable. Retrying every 30s.'))
            .dy,
        greaterThanOrEqualTo(topInset),
      );
      // The page starts right under the banner and does not add the status
      // bar height a second time.
      final page = find
          .descendant(
            of: find.byType(StatefulNavigationShell),
            matching: find.byType(Scaffold),
          )
          .first;
      expect(
        tester.getTopLeft(page).dy,
        // The desktop workspace keeps its own content margin.
        desktopRuntime
            ? greaterThanOrEqualTo(tester.getBottomLeft(banner).dy)
            : tester.getBottomLeft(banner).dy,
      );
      expect(MediaQuery.paddingOf(tester.element(page)).top, 0);
      if (name == 'phone') {
        // Only the 12px portrait toolbar sits above the Library tabs.
        expect(
          tester.getTopLeft(find.byType(TabBar)).dy,
          tester.getBottomLeft(banner).dy + 12,
        );
      }

      await tester.tap(find.byKey(ShellOfflineBanner.retryKey));
      await tester.pumpAndSettle();
      expect(reachability.retryCalls, 1);
    });
  }

  testWidgets('app notices never sit over the offline banner as it goes', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 2
      ..physicalSize = const Size(400, 800) * 2
      ..padding = const FakeViewPadding(top: 48)
      ..viewPadding = const FakeViewPadding(top: 48);
    addTearDown(tester.view.reset);
    final reachability = _StaticReachabilityController(
      const ServerReachabilityState(status: ServerReachabilityStatus.offline),
    );
    final container = _createContainerWithDatabase(
      overrides: [
        desktopPresentationRuntimeProvider.overrideWithValue(false),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(() => reachability),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    container
        .read(appNoticeDiagnosticsProvider.notifier)
        .show(message: 'Notice under the banner', level: AppNoticeLevel.info);
    await tester.pumpAndSettle();
    final banner = find.byKey(ShellOfflineBanner.bannerKey);
    final notice = find.text('Notice under the banner');
    expect(notice, findsOneWidget);
    expect(
      tester.getTopLeft(notice).dy,
      greaterThan(tester.getBottomLeft(banner).dy),
    );

    reachability.set(
      const ServerReachabilityState(status: ServerReachabilityStatus.online),
    );
    await tester.pump();
    var collapsingFrames = 0;
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (banner.evaluate().isEmpty) {
        break;
      }
      collapsingFrames++;
      expect(
        tester.getTopLeft(notice).dy,
        greaterThan(tester.getBottomLeft(banner).dy),
        reason: 'frame $frame of the collapse',
      );
    }
    expect(collapsingFrames, greaterThan(3));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    // Back in its usual place below the status bar.
    expect(tester.getTopLeft(notice).dy, greaterThan(24 + 12));
    expect(tester.getTopLeft(notice).dy, lessThan(24 + 12 + 24));
  });

  testWidgets('supports route params for detail pages', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/library/artists/artist-42');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Artist'), findsOneWidget);

    router.go('/settings/cache');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Cache & Storage'), findsWidgets);

    // Flush any pending Riverpod retry timers (e.g. from the artist provider
    // failing its HTTP call in the test environment) to avoid a pending-timer
    // assertion after widget disposal.
    await tester.pump(const Duration(milliseconds: 500));
  });

  group('detail pages follow their id', () {
    // `router.go` between two ids of one detail route reuses the page's
    // State unless the id keys the page, so the second id would never be
    // hydrated and would show the first one's content.
    Future<GoRouter> openApp(WidgetTester tester) async {
      _RecordingLibrarySyncController.requests.clear();
      final container = _createContainerWithDatabase(
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          serverReachabilityControllerProvider.overrideWith(
            () => _StaticReachabilityController(
              const ServerReachabilityState(
                status: ServerReachabilityStatus.online,
              ),
            ),
          ),
          librarySyncControllerProvider.overrideWith(
            _RecordingLibrarySyncController.new,
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeFrequentAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
          artistInfoProvider.overrideWith((ref, artistId) async => null),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: _testApp),
      );
      await tester.pumpAndSettle();
      return container.read(appRouterProvider);
    }

    Future<void> goTo(WidgetTester tester, GoRouter router, String path) async {
      router.go(path);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('going from one artist to another hydrates the second', (
      tester,
    ) async {
      final router = await openApp(tester);

      await goTo(tester, router, '/library/artists/ext-deezer-artist-1');
      await goTo(tester, router, '/library/artists/ext-deezer-artist-2');

      expect(_RecordingLibrarySyncController.requests, <String>[
        'artist:ext-deezer-artist-1',
        'artist:ext-deezer-artist-2',
      ]);
      // Leaves the page so its hydration timeout does not outlive the test.
      await goTo(tester, router, '/settings/cache');
    });

    testWidgets('going from one album to another hydrates the second', (
      tester,
    ) async {
      final router = await openApp(tester);

      await goTo(tester, router, '/library/albums/ext-deezer-album-1');
      await goTo(tester, router, '/library/albums/ext-deezer-album-2');

      expect(_RecordingLibrarySyncController.requests, <String>[
        'album:ext-deezer-album-1',
        'album:ext-deezer-album-2',
      ]);
      await goTo(tester, router, '/settings/cache');
    });
  });

  testWidgets('retired Settings paths redirect to their new pages', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(
            ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/settings/external-services');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(router.state.matchedLocation, '/settings/integrations');
    expect(find.text('Online services'), findsOneWidget);

    router.go('/settings/group-listening');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(router.state.matchedLocation, '/settings/server');
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('hero-driven album detail does not fade the landing artwork', (
    tester,
  ) async {
    final child = SizedBox(key: UniqueKey());

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            final page = buildSlideFadePage<void>(
              context: context,
              key: const ValueKey<String>('album-detail'),
              heroDriven: true,
              child: child,
            ) as CustomTransitionPage<void>;
            return page.transitionsBuilder(
              context,
              const AlwaysStoppedAnimation<double>(0.5),
              const AlwaysStoppedAnimation<double>(0),
              child,
            );
          },
        ),
      ),
    );

    expect(find.byKey(child.key!), findsOneWidget);
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
  });

  testWidgets('fade-only album detail does not travel during the route fade', (
    tester,
  ) async {
    final child = SizedBox(key: UniqueKey());

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            final page = buildSlideFadePage<void>(
              context: context,
              key: const ValueKey<String>('mobile-album-detail'),
              fadeOnly: true,
              child: child,
            ) as CustomTransitionPage<void>;
            expect(page.transitionDuration, const Duration(milliseconds: 180));
            expect(
              page.reverseTransitionDuration,
              const Duration(milliseconds: 180),
            );
            return page.transitionsBuilder(
              context,
              const AlwaysStoppedAnimation<double>(0.5),
              const AlwaysStoppedAnimation<double>(0),
              child,
            );
          },
        ),
      ),
    );

    expect(find.byKey(child.key!), findsOneWidget);
    expect(find.byType(FadeTransition), findsOneWidget);
    expect(find.byType(SlideTransition), findsNothing);
  });

  testWidgets('reduced motion removes the detail-route fade and slide', (
    tester,
  ) async {
    final child = SizedBox(key: UniqueKey());

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              final page = buildSlideFadePage<void>(
                context: context,
                key: const ValueKey<String>('detail'),
                child: child,
              ) as CustomTransitionPage<void>;
              expect(page.transitionDuration, Duration.zero);
              expect(page.reverseTransitionDuration, Duration.zero);
              return page.transitionsBuilder(
                context,
                const AlwaysStoppedAnimation<double>(0.5),
                const AlwaysStoppedAnimation<double>(0),
                child,
              );
            },
          ),
        ),
      ),
    );

    expect(find.byKey(child.key!), findsOneWidget);
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);
  });

  testWidgets('keeps the current route across a sync timestamp update', (
    tester,
  ) async {
    const config = ServerConfigModel(
      id: 1,
      url: 'https://example.com',
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
    );
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigProvider.overrideWith(
          () => _TestServerConfigNotifier(config),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
        scrobbleDispatchControllerProvider.overrideWith(
          _NoopScrobbleDispatchController.new,
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/library');
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/library');

    await container
        .read(serverConfigProvider.notifier)
        .save(config.copyWith(lastSynced: DateTime.utc(2026, 8, 10)));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(container.read(appRouterProvider), same(router));
    expect(router.state.matchedLocation, '/library');
  });

  testWidgets('iOS detail pages keep the edge-swipe back gesture', (
    tester,
  ) async {
    late Page<void> page;
    late Page<void> heroPage;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) {
            page = buildSlideFadePage<void>(
              context: context,
              key: const ValueKey('detail'),
              child: const SizedBox(),
            );
            heroPage = buildSlideFadePage<void>(
              context: context,
              key: const ValueKey('hero'),
              heroDriven: true,
              child: const SizedBox(),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(page, isA<CupertinoPage<void>>());
    expect(heroPage, isA<CustomTransitionPage<void>>());
  });

  testWidgets('every AppRoutes location resolves to a real route', (
    tester,
  ) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
      ],
    );
    final configuration = container.read(appRouterProvider).configuration;
    final locations = <String>[
      AppRoutes.home,
      AppRoutes.library,
      AppRoutes.search,
      AppRoutes.settings,
      AppRoutes.login,
      AppRoutes.initialSync,
      AppRoutes.libraryRebuild,
      AppRoutes.onboardingReview,
      AppRoutes.album('al/bum?#1'),
      AppRoutes.artist('artist 1'),
      AppRoutes.artistTopTracks('artist-1'),
      AppRoutes.playlist('playlist-1'),
      AppRoutes.listenBrainzWeekly('patch/1'),
      AppRoutes.likedAlbums,
      AppRoutes.likedArtists,
      AppRoutes.matchFlow,
      AppRoutes.matchFlowSearch('flow-1'),
      AppRoutes.changelog,
      AppRoutes.privacy,
      for (final page in SettingsPage.values) page.location,
    ];
    for (final location in locations) {
      final match = configuration.findMatch(Uri.parse(location));
      expect(match.isError, isFalse, reason: location);
      expect(match.isEmpty, isFalse, reason: location);
    }
    expect(
      configuration
          .findMatch(Uri.parse(AppRoutes.album('al/bum?#1')))
          .pathParameters['id'],
      'al/bum?#1',
    );
  });

  testWidgets('contains all expected route paths', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
      ],
    );

    final router = container.read(appRouterProvider);

    final configuredLocations = <String>{};
    void collect(RouteBase route, [String prefix = '']) {
      if (route case GoRoute(:final path, routes: final routes)) {
        final full = path.startsWith('/') ? path : '$prefix/$path';
        configuredLocations.add(full.replaceAll('//', '/'));
        for (final child in routes) {
          collect(child, full);
        }
      } else if (route case StatefulShellRoute(:final branches)) {
        for (final branch in branches) {
          for (final route in branch.routes) {
            collect(route, prefix);
          }
        }
      }
    }

    router.configuration.routes.forEach(collect);

    expect(configuredLocations, contains('/login'));
    expect(configuredLocations, contains('/initial-sync'));
    expect(configuredLocations, contains('/library-rebuild'));
    expect(configuredLocations, contains('/'));
    expect(configuredLocations, contains('/library'));
    expect(configuredLocations, contains('/library/artists/:id'));
    expect(configuredLocations, contains('/library/albums/:id'));
    expect(configuredLocations, contains('/search'));
    expect(configuredLocations, contains('/library/playlists/:id'));
    expect(configuredLocations, contains('/settings'));
    expect(configuredLocations, contains('/settings/server'));
    expect(configuredLocations, contains('/settings/integrations'));
    expect(configuredLocations, isNot(contains('/settings/audiomuse')));
    expect(configuredLocations, contains('/settings/cache'));
    expect(configuredLocations, contains('/settings/sync'));
    expect(configuredLocations, contains('/settings/playback'));
    expect(configuredLocations, contains('/settings/appearance'));

    // /queue is now a modal sheet (NavService.showQueue), not a GoRouter route.
    // /downloads will be re-added in Phase 8.

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sign out from server settings routes user to /login', (
    tester,
  ) async {
    late _TestServerConfigNotifier notifier;

    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigProvider.overrideWith(
          () => notifier = _TestServerConfigNotifier(
            const ServerConfigModel(
              url: 'https://example.com',
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          ),
        ),
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        signOutServiceProvider.overrideWithValue(
          _CallbackSignOutService(({required wipeLocalData}) async {
            await notifier.clear();
          }),
        ),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
        homeRecentlyPlayedProvider.overrideWithValue(
          const AsyncData(<SongsTableData>[]),
        ),
        homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeFrequentAlbumsProvider.overrideWithValue(
          const AsyncData(<Album>[]),
        ),
        homeRandomAlbumsProvider.overrideWithValue(const AsyncData(<Album>[])),
        homeStarredSongsProvider.overrideWithValue(const AsyncData(<Song>[])),
        artistInfoProvider.overrideWith((ref, artistId) async => null),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _testApp),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/settings/server');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out (keep local data)'));
    await tester.pumpAndSettle();

    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );
  });

  group('navigation source guard', () {
    // Files outside lib/src/routing that may drive the router directly, and
    // why. Every entry must still contain a direct call, so stale entries fail.
    const allowedDirectRouterFiles = <String, String>{
      'lib/src/features/auth/presentation/login_screen.dart':
          'signing in replaces the whole app location',
      'lib/src/features/settings/presentation/server_settings_screen.dart':
          'signing out replaces the whole app location',
      'lib/src/features/onboarding/presentation/onboarding_screen.dart':
          'finishing first-run onboarding enters the app',
      'lib/src/features/library/presentation/required_library_rebuild_screen.dart':
          'a completed rebuild leaves the full-screen flow',
      'lib/src/features/settings/presentation/cache_settings_screen.dart':
          'a cache reset enters the full-screen rebuild flow',
      'lib/src/features/player/presentation/playback_recovery_provider.dart':
          'playback recovery enters the full-screen rebuild flow',
      'lib/src/utils/sync_diagnostics_server.dart':
          'the diagnostics API drives the router deliberately',
    };
    final directRouterCall = RegExp(
      r'(?:\b(?:context|router|_router)|GoRouter\.of\([^)]*\)|'
      r'read\(\s*appRouterProvider\s*\)|\b_router\(\))\s*\.\s*'
      r'(?:go|push|pushReplacement|replace|restore)\s*(?:<[^>]*>)?\s*\(',
    );
    final routeLiteral = RegExp(
      r'''['"]/(?:library|settings|search|login|onboarding|initial-sync)\b''',
    );

    Iterable<({String path, String source})> libSources() sync* {
      for (final entity in Directory('lib').listSync(recursive: true)) {
        final path = entity.path.replaceAll(r'\', '/');
        if (entity is! File ||
            !path.endsWith('.dart') ||
            path.endsWith('.g.dart') ||
            path.endsWith('.freezed.dart') ||
            path.startsWith('lib/l10n/')) {
          continue;
        }
        yield (path: path, source: _blankComments(entity.readAsStringSync()));
      }
    }

    String location(String source, int offset) =>
        '${'\n'.allMatches(source.substring(0, offset)).length + 1}';

    test('feature code navigates through NavService', () {
      final violations = <String>[];
      final unusedAllowances = allowedDirectRouterFiles.keys.toSet();
      for (final file in libSources()) {
        if (file.path.startsWith('lib/src/routing/')) {
          continue;
        }
        final matches = directRouterCall.allMatches(file.source).toList();
        if (matches.isEmpty) {
          continue;
        }
        if (unusedAllowances.remove(file.path)) {
          continue;
        }
        for (final match in matches) {
          violations.add(
            '${file.path}:${location(file.source, match.start)}: '
            '${match.group(0)}',
          );
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'Use NavService for app navigation:\n${violations.join('\n')}',
      );
      expect(
        unusedAllowances,
        isEmpty,
        reason: 'Remove stale direct-router allowances.',
      );
    });

    test('route locations are only written in app_routes.dart', () {
      final violations = <String>[
        for (final file in libSources())
          if (file.path != 'lib/src/routing/app_routes.dart')
            for (final match in routeLiteral.allMatches(file.source))
              '${file.path}:${location(file.source, match.start)}: '
                  '${match.group(0)}',
      ];
      expect(
        violations,
        isEmpty,
        reason: 'Build locations with AppRoutes:\n${violations.join('\n')}',
      );
    });
  });
}

/// Replaces comments with spaces, keeping newlines so offsets map to lines.
String _blankComments(String source) {
  return source.replaceAllMapped(
    RegExp(r'//[^\n]*|/\*[\s\S]*?\*/'),
    (match) => match.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '),
  );
}
