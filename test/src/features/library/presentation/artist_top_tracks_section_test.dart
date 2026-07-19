import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_section.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

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
  return Song(
    id: id,
    title: title,
    artist: 'Test Artist',
    album: 'Top Tracks',
  );
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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        albumQueueEnabledProvider.overrideWithValue(albumQueueEnabled),
        artistTopTracksProvider.overrideWith((ref, artistName) async => tracks),
        queueProvider.overrideWith(_QueueSpyController.new),
        songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
        songDownloadStateProvider.overrideWith(
          (ref, songId) => SongDownloadState.none,
        ),
        subsonicApiProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: ArtistTopTracksSection(artistName: 'Test Artist'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final context = tester.element(find.byType(ArtistTopTracksSection));
  return ProviderScope.containerOf(
        context,
      ).read(queueProvider.notifier)
      as _QueueSpyController;
}

void main() {
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

    expect(
      queueSpy.lastReplaceIds,
      const <String>['song-1', 'song-2', 'song-3'],
    );
    expect(queueSpy.lastStartIndex, 1);
    expect(queueSpy.lastAutoPlay, isTrue);
  });

  testWidgets(
    'queues only the tapped track when it is the only resolved track',
    (
      tester,
    ) async {
      final queueSpy = await _pumpTopTracksSection(
        tester,
        albumQueueEnabled: true,
        tracks: [
          _track(rank: 1, id: 'song-1', title: 'Only Song'),
        ],
      );

      await tester.tap(find.text('Only Song'));
      await tester.pumpAndSettle();

      expect(queueSpy.lastReplaceIds, const <String>['song-1']);
      expect(queueSpy.lastStartIndex, 0);
      expect(queueSpy.lastAutoPlay, isTrue);
    },
  );
}
