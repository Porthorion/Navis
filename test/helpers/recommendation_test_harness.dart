import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Test-controlled playback state for recommendation notifier tests.
class RecommendationSnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void emitSnapshot(PlaybackSnapshot snapshot, [Object? marker]) {
    state = snapshot;
  }
}

final recommendationSnapshotProvider =
    NotifierProvider<RecommendationSnapshotController, PlaybackSnapshot>(
      RecommendationSnapshotController.new,
    );

/// Builds a ready, playing snapshot with the defaults the Server Mix and Same
/// Vibes tests share. [radioMode] attaches a radio station.
PlaybackSnapshot recommendationSnapshot({
  required List<String> queueSongIds,
  required String? currentSongId,
  required int? currentIndex,
  bool radioMode = false,
}) {
  return PlaybackSnapshot(
    queueSongIds: queueSongIds,
    currentSongId: currentSongId,
    currentIndex: currentIndex,
    playing: true,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: const Duration(minutes: 3),
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.none,
    radioStation: radioMode
        ? const RadioStationMetadata(
            stationId: 'station-1',
            stationName: 'Test Station',
            streamUrl: 'https://example.com/stream',
          )
        : null,
  );
}

/// Queue controller that records recommendation batches and retained seeds.
/// [insertedCount] caps how many offered songs report as inserted, [error] is
/// thrown after recording a batch, and [onRetain] observes retained seeds.
class RecordingRecommendationQueue extends QueueController {
  new({this.insertedCount, this.error, this.onRetain});

  final List<List<Song>> appendedSongBatches = <List<Song>>[];
  final List<String> retainedSongIds = <String>[];
  final int? insertedCount;
  final Exception? error;
  final void Function(String id)? onRetain;

  List<Song> get queuedSongs =>
      appendedSongBatches.expand((songs) => songs).toList(growable: false);

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> retainCurrentAsQueue(String id) async {
    retainedSongIds.add(id);
    onRetain?.call(id);
  }

  @override
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent != null && !isCurrent()) {
      return const RecommendationQueueResult(<String>[]);
    }
    appendedSongBatches.add(List<Song>.from(songs));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final count = insertedCount ?? songs.length;
    return RecommendationQueueResult(
      songs.take(count).map((song) => song.id).toList(),
    );
  }
}

/// Creates a container whose player state follows
/// [recommendationSnapshotProvider]. [overrides] supply the queue, API, policy
/// and lookup fakes each test needs. The container is disposed with the test.
ProviderContainer createRecommendationContainer({
  List<Override> overrides = const <Override>[],
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      playerStateProvider.overrideWith(
        (ref) => ref.watch(recommendationSnapshotProvider),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}
