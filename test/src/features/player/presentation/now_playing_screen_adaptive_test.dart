import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

const PlaybackSnapshot _songPlayback = PlaybackSnapshot(
  queueSongIds: <String>['song-1'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

class _TestPlaybackNotifier extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();
}

final _testPlaybackProvider =
    NotifierProvider<_TestPlaybackNotifier, PlaybackSnapshot>(
      _TestPlaybackNotifier.new,
    );

ProviderContainer _createContainer() {
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        playerStateProvider.overrideWith(
          (ref) => ref.watch(_testPlaybackProvider),
        ),
      ],
    ),
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return container;
}

Finder _findNowPlayingHandle() {
  return find.byWidgetPredicate((widget) {
    if (widget is! Container) {
      return false;
    }
    final constraints = widget.constraints;
    if (constraints == null ||
        constraints.minWidth != 36 ||
        constraints.maxWidth != 36 ||
        constraints.minHeight != 4 ||
        constraints.maxHeight != 4) {
      return false;
    }
    final decoration = widget.decoration;
    return decoration is BoxDecoration && decoration.borderRadius != null;
  });
}

Future<void> _pumpNowPlaying(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: NowPlayingScreen(onCollapse: _noopCollapse)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _noopCollapse() {}

void main() {
  testWidgets(
    'desktop runtime follows width parity for now playing wide mode',
    (tester) async {
      if (!sqliteAvailable) {
        return;
      }
      setAdaptiveTestViewport(tester, const Size(840, 1000));
      final container = _createContainer();
      await _pumpNowPlaying(tester, container);

      expect(_findNowPlayingHandle(), findsOneWidget);
      expect(find.byKey(const Key('nowPlayingCloseButton')), findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1200, 1000);
      await tester.pumpAndSettle();

      expect(_findNowPlayingHandle(), findsNothing);
      expect(find.byKey(const Key('nowPlayingCloseButton')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('split layout lyrics action opens fullscreen lyrics page', (
    tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    setAdaptiveTestViewport(tester, const Size(1000, 900));
    final container = _createContainer();
    container.read(_testPlaybackProvider.notifier).state = _songPlayback;
    await _pumpNowPlaying(tester, container);

    expect(find.text('Lyrics'), findsNothing);
    await tester.tap(find.byTooltip('Lyrics').first);
    await tester.pumpAndSettle();

    expect(find.text('Lyrics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
