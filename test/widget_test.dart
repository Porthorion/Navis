import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'helpers/test_theme.dart';

/// Overrides that prevent Drift streams (and their periodic timers) from being
/// subscribed in widget tests.  Without these, `tester.pump()` enters an
/// infinite loop servicing Drift's internal change-check timer.
List<Override> _noDbOverrides({
  List<Override> extras = const [],
  AppSettingsModel settings = const AppSettingsModel.defaults(),
}) {
  return [
    // Prevent the database from being accessed at all.
    appSettingsProvider.overrideWith((_) => Stream.value(settings)),
    onboardingVersionProvider.overrideWithValue(
      const AsyncData(currentOnboardingVersion),
    ),
    retainedServerProvider.overrideWith((_) async => null),
    ...extras,
  ];
}

class _StaticAudioBootstrapController extends AudioBootstrapController {
  new({required this._state});

  final AudioBootstrapState _state;

  @override
  AudioBootstrapState build() => _state;

  @override
  void ensureInitialized() {}
}

class _FakePlaybackRecoveryService implements PlaybackRecoveryService {
  int retryCalls = 0;
  int restartCalls = 0;
  int copyCalls = 0;

  @override
  Future<void> restartNavis() async => restartCalls++;

  @override
  Future<void> copyDetails() async => copyCalls++;
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
  testWidgets(
    'Auto switches cached light and OLED themes with system brightness',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: _noDbOverrides(
            extras: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(null),
              ),
              themeModeProvider.overrideWithValue('system'),
              oledForAutoProvider.overrideWithValue(true),
            ],
          ),
          child: testNavisApp,
        ),
      );
      await tester.pump();
      MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
      final light = app().theme!.colorScheme;
      expect(light, buildLightTheme(defaultColorSchemeSeedColor).colorScheme);
      expect(app().darkTheme, isNull);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      final oled = app().darkTheme!.colorScheme;
      expect(oled, buildOledTheme(defaultColorSchemeSeedColor).colorScheme);
      expect(app().theme, isNull);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      expect(app().theme!.colorScheme, light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      expect(app().darkTheme!.colorScheme, oled);
    },
  );

  testWidgets('resuming re-checks the scheduled Night style', (tester) async {
    var clock = DateTime(2026, 10, 8, 12);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          settings: const AppSettingsModel.defaults().copyWith(
            nightScheduleEnabled: true,
          ),
          extras: [
            nowProvider.overrideWithValue(() => clock),
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          ],
        ),
        child: testNavisApp,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    expect(
      container.read(effectiveColorStyleProvider),
      NavisColorStyle.neutral,
    );

    clock = DateTime(2026, 10, 8, 23);
    expect(
      container.read(effectiveColorStyleProvider),
      NavisColorStyle.neutral,
    );

    <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ].forEach(tester.binding.handleAppLifecycleStateChanged);
    await tester.pump();

    expect(container.read(effectiveColorStyleProvider), NavisColorStyle.night);
  });

  testWidgets('shows login screen while unauthenticated', (tester) async {
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
      tester.getCenter(find.byKey(const ValueKey<String>('bootstrap-logo'))),
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

  testWidgets(
    'shows recovery actions exactly five seconds after the overlay appears',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: _noDbOverrides(
            extras: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(null),
              ),
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

      await tester.pump(const Duration(milliseconds: 4999));
      expect(find.text('Restart Navis'), findsNothing);
      expect(find.text('Copy details'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Restart Navis'), findsOneWidget);
      expect(find.text('Copy details'), findsOneWidget);
      expect(find.text('Continue to sign in'), findsOneWidget);

      await tester.tap(find.text('Continue to sign in'));
      await tester.pump();
      expect(
        find.text('Connect to your Subsonic or Navidrome server.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'recovery panel restarts and copies through its existing service',
    (tester) async {
      final recovery = _FakePlaybackRecoveryService();
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: _noDbOverrides(
            extras: [
              serverConfigStateProvider.overrideWithValue(
                const AsyncData(null),
              ),
              playbackRecoveryServiceProvider.overrideWithValue(recovery),
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
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('Restart Navis'));
      await tester.pump();
      expect(recovery.restartCalls, 1);
      await tester.tap(find.text('Copy details'));
      await tester.pump();
      expect(recovery.copyCalls, 1);
      expect(find.text('Startup details copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final serverConfig in <AsyncValue<ServerConfigModel?>>[
    const AsyncLoading(),
    AsyncError(const CredentialReadException(), StackTrace.empty),
  ]) {
    testWidgets(
      'startup recovery preserves an unknown session: $serverConfig',
      (tester) async {
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: _noDbOverrides(
              extras: [
                serverConfigStateProvider.overrideWithValue(serverConfig),
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

        expect(find.text('Continue to sign in'), findsNothing);
        expect(find.text('Reset library cache and retry'), findsOneWidget);
        expect(find.text('Sign out (keep local data)'), findsOneWidget);
        expect(find.text('Sign out and clear local data'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'shows authenticated startup recovery actions after ten seconds',
    (tester) async {
      final recovery = _FakePlaybackRecoveryService();
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
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
