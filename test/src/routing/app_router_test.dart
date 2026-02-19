import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/routing/app_router.dart';

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

void main() {
  testWidgets('redirects unauthenticated user to /login', (tester) async {
    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
      ],
    );
    addTearDown(container.dispose);

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
    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWithValue(
          const AsyncLoading<ServerConfigModel?>(),
        ),
      ],
    );
    addTearDown(container.dispose);

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
    final container = ProviderContainer(
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
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Phase 3: discovery feed and personalized carousels.'),
      findsOneWidget,
    );
    expect(find.text('MiniPlayer (Phase 5)'), findsOneWidget);
  });

  testWidgets('shows offline banner when reachability is offline', (
    tester,
  ) async {
    final container = ProviderContainer(
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
      ],
    );
    addTearDown(container.dispose);

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
    final container = ProviderContainer(
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
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NavisApp(),
      ),
    );
    await tester.pumpAndSettle();

    final router = container.read(appRouterProvider);
    router.go('/library/artists/artist-42');
    await tester.pumpAndSettle();

    expect(find.text('Artist ID: artist-42'), findsOneWidget);

    router.go('/settings/cache');
    await tester.pumpAndSettle();

    expect(find.text('Cache Settings'), findsWidgets);
  });

  testWidgets('contains all expected route paths', (tester) async {
    final container = ProviderContainer(
      overrides: [
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
      ],
    );
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);

    final configuredLocations = <String>{};
    void collect(RouteBase route, [String prefix = '']) {
      if (route case GoRoute(path: final path, routes: final routes)) {
        final full = path.startsWith('/') ? path : '$prefix/$path';
        configuredLocations.add(full.replaceAll('//', '/'));
        for (final child in routes) {
          collect(child, full);
        }
      } else if (route case StatefulShellRoute(branches: final branches)) {
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
    expect(configuredLocations, contains('/playlists'));
    expect(configuredLocations, contains('/playlists/:id'));
    expect(configuredLocations, contains('/settings'));
    expect(configuredLocations, contains('/settings/server'));
    expect(configuredLocations, contains('/settings/cache'));
    expect(configuredLocations, contains('/settings/playback'));
    expect(configuredLocations, contains('/settings/appearance'));
    expect(configuredLocations, contains('/downloads'));
    expect(configuredLocations, contains('/now-playing'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sign out from server settings routes user to /login', (
    tester,
  ) async {
    late _TestServerConfigNotifier notifier;

    final container = ProviderContainer(
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
      ],
    );
    addTearDown(container.dispose);

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
