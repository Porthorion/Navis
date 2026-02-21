import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'helpers/test_database.dart';

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
    WidgetTester tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
          ],
        ),
        child: const NavisApp(),
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
    WidgetTester tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.initializing(),
              ),
            ),
          ],
        ),
        child: const NavisApp(requirePlaybackBootstrap: true),
      ),
    );
    await tester.pump();

    expect(find.text('Preparing playback'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows retry action when playback bootstrap fails', (
    WidgetTester tester,
  ) async {
    var retried = false;
    final database = createTestDatabase();
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            audioBootstrapControllerProvider.overrideWith(
              () => _StaticAudioBootstrapController(
                state: const AudioBootstrapState.failed('failed'),
                onRetry: () => retried = true,
              ),
            ),
          ],
        ),
        child: const NavisApp(requirePlaybackBootstrap: true),
      ),
    );
    await tester.pump();

    expect(find.text('Playback initialization failed'), findsOneWidget);
    await tester.tap(find.text('Retry playback startup'));
    await tester.pump();
    expect(retried, isTrue);
  });
}
