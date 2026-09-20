import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _QueueHandler extends Mock implements NavisPlaybackHandler {
  _QueueHandler(this.insertCount);

  final int insertCount;
  final List<String> ids = <String>['existing'];

  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot(
    queueSongIds: List<String>.of(ids),
    currentSongId: ids.first,
    currentIndex: 0,
    playing: false,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: Duration.zero,
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.none,
  );

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    ids.addAll(songIds.take(insertCount));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final count in <int>[0, 1, 2]) {
    test('reports $count actual recommendation insertions', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final handler = _QueueHandler(count);
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          audioHandlerProvider.overrideWithValue(handler),
          playbackSnapshotProvider.overrideWithValue(
            const AsyncData(PlaybackSnapshot.idle()),
          ),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(queueProvider.notifier)
          .appendRecommendationTracks(const <Song>[
            Song(id: 'one', title: 'One'),
            Song(id: 'two', title: 'Two'),
          ]);

      expect(result.count, count);
      expect(result.insertedIds, <String>['one', 'two'].take(count).toList());
    });
  }
}
