import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart'
    show PlaybackSourceUnavailableException;
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Handler extends Mock implements NavisPlaybackHandler;

class _BatchHandler extends _Handler implements QueueBatchEditor;

void main() {
  late NavisDatabase database;
  late ProviderContainer container;
  late List<String> queue;
  late StreamController<PlaybackSnapshot> snapshots;
  late List<int> removed;
  late List<QueueInsertRun> inserted;
  late List<PlaybackActionError> errors;
  late int running;
  late int maxRunning;
  late Duration removeDelay;
  late bool removePublishes;
  late List<String> skipped;

  void publish(List<String> ids) {
    queue = List.unmodifiable(ids);
    snapshots.add(const PlaybackSnapshot.idle().copyWith(queueSongIds: queue));
  }

  Future<void> start(_Handler handler, List<String> ids) async {
    queue = List.unmodifiable(ids);
    when(() => handler.snapshotStream).thenAnswer((_) => snapshots.stream);
    when(() => handler.snapshot).thenAnswer(
      (_) => const PlaybackSnapshot.idle().copyWith(queueSongIds: queue),
    );
    when(() => handler.removeAt(any())).thenAnswer((invocation) async {
      final index = invocation.positionalArguments.first as int;
      running++;
      if (running > maxRunning) maxRunning = running;
      if (removeDelay > Duration.zero) await Future<void>.delayed(removeDelay);
      removed.add(index);
      final next = [...queue]..removeAt(index);
      if (removePublishes) publish(next);
      running--;
    });
    if (handler is QueueBatchEditor) {
      when(() => (handler as QueueBatchEditor).insertQueueRuns(any()))
          .thenAnswer((invocation) async {
            final runs =
                invocation.positionalArguments.first as List<QueueInsertRun>;
            inserted.addAll(runs);
            final next = [...queue];
            for (final run in runs) {
              next.insertAll(
                run.index.clamp(0, next.length),
                run.songs.map((song) => song.id),
              );
            }
            publish(next);
            return QueueBatchEditResult(skippedSongIds: skipped);
          });
    }
    container = ProviderContainer(
      overrides: [
        ...withTestDatabase(database),
        audioHandlerProvider.overrideWithValue(handler),
      ],
    );
    addTearDown(container.dispose);
    container.listen(queueProvider, (_, _) {});
    container.listen(
      playbackActionErrorProvider,
      (_, next) => next.whenData(errors.add),
    );
    await pumpEventQueue();
    expect(container.read(queueProvider), ids);
  }

  QueueController controller() => container.read(queueProvider.notifier);

  setUp(() async {
    database = createTestDatabase();
    addTearDown(database.close);
    snapshots = StreamController<PlaybackSnapshot>.broadcast();
    addTearDown(snapshots.close);
    removed = [];
    inserted = [];
    errors = [];
    running = 0;
    maxRunning = 0;
    removeDelay = Duration.zero;
    removePublishes = true;
    skipped = const [];
    await database.libraryDao.upsertSongs([
      for (final id in ['a', 'b', 'c', 'd', 'x', 'z'])
        SongsTableCompanion.insert(id: id, title: 'Song $id'),
    ]);
  });

  group('removeForUndo', () {
    test('a stale index or song id removes nothing', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);

      expect(await controller().removeForUndo(1, 'x'), isNull);
      expect(await controller().removeForUndo(5, 'x'), isNull);
      expect(await controller().removeForUndo(-1, 'x'), isNull);

      expect(removed, isEmpty);
    }, skip: !sqliteAvailable);

    test('describes the removal once the queue has changed', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final epoch = controller().selectionGeneration;

      final removal = await controller().removeForUndo(1, 'b');
      expect(removal, isNotNull);
      expect(removal!.index, 1);
      expect(removal.songId, 'b');
      expect(removal.successorId, 'c');
      expect(removal.epoch, epoch);
      expect(removal.idsAfter, ['a', 'c']);
      expect(removal.wasOnly, isFalse);
      expect(removed, [1]);
    }, skip: !sqliteAvailable);

    test('the last row has no successor and the only row is flagged', () async {
      await start(_BatchHandler(), ['a', 'b']);

      final last = await controller().removeForUndo(1, 'b');
      expect(last!.successorId, isNull);
      final only = await controller().removeForUndo(0, 'a');
      expect(only!.wasOnly, isTrue);
    }, skip: !sqliteAvailable);

    test('two rapid removals run one at a time, in order', () async {
      removeDelay = const Duration(milliseconds: 20);
      await start(_BatchHandler(), ['a', 'b', 'c', 'd']);

      final first = controller().removeForUndo(1, 'b');
      // The second tap saw the original list; it is valid only because the
      // first removal has completed by its turn.
      final second = controller().removeForUndo(1, 'c');

      expect((await first)!.idsAfter, ['a', 'c', 'd']);
      expect((await second)!.idsAfter, ['a', 'd']);
      expect(removed, [1, 1]);
      expect(maxRunning, 1);
    }, skip: !sqliteAvailable);

    test('a second removal of a row the first removed is stale', () async {
      removeDelay = const Duration(milliseconds: 20);
      await start(_BatchHandler(), ['a', 'b', 'c']);

      final first = controller().removeForUndo(1, 'b');
      final second = controller().removeForUndo(1, 'b');

      expect(await first, isNotNull);
      expect(await second, isNull);
      expect(removed, [1]);
    }, skip: !sqliteAvailable);

    test('a row shifted by an earlier removal falls back to its only copy', () async {
      removeDelay = const Duration(milliseconds: 20);
      await start(_BatchHandler(), ['a', 'b', 'c', 'd']);

      final first = controller().removeForUndo(1, 'b');
      // Swiped while 'b' was still listed: index 3 is out of range by its turn.
      final second = controller().removeForUndo(3, 'd');

      expect((await first)!.idsAfter, ['a', 'c', 'd']);
      final removal = (await second)!;
      expect(removal.index, 2);
      expect(removal.songId, 'd');
      expect(removal.idsAfter, ['a', 'c']);
      expect(removed, [1, 2]);
    }, skip: !sqliteAvailable);

    test('a shifted row is refused after the queue was replaced', () async {
      removeDelay = const Duration(milliseconds: 20);
      await start(_BatchHandler(), ['a', 'b', 'c', 'd']);

      final first = controller().removeForUndo(1, 'b');
      final second = controller().removeForUndo(3, 'd');
      controller().reserveSelection();

      expect(await first, isNotNull);
      expect(await second, isNull);
      expect(removed, [1]);
    }, skip: !sqliteAvailable);

    test('a shifted row of a duplicated song is refused', () async {
      removeDelay = const Duration(milliseconds: 20);
      await start(_BatchHandler(), ['a', 'x', 'b', 'x']);

      final first = controller().removeForUndo(0, 'a');
      final second = controller().removeForUndo(3, 'x');

      expect(await first, isNotNull);
      expect(await second, isNull);
      expect(removed, [0]);
    }, skip: !sqliteAvailable);

    test('a failed removal reports the error and returns null', () async {
      final handler = _BatchHandler();
      await start(handler, ['a', 'b']);
      when(() => handler.removeAt(any())).thenThrow(StateError('boom'));

      expect(await controller().removeForUndo(0, 'a'), isNull);
      await pumpEventQueue();

      expect(errors.single.error, isA<StateError>());
    }, skip: !sqliteAvailable);

    test('a removal the queue never shows still returns the removal', () async {
      removePublishes = false;
      await start(_BatchHandler(), ['a', 'b']);

      final removal = await controller().removeForUndo(0, 'a');

      expect(removed, [0]);
      expect(removal, isNotNull);
      expect(removal!.index, 0);
      expect(removal.songId, 'a');
      expect(removal.successorId, 'b');
      expect(removal.idsAfter, ['a', 'b']);
      expect(removal.wasOnly, isFalse);
      expect(errors, isEmpty);
    }, skip: !sqliteAvailable);

    test('a lagging removal is undone before its successor', () async {
      removePublishes = false;
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;
      // The queue catches up with the removal after the wait.
      publish(['a', 'c']);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted.single.index, 1);
      expect(inserted.single.songs.map((s) => s.id), ['b']);
    }, skip: !sqliteAvailable);
  });

  group('undoRemoval', () {
    test('inserts at the old index when the queue is unchanged', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;

      await controller().undoRemoval(removal);

      expect(inserted, hasLength(1));
      expect(inserted.single.index, 1);
      expect(inserted.single.songs.map((s) => s.id), ['b']);
      await pumpEventQueue();
      expect(container.read(queueProvider), ['a', 'b', 'c']);
      expect(errors, isEmpty);
    }, skip: !sqliteAvailable);

    test('inserts before the successor when the queue moved on', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;
      publish(['x', 'a', 'c']);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted.single.index, 2);
      await pumpEventQueue();
      expect(container.read(queueProvider), ['x', 'a', 'b', 'c']);
    }, skip: !sqliteAvailable);

    test('prefers the successor copy at or after the old index', () async {
      await start(_BatchHandler(), ['c', 'a', 'b', 'c']);
      final removal = (await controller().removeForUndo(2, 'b'))!;
      expect(removal.successorId, 'c');
      publish(['c', 'x', 'a', 'c']);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted.single.index, 3);
    }, skip: !sqliteAvailable);

    test('clamps to the old index when the successor is gone', () async {
      await start(_BatchHandler(), ['a', 'b', 'c', 'd']);
      final removal = (await controller().removeForUndo(2, 'c'))!;
      publish(['z']);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted.single.index, 1);
      await pumpEventQueue();
      expect(container.read(queueProvider), ['z', 'c']);
    }, skip: !sqliteAvailable);

    test('does nothing after the queue was replaced', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;
      controller().reserveSelection();

      await controller().undoRemoval(removal);

      expect(inserted, isEmpty);
    }, skip: !sqliteAvailable);

    test('does nothing when the replaced queue is empty', () async {
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;
      publish([]);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted, isEmpty);
    }, skip: !sqliteAvailable);

    test('does nothing for the only row', () async {
      await start(_BatchHandler(), ['a']);
      final removal = (await controller().removeForUndo(0, 'a'))!;
      publish(['b']);
      await pumpEventQueue();

      await controller().undoRemoval(removal);

      expect(inserted, isEmpty);
    }, skip: !sqliteAvailable);

    test('never appends through a handler without batched edits', () async {
      final handler = _Handler();
      await start(handler, ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;

      await controller().undoRemoval(removal);

      verifyNever(() => handler.addToQueue(any()));
      await pumpEventQueue();
      expect(container.read(queueProvider), ['a', 'c']);
    }, skip: !sqliteAvailable);

    test('a song with no playable source emits a playback error', () async {
      skipped = const ['b'];
      await start(_BatchHandler(), ['a', 'b', 'c']);
      final removal = (await controller().removeForUndo(1, 'b'))!;

      await controller().undoRemoval(removal);
      await pumpEventQueue();

      expect(errors, hasLength(1));
      expect(errors.single.error, isA<PlaybackSourceUnavailableException>());
    }, skip: !sqliteAvailable);

    test('an Undo never overtakes a later removal', () async {
      await start(_BatchHandler(), ['a', 'b', 'c', 'd']);
      final removal = (await controller().removeForUndo(1, 'b'))!;
      removeDelay = const Duration(milliseconds: 20);

      final later = controller().removeForUndo(0, 'a');
      final undo = controller().undoRemoval(removal);

      expect((await later)!.idsAfter, ['c', 'd']);
      await undo;
      // The Undo ran after the removal, found the queue changed and went
      // before the song that followed the removed one.
      expect(inserted.single.index, 0);
      await pumpEventQueue();
      expect(container.read(queueProvider), ['b', 'c', 'd']);
    }, skip: !sqliteAvailable);
  });

  test(
    'undoRemoval without a handler emits an error instead of throwing',
    () async {
      final noHandler = ProviderContainer(
        overrides: [
          ...withTestDatabase(database),
          audioHandlerProvider.overrideWithValue(null),
          playbackSnapshotProvider.overrideWith(
            (ref) => Stream.value(
              const PlaybackSnapshot.idle().copyWith(
                queueSongIds: const ['a', 'c'],
              ),
            ),
          ),
        ],
      );
      addTearDown(noHandler.dispose);
      noHandler.listen(queueProvider, (_, _) {});
      final seen = <PlaybackActionError>[];
      noHandler.listen(
        playbackActionErrorProvider,
        (_, next) => next.whenData(seen.add),
      );
      await pumpEventQueue();

      await noHandler
          .read(queueProvider.notifier)
          .undoRemoval(
            const QueueRemoval(
              index: 1,
              songId: 'b',
              successorId: 'c',
              epoch: 0,
              idsAfter: ['a', 'c'],
              wasOnly: false,
            ),
          );
      await pumpEventQueue();

      expect(seen.single.error, isA<PlaybackUnavailableException>());
    },
    skip: !sqliteAvailable,
  );

  group('runReportingErrors', () {
    test(
      'returns true on success and false with an error on failure',
      () async {
        await start(_BatchHandler(), ['a']);

        expect(await controller().runReportingErrors(() async {}), isTrue);
        expect(errors, isEmpty);

        expect(
          await controller().runReportingErrors(
            () async => throw StateError('boom'),
            label: 'x',
          ),
          isFalse,
        );
        await pumpEventQueue();
        expect(errors.single.action, 'x');
      },
      skip: !sqliteAvailable,
    );

    test('a superseded action is false but silent', () async {
      await start(_BatchHandler(), ['a']);

      expect(
        await controller().runReportingErrors(
          () async => throw OperationCancelledException(),
        ),
        isFalse,
      );
      await pumpEventQueue();
      expect(errors, isEmpty);
    }, skip: !sqliteAvailable);

    test('fireAndForget still reports errors', () async {
      await start(_BatchHandler(), ['a']);

      controller().fireAndForget(
        () async => throw StateError('boom'),
        label: 'y',
      );
      await pumpEventQueue();

      expect(errors.single.action, 'y');
    }, skip: !sqliteAvailable);
  });
}
