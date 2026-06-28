import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_repository.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void emitSnapshot(PlaybackSnapshot snapshot, [Object? marker]) {
    state = snapshot;
  }
}

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient {}

class _MockAudioMuseRepository extends Mock implements AudioMuseRepository {}

class _FakeQueueController extends QueueController {
  _FakeQueueController({this.insertedCount, this.error});

  final List<List<Song>> mixTrackBatches = <List<Song>>[];
  final int? insertedCount;
  final Exception? error;

  @override
  List<String> build() => const <String>[];

  @override
  Future<int> insertMixTracksAfterCurrent(
    List<Song> songs, {
    bool expandMatchFlows = false,
  }) async {
    mixTrackBatches.add(List<Song>.from(songs));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    return insertedCount ?? songs.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Song> songs(int count, {String prefix = 'rec'}) {
    return List<Song>.generate(
      count,
      (index) => Song(id: '$prefix-$index', title: 'Track $index'),
      growable: false,
    );
  }

  PlaybackSnapshot snapshot({
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

  test('deactivates when queue is cleared', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['a', 'b', 'c', 'd'],
            currentSongId: 'a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('a');

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          const PlaybackSnapshot.idle(),
        );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(instantMixProvider);
    expect(state.active, isFalse);
    expect(state.seedSongId, isNull);
  });

  test(
    'legacy activation inserts 50 Subsonic instant-mix tracks',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      when(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(50));

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          audioMuseRepositoryProvider.overrideWith((_) => null),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'queued'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');

      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queue.mixTrackBatches, hasLength(1));
      expect(queue.mixTrackBatches.single, hasLength(50));
      expect(queue.mixTrackBatches.single.first.id, 'rec-0');
      verify(() => api.getInstantMix('seed', count: 50)).called(1);
      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test(
    'legacy activation treats partial queue insertion as success',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      when(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(50));

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(
            () => _FakeQueueController(insertedCount: 1),
          ),
          subsonicApiProvider.overrideWithValue(api),
          audioMuseRepositoryProvider.overrideWith((_) => null),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'rec-0'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );
      await Future<void>.delayed(Duration.zero);

      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      final state = container.read(instantMixProvider);
      expect(queue.mixTrackBatches, hasLength(1));
      expect(state.active, isTrue);
      expect(state.error, isNull);
      expect(state.pendingSnackbar, '1');
    },
  );

  test(
    'legacy activation with zero inserted tracks fails once and deactivates',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      when(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(50));

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(
            () => _FakeQueueController(insertedCount: 0),
          ),
          subsonicApiProvider.overrideWithValue(api),
          audioMuseRepositoryProvider.overrideWith((_) => null),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );
      await Future<void>.delayed(Duration.zero);

      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      final state = container.read(instantMixProvider);
      expect(queue.mixTrackBatches, hasLength(1));
      expect(state.active, isFalse);
      expect(state.error, InstantMixError.networkError);
    },
  );

  test(
    'legacy activation falls back to similar songs when instant mix is unsupported',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      when(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        const SubsonicNotFoundException(message: 'Unsupported endpoint'),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(50, prefix: 'similar'));

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          audioMuseRepositoryProvider.overrideWith((_) => null),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'queued'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');

      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queue.mixTrackBatches, hasLength(1));
      expect(queue.mixTrackBatches.single, hasLength(50));
      expect(queue.mixTrackBatches.single.first.id, 'similar-0');
      verify(() => api.getInstantMix('seed', count: 50)).called(1);
      verify(() => api.getSimilarSongs('seed', count: 50)).called(1);
    },
  );

  test('AudioMuse recommendations insert with playNextWithSongs', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final audioMuse = _MockAudioMuseRepository();
    when(
      () => audioMuse.getRecommendations(
        seedSongId: any(named: 'seedSongId'),
      ),
    ).thenAnswer(
      (_) async => const <AudioMuseRecommendation>[
        AudioMuseRecommendation(id: 'ai-1', title: 'AI 1'),
        AudioMuseRecommendation(id: 'ai-2', title: 'AI 2'),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWithValue(audioMuse),
        lastFmApiKeyProvider.overrideWithValue('test-key'),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(
              legacyInstantMixEnabled: false,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'queued'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');

    final queue =
        container.read(queueProvider.notifier) as _FakeQueueController;
    expect(queue.mixTrackBatches.single.length, 2);
    expect(queue.mixTrackBatches.single.first.id, 'ai-1');
  });

  test('auto-refill path updates seed when remaining tracks <= 3', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd', 'e'],
            currentSongId: 'seed-a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('seed-a');

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-b',
            currentIndex: 0,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(instantMixProvider);
    expect(state.active, isTrue);
    expect(state.seedSongId, 'seed-b');
  });

  test('does not auto-refill while radio mode is active', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('seed-a');

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-radio',
            currentIndex: 0,
            radioMode: true,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(instantMixProvider);
    expect(state.seedSongId, 'seed-a');
  });
}
