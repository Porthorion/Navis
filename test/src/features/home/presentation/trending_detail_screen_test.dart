import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/track_match_status_label.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/trending_detail_screen.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/presentation/ranked_virtual_playlist_content.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import '../../../../helpers/queue_replace_spy.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Stream<List<ResolvedArtistTopTrack>> Function(Ref ref) tracks, {
    bool albumQueue = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  albumQueueEnabled: albumQueue,
                ),
              ),
            ),
            queueProvider.overrideWith(QueueReplaceSpy.new),
            homeTrendingProvider.overrideWith(tracks),
            songDownloadStateProvider.overrideWith(
              (ref, songId) => SongDownloadState.none,
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TrendingDetailScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(TrendingDetailScreen)),
    );
  }

  Finder row(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(AdaptiveTrackRow),
  );

  const remote = Song(
    id: 'ext-deezer-song-2',
    title: 'Remote Song',
    artist: 'Stranger',
    artistId: 'ext-deezer-artist-9',
    album: 'Remote Album',
    albumId: 'ext-deezer-album-7',
    isExternal: true,
  );

  const chart = <ResolvedArtistTopTrack>[
    ResolvedArtistTopTrack(
      rank: 1,
      title: 'Library Song',
      artist: 'Known',
      resolvedSong: Song(id: 'lib-1', title: 'Library Song', artist: 'Known'),
    ),
    ResolvedArtistTopTrack(
      rank: 2,
      title: 'Remote Song',
      artist: 'Stranger',
      resolvedSong: remote,
    ),
    ResolvedArtistTopTrack(rank: 3, title: 'Missing Song', artist: 'X'),
  ];

  test('the route lives under Library', () {
    expect(AppRoutes.trending, '/library/trending');
  });

  for (final albumQueue in <bool>[true, false]) {
    testWidgets(
      'tapping a chart song ${albumQueue ? 'queues the chart from it' : 'plays only it'} '
      'with Album Queue ${albumQueue ? 'on' : 'off'}',
      (tester) async {
        // An unresolved row sits between the playable ones and is skipped.
        const gappedChart = <ResolvedArtistTopTrack>[
          ResolvedArtistTopTrack(
            rank: 1,
            title: 'Library Song',
            artist: 'Known',
            resolvedSong: Song(
              id: 'lib-1',
              title: 'Library Song',
              artist: 'Known',
            ),
          ),
          ResolvedArtistTopTrack(rank: 2, title: 'Missing Song', artist: 'X'),
          ResolvedArtistTopTrack(
            rank: 3,
            title: 'Remote Song',
            artist: 'Stranger',
            resolvedSong: remote,
          ),
        ];
        final container = await pump(
          tester,
          (ref) => Stream.value(gappedChart),
          albumQueue: albumQueue,
        );

        await tester.tap(row('Remote Song'));
        await tester.pumpAndSettle();

        final queue = container.read(queueProvider.notifier) as QueueReplaceSpy;
        expect(
          queue.lastReplaceIds,
          albumQueue ? <String>['lib-1', remote.id] : <String>[remote.id],
        );
        expect(queue.lastStartIndex, albumQueue ? 1 : 0);
      },
    );
  }

  testWidgets('lists every chart song in chart order, without gaps', (
    tester,
  ) async {
    await pump(tester, (ref) => Stream.value(chart));
    expect(find.byType(RankedVirtualPlaylistContent), findsOneWidget);
    expect(
      find.text('Deezer chart • 3 songs • 2 of 3 available'),
      findsOneWidget,
    );
    for (final (title, rank) in <(String, String)>[
      ('Library Song', '1'),
      ('Remote Song', '2'),
      ('Missing Song', '3'),
    ]) {
      expect(
        find.descendant(of: row(title), matching: find.text(rank)),
        findsOneWidget,
      );
    }
    // Playable songs have no status; the missing one looks like a weekly
    // playlist's: faded, "Not on server" and a Search action.
    expect(find.byType(TrackMatchStatusLabel), findsOneWidget);
    expect(
      find.descendant(
        of: row('Missing Song'),
        matching: find.text('Not on server'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row('Missing Song'),
        matching: find.byIcon(Icons.search_rounded),
      ),
      findsOneWidget,
    );
    final fade = tester.widget<Opacity>(
      find
          .ancestor(of: row('Missing Song'), matching: find.byType(Opacity))
          .first,
    );
    expect(fade.opacity, TrackMatchStatusLabel.unavailableOpacity);
    expect(
      tester.widget<AdaptiveTrackRow>(row('Remote Song')).isRemote,
      isTrue,
    );
  });

  testWidgets('songs still searched show Matching', (tester) async {
    await pump(
      tester,
      (ref) => Stream.value(const <ResolvedArtistTopTrack>[
        ResolvedArtistTopTrack(
          rank: 1,
          title: 'Pending Song',
          artist: 'X',
          isMatching: true,
        ),
      ]),
    );
    expect(
      find.text('Deezer chart • 1 song • No tracks available, matching'),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row('Pending Song'), matching: find.text('Matching')),
      findsOneWidget,
    );
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.hourglass_empty_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'a remote song menu stores the song and offers its album and artist',
    (tester) async {
      await pump(tester, (ref) => Stream.value(chart));
      await tester.longPress(find.text('Remote Song'));
      await tester.pumpAndSettle();

      expect(find.text('Open album'), findsOneWidget);
      expect(find.text('Open artist'), findsOneWidget);
      final stored = await tester.runAsync(
        () => database.libraryDao.getSongById(remote.id),
      );
      expect(stored?.albumId, 'ext-deezer-album-7');
      expect(stored?.isExternal, isTrue);
    },
  );

  testWidgets('says when there is no chart to show', (tester) async {
    await pump(tester, (ref) => Stream.value(const <ResolvedArtistTopTrack>[]));
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No Trending Songs'), findsOneWidget);
  });

  testWidgets('a retry after a failed chart is a manual refresh', (
    tester,
  ) async {
    final container = await pump(
      tester,
      (ref) => Stream.error(StateError('offline')),
    );
    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Could Not Load Trending'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(ErrorState),
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton,
        ),
      ),
    );
    await tester.pump();
    expect(container.read(homeTrendingRefreshProvider).manual, isTrue);
  });
}
