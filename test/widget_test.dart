import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
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
  _StaticAudioBootstrapController({
    required AudioBootstrapState state,
    this.onRetry,
  }) : _state = state;

  final AudioBootstrapState _state;
  final VoidCallback? onRetry;

  @override
  AudioBootstrapState build() => _state;

  @override
  void ensureInitialized() {}

  @override
  Future<void> retry() async {
    onRetry?.call();
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

  testWidgets('shows retry action when playback bootstrap fails', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _noDbOverrides(
          extras: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.failed('failed'),
                onRetry: () => retried = true,
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

    expect(find.text('Playback initialization failed'), findsOneWidget);
    await tester.tap(find.text('Retry playback startup'));
    await tester.pump();
    expect(retried, isTrue);
  });
}
