import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_shuffle_controls.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required AudioServiceShuffleMode shuffleMode,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(
            PlaybackSnapshot(
              queueSongIds: const <String>['song-1'],
              currentSongId: 'song-1',
              currentIndex: 0,
              playing: false,
              position: Duration.zero,
              bufferedPosition: Duration.zero,
              duration: Duration.zero,
              processingState: AudioProcessingState.ready,
              repeatMode: AudioServiceRepeatMode.none,
              shuffleMode: shuffleMode,
            ),
          ),
          audioHandlerProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Row(
              children: [
                QueueShuffleToggle(),
                QueueShuffleBadge(child: Icon(Icons.queue_music_outlined)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Badge badge(WidgetTester tester) =>
      tester.widget<Badge>(find.byKey(QueueShuffleBadge.badgeKey));
  IconButton toggle(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(QueueShuffleToggle.toggleKey));

  testWidgets('queue shows shuffle state on its toggle and badge', (
    tester,
  ) async {
    await pump(tester, shuffleMode: AudioServiceShuffleMode.none);
    expect(toggle(tester).isSelected, isFalse);
    expect(toggle(tester).tooltip, 'Shuffle Off');
    expect(badge(tester).isLabelVisible, isFalse);

    await pump(tester, shuffleMode: AudioServiceShuffleMode.all);
    expect(toggle(tester).isSelected, isTrue);
    expect(toggle(tester).tooltip, 'Shuffle');
    expect(badge(tester).isLabelVisible, isTrue);

    await tester.tap(find.byKey(QueueShuffleToggle.toggleKey));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
