import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void emitSnapshot(PlaybackSnapshot snapshot, [Object? marker]) {
    state = snapshot;
  }
}

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

class _FakeQueueController extends QueueController {
  new({this.insertedCount, this.error, this.onRetain});

  final List<List<Song>> mixTrackBatches = <List<Song>>[];
  final List<String> retainedSongIds = <String>[];
  final int? insertedCount;
  final Exception? error;
  final void Function(String id)? onRetain;

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
    mixTrackBatches.add(List<Song>.from(songs));
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

/// Accepts the first recommendation append, then inserts nothing.
class _DryingQueueController extends _FakeQueueController {
  new() : super();

  int appends = 0;

  @override
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) async {
    appends++;
    if (appends > 1) return const RecommendationQueueResult(<String>[]);
    return super.appendRecommendationTracks(
      songs,
      expandMatchFlows: expandMatchFlows,
      isCurrent: isCurrent,
    );
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
        queueProvider.overrideWith(_FakeQueueController.new),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
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
        .emitSnapshot(const PlaybackSnapshot.idle());
    await Future<void>.delayed(Duration.zero);

    final state = container.read(instantMixProvider);
    expect(state.active, isFalse);
    expect(state.seedSongId, isNull);
  });

  test('deactivates when a regular queue replacement starts', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(5));
    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWithValue(api),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
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
    expect(container.read(instantMixProvider).active, isTrue);

    container.read(regularQueueReplacementEpochProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(instantMixProvider).active, isFalse);
  });

  test('server activation inserts 50 generic similar tracks', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(50));

    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(
          () => _FakeQueueController(
            onRetain: (id) {
              container
                  .read(snapshotState.notifier)
                  .emitSnapshot(
                    snapshot(
                      queueSongIds: <String>[id],
                      currentSongId: id,
                      currentIndex: 0,
                    ),
                  );
            },
          ),
        ),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiKeyProvider.overrideWithValue('test-key'),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(legacyInstantMixEnabled: true),
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
    expect(queue.retainedSongIds, <String>['seed']);
    expect(queue.mixTrackBatches, hasLength(1));
    expect(queue.mixTrackBatches.single, hasLength(50));
    expect(queue.mixTrackBatches.single.first.id, 'rec-0');
    expect(container.read(instantMixProvider).pendingSnackbar, '50');
    verify(
      () => api.getSimilarSongs2(
        'seed',
        count: 50,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verifyNever(
      () => api.getInstantMix(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('legacy activation treats partial queue insertion as success', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
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
        lastFmApiKeyProvider.overrideWithValue('test-key'),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(legacyInstantMixEnabled: true),
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
    expect(queue.retainedSongIds, <String>['seed']);
    expect(queue.mixTrackBatches, hasLength(1));
    expect(state.active, isTrue);
    expect(state.error, isNull);
    expect(state.pendingSnackbar, '1');
  });

  test(
    'legacy activation with zero inserted tracks fails once and deactivates',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
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

  test('server activation falls back to instant mix only when similarity is unsupported', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(
      const SubsonicNotFoundException(message: 'Unsupported endpoint'),
    );
    when(
      () => api.getLegacySimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(
      const SubsonicNotFoundException(message: 'Unsupported endpoint'),
    );
    when(
      () => api.getInstantMix(
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
        lastFmApiKeyProvider.overrideWithValue('test-key'),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(legacyInstantMixEnabled: true),
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
    verify(
      () => api.getSimilarSongs2(
        'seed',
        count: 50,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verify(
      () => api.getInstantMix(
        'seed',
        count: 50,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('server mix is built from the server similar-songs API', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(2, prefix: 'server'));

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWithValue(api),
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
    expect(queue.mixTrackBatches.single.first.id, 'server-0');
  });

  test('auto-refill path updates seed when remaining tracks <= 3', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(5));
    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(api),
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

    await Future<void>.delayed(const Duration(milliseconds: 1250));

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>[
              'seed-a',
              'b',
              'c',
              'd',
              'e',
              'f',
              'g',
              'h',
            ],
            currentSongId: 'seed-b',
            currentIndex: 6,
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

    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(5));
    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(api),
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
    expect(state.active, isFalse);
    expect(state.seedSongId, isNull);
  });

  group('a remote seed', () {
    const remoteSeedId = 'ext-deezer-song-1';
    late _MockSubsonicApiClient api;

    setUp(() {
      api = _MockSubsonicApiClient();
      // Octo-Fiesta's similarity endpoints know only library ids (code 70).
      for (final call in <Future<List<Song>> Function()>[
        () => api.getSimilarSongs2(
          remoteSeedId,
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
        () => api.getLegacySimilarSongs(
          remoteSeedId,
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
        () => api.getInstantMix(
          remoteSeedId,
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ]) {
        when(
          call,
        ).thenThrow(const SubsonicNotFoundException(message: 'Song not found'));
      }
    });

    ProviderContainer playingLocal({int? insertedCount}) {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(
            () => _FakeQueueController(insertedCount: insertedCount),
          ),
          subsonicApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['local-1', 'queued'],
              currentSongId: 'local-1',
              currentIndex: 0,
            ),
          );
      return container;
    }

    test('mixes from its library copy on the server', () async {
      when(
        () => api.getSong(remoteSeedId, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => const Song(
          id: 'lib-copy',
          title: 'Dystopia',
          artist: 'ONE OK ROCK',
        ),
      );
      when(
        () => api.getSimilarSongs2(
          'lib-copy',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => <Song>[
          const Song(id: 'lib-copy', title: 'Dystopia'),
          const Song(id: remoteSeedId, title: 'Dystopia'),
          ...songs(3),
        ],
      );
      final container = playingLocal();

      await container.read(instantMixProvider.notifier).activate(remoteSeedId);

      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queue.retainedSongIds, <String>[remoteSeedId]);
      // The library copy and the remote original are the song just chosen,
      // so neither is queued again.
      expect(queue.mixTrackBatches.single.map((song) => song.id), <String>[
        'rec-0',
        'rec-1',
        'rec-2',
      ]);
      final session = container.read(recommendationSessionProvider);
      expect(session.seedId, remoteSeedId);
      expect(session.stage, 'active');
      expect(session.insertedCount, 3);
      verifyNever(
        () => api.getSimilarSongs2(
          remoteSeedId,
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('without a library copy reports unsupported', () async {
      when(
        () => api.getSong(remoteSeedId, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => const Song(
          id: remoteSeedId,
          title: 'Dystopia',
          artist: 'ONE OK ROCK',
        ),
      );
      final container = playingLocal();

      await container.read(instantMixProvider.notifier).activate(remoteSeedId);

      expect(
        container.read(instantMixProvider).error,
        InstantMixError.unsupported,
      );
      final session = container.read(recommendationSessionProvider);
      expect(session.stage, 'failed');
      expect(session.errorCategory, 'unsupported');
      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queue.retainedSongIds, isEmpty);
    });

    test('an activation that queues nothing reports failure', () async {
      when(
        () => api.getSong(remoteSeedId, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => const Song(
          id: 'lib-copy',
          title: 'Dystopia',
          artist: 'ONE OK ROCK',
        ),
      );
      when(
        () => api.getSimilarSongs2(
          'lib-copy',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(3));
      final container = playingLocal(insertedCount: 0);

      await container.read(instantMixProvider.notifier).activate(remoteSeedId);

      expect(
        container.read(instantMixProvider).error,
        InstantMixError.networkError,
      );
      expect(container.read(recommendationSessionProvider).stage, 'failed');
    });
  });

  group('activating again while a refill runs', () {
    late _MockSubsonicApiClient api;
    late Completer<List<Song>> firstFetch;

    setUp(() {
      api = _MockSubsonicApiClient();
      firstFetch = Completer<List<Song>>();
      when(
        () => api.getSimilarSongs2(
          'seed-a',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => firstFetch.future);
      when(
        () => api.getSimilarSongs2(
          'seed-b',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(3, prefix: 'b'));
    });

    ProviderContainer build() {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed-a', 'seed-b'],
              currentSongId: 'seed-a',
              currentIndex: 0,
            ),
          );
      return container;
    }

    Future<void> startTwice(ProviderContainer container) async {
      final notifier = container.read(instantMixProvider.notifier);
      unawaited(notifier.activate('seed-a'));
      await pumpEventQueue();
      await notifier.activate('seed-b');
    }

    void expectSecondMixActive(ProviderContainer container) {
      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queue.retainedSongIds, <String>['seed-b']);
      expect(
        queue.mixTrackBatches.map((batch) => batch.map((song) => song.id)),
        <List<String>>[
          <String>['b-0', 'b-1', 'b-2'],
        ],
      );
      final session = container.read(recommendationSessionProvider);
      expect(session.seedId, 'seed-b');
      expect(session.stage, 'active');
      expect(session.insertedCount, 3);
      final state = container.read(instantMixProvider);
      expect(state.active, isTrue);
      expect(state.error, isNull);
    }

    test(
      "inserts for the second seed and drops the first one's songs",
      () async {
        final container = build();

        await startTwice(container);
        expectSecondMixActive(container);

        firstFetch.complete(songs(3, prefix: 'a'));
        await pumpEventQueue();
        expectSecondMixActive(container);
      },
    );

    test(
      'a failure of the superseded refill never reaches the new session',
      () async {
        final container = build();

        await startTwice(container);
        firstFetch.completeError(StateError('first fetch failed'));
        await pumpEventQueue();

        expectSecondMixActive(container);
      },
    );
  });

  group('retry exhaustion', () {
    var fakeNow = DateTime(2026, 10, 9, 12);
    setUp(() {
      fakeNow = DateTime(2026, 10, 9, 12);
      recommendationNow = () => fakeNow;
    });
    tearDown(() => recommendationNow = DateTime.now);

    test(
      'five failed refills stop the mix until it is started again',
      () async {
        final snapshotState =
            NotifierProvider<_SnapshotController, PlaybackSnapshot>(
              _SnapshotController.new,
            );
        final api = _MockSubsonicApiClient();
        var fetches = 0;
        when(
          () => api.getSimilarSongs2(
            any(),
            count: any(named: 'count'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          fetches++;
          return songs(5);
        });
        final container = ProviderContainer(
          overrides: [
            playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
            queueProvider.overrideWith(_DryingQueueController.new),
            audioHandlerProvider.overrideWithValue(null),
            subsonicApiProvider.overrideWithValue(api),
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(instantMixProvider.notifier);
        void emit(int length) => container
            .read(snapshotState.notifier)
            .emitSnapshot(
              snapshot(
                queueSongIds: List<String>.generate(length, (i) => 'q-$i'),
                currentSongId: 'q-8',
                currentIndex: 8,
              ),
            );
        // Moves the clock past any backoff and clears the error the app shell
        // clears after showing it, then lets a due refill run.
        Future<void> nextSnapshot(int length) async {
          fakeNow = fakeNow.add(const Duration(minutes: 5));
          notifier.clearError();
          emit(length);
          await pumpEventQueue();
          while (container.read(instantMixProvider).refilling) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        emit(5);
        await notifier.activate('seed-a');
        expect(fetches, 1);

        for (var failure = 1; failure <= 5; failure++) {
          await nextSnapshot(10 + failure);
          expect(fetches, 1 + failure);
        }
        final exhausted = container.read(recommendationSessionProvider);
        expect(exhausted.stage, 'retryExhausted');
        expect(exhausted.retryCount, 5);

        // Later snapshots no longer resume the exhausted refill.
        await nextSnapshot(20);
        await nextSnapshot(21);
        expect(fetches, 6);
        expect(
          container.read(recommendationSessionProvider).stage,
          'retryExhausted',
        );

        // Starting the mix again re-arms it.
        await notifier.activate('seed-a');
        expect(fetches, 7);
      },
    );
  });
}
