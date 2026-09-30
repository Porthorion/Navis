import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';

class _InnerHandler extends BaseAudioHandler {
  final List<Duration> seeks = <Duration>[];

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
}

void main() {
  const item = MediaItem(
    id: 'song',
    title: 'Song',
    duration: Duration(minutes: 3),
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
}
