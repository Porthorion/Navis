import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_track_row.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/fake_playback_handler.dart';

/// A handler whose reorder only returns when the test says so, like the real
/// one waiting on the native `moveAudioSource`.
class _SlowReorderHandler extends InertPlaybackHandler {
  _SlowReorderHandler(List<String> ids) : queue = List.unmodifiable(ids);

  List<String> queue;
  final snapshots = StreamController<PlaybackSnapshot>.broadcast();
  final pending = <Completer<void>>[];
  final calls = <(int, int)>[];
  final played = <int>[];

  /// The song the handler's queue held at each played index when it was asked.
  final playedIds = <String>[];

  @override
  PlaybackSnapshot get snapshot =>
      const PlaybackSnapshot.idle().copyWith(queueSongIds: queue);

  @override
  Stream<PlaybackSnapshot> get snapshotStream => snapshots.stream;

  void publish(List<String> ids) {
    queue = List.unmodifiable(ids);
    snapshots.add(snapshot);
  }

  @override
  Future<void> playFromIndex(int index) async {
    played.add(index);
    playedIds.add(queue[index]);
  }

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) {
    calls.add((oldIndex, newIndex));
    final done = Completer<void>();
    pending.add(done);
    return done.future;
  }
}

void main() {
  late _SlowReorderHandler handler;
  late ProviderContainer container;

  Future<void> start(List<String> ids) async {
    handler = _SlowReorderHandler(ids);
    addTearDown(handler.snapshots.close);
    container = ProviderContainer(
      overrides: [audioHandlerProvider.overrideWithValue(handler)],
    );
    addTearDown(container.dispose);
    container.listen(queueProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(queueProvider), ids);
  }

  List<String> shown() => container.read(queueProvider);
  Future<void> reorder(int from, int to) =>
      container.read(queueProvider.notifier).reorder(from, to);

  test('shows the moved order before the handler finishes', () async {
    await start(['a', 'b', 'c', 'd']);

    final done = reorder(3, 0);
    expect(shown(), ['d', 'a', 'b', 'c']);
    expect(handler.calls, [(3, 0)]);

    handler.publish(['d', 'a', 'b', 'c']);
    handler.pending.single.complete();
    await done;
    await pumpEventQueue();
    expect(shown(), ['d', 'a', 'b', 'c']);
  });

  test('an insertion index past the old row lands one earlier', () async {
    await start(['a', 'b', 'c', 'd']);

    final done = reorder(0, 3);
    expect(shown(), ['b', 'c', 'a', 'd']);
    handler.pending.single.complete();
    await done;
  });

  test('an old-order snapshot in between does not undo the move', () async {
    await start(['a', 'b', 'c', 'd']);

    final done = reorder(3, 0);
    handler.publish(['a', 'b', 'c', 'd']);
    await pumpEventQueue();
    expect(shown(), ['d', 'a', 'b', 'c']);

    handler.pending.single.complete();
    await done;
  });

  test('a failed move returns to the handler order', () async {
    await start(['a', 'b', 'c', 'd']);

    final done = reorder(3, 0);
    expect(shown(), ['d', 'a', 'b', 'c']);

    handler.pending.single.completeError(StateError('move failed'));
    await expectLater(done, throwsStateError);
    await pumpEventQueue();
    expect(shown(), ['a', 'b', 'c', 'd']);
  });

  test('two quick moves compose', () async {
    await start(['a', 'b', 'c', 'd']);

    final first = reorder(3, 0);
    final second = reorder(3, 1);
    expect(shown(), ['d', 'c', 'a', 'b']);
    expect(handler.calls, [(3, 0), (3, 1)]);

    handler.publish(['d', 'a', 'b', 'c']);
    handler.pending.first.complete();
    await first;
    await pumpEventQueue();
    expect(shown(), ['d', 'c', 'a', 'b'], reason: 'the second is in flight');

    handler.publish(['d', 'c', 'a', 'b']);
    handler.pending.last.complete();
    await second;
    await pumpEventQueue();
    expect(shown(), ['d', 'c', 'a', 'b']);
  });

  test('a replaced queue is shown as the handler published it', () async {
    await start(['a', 'b', 'c', 'd']);

    final done = reorder(3, 0);
    handler.publish(['x', 'y']);
    await pumpEventQueue();
    expect(shown(), ['x', 'y']);

    handler.pending.single.complete();
    await done;
    await pumpEventQueue();
    expect(shown(), ['x', 'y']);
  });

  test('an out-of-range move is left to the handler', () async {
    await start(['a', 'b']);

    final done = reorder(5, 0);
    expect(shown(), ['a', 'b']);
    handler.pending.single.complete();
    await done;
  });

  Future<void> tap(int index) =>
      container.read(queueProvider.notifier).playFromIndex(index);

  test('a tap during a pending move plays the tapped song', () async {
    await start(['a', 'b', 'c', 'd']);

    final move = reorder(3, 0); // shown: d a b c
    expect(shown(), ['d', 'a', 'b', 'c']);
    final tapped = tap(2); // "b" in the shown order, index 1 in the handler's
    await pumpEventQueue();
    expect(handler.played, isEmpty, reason: 'waits for the move, not dropped');

    handler.publish(['d', 'a', 'b', 'c']);
    handler.pending.single.complete();
    await move;
    await tapped;
    expect(handler.played, [2]);
    expect(handler.playedIds, ['b']);
  });

  test('the handler order decides when the move did not apply', () async {
    await start(['a', 'b', 'c', 'd']);

    final move = reorder(3, 0);
    final tapped = tap(0); // "d", index 3 while the move has not applied
    handler.pending.single.completeError(StateError('move failed'));
    await expectLater(move, throwsStateError);
    await tapped;
    expect(handler.played, [3]);
  });

  test(
    'a tap on the second copy of a duplicate plays the second copy',
    () async {
      await start(['a', 'b', 'a', 'c']);

      final move = reorder(3, 0); // shown: c a b a
      expect(shown(), ['c', 'a', 'b', 'a']);
      final tapped = tap(3); // second "a"
      handler.publish(['c', 'a', 'b', 'a']);
      handler.pending.single.complete();
      await move;
      await tapped;
      expect(handler.played, [3]);

      // Published order differs from the shown one: still the second copy.
      await pumpEventQueue();
      expect(shown(), ['c', 'a', 'b', 'a']);
      final again = reorder(0, 4); // shown: a b a c
      final second = tap(2); // second "a"
      handler.publish(['a', 'b', 'a', 'c']);
      handler.pending.last.complete();
      await again;
      await second;
      expect(handler.played, [3, 2]);
      expect(handler.playedIds, ['a', 'a']);
    },
  );

  test('a queue replaced under the tap plays nothing', () async {
    await start(['a', 'b', 'c', 'd']);

    final move = reorder(3, 0);
    final tapped = tap(1);
    handler.publish(['x', 'y']);
    handler.pending.single.complete();
    await move;
    await tapped;
    expect(handler.played, isEmpty);
  });

  test('a tap with no move in flight goes straight to the handler', () async {
    await start(['a', 'b', 'c']);
    await tap(1);
    expect(handler.played, [1]);
  });

  group('queuePlayingIndex', () {
    PlaybackSnapshot playing(List<String> ids, int index) =>
        const PlaybackSnapshot.idle().copyWith(
          queueSongIds: ids,
          currentIndex: index,
        );

    test('follows a unique song through a shown move', () {
      expect(
        queuePlayingIndex(playing(['a', 'b', 'c'], 2), ['c', 'a', 'b']),
        0,
      );
    });

    test('keeps the occurrence when the copies keep their order', () {
      expect(
        queuePlayingIndex(playing(['a', 'b', 'a'], 2), ['a', 'a', 'b']),
        1,
      );
    });

    test('is a copy of the playing song when a move swaps the copies', () {
      // Limit: the playing copy is not tracked through the move, only the
      // song is. Published [a, b, a] plays index 2; shown [b, a, a].
      final index = queuePlayingIndex(playing(['a', 'b', 'a'], 2), [
        'b',
        'a',
        'a',
      ]);
      expect(['b', 'a', 'a'][index!], 'a');
    });
  });
}
