import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';

class _InnerHandler extends BaseAudioHandler {
  final List<Duration> seeks = <Duration>[];
  final List<int> skips = <int>[];

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> skipToQueueItem(int index) async => skips.add(index);
}

List<MediaItem> _items(int count) => List<MediaItem>.generate(
  count,
  (index) => MediaItem(id: 'song-$index', title: 'Song $index'),
);

void main() {
  const item = MediaItem(
    id: 'song',
    title: 'Song',
    duration: Duration(minutes: 3),
  );

  test(
    'service recreation republishes deduped metadata, queue and playback state',
    () async {
      final inner = _InnerHandler();
      final projection = RealTimeProjectionAudioHandler(inner);
      addTearDown(projection.dispose);
      inner.queue.add([const MediaItem(id: 'song', title: 'Song')]);
      inner.mediaItem.add(const MediaItem(id: 'song', title: 'Song'));
      inner.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          queueIndex: 0,
        ),
      );
      await pumpEventQueue();
      final queues = <List<MediaItem>>[];
      final items = <MediaItem?>[];
      final states = <PlaybackState>[];
      final subscriptions = [
        projection.queue.listen(queues.add),
        projection.mediaItem.listen(items.add),
        projection.playbackState.listen(states.add),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });
      await pumpEventQueue();
      final before = (queues.length, items.length, states.length);
      await projection.customAction('navisServiceRecreated');
      await pumpEventQueue();
      expect(
        (queues.length, items.length, states.length),
        (before.$1 + 1, before.$2 + 1, before.$3 + 1),
      );
      expect(items.last?.id, 'song');
      expect(states.last.playing, isTrue);
    },
  );

  test('publishes real listening time at non-normal speeds', () async {
    final inner = _InnerHandler();
    final projection = RealTimeProjectionAudioHandler(inner);
    inner.mediaItem.add(item);
    inner.playbackState.add(
      PlaybackState(
        playing: true,
        updatePosition: const Duration(seconds: 90),
        bufferedPosition: const Duration(seconds: 120),
        speed: 1.5,
      ),
    );
    await pumpEventQueue();

    final state = projection.playbackState.value;
    expect(state.updatePosition, const Duration(seconds: 60));
    expect(state.bufferedPosition, const Duration(seconds: 80));
    expect(state.speed, 1.0);
    expect(projection.mediaItem.value!.duration, const Duration(minutes: 2));

    await projection.seek(const Duration(seconds: 40));
    expect(inner.seeks, <Duration>[const Duration(seconds: 60)]);
  });

  test('normal speed is published unchanged', () async {
    final inner = _InnerHandler();
    final projection = RealTimeProjectionAudioHandler(inner);
    inner.mediaItem.add(item);
    inner.playbackState.add(
      PlaybackState(updatePosition: const Duration(seconds: 90)),
    );
    await pumpEventQueue();

    expect(
      projection.playbackState.value.updatePosition,
      const Duration(seconds: 90),
    );
    expect(projection.mediaItem.value, same(item));
    await projection.seek(const Duration(seconds: 40));
    expect(inner.seeks, <Duration>[const Duration(seconds: 40)]);
  });

  test('metadata is republished only when the item or speed changes', () async {
    final inner = _InnerHandler();
    final projection = RealTimeProjectionAudioHandler(inner);
    final published = <MediaItem?>[];
    projection.mediaItem.listen(published.add);
    inner.mediaItem.add(item);
    for (var i = 0; i < 5; i++) {
      inner.playbackState.add(
        PlaybackState(updatePosition: Duration(seconds: i), speed: 1.25),
      );
    }
    await pumpEventQueue();
    // Initial null, the item, and the item at 1.25×.
    expect(published.length, lessThanOrEqualTo(3));
    expect(published.last!.duration, const Duration(seconds: 144));

    inner.playbackState.add(PlaybackState(speed: 2));
    await pumpEventQueue();
    expect(published.last!.duration, const Duration(seconds: 90));
  });

  test(
    'the system queue is a bounded window around the current song',
    () async {
      final inner = _InnerHandler();
      final projection = RealTimeProjectionAudioHandler(inner);
      final published = <List<MediaItem>>[];
      projection.queue.listen(published.add);
      final items = _items(5000);
      inner.queue.add(items);
      inner.playbackState.add(PlaybackState(queueIndex: 2500));
      await pumpEventQueue();

      const size =
          RealTimeProjectionAudioHandler.queueWindowBefore +
          RealTimeProjectionAudioHandler.queueWindowAfter +
          1;
      final window = projection.queue.value;
      expect(window.length, size);
      expect(window.first.id, 'song-${2500 - 20}');
      expect(projection.playbackState.value.queueIndex, 20);

      // A system tap on a window row plays that song in the full queue.
      await projection.skipToQueueItem(25);
      expect(inner.skips, <int>[2505]);
    },
  );

  test('the window is republished only when its songs change', () async {
    final inner = _InnerHandler();
    final projection = RealTimeProjectionAudioHandler(inner);
    final published = <List<MediaItem>>[];
    projection.queue.listen(published.add);
    final items = _items(300);
    inner.queue.add(items);
    inner.playbackState.add(PlaybackState(queueIndex: 100));
    await pumpEventQueue();
    final before = published.length;

    // Advancing a few songs and appending far beyond the window change
    // nothing the system shows.
    inner.playbackState.add(PlaybackState(queueIndex: 101));
    inner.queue.add(<MediaItem>[...items, ..._items(2000).skip(300)]);
    await pumpEventQueue();
    expect(published.length, before);

    // Reaching the window's edge recentres it once.
    inner.playbackState.add(PlaybackState(queueIndex: 170));
    await pumpEventQueue();
    expect(published.length, before + 1);
    expect(projection.queue.value.first.id, 'song-150');
    expect(projection.playbackState.value.queueIndex, 20);
  });
}
