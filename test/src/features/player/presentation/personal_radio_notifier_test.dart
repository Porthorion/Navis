import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class _MockRecommendationService extends Mock implements RecommendationService;

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void setQueue(List<String> ids, {int currentIndex = 0}) {
    state = PlaybackSnapshot(
      queueSongIds: ids,
      currentSongId: ids.isEmpty ? null : ids[currentIndex],
      currentIndex: ids.isEmpty ? null : currentIndex,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );
  }
}

class _QueueController extends QueueController {
  new(this.onReplace);

  final void Function(List<String>) onReplace;
  int replacementCount = 0;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replaceWithSongs(
    List<Song> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    replacementCount++;
    onReplace(songs.map((song) => song.id).toList());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const RadioFilters()));

  ProviderContainer makeContainer(
    _MockRecommendationService service,
    NotifierProvider<_SnapshotController, PlaybackSnapshot> snapshotProvider,
  ) {
    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotProvider)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(null),
        recommendationServiceProvider.overrideWithValue(service),
        queueProvider.overrideWith(
          () => _QueueController(
            (ids) => container.read(snapshotProvider.notifier).setQueue(ids),
          ),
        ),
      ],
    );
    return container;
  }

  test('empty start preserves the previous queue', () async {
    final service = _MockRecommendationService();
    when(
      () => service.personalRadio(
        any(),
        excludedIds: any(named: 'excludedIds'),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => const RecommendationBatch(
        songs: <Song>[],
        source: RecommendationSource.shuffle,
        issue: RecommendationIssue.empty,
      ),
    );
    final snapshots = NotifierProvider<_SnapshotController, PlaybackSnapshot>(
      _SnapshotController.new,
    );
    final container = makeContainer(service, snapshots);
    addTearDown(container.dispose);
    container.read(snapshots.notifier).setQueue(<String>['old', 'next']);

    final result = await container.read(personalRadioProvider.notifier).start();

    expect(result.succeeded, isFalse);
    expect(container.read(playerStateProvider).queueSongIds, <String>[
      'old',
      'next',
    ]);
    expect(
      (container.read(
        queueProvider.notifier,
      ) as _QueueController).replacementCount,
      0,
    );
  });

  test(
    'stopped preparation cannot replace the queue after it completes',
    () async {
      final pending = Completer<RecommendationBatch>();
      final service = _MockRecommendationService();
      when(
        () => service.personalRadio(
          any(),
          excludedIds: any(named: 'excludedIds'),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      final snapshots = NotifierProvider<_SnapshotController, PlaybackSnapshot>(
        _SnapshotController.new,
      );
      final container = makeContainer(service, snapshots);
      addTearDown(container.dispose);
      container.read(snapshots.notifier).setQueue(<String>['old']);

      final start = container.read(personalRadioProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);
      container.read(personalRadioProvider.notifier).stop();
      pending.complete(
        const RecommendationBatch(
          songs: <Song>[Song(id: 'late', title: 'Late')],
          source: RecommendationSource.server,
        ),
      );
      await start;

      expect(container.read(playerStateProvider).queueSongIds, <String>['old']);
      expect(
        (container.read(
          queueProvider.notifier,
        ) as _QueueController).replacementCount,
        0,
      );
    },
  );
}
