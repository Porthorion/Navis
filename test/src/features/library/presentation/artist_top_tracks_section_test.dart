import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_section.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/test_theme.dart';
import '../../../../helpers/test_database.dart';

class _QueueSpyController extends QueueController {
  List<String>? lastReplaceIds;
  int? lastStartIndex;
  bool? lastAutoPlay;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replaceWithSongs(
    List<Song> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    final ids = songs.map((song) => song.id).toList(growable: false);
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    state = List<String>.unmodifiable(ids);
  }
}

Song _song(String id, String title) {
  return Song(id: id, title: title, artist: 'Test Artist', album: 'Top Tracks');
}

ResolvedArtistTopTrack _track({
  required int rank,
  required String id,
  required String title,
}) {
  return ResolvedArtistTopTrack(
    rank: rank,
    title: title,
    artist: 'Test Artist',
    resolvedSong: _song(id, title),
  );
}

Future<_QueueSpyController> _pumpTopTracksSection(
  WidgetTester tester, {
  required bool albumQueueEnabled,
  required List<ResolvedArtistTopTrack> tracks,
  PlaybackSnapshot? playbackSnapshot,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        albumQueueEnabledProvider.overrideWithValue(albumQueueEnabled),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        artistTopTracksProvider.overrideWith(
          (ref, key) => Stream.value(tracks),
        ),
        queueProvider.overrideWith(_QueueSpyController.new),
        songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
        songDownloadStateProvider.overrideWith(
          (ref, songId) => SongDownloadState.none,
        ),
        subsonicApiProvider.overrideWithValue(null),
        if (playbackSnapshot != null)
          playerStateProvider.overrideWithValue(playbackSnapshot),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: ArtistTopTracksSection(
            artistId: 'artist-1',
            artistName: 'Test Artist',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final context = tester.element(find.byType(ArtistTopTracksSection));
  return ProviderScope.containerOf(context).read(queueProvider.notifier)
      as _QueueSpyController;
}

void main() {
  testWidgets('marks the paused current artist top track', (tester) async {
    await _pumpTopTracksSection(
      tester,
      albumQueueEnabled: false,
      tracks: [
        _track(rank: 1, id: 'song-1', title: 'First Song'),
        _track(rank: 2, id: 'song-2', title: 'Second Song'),
      ],
      playbackSnapshot: const PlaybackSnapshot(
        queueSongIds: <String>['song-2'],
        currentSongId: 'song-2',
        currentIndex: 0,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(minutes: 3),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      ),
    );

    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.text('2'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.value == 'Now Playing',
      ),
      findsOneWidget,
    );
  });

  testWidgets('queues only tapped top track when Album Queue is disabled', (
    tester,
  ) async {
    final queueSpy = await _pumpTopTracksSection(
      tester,
      albumQueueEnabled: false,
      tracks: [
        _track(rank: 1, id: 'song-1', title: 'First Song'),
        _track(rank: 2, id: 'song-2', title: 'Second Song'),
        _track(rank: 3, id: 'song-3', title: 'Third Song'),
      ],
    );

    await tester.tap(find.text('Second Song'));
    await tester.pumpAndSettle();

    expect(queueSpy.lastReplaceIds, const <String>['song-2']);
    expect(queueSpy.lastStartIndex, 0);
    expect(queueSpy.lastAutoPlay, isTrue);
  });

  testWidgets('desktop top-track More opens the anchored song menu', (
    tester,
  ) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const localSong = SongsTableData(
      id: 'song-menu',
      title: 'Menu Song',
      artistName: 'Test Artist',
      isProvisional: false,
      isExternal: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            albumQueueEnabledProvider.overrideWithValue(false),
            artistTopTracksProvider.overrideWith(
              (ref, key) => Stream.value([
                _track(rank: 1, id: 'song-menu', title: 'Menu Song'),
              ]),
            ),
            songByIdProvider.overrideWith(
              (ref, songId) => Stream.value(localSong),
            ),
            songDownloadStateProvider.overrideWith(
              (ref, songId) => SongDownloadState.none,
            ),
            subsonicApiProvider.overrideWithValue(null),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(900, 700),
              safePadding: EdgeInsets.zero,
            ),
            child: const Scaffold(
              body: ArtistTopTracksSection(
                artistId: 'artist-1',
                artistName: 'Test Artist',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('More'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Play now'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('queues all resolved top tracks when Album Queue is enabled', (
    tester,
  ) async {
    final queueSpy = await _pumpTopTracksSection(
      tester,
      albumQueueEnabled: true,
      tracks: [
        _track(rank: 1, id: 'song-1', title: 'First Song'),
        _track(rank: 2, id: 'song-2', title: 'Second Song'),
        _track(rank: 3, id: 'song-3', title: 'Third Song'),
      ],
    );

    await tester.tap(find.text('Second Song'));
    await tester.pumpAndSettle();

    expect(queueSpy.lastReplaceIds, const <String>[
      'song-1',
      'song-2',
      'song-3',
    ]);
    expect(queueSpy.lastStartIndex, 1);
    expect(queueSpy.lastAutoPlay, isTrue);
  });

  testWidgets(
    'queues only the tapped track when it is the only resolved track',
    (tester) async {
      final queueSpy = await _pumpTopTracksSection(
        tester,
        albumQueueEnabled: true,
        tracks: [_track(rank: 1, id: 'song-1', title: 'Only Song')],
      );

      await tester.tap(find.text('Only Song'));
      await tester.pumpAndSettle();

      expect(queueSpy.lastReplaceIds, const <String>['song-1']);
      expect(queueSpy.lastStartIndex, 0);
      expect(queueSpy.lastAutoPlay, isTrue);
    },
  );
}
