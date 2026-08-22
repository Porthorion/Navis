import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:riverpod/src/framework.dart' show Override;

import 'helpers/test_theme.dart';

/// Overrides that prevent Drift streams (and their periodic timers) from being
/// subscribed in widget tests.  Without these, `tester.pump()` enters an
/// infinite loop servicing Drift's internal change-check timer.
List<Override> _noDbOverrides({
  List<Override> extras = const [],
}) {
  return [
    // Prevent the database from being accessed at all.
    appSettingsProvider.overrideWith(
      (_) => Stream.value(const AppSettingsModel.defaults()),
    ),
    ...extras,
  ];
}

class _StaticAudioBootstrapController extends AudioBootstrapController {
  _StaticAudioBootstrapController({required AudioBootstrapState state})
    : _state = state;

  final AudioBootstrapState _state;

  @override
  AudioBootstrapState build() => _state;

  @override
  void ensureInitialized() {}
}

class _FakePlaybackRecoveryService implements PlaybackRecoveryService {
  int retryCalls = 0;
  int resetCalls = 0;
  bool? signOutWipeLocalData;

  @override
  void retryPlayback() => retryCalls += 1;

  @override
  Future<void> resetLibraryCacheAndRetry() async {
    resetCalls += 1;
  }

  @override
  Future<void> signOut({required bool wipeLocalData}) async {
    signOutWipeLocalData = wipeLocalData;
  }
}

void main() {
  testWidgets('shows login screen while unauthenticated', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          extras: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          ],
        ),
        child: testNavisApp,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });

  testWidgets('shows playback bootstrap loading gate when required', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          extras: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.initializing(),
              ),
            ),
          ],
        ),
        child: const NavisApp(
          requirePlaybackBootstrap: true,
          splashFactory: NoSplash.splashFactory,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.getCenter(
        find.byKey(const ValueKey<String>('bootstrap-logo')),
      ),
      tester.getCenter(find.byType(CircularProgressIndicator)),
    );
  });

  testWidgets('keeps showing the loading gate when playback bootstrap fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          extras: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.failed('failed'),
              ),
            ),
          ],
        ),
        child: const NavisApp(
          requirePlaybackBootstrap: true,
          splashFactory: NoSplash.splashFactory,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Preparing Playback'), findsOneWidget);
    expect(find.text('Restoring your listening session…'), findsOneWidget);
    expect(find.text('Playback initialization failed'), findsNothing);
    expect(find.text('Retry playback startup'), findsNothing);
  });

  testWidgets('shows an unauthenticated recovery escape after ten seconds', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          extras: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.failed('failed'),
              ),
            ),
          ],
        ),
        child: const NavisApp(
          requirePlaybackBootstrap: true,
          splashFactory: NoSplash.splashFactory,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Continue to sign in'), findsNothing);

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Continue to sign in'), findsOneWidget);

    await tester.tap(find.text('Continue to sign in'));
    await tester.pump();
    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows authenticated startup recovery actions after ten seconds',
    (
      tester,
    ) async {
      final recovery = _FakePlaybackRecoveryService();
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const SizedBox.shrink(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: _noDbOverrides(
            extras: [
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
              playbackRecoveryServiceProvider.overrideWithValue(recovery),
              appRouterProvider.overrideWithValue(router),
              audioBootstrapControllerProvider.overrideWith(
                () => _StaticAudioBootstrapController(
                  state: const AudioBootstrapState.failed('failed'),
                ),
              ),
            ],
          ),
          child: const NavisApp(
            requirePlaybackBootstrap: true,
            splashFactory: NoSplash.splashFactory,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 10));

      expect(find.text('Reset library cache and retry'), findsOneWidget);
      expect(find.text('Sign out (keep local data)'), findsOneWidget);
      expect(find.text('Sign out and clear local data'), findsOneWidget);
    },
  );
}
