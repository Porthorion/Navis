import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:riverpod/src/framework.dart' show Override;
import '../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _TestServerConfigNotifier extends ServerConfigNotifier {
  _TestServerConfigNotifier(this._initial);

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

  @override
  Future<void> clear() async {
    _initial = null;
    state = const AsyncData(null);
  }
}

class _CallbackSignOutService implements SignOutService {
  _CallbackSignOutService(this._onSignOut);

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
    bool forceFull = false,
    bool preferIncremental = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

class _NoopScrobbleDispatchController extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

ProviderContainer _createContainerWithDatabase({
  List<Override> overrides = const <Override>[],
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(database, overrides: overrides),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

void main() {
  testWidgets('redirects unauthenticated user to /login', (tester) async {
    final container = _createContainerWithDatabase(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        librarySyncControllerProvider.overrideWith(
          _StaticLibrarySyncController.new,
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
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
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
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
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Unknown track'), findsNothing);
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
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Server unreachable. Retrying every 30s.'),
      findsOneWidget,
    );
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
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
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

    for (final route in router.configuration.routes) {
      collect(route);
    }

    expect(configuredLocations, contains('/login'));
    expect(configuredLocations, contains('/'));
    expect(configuredLocations, contains('/library'));
    expect(configuredLocations, contains('/library/artists/:id'));
    expect(configuredLocations, contains('/library/albums/:id'));
    expect(configuredLocations, contains('/search'));
    expect(configuredLocations, contains('/library/playlists/:id'));
    expect(configuredLocations, contains('/settings'));
    expect(configuredLocations, contains('/settings/server'));
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
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
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

    expect(find.text('Sign in'), findsOneWidget);
  });
}
