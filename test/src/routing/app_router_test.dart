import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/routing/app_router.dart';

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
      find.text('Phase 2: server URL, username and password form.'),
      findsOneWidget,
    );
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
}
