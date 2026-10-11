import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/playback_seek_bar_style.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playbackPositionProvider, playerStateProvider;

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

  PlaybackSnapshot snapshot({Duration? pendingSeek}) => PlaybackSnapshot(
    queueSongIds: const <String>['song-1'],
    currentSongId: 'song-1',
    currentIndex: 0,
    playing: true,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: const Duration(minutes: 4),
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.one,
    pendingSeekPosition: pendingSeek,
  );

  testWidgets('a finished seek never freezes the shown position', (
    tester,
  ) async {
    // The parent's snapshot can still carry the seek after the handler has
    // cleared it (it rebuilt for nothing else, e.g. under Repeat One). The
    // bar must follow the live position, not stay on the seek target.
    final positions = StreamController<Duration>();
    addTearDown(positions.close);
    final stale = snapshot(pendingSeek: const Duration(seconds: 60));
    final container = ProviderContainer(
      overrides: [
        playbackPositionProvider.overrideWith((ref) => positions.stream),
        _live.overrideWith(
          () =>
              _LiveSnapshot(snapshot(pendingSeek: const Duration(seconds: 60))),
        ),
        playerStateProvider.overrideWith((ref) => ref.watch(_live)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) =>
                Text('${watchDisplayedPlaybackPosition(ref, stale).inSeconds}'),
          ),
        ),
      ),
    );
    expect(find.text('60'), findsOneWidget);
    // The seek completes: the handler clears it and playback moves on.
    container.read(_live.notifier).current = snapshot();
    positions.add(const Duration(seconds: 61));
    await tester.pump();
    await tester.pump();
    expect(find.text('61'), findsOneWidget);
    positions.add(const Duration(seconds: 65));
    await tester.pump();
    await tester.pump();
    expect(find.text('65'), findsOneWidget);
  });
}

final _live = NotifierProvider<_LiveSnapshot, PlaybackSnapshot>(
  () => throw UnimplementedError('overridden in the test'),
);

class _LiveSnapshot extends Notifier<PlaybackSnapshot> {
  new(this._initial);

  final PlaybackSnapshot _initial;

  @override
  PlaybackSnapshot build() => _initial;

  set current(PlaybackSnapshot value) => state = value;
}
