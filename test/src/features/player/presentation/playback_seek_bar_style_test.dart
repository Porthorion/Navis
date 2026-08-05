import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/playback_seek_bar_style.dart';

void main() {
  test('buffered seek value is track keyed and clamped to duration', () {
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: const Duration(seconds: 240),
      ),
      90000,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 300),
        ),
        duration: const Duration(seconds: 240),
      ),
      240000,
    );
  });

  test('buffered seek value hides stale, empty, and unknown timelines', () {
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-2',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: const Duration(seconds: 240),
      ),
      isNull,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration.zero,
        ),
        duration: const Duration(seconds: 240),
      ),
      isNull,
    );
    expect(
      resolveBufferedSeekValue(
        currentSongId: 'song-1',
        bufferState: const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 90),
        ),
        duration: Duration.zero,
      ),
      isNull,
    );
  });
}
