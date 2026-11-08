import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
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

import '../../../../helpers/recommendation_test_harness.dart';

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

/// Accepts the first recommendation append, then inserts nothing.
class _DryingQueueController extends RecordingRecommendationQueue {
  new() : super();

  int appends = 0;

  @override
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) {
    appends++;
    if (appends > 1) {
      return Future.value(const RecommendationQueueResult(<String>[]));
    }
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

  const snapshot = recommendationSnapshot;

  group('refill cancellation tokens', () {
    late ProviderContainer container;
    late List<CancelToken> tokens;
    late List<Completer<List<Song>>> calls;
    late DateTime now;

    setUp(() {
      tokens = [];
      calls = [];
      now = DateTime.utc(2026);
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        tokens.add(invocation.namedArguments[#cancelToken]! as CancelToken);
        final call = Completer<List<Song>>();
        calls.add(call);
        return call.future;
      });
      container = createRecommendationContainer(
        overrides: [
          queueProvider.overrideWith(RecordingRecommendationQueue.new),
          audioHandlerProvider.overrideWithValue(null),
          subsonicApiProvider.overrideWithValue(api),
          instantMixProvider.overrideWith(
            () => InstantMixNotifier(now: () => now),
          ),
        ],
      );
      container.listen(instantMixProvider, (_, _) {});
    });

    Future<void> activate() async {
      final activation = container
          .read(instantMixProvider.notifier)
          .activate('seed');
      await pumpEventQueue();
      calls[0].complete(songs(5));
      await activation;
    }

    Future<void> refill(int index) async {
      now = now.add(const Duration(minutes: 1));
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: List.generate(index + 1, (i) => 'q-$i'),
              currentSongId: 'q-$index',
              currentIndex: index,
            ),
          );
      await pumpEventQueue();
    }

    test('each mix refill uses a distinct token', () async {
      await activate();
      for (var i = 1; i <= 2; i++) {
        await refill(i * 5);
        expect(calls, hasLength(i + 1));
        calls[i].complete(songs(5, prefix: 'refill-$i'));
        await pumpEventQueue();
      }

      expect(Set<CancelToken>.identity()..addAll(tokens), hasLength(3));
      container.read(instantMixProvider.notifier).deactivate();
      expect(tokens.every((token) => !token.isCancelled), isTrue);
    });

    test('deactivating mix cancels an in-flight refill only', () async {
      await activate();
      await refill(5);
      expect(tokens, hasLength(2));

      container.read(instantMixProvider.notifier).deactivate();
      calls[1].complete(songs(5, prefix: 'late'));
      await pumpEventQueue();

      expect(tokens.last.isCancelled, isTrue);
      expect(tokens.first.isCancelled, isFalse);
      expect(
        (container.read(
          queueProvider.notifier,
        ) as RecordingRecommendationQueue).appendedSongBatches,
        hasLength(1),
      );
    });
  });

  test('deactivates when queue is cleared', () async {
    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(RecordingRecommendationQueue.new),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['a', 'b', 'c', 'd'],
            currentSongId: 'a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('a');

    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(const PlaybackSnapshot.idle());
    await Future<void>.delayed(Duration.zero);

    final state = container.read(instantMixProvider);
    expect(state.active, isFalse);
    expect(state.seedSongId, isNull);
  });

  test('deactivates when a regular queue replacement starts', () async {
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(5));
    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(RecordingRecommendationQueue.new),
        subsonicApiProvider.overrideWithValue(api),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );

    container
        .read(recommendationSnapshotProvider.notifier)
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
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(50));

    late final ProviderContainer container;
    container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(
          () => RecordingRecommendationQueue(
            onRetain: (id) {
              container
                  .read(recommendationSnapshotProvider.notifier)
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

    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'queued'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');

    final queue =
        container.read(queueProvider.notifier) as RecordingRecommendationQueue;
    expect(queue.retainedSongIds, <String>['seed']);
    expect(queue.appendedSongBatches, hasLength(1));
    expect(queue.appendedSongBatches.single, hasLength(50));
    expect(queue.appendedSongBatches.single.first.id, 'rec-0');
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
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(50));

    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(
          () => RecordingRecommendationQueue(insertedCount: 1),
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

    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');
    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'rec-0'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    final queue =
        container.read(queueProvider.notifier) as RecordingRecommendationQueue;
    final state = container.read(instantMixProvider);
    expect(queue.retainedSongIds, <String>['seed']);
    expect(queue.appendedSongBatches, hasLength(1));
    expect(state.active, isTrue);
    expect(state.error, isNull);
    expect(state.pendingSnackbar, '1');
  });

  test(
    'legacy activation with zero inserted tracks fails once and deactivates',
    () async {
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(50));

      final container = createRecommendationContainer(
        overrides: [
          queueProvider.overrideWith(
            () => RecordingRecommendationQueue(insertedCount: 0),
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

      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );
      await Future<void>.delayed(Duration.zero);

      final queue = container.read(
        queueProvider.notifier,
      ) as RecordingRecommendationQueue;
      final state = container.read(instantMixProvider);
      expect(queue.appendedSongBatches, hasLength(1));
      expect(state.active, isFalse);
      expect(state.error, InstantMixError.networkError);
    },
  );

  test('server activation falls back to instant mix only when similarity is unsupported', () async {
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

    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(RecordingRecommendationQueue.new),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiKeyProvider.overrideWithValue('test-key'),
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(legacyInstantMixEnabled: true),
          ),
        ),
      ],
    );

    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'queued'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');

    final queue =
        container.read(queueProvider.notifier) as RecordingRecommendationQueue;
    expect(queue.appendedSongBatches, hasLength(1));
    expect(queue.appendedSongBatches.single, hasLength(50));
    expect(queue.appendedSongBatches.single.first.id, 'similar-0');
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
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(2, prefix: 'server'));

    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(RecordingRecommendationQueue.new),
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

    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'queued'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');

    final queue =
        container.read(queueProvider.notifier) as RecordingRecommendationQueue;
    expect(queue.appendedSongBatches.single.length, 2);
    expect(queue.appendedSongBatches.single.first.id, 'server-0');
  });

  test(
    'auto-refill updates seed at eight remaining tracks, but not nine',
    () async {
      final api = _MockSubsonicApiClient();
      var now = DateTime.utc(2026);
      var batch = 0;
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => songs(10, prefix: 'rec-${batch++}'));
      final container = createRecommendationContainer(
        overrides: [
          instantMixProvider.overrideWith(
            () => InstantMixNotifier(now: () => now),
          ),
          queueProvider.overrideWith(RecordingRecommendationQueue.new),
          audioHandlerProvider.overrideWithValue(null),
          subsonicApiProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
      );
      container.listen(instantMixProvider, (_, _) {});
      final snapshots = container.read(recommendationSnapshotProvider.notifier);
      snapshots.emitSnapshot(
        snapshot(
          queueSongIds: ['seed'],
          currentSongId: 'seed',
          currentIndex: 0,
        ),
      );
      await container.read(instantMixProvider.notifier).activate('seed');
      final queue = container.read(
        queueProvider.notifier,
      ) as RecordingRecommendationQueue;
      expect(queue.appendedSongBatches, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      final ids = ['seed', ...List.generate(10, (i) => 'rec-0-$i')];

      snapshots.emitSnapshot(
        snapshot(queueSongIds: ids, currentSongId: ids[1], currentIndex: 1),
      );
      await pumpEventQueue();
      expect(queue.appendedSongBatches, hasLength(1));

      snapshots.emitSnapshot(
        snapshot(queueSongIds: ids, currentSongId: ids[2], currentIndex: 2),
      );
      await pumpEventQueue();
      expect(queue.appendedSongBatches, hasLength(2));
      expect(container.read(instantMixProvider).seedSongId, ids[2]);
    },
  );

  test('does not auto-refill while radio mode is active', () async {
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => songs(5));
    final container = createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(RecordingRecommendationQueue.new),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWithValue(api),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('seed-a');

    container
        .read(recommendationSnapshotProvider.notifier)
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
      final container = createRecommendationContainer(
        overrides: [
          queueProvider.overrideWith(
            () => RecordingRecommendationQueue(insertedCount: insertedCount),
          ),
          subsonicApiProvider.overrideWithValue(api),
        ],
      );
      container
          .read(recommendationSnapshotProvider.notifier)
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

      final queue = container.read(
        queueProvider.notifier,
      ) as RecordingRecommendationQueue;
      expect(queue.retainedSongIds, <String>[remoteSeedId]);
      // The library copy and the remote original are the song just chosen,
      // so neither is queued again.
      expect(queue.appendedSongBatches.single.map((song) => song.id), <String>[
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
      final queue = container.read(
        queueProvider.notifier,
      ) as RecordingRecommendationQueue;
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
      final container = createRecommendationContainer(
        overrides: [
          queueProvider.overrideWith(RecordingRecommendationQueue.new),
          subsonicApiProvider.overrideWithValue(api),
        ],
      );
      container
          .read(recommendationSnapshotProvider.notifier)
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
      final queue = container.read(
        queueProvider.notifier,
      ) as RecordingRecommendationQueue;
      expect(queue.retainedSongIds, <String>['seed-b']);
      expect(
        queue.appendedSongBatches.map((batch) => batch.map((song) => song.id)),
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
    });

    ProviderContainer build(
      _MockSubsonicApiClient api, {
      RecordingRecommendationQueue Function() queue =
          RecordingRecommendationQueue.new,
      Duration? refillTimeout,
    }) => createRecommendationContainer(
      overrides: [
        queueProvider.overrideWith(queue),
        audioHandlerProvider.overrideWithValue(null),
        instantMixProvider.overrideWith(
          () => InstantMixNotifier(
            now: () => fakeNow,
            refillTimeout: refillTimeout,
          ),
        ),
        subsonicApiProvider.overrideWithValue(api),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );

    /// Plays [song] (index [index]) of a queue of [length] songs; each call
    /// differs by [length], so the snapshot listener fires. The clock moves
    /// past any backoff, and the error the app shell clears after showing it
    /// is cleared.
    Future<void> tick(
      ProviderContainer container, {
      required int length,
      required int index,
      String? currentId,
      Duration position = Duration.zero,
      AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
    }) async {
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      container.read(instantMixProvider.notifier).clearError();
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: List<String>.generate(length, (i) => 'q-$i'),
              currentSongId: currentId ?? 'q-$index',
              currentIndex: index,
            ).copyWith(repeatMode: repeatMode, position: position),
          );
      await pumpEventQueue();
      while (container.read(instantMixProvider).refilling) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'zero insertions from an unchanged seed wait for the next song',
      () async {
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
        final container = build(api, queue: _DryingQueueController.new);
        final stages = <String>[];
        container.listen(
          recommendationSessionProvider,
          (_, next) => stages.add(next.stage),
        );
        final notifier = container.read(instantMixProvider.notifier);
        container
            .read(recommendationSnapshotProvider.notifier)
            .emitSnapshot(
              snapshot(
                queueSongIds: const <String>['q-0'],
                currentSongId: 'q-0',
                currentIndex: 0,
              ),
            );
        await notifier.activate('seed-a');
        expect(fetches, 1);

        for (var length = 11; length <= 18; length++) {
          await tick(container, length: length, index: 8);
        }
        expect(fetches, 2, reason: 'one fetch, then parked on the song');
        expect(stages, isNot(contains('retryPending')));
        expect(stages, isNot(contains('retryExhausted')));
        expect(container.read(recommendationSessionProvider).retryCount, 0);

        await tick(container, length: 20, index: 9);
        expect(fetches, 3, reason: 'a new song gets its own try');
        expect(container.read(instantMixProvider).active, isTrue);
        expect(container.read(instantMixProvider).error, isNull);
      },
    );

    test('a skip during a parking refill still gives the new song its try without another snapshot', () async {
      final api = _MockSubsonicApiClient();
      var fetches = 0;
      Completer<List<Song>>? gate;
      final seeds = <String>[];
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((inv) async {
        fetches++;
        seeds.add(inv.positionalArguments.first as String);
        if (fetches == 1) return songs(5);
        final g = gate;
        if (g != null) return g.future;
        return const <Song>[];
      });
      final container = build(api);
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['q-0'],
              currentSongId: 'q-0',
              currentIndex: 0,
            ),
          );
      await container.read(instantMixProvider.notifier).activate('seed-a');
      gate = Completer<List<Song>>();
      void emit(int index) => container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: List<String>.generate(12, (i) => 'q-$i'),
              currentSongId: 'q-$index',
              currentIndex: index,
            ),
          );
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      emit(8);
      while (fetches < 2) {
        container.read(instantMixProvider);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      emit(9); // skip while the q-8 refill runs
      container.read(instantMixProvider);
      await pumpEventQueue();
      gate.complete(const <Song>[]);
      gate = null;
      while (container.read(instantMixProvider).refilling) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      await Future<void>.delayed(const Duration(seconds: 4));
      container.read(instantMixProvider);
      await pumpEventQueue();
      expect(seeds, ['seed-a', 'q-8', 'q-9'], reason: 'q-9 never refilled');
    });

    /// Starts a mix on 'seed-a' whose first fetch gives five songs; later
    /// fetches are answered by [later].
    Future<ProviderContainer> startMix(
      _MockSubsonicApiClient api,
      Future<List<Song>> Function(String seed, int fetch) later, {
      RecordingRecommendationQueue Function() queue =
          RecordingRecommendationQueue.new,
      Duration? refillTimeout,
    }) async {
      var fetches = 0;
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        fetches++;
        if (fetches == 1) return Future.value(songs(5));
        return later(invocation.positionalArguments.first as String, fetches);
      });
      final container = build(api, queue: queue, refillTimeout: refillTimeout);
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['q-0'],
              currentSongId: 'q-0',
              currentIndex: 0,
            ),
          );
      await container.read(instantMixProvider.notifier).activate('seed-a');
      return container;
    }

    test('a remote song without a library copy parks instead of ending the '
        'mix', () async {
      final api = _MockSubsonicApiClient();
      when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
          .thenAnswer((invocation) async {
            // The server has no library copy: it answers with the remote song.
            return Song(
              id: invocation.positionalArguments.first as String,
              title: 'Remote',
            );
          });
      var fetches = 0;
      final container = await startMix(api, (seed, fetch) {
        fetches++;
        throw const SubsonicNotFoundException(message: 'Song not found');
      });
      when(
        () => api.getLegacySimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(const SubsonicNotFoundException(message: 'Song not found'));
      when(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(const SubsonicNotFoundException(message: 'Song not found'));

      for (var length = 11; length <= 14; length++) {
        await tick(
          container,
          length: length,
          index: 8,
          currentId: 'ext-deezer-song-1',
        );
      }
      expect(fetches, 1, reason: 'one fetch, then parked on the song');
      final state = container.read(instantMixProvider);
      expect(state.active, isTrue);
      expect(state.error, isNull);
      expect(container.read(recommendationSessionProvider).stage, 'active');

      // A song the server can address that it says it cannot mix still ends
      // the mix.
      await tick(container, length: 20, index: 9);
      expect(container.read(instantMixProvider).active, isFalse);
      expect(
        container.read(instantMixProvider).error,
        InstantMixError.unsupported,
      );
    });

    test('a refill that times out mid-mix is a silent failure that retries, '
        'while the first one still ends the start', () async {
      final api = _MockSubsonicApiClient();
      final container = await startMix(
        api,
        (seed, fetch) => Completer<List<Song>>().future,
        refillTimeout: const Duration(milliseconds: 40),
      );
      await tick(container, length: 11, index: 8);
      final state = container.read(instantMixProvider);
      expect(state.active, isTrue);
      expect(state.error, isNull, reason: 'no "Couldn\'t start" mid-mix');
      final session = container.read(recommendationSessionProvider);
      expect(session.stage, 'retryPending');
      expect(session.retryCount, 1);

      final startApi = _MockSubsonicApiClient();
      when(
        () => startApi.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => Completer<List<Song>>().future);
      final starting = build(
        startApi,
        refillTimeout: const Duration(milliseconds: 40),
      );
      await starting.read(instantMixProvider.notifier).activate('seed-a');
      expect(starting.read(instantMixProvider).active, isFalse);
      expect(
        starting.read(instantMixProvider).error,
        InstantMixError.networkError,
      );
    });

    test('the retry follows the song playing when it fires', () async {
      final api = _MockSubsonicApiClient();
      final seeds = <String>[];
      final container = await startMix(api, (seed, fetch) {
        seeds.add(seed);
        if (seeds.length == 1) throw const SubsonicConnectionException('x');
        return Future.value(songs(5, prefix: 'more'));
      });
      await tick(container, length: 12, index: 8);
      expect(seeds, ['q-8']);
      // Skip during the 3 s backoff: the snapshot is held back by the
      // backoff, so only the timer can serve q-9.
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: List<String>.generate(12, (i) => 'q-$i'),
              currentSongId: 'q-9',
              currentIndex: 9,
            ),
          );
      container.read(instantMixProvider);
      await Future<void>.delayed(const Duration(milliseconds: 3600));
      expect(seeds, ['q-8', 'q-9']);
    });

    test('parking cancels a retry still pending for the same song', () async {
      final api = _MockSubsonicApiClient();
      var failNext = true;
      final container = await startMix(api, (seed, fetch) {
        if (failNext) throw const SubsonicConnectionException('x');
        return Future.value(songs(5));
      }, queue: _DryingQueueController.new);
      // The last song of the queue: a stale retry would find it parked and
      // end the mix.
      await tick(container, length: 10, index: 9);
      expect(
        container.read(recommendationSessionProvider).stage,
        'retryPending',
      );
      failNext = false;
      await tick(
        container,
        length: 10,
        index: 9,
        position: const Duration(seconds: 1),
      );
      expect(container.read(recommendationSessionProvider).stage, 'active');
      await Future<void>.delayed(const Duration(milliseconds: 3600));
      container.read(instantMixProvider);
      await pumpEventQueue();
      expect(container.read(instantMixProvider).active, isTrue);
    });

    test('five network failures wait for the next song, then retry', () async {
      final api = _MockSubsonicApiClient();
      var fetches = 0;
      var failing = true;
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        fetches++;
        if (fetches > 1 && failing) {
          throw const SubsonicConnectionException('offline');
        }
        return songs(5);
      });
      final container = build(api);
      final notifier = container.read(instantMixProvider.notifier);
      String stage() => container.read(recommendationSessionProvider).stage;
      container
          .read(recommendationSnapshotProvider.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['q-0'],
              currentSongId: 'q-0',
              currentIndex: 0,
            ),
          );
      await notifier.activate('seed-a');
      expect(fetches, 1);

      for (var failure = 1; failure <= 5; failure++) {
        await tick(container, length: 10 + failure, index: 8);
        expect(fetches, 1 + failure);
      }
      expect(stage(), 'retryExhausted');
      expect(container.read(recommendationSessionProvider).retryCount, 5);
      expect(container.read(instantMixProvider).active, isTrue);
      expect(
        container.read(instantMixProvider).error,
        isNull,
        reason: 'the mix heals by itself, so no notice',
      );

      // The same song makes no further fetch.
      await tick(container, length: 20, index: 8);
      await tick(container, length: 21, index: 8);
      expect(fetches, 6);
      expect(stage(), 'retryExhausted');

      // The next song re-arms the mix with a fresh failure count.
      await tick(container, length: 22, index: 9);
      expect(fetches, 7);
      expect(stage(), 'retryPending');
      expect(container.read(recommendationSessionProvider).retryCount, 1);

      // Once the connection is back the mix queues songs again.
      failing = false;
      await tick(container, length: 23, index: 9);
      expect(fetches, 8);
      expect(stage(), 'active');
      expect(container.read(instantMixProvider).active, isTrue);
      expect(container.read(instantMixProvider).error, isNull);

      // Starting the mix again re-arms it too.
      await notifier.activate('seed-a');
      expect(fetches, 9);
    });

    for (final repeatMode in <AudioServiceRepeatMode>[
      AudioServiceRepeatMode.none,
      AudioServiceRepeatMode.all,
    ]) {
      test('the last song finding nothing new ends the mix only when repeat '
          'is off (${repeatMode.name})', () async {
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
          return fetches == 1 ? songs(5) : const <Song>[];
        });
        final container = build(api);
        container
            .read(recommendationSnapshotProvider.notifier)
            .emitSnapshot(
              snapshot(
                queueSongIds: const <String>['q-0'],
                currentSongId: 'q-0',
                currentIndex: 0,
              ),
            );
        await container.read(instantMixProvider.notifier).activate('seed-a');

        await tick(container, length: 6, index: 5, repeatMode: repeatMode);
        expect(fetches, 2);
        expect(container.read(instantMixProvider).active, isTrue);

        await tick(container, length: 6, index: 5, repeatMode: repeatMode);
        expect(fetches, 2);
        final state = container.read(instantMixProvider);
        expect(state.error, isNull, reason: 'running out is not an error');
        expect(state.active, repeatMode != AudioServiceRepeatMode.none);
      });
    }
  });
}
