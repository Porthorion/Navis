import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';

void main() {
  group('resolveSongPlaybackIndicatorState', () {
    test('resolves idle, current, and paused songs', () {
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-1',
          currentSongId: null,
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.inactive,
      );
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-1',
          currentSongId: 'song-1',
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.current,
      );
    });

    test('loading target replaces the previous current song', () {
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-1',
          currentSongId: 'song-1',
          isLoading: true,
          loadingSongId: 'song-2',
        ),
        SongPlaybackIndicatorState.inactive,
      );
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-2',
          currentSongId: 'song-1',
          isLoading: true,
          loadingSongId: 'song-2',
        ),
        SongPlaybackIndicatorState.loading,
      );
    });

    test('falls back after loading ends and ignores radio playback', () {
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-1',
          currentSongId: 'song-1',
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.current,
      );
      expect(
        resolveSongPlaybackIndicatorState(
          songId: 'song-1',
          currentSongId: null,
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.inactive,
      );
    });

    test('queue state prioritizes loading target and current occurrence', () {
      const queue = <String>['song-1', 'song-2', 'song-1'];
      expect(
        resolveQueueSongPlaybackIndicatorState(
          rowIndex: 1,
          rowSongId: 'song-2',
          queueSongIds: queue,
          currentIndex: 0,
          currentSongId: 'song-1',
          isLoading: true,
          loadingSongId: 'song-2',
        ),
        SongPlaybackIndicatorState.loading,
      );
      expect(
        resolveQueueSongPlaybackIndicatorState(
          rowIndex: 2,
          rowSongId: 'song-1',
          queueSongIds: queue,
          currentIndex: 2,
          currentSongId: 'song-1',
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.current,
      );
      expect(
        resolveQueueSongPlaybackIndicatorState(
          rowIndex: 0,
          rowSongId: 'song-1',
          queueSongIds: queue,
          currentIndex: 2,
          currentSongId: 'song-1',
          isLoading: false,
          loadingSongId: null,
        ),
        SongPlaybackIndicatorState.inactive,
      );
    });
  });

  testWidgets('track-number tile shows selected equalizer while paused', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      snapshot: _snapshot(currentSongId: 'song-1', playing: false),
      showAlbumArt: false,
    );

    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.selected, isTrue);
    expect(tile.selectedTileColor, isNotNull);
    expect(find.text('7'), findsNothing);
    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.value == 'Now Playing',
      ),
    );
    expect(semantics.properties.value, 'Now Playing');
  });

  testWidgets('artwork tile overlays progress for the loading target', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      snapshot: _snapshot(
        currentSongId: 'old-song',
        isLoading: true,
        loadingSongId: 'song-1',
      ),
      showAlbumArt: true,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(ArtworkPlaybackMarker), findsOneWidget);
    expect(tester.widget<ListTile>(find.byType(ListTile)).selected, isTrue);
  });

  testWidgets('inactive tile keeps its track number and default styling', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      snapshot: _snapshot(currentSongId: 'different-song'),
      showAlbumArt: false,
    );

    expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
    expect(find.text('7'), findsOneWidget);
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.selected, isFalse);
  });

  testWidgets('album and playlist number columns align with current marker', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStateProvider.overrideWithValue(
            _snapshot(currentSongId: 'song-2'),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Column(
              children: <Widget>[
                TrackListTile(song: _song),
                TrackListTile(song: _secondSong),
              ],
            ),
          ),
        ),
      ),
    );

    final number = find.text('7');
    final marker = find.byIcon(Icons.graphic_eq_rounded);
    expect(number, findsOneWidget);
    expect(marker, findsOneWidget);
    expect(
      tester.getCenter(marker).dx,
      closeTo(tester.getCenter(number).dx, 0.1),
    );
    expect(
      tester.getTopLeft(find.text('Song One')).dx,
      closeTo(tester.getTopLeft(find.text('Song Two')).dx, 0.1),
    );
  });
}

Future<void> _pumpTile(
  WidgetTester tester, {
  required PlaybackSnapshot snapshot,
  required bool showAlbumArt,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(snapshot),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TrackListTile(
            song: _song,
            showAlbumArt: showAlbumArt,
          ),
        ),
      ),
    ),
  );
}

const _song = SongsTableData(
  id: 'song-1',
  title: 'Song One',
  track: 7,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

const _secondSong = SongsTableData(
  id: 'song-2',
  title: 'Song Two',
  track: 8,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

PlaybackSnapshot _snapshot({
  String? currentSongId,
  bool playing = true,
  bool isLoading = false,
  String? loadingSongId,
}) {
  return PlaybackSnapshot(
    queueSongIds: currentSongId == null
        ? const <String>[]
        : <String>[currentSongId],
    currentSongId: currentSongId,
    currentIndex: currentSongId == null ? null : 0,
    playing: playing,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: const Duration(minutes: 3),
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.none,
    isLoading: isLoading,
    loadingSongId: loadingSongId,
  );
}
