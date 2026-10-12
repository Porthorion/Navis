import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/recommendation_test_harness.dart';

class _MockRecommendationService extends Mock implements RecommendationService;

class _MockPlaybackHandler extends Mock implements NavisPlaybackHandler;

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

class _QueueController extends RecordingRecommendationQueue {
  new(this.onReplace, this.onAppend);

  final void Function(List<String>) onReplace;
  final void Function(List<String>) onAppend;
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
    List<String>? originalOrder,
  }) async {
    replacementCount++;
    onReplace(songs.map((song) => song.id).toList());
  }

  @override
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) async {
    final result = await super.appendRecommendationTracks(
      songs,
      expandMatchFlows: expandMatchFlows,
      isCurrent: isCurrent,
    );
    if (isCurrent == null || isCurrent()) onAppend(result.insertedIds);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const RadioFilters()));

  ProviderContainer makeContainer(
    _MockRecommendationService service,
    NotifierProvider<_SnapshotController, PlaybackSnapshot> snapshotProvider, {
    NavisPlaybackHandler? handler,
  }) {
    late final ProviderContainer container;
    return container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotProvider)),
        audioHandlerProvider.overrideWithValue(handler),
        subsonicApiProvider.overrideWithValue(null),
        recommendationServiceProvider.overrideWithValue(service),
        queueProvider.overrideWith(
          () => _QueueController(
            (ids) => container.read(snapshotProvider.notifier).setQueue(ids),
            (ids) {
              final before = container.read(snapshotProvider);
              container.read(snapshotProvider.notifier).setQueue([
                ...before.queueSongIds,
                ...ids,
              ], currentIndex: before.currentIndex ?? 0);
            },
          ),
        ),
      ],
    );
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

  group('a superseded run cannot release a newer run', () {
    late _MockRecommendationService service;
    late List<Completer<RecommendationBatch>> calls;
    late List<CancelToken> tokens;
    late NotifierProvider<_SnapshotController, PlaybackSnapshot> snapshots;
    late ProviderContainer container;
    late _MockPlaybackHandler handler;
    late List<String> skippedTo;

    RecommendationBatch batchOf(List<String> ids) => RecommendationBatch(
      songs: [for (final id in ids) Song(id: id, title: id)],
      source: RecommendationSource.server,
    );

    setUp(() {
      service = _MockRecommendationService();
      calls = <Completer<RecommendationBatch>>[];
      tokens = <CancelToken>[];
      when(
        () => service.personalRadio(
          any(),
          excludedIds: any(named: 'excludedIds'),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        tokens.add(invocation.namedArguments[#cancelToken]! as CancelToken);
        final call = Completer<RecommendationBatch>();
        calls.add(call);
        return call.future;
      });
      snapshots = NotifierProvider<_SnapshotController, PlaybackSnapshot>(
        _SnapshotController.new,
      );
      handler = _MockPlaybackHandler();
      skippedTo = [];
      when(() => handler.snapshot).thenAnswer((_) => container.read(snapshots));
      when(() => handler.skipToNext()).thenAnswer((_) async {
        final before = container.read(snapshots);
        final index = before.currentIndex! + 1;
        skippedTo.add(before.queueSongIds[index]);
        container
            .read(snapshots.notifier)
            .setQueue(before.queueSongIds, currentIndex: index);
      });
      container = makeContainer(service, snapshots, handler: handler);
      addTearDown(container.dispose);
      container.listen(personalRadioProvider, (_, _) {});
      container.read(snapshots.notifier).setQueue(<String>['old']);
    });

    test('refill starts at eight remaining tracks, but not nine', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final start = radio.start();
      final ids = List.generate(11, (index) => 'r$index');
      calls[0].complete(batchOf(ids));
      await start;

      container.read(snapshots.notifier).setQueue(ids, currentIndex: 1);
      await pumpEventQueue();
      expect(calls, hasLength(1));

      container.read(snapshots.notifier).setQueue(ids, currentIndex: 2);
      await pumpEventQueue();
      expect(calls, hasLength(2));
      expect(container.read(personalRadioProvider).busy, isTrue);
      calls[1].complete(batchOf(['new']));
      await pumpEventQueue();
    });

    test(
      'Next at queue end during refill lands on first appended track',
      () async {
        final radio = container.read(personalRadioProvider.notifier);
        final start = radio.start();
        calls[0].complete(batchOf(['r1', 'r2']));
        await start;
        container.read(snapshots.notifier).setQueue([
          'r1',
          'r2',
        ], currentIndex: 1);
        await pumpEventQueue();
        expect(calls, hasLength(2));

        radio.requestSkipAfterRefill(1, 'r2');
        radio.requestSkipAfterRefill(1, 'r2');
        expect(skippedTo, isEmpty);
        expect(calls, hasLength(2));
        calls[1].complete(batchOf(['new-first', 'new-second']));
        await pumpEventQueue();

        expect(skippedTo, ['new-first']);
        expect(container.read(playerStateProvider).currentIndex, 2);
        expect(container.read(playerStateProvider).currentSongId, 'new-first');
      },
    );

    test(
      'queue-end Next starts refill before another snapshot arrives',
      () async {
        final radio = container.read(personalRadioProvider.notifier);
        final start = radio.start();
        calls[0].complete(batchOf(['r1']));
        await start;
        expect(calls, hasLength(1));

        radio.requestSkipAfterRefill(0, 'r1');
        expect(calls, hasLength(2));
        calls[1].complete(batchOf(['new-first', 'new-second']));
        await pumpEventQueue();
        expect(skippedTo, ['new-first']);
      },
    );

    test('stopping radio drops a pending skip', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final start = radio.start();
      calls[0].complete(batchOf(['r1', 'r2']));
      await start;
      container.read(snapshots.notifier).setQueue([
        'r1',
        'r2',
      ], currentIndex: 1);
      await pumpEventQueue();
      radio.requestSkipAfterRefill(1, 'r2');

      radio.stop();
      calls[1].complete(batchOf(['late']));
      await pumpEventQueue();

      expect(tokens.last.isCancelled, isTrue);
      expect(skippedTo, isEmpty);
      expect(container.read(playerStateProvider).currentSongId, 'r2');
      expect(container.read(playerStateProvider).queueSongIds, ['r1', 'r2']);
    });

    test('moving away from the tail drops a pending skip', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final start = radio.start();
      calls[0].complete(batchOf(['r1', 'r2']));
      await start;
      container.read(snapshots.notifier).setQueue([
        'r1',
        'r2',
      ], currentIndex: 1);
      await pumpEventQueue();
      radio.requestSkipAfterRefill(1, 'r2');

      container.read(snapshots.notifier).setQueue(['r1', 'r2']);
      await pumpEventQueue();
      calls[1].complete(batchOf(['new']));
      await pumpEventQueue();

      expect(skippedTo, isEmpty);
      expect(container.read(playerStateProvider).currentSongId, 'r1');
    });

    test('each radio refill uses a distinct token', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final start = radio.start();
      calls[0].complete(batchOf(<String>['r1', 'r2']));
      await start;

      for (var refill = 1; refill <= 2; refill++) {
        container.read(snapshots.notifier).setQueue(<String>[
          'r1',
          'r2',
        ], currentIndex: refill % 2);
        await pumpEventQueue();
        expect(calls, hasLength(refill + 1));
        calls[refill].complete(batchOf(<String>['refill-$refill']));
        await pumpEventQueue();
      }

      expect(Set<CancelToken>.identity()..addAll(tokens), hasLength(3));
      radio.stop();
      expect(tokens.every((token) => !token.isCancelled), isTrue);
    });

    test('stopping radio cancels an in-flight refill only', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final start = radio.start();
      calls[0].complete(batchOf(<String>['r1', 'r2']));
      await start;
      container.read(snapshots.notifier).setQueue(<String>[
        'r1',
        'r2',
      ], currentIndex: 1);
      await pumpEventQueue();
      expect(tokens, hasLength(2));

      radio.stop();
      calls[1].complete(batchOf(<String>['late']));
      await pumpEventQueue();

      expect(tokens.last.isCancelled, isTrue);
      expect(tokens.first.isCancelled, isFalse);
      expect(container.read(playerStateProvider).queueSongIds, ['r1', 'r2']);
      expect(
        (container.read(
          queueProvider.notifier,
        ) as _QueueController).appendedSongBatches,
        isEmpty,
      );
    });

    test('an old start does not clear the newer start busy flag', () async {
      final radio = container.read(personalRadioProvider.notifier);

      final startA = radio.start();
      await pumpEventQueue();
      radio.stop();
      final startB = radio.start();
      await pumpEventQueue();
      expect(calls, hasLength(2));

      calls[0].complete(batchOf(<String>['a']));
      await startA;

      // Start B is still preparing, so a third start must be turned away.
      final startC = await radio.start();
      expect(startC.succeeded, isFalse);
      expect(calls, hasLength(2));

      calls[1].complete(batchOf(<String>['b']));
      expect((await startB).succeeded, isTrue);
    });

    test('an old refill does not clear the newer refill flag', () async {
      final radio = container.read(personalRadioProvider.notifier);
      final snapshotsNotifier = container.read(snapshots.notifier);

      final startA = radio.start();
      await pumpEventQueue();
      calls[0].complete(batchOf(<String>['r1', 'r2']));
      await startA;

      // Refill of the first radio session.
      snapshotsNotifier.setQueue(<String>['r1', 'r2'], currentIndex: 1);
      await pumpEventQueue();
      expect(calls, hasLength(2));

      radio.requestSkipAfterRefill(1, 'r2');
      radio.stop();
      final startB = radio.start();
      await pumpEventQueue();
      calls[2].complete(batchOf(<String>['b1', 'b2']));
      await startB;

      // Refill of the second radio session.
      snapshotsNotifier.setQueue(<String>['b1', 'b2'], currentIndex: 1);
      await pumpEventQueue();
      expect(calls, hasLength(4));

      // The first session's refill finishes while the second one still runs.
      calls[1].complete(batchOf(<String>['late']));
      await pumpEventQueue();
      expect(skippedTo, isEmpty);

      snapshotsNotifier.setQueue(<String>['b1', 'b2', 'x'], currentIndex: 2);
      await pumpEventQueue();
      expect(
        calls,
        hasLength(4),
        reason: 'the newer refill is still running; no second one may start',
      );
    });
  });
}
