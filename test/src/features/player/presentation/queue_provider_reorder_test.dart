import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
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
}
