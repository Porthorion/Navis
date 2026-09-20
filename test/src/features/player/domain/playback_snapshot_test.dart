import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

void main() {
  group('PlaybackSnapshot', () {
    test('idle snapshot defaults isCurrentSongLiked to false', () {
      const snapshot = PlaybackSnapshot.idle();
      expect(snapshot.isCurrentSongLiked, isFalse);
      expect(snapshot.pendingQueueIndex, isNull);
    });

    test('pending queue index identifies the requested entry', () {
      const snapshot = PlaybackSnapshot(
        queueSongIds: <String>['a', 'b'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.loading,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        pendingQueueIndex: 1,
      );
      expect(snapshot.pendingQueueIndex, 1);
      expect(snapshot.copyWith(playing: false).pendingQueueIndex, 1);
    });

    test('full constructor defaults isCurrentSongLiked to false', () {
      const snapshot = PlaybackSnapshot(
        queueSongIds: <String>['a'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(seconds: 180),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      );
      expect(snapshot.isCurrentSongLiked, isFalse);
    });

    test('isCurrentSongLiked can be set to true', () {
      const snapshot = PlaybackSnapshot(
        queueSongIds: <String>['a'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(seconds: 180),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        isCurrentSongLiked: true,
      );
      expect(snapshot.isCurrentSongLiked, isTrue);
    });

    test('copyWith preserves isCurrentSongLiked when not overridden', () {
      const original = PlaybackSnapshot(
        queueSongIds: <String>['a'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(seconds: 200),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        isCurrentSongLiked: true,
      );

      final copied = original.copyWith(playing: true);
      expect(copied.isCurrentSongLiked, isTrue);
      expect(copied.playing, isTrue);
    });

    test('copyWith can toggle isCurrentSongLiked', () {
      const original = PlaybackSnapshot(
        queueSongIds: <String>['a'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(seconds: 200),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
        isCurrentSongLiked: true,
      );

      final toggled = original.copyWith(isCurrentSongLiked: false);
      expect(toggled.isCurrentSongLiked, isFalse);
      expect(toggled.currentSongId, 'a');
    });

    test('hasQueue returns true when songs present', () {
      const snapshot = PlaybackSnapshot(
        queueSongIds: <String>['a', 'b'],
        currentSongId: 'a',
        currentIndex: 0,
        playing: false,
        processingState: AudioProcessingState.idle,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      );
      expect(snapshot.hasQueue, isTrue);
    });

    test('idle snapshot hasQueue returns false', () {
      const snapshot = PlaybackSnapshot.idle();
      expect(snapshot.hasQueue, isFalse);
    });

    test('idle snapshot defaults load state fields', () {
      const snapshot = PlaybackSnapshot.idle();
      expect(snapshot.isLoading, isFalse);
      expect(snapshot.hasPendingLogicalQueue, isFalse);
      expect(snapshot.loadingSongId, isNull);
      expect(snapshot.lastFailedSongId, isNull);
    });

    test('remote loading follows the selected song, then active buffering', () {
      const local = PlaybackSnapshot(
        queueSongIds: <String>['local'],
        currentSongId: 'local',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(minutes: 3),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      );
      final remotePending = local.copyWith(
        isLoading: true,
        loadingSongId: 'ext-deezer-track',
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remotePending,
          currentIsExternal: false,
        ),
        isTrue,
      );

      final remoteReady = remotePending.copyWith(
        currentSongId: 'ext-deezer-track',
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady,
          currentIsExternal: true,
        ),
        isFalse,
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady.copyWith(
            isLoading: false,
            processingState: AudioProcessingState.buffering,
          ),
          currentIsExternal: true,
        ),
        isTrue,
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady.copyWith(isLoading: false),
          currentIsExternal: true,
        ),
        isFalse,
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady.copyWith(
            isLoading: false,
            playing: false,
            processingState: AudioProcessingState.buffering,
          ),
          currentIsExternal: true,
        ),
        isFalse,
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady.copyWith(
            isLoading: true,
            loadingSongId: 'local-track',
            processingState: AudioProcessingState.buffering,
          ),
          currentIsExternal: true,
        ),
        isFalse,
      );
      expect(
        shouldShowRemotePlaybackLoading(
          playback: remoteReady.copyWith(
            isLoading: false,
            processingState: AudioProcessingState.idle,
            lastFailedSongId: 'ext-deezer-track',
          ),
          currentIsExternal: true,
        ),
        isFalse,
      );
    });

    test('song metadata keeps transcoded playback duration stable', () {
      const metadataDuration = Duration(minutes: 4);

      expect(
        resolveEffectivePlaybackDuration(
          isRadioMode: false,
          mediaDuration: metadataDuration,
          playerDuration: const Duration(seconds: 18),
        ),
        metadataDuration,
      );
      expect(
        resolveEffectivePlaybackDuration(
          isRadioMode: false,
          mediaDuration: metadataDuration,
          playerDuration: const Duration(seconds: 37),
        ),
        metadataDuration,
      );
    });

    test('duration falls back to decoder and preserves radio precedence', () {
      const decoderDuration = Duration(minutes: 2);

      expect(
        resolveEffectivePlaybackDuration(
          isRadioMode: false,
          mediaDuration: null,
          playerDuration: decoderDuration,
        ),
        decoderDuration,
      );
      expect(
        resolveEffectivePlaybackDuration(
          isRadioMode: true,
          mediaDuration: const Duration(minutes: 5),
          playerDuration: decoderDuration,
        ),
        decoderDuration,
      );
    });

    test('pending queue index can be cleared after navigation settles', () {
      const pending = PlaybackSnapshot.idle();
      final selected = pending.copyWith(pendingQueueIndex: 3);

      expect(selected.pendingQueueIndex, 3);
      expect(selected.copyWith().pendingQueueIndex, 3);
      expect(
        selected.copyWith(pendingQueueIndex: null).pendingQueueIndex,
        isNull,
      );
    });
  });
}
