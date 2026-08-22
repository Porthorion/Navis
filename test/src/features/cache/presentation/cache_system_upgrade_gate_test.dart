import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/cache/presentation/cache_system_upgrade_gate.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/routing/app_router.dart';

import '../../../../helpers/test_theme.dart';

void main() {
  testWidgets('legacy cache prompt can defer but remains unacknowledged', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.test',
                username: 'user',
                password: 'password',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          cacheSystemUpgradeNeededProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const CacheSystemUpgradeGate(child: Scaffold()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Update Library Cache'), findsOneWidget);
    expect(
      find.textContaining('Your downloaded music will be kept.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Clear Library Cache'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Update Library Cache'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Update Library Cache'), findsNothing);
  });

  testWidgets('clearing the legacy prompt enters the required rebuild route', (
    tester,
  ) async {
    late final GoRouter router;
    router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const CacheSystemUpgradeGate(
            child: Scaffold(body: Text('Home')),
          ),
        ),
        GoRoute(
          path: '/library-rebuild',
          builder: (context, state) => const Scaffold(
            body: Text('Required rebuild'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.test',
                username: 'user',
                password: 'password',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          cacheSystemUpgradeNeededProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Clear Library Cache'));
    await tester.pumpAndSettle();
    expect(find.text('Required rebuild'), findsOneWidget);
    expect(
      router.routeInformationProvider.value.uri.queryParameters['reason'],
      'cache-upgrade',
    );
  });
}
