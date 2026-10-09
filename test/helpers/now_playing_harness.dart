import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import 'adaptive_test_harness.dart';
import 'test_database.dart';
import 'test_theme.dart';

/// Test-controlled playback state that the Now Playing screen reads through
/// the real `playerStateProvider`.
class NowPlayingTestPlayback extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();
}

final nowPlayingTestPlaybackProvider =
    NotifierProvider<NowPlayingTestPlayback, PlaybackSnapshot>(
      NowPlayingTestPlayback.new,
    );

/// Builds a container backed by a test database whose player state follows
/// [nowPlayingTestPlaybackProvider]. The container and database are disposed
/// when the test ends.
ProviderContainer createNowPlayingContainer({
  List<Override> overrides = const <Override>[],
}) {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        playerStateProvider.overrideWith(
          (ref) => ref.watch(nowPlayingTestPlaybackProvider),
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

/// Publishes [snapshot] as the current playback state. Callers decide whether
/// to `pump` or `pumpAndSettle` afterwards.
void emitNowPlayingPlayback(
  ProviderContainer container,
  PlaybackSnapshot snapshot,
) {
  container.read(nowPlayingTestPlaybackProvider.notifier).state = snapshot;
}

/// Sets the 880x1200 viewport the transition tests use and mounts a plain
/// [NowPlayingScreen]. It only calls `pumpWidget`; the caller pumps frames
/// explicitly so animation assertions keep their observation points.
Future<void> pumpPlainNowPlayingScreen(
  WidgetTester tester,
  ProviderContainer container, {
  Size viewport = const Size(880, 1200),
}) async {
  setAdaptiveTestViewport(tester, viewport);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: NowPlayingScreen()),
      ),
    ),
  );
}
