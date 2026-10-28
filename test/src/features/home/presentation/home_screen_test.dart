import 'dart:async';

import 'package:navis/src/features/settings/data/update_check_store.dart';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/routing/home_activity_scope.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/features/home/presentation/trending_detail_screen.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/queue_replace_spy.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

import 'package:go_router/go_router.dart';
import 'package:navis/src/routing/app_routes.dart';

class _StaticLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    return const LibrarySyncState.idle();
  }
}

class _FixedLibrarySyncController extends LibrarySyncController {
  new(this._fixedState);

  final LibrarySyncState _fixedState;

  @override
  LibrarySyncState build() => _fixedState;

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return _fixedState;
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    return _fixedState;
  }
}

class _PendingRefreshLibrarySyncController extends LibrarySyncController {
  int syncNowCalls = 0;
  Completer<LibrarySyncState> _completer = Completer<LibrarySyncState>();

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async {
    return const LibrarySyncState.idle();
  }

  @override
  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) {
    syncNowCalls++;
    return _completer.future;
  }

  void complete([LibrarySyncState state = const LibrarySyncState.idle()]) {
    if (!_completer.isCompleted) {
      _completer.complete(state);
    }
    _completer = Completer<LibrarySyncState>();
  }
}

class _MatchingRematchController extends ListenBrainzPlaylistRematchController {
  @override
  Set<String> build() => const <String>{'weekly-jams'};
}

class _LastFmIssueRadio extends PersonalRadioNotifier {
  _LastFmIssueRadio(this.lastFmIssue);

  final RecommendationIssue lastFmIssue;

  @override
  Future<RadioStartResult> start({
    RadioFilters filters = const RadioFilters(),
    bool autoPlay = true,
    bool Function()? isCurrent,
  }) async => RadioStartResult(
    insertedCount: 3,
    issue: RecommendationIssue.none,
    lastFmIssue: lastFmIssue,
  );
}

class _AutoAdvancePreference extends Notifier<bool> {
  @override
  bool build() => true;
  void setEnabled({required bool enabled}) => state = enabled;
}

final _autoAdvancePreference = NotifierProvider<_AutoAdvancePreference, bool>(
  _AutoAdvancePreference.new,
);

class _ShowcaseFixture extends Notifier<List<HomeRandomShowcaseItem>> {
  @override
  List<HomeRandomShowcaseItem> build() => const [];
  set items(List<HomeRandomShowcaseItem> value) => state = value;
}

final _showcaseFixture =
    NotifierProvider<_ShowcaseFixture, List<HomeRandomShowcaseItem>>(
      _ShowcaseFixture.new,
    );

class _QueueSpyController extends QueueController {
  List<String>? lastReplaceIds;
  int? lastStartIndex;
  bool? lastAutoPlay;
  bool? lastExpandMatchFlows;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    lastExpandMatchFlows = expandMatchFlows;
    state = List<String>.unmodifiable(ids);
  }

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    final ids = songs.map((s) => s.id).toList(growable: false);
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    lastExpandMatchFlows = expandMatchFlows;
    state = List<String>.unmodifiable(ids);
  }

  @override
  Future<void> replaceWithSongs(
    List<Song> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    final ids = songs.map((s) => s.id).toList(growable: false);
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    lastExpandMatchFlows = expandMatchFlows;
    state = List<String>.unmodifiable(ids);
  }
}

ListenBrainzDiscoverPlaylist _listenBrainzPlaylist(String id, String title) {
  final sourcePatch = switch (id) {
    'jams' => 'weekly-jams',
    'exploration' => 'weekly-exploration',
    _ => null,
  };
  return ListenBrainzDiscoverPlaylist(
    playlist: ListenBrainzPlaylist(
      identifier: id,
      title: title,
      sourcePatch: sourcePatch,
      tracks: const <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(
          title: 'Remote Song',
          creator: 'Remote Artist',
        ),
      ],
    ),
    recommendations: const <ListenBrainzResolvedRecommendation>[
      ListenBrainzResolvedRecommendation(
        track: ListenBrainzPlaylistTrack(
          title: 'Remote Song',
          creator: 'Remote Artist',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: Song(
          id: 'remote-song',
          title: 'Remote Song',
          artist: 'Remote Artist',
          album: 'Remote Album',
        ),
      ),
    ],
  );
}

ListenBrainzDiscoverPlaylist _listenBrainzPlaylistWithApiSongs() {
  return const ListenBrainzDiscoverPlaylist(
    playlist: ListenBrainzPlaylist(
      identifier: 'exploration',
      title: 'Weekly Exploration for alice, week of 2026-06-15',
      sourcePatch: 'weekly-exploration',
      tracks: <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(
          title: 'Remote Song 1',
          creator: 'Remote Artist',
        ),
        ListenBrainzPlaylistTrack(
          title: 'Remote Song 2',
          creator: 'Remote Artist',
        ),
      ],
    ),
    recommendations: <ListenBrainzResolvedRecommendation>[
      ListenBrainzResolvedRecommendation(
        track: ListenBrainzPlaylistTrack(
          title: 'Remote Song 1',
          creator: 'Remote Artist',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: Song(
          id: 'remote-song-1',
          title: 'Remote Song 1',
          artist: 'Remote Artist',
          album: 'Remote Album',
        ),
      ),
      ListenBrainzResolvedRecommendation(
        track: ListenBrainzPlaylistTrack(
          title: 'Remote Song 2',
          creator: 'Remote Artist',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: Song(
          id: 'remote-song-2',
          title: 'Remote Song 2',
          artist: 'Remote Artist',
          album: 'Remote Album',
        ),
      ),
    ],
  );
}

void _expectWeeklyMarkerAlignedWithNumber(WidgetTester tester) {
  final inactiveTile = find.ancestor(
    of: find.text('Remote Song 1'),
    matching: find.byType(AdaptiveTrackRow),
  );
  final currentTile = find.ancestor(
    of: find.text('Remote Song 2'),
    matching: find.byType(AdaptiveTrackRow),
  );
  final number = find.descendant(of: inactiveTile, matching: find.text('1'));
  final marker = find.descendant(
    of: currentTile,
    matching: find.byIcon(Icons.graphic_eq_rounded),
  );
  expect(number, findsOneWidget);
  expect(marker, findsOneWidget);
  expect(
    tester.getCenter(marker).dx,
    closeTo(tester.getCenter(number).dx, 0.1),
  );
}

ListenBrainzDiscoverPlaylist _listenBrainzPlaylistWithTableSongs() {
  final songs = <SongsTableData>[
    _songRow(id: 'weekly-song-1', title: 'Weekly Song 1', albumId: 'weekly'),
    _songRow(id: 'weekly-song-2', title: 'Weekly Song 2', albumId: 'weekly'),
    _songRow(id: 'weekly-song-3', title: 'Weekly Song 3', albumId: 'weekly'),
  ];
  return ListenBrainzDiscoverPlaylist(
    playlist: const ListenBrainzPlaylist(
      identifier: 'exploration',
      title: 'Weekly Exploration for alice, week of 2026-06-15',
      sourcePatch: 'weekly-exploration',
      tracks: <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(title: 'Weekly Song 1', creator: 'Artist'),
        ListenBrainzPlaylistTrack(title: 'Weekly Song 2', creator: 'Artist'),
        ListenBrainzPlaylistTrack(title: 'Weekly Song 3', creator: 'Artist'),
      ],
    ),
    recommendations: <ListenBrainzResolvedRecommendation>[
      for (final song in songs)
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(
            title: song.title,
            creator: song.artistName,
          ),
          status: ListenBrainzRecommendationMatchStatus.matched,
          tableSong: song,
          song: Song(id: song.id, title: song.title, artist: song.artistName),
        ),
    ],
  );
}

/// A weekly playlist with an on-server match, a remote-only match, an
/// unmatched track and another on-server match, in that order.
ListenBrainzDiscoverPlaylist _listenBrainzMixedPlaylist() {
  final first = _songRow(
    id: 'weekly-song-1',
    title: 'Weekly Song 1',
    albumId: 'weekly',
  );
  final last = _songRow(
    id: 'weekly-song-3',
    title: 'Weekly Song 3',
    albumId: 'weekly',
  );
  return ListenBrainzDiscoverPlaylist(
    playlist: const ListenBrainzPlaylist(
      identifier: 'exploration',
      title: 'Weekly Exploration for alice, week of 2026-06-15',
      sourcePatch: 'weekly-exploration',
      tracks: <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(title: 'Weekly Song 1', creator: 'Artist'),
        ListenBrainzPlaylistTrack(title: 'Remote Song 2', creator: 'Remote'),
        ListenBrainzPlaylistTrack(title: 'Missing Song', creator: 'Nobody'),
        ListenBrainzPlaylistTrack(title: 'Weekly Song 3', creator: 'Artist'),
      ],
    ),
    recommendations: <ListenBrainzResolvedRecommendation>[
      ListenBrainzResolvedRecommendation(
        track: const ListenBrainzPlaylistTrack(
          title: 'Weekly Song 1',
          creator: 'Artist',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        tableSong: first,
        song: Song(id: first.id, title: first.title, artist: 'Artist'),
      ),
      const ListenBrainzResolvedRecommendation(
        track: ListenBrainzPlaylistTrack(
          title: 'Remote Song 2',
          creator: 'Remote',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        song: Song(
          id: 'ext-deezer-song-2',
          title: 'Remote Song 2',
          artist: 'Remote',
          isExternal: true,
        ),
      ),
      const ListenBrainzResolvedRecommendation(
        track: ListenBrainzPlaylistTrack(
          title: 'Missing Song',
          creator: 'Nobody',
        ),
        status: ListenBrainzRecommendationMatchStatus.unmatched,
      ),
      ListenBrainzResolvedRecommendation(
        track: const ListenBrainzPlaylistTrack(
          title: 'Weekly Song 3',
          creator: 'Artist',
        ),
        status: ListenBrainzRecommendationMatchStatus.matched,
        tableSong: last,
        song: Song(id: last.id, title: last.title, artist: 'Artist'),
      ),
    ],
  );
}

SongsTableData _songRow({
  required String id,
  required String title,
  required String albumId,
  String artist = 'Artist',
  int? discNumber,
  int? track,
}) {
  return SongsTableData(
    isProvisional: false,
    isExternal: false,
    id: id,
    title: title,
    albumId: albumId,
    artistName: artist,
    albumName: 'Album',
    discNumber: discNumber,
    track: track,
    duration: 210,
    coverArt: 'cover-$albumId',
  );
}

AlbumWithSongs _albumWithSongs(
  String albumId,
  String albumName,
  List<SongsTableData> songs,
) {
  return AlbumWithSongs(
    album: AlbumsTableData(
      isProvisional: false,
      isExternal: false,
      id: albumId,
      name: albumName,
      artistName: 'Album Artist',
      coverArt: 'cover-$albumId',
      songsHydrated: true,
      artists: const <ArtistRef>[],
    ),
    songs: songs,
  );
}

/// Trending Now with [count] playable chart songs at positions 1, 3, 5...
/// and an unmatched one ("Missing Song <n>") after each.
HomeRandomShowcaseTrending _trending({int count = 8}) =>
    HomeRandomShowcaseTrending(
      tracks: <ResolvedArtistTopTrack>[
        for (var i = 0; i < count; i++) ...<ResolvedArtistTopTrack>[
          ResolvedArtistTopTrack(
            rank: i * 2 + 1,
            title: 'Chart Song ${i + 1}',
            artist: 'Chart Artist',
            resolvedSong: Song(
              id: 'chart-${i + 1}',
              title: 'Chart Song ${i + 1}',
              artist: 'Chart Artist',
              album: 'Chart Album',
              duration: 200,
              coverArt: 'chart-cover-${i % 4}',
            ),
          ),
          ResolvedArtistTopTrack(
            rank: i * 2 + 2,
            title: 'Missing Song ${i + 1}',
            artist: 'Chart Artist',
          ),
        ],
      ],
    );

/// Hides every default Home section except [visible]: a saved order alone
/// gains the default sections it lacks.
List<String> _hiddenExcept(List<String> visible) => <String>[
  for (final id in HomeSectionIds.defaultOrder)
    if (!visible.contains(id)) id,
];

Future<void> _pumpHomeWithSyncState(
  WidgetTester tester,
  LibrarySyncState syncState,
  NavisDatabase database, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          connectivityProvider.overrideWith((ref) => const Stream.empty()),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
          librarySyncControllerProvider.overrideWith(
            () => _FixedLibrarySyncController(syncState),
          ),
          homeLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
        ],
      ),
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: testTheme(theme),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpHomeWithControllerOverride(
  WidgetTester tester, {
  required LibrarySyncController Function() createController,
  required NavisDatabase database,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          connectivityProvider.overrideWith((ref) => const Stream.empty()),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
          librarySyncControllerProvider.overrideWith(createController),
          homeLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpRandomSectionHome(
  WidgetTester tester, {
  required List<HomeRandomShowcaseItem> randomAlbums,
  required NavisDatabase database,
  List<Override> overrides = const <Override>[],
  bool settle = true,
  bool nativeTouch = false,
  bool forceDesktop = false,
  bool mutableShowcase = false,
  List<SongsTableData> homeLikedSongs = const [],
  List<String> sectionOrder = const [HomeSectionIds.randomAlbums],
  bool reduceMotion = true,
  ValueNotifier<bool>? homeActive,
  ThemeData? baseTheme,
  ValueNotifier<ThemeData?>? themeNotifier,
  double textScale = 1,
}) async {
  final sectionOverrides = withTestDatabase(
    database,
    overrides: <Override>[
      appSettingsProvider.overrideWithValue(
        AsyncData(
          const AppSettingsModel.defaults().copyWith(
            homeSectionOrder: sectionOrder,
            homeSectionsHidden: _hiddenExcept(sectionOrder),
          ),
        ),
      ),
      connectivityProvider.overrideWith((ref) => const Stream.empty()),
      serverConfigStateProvider.overrideWithValue(
        const AsyncData<ServerConfigModel?>(null),
      ),
      librarySyncControllerProvider.overrideWith(
        _StaticLibrarySyncController.new,
      ),
      subsonicApiProvider.overrideWithValue(null),
      listenBrainzDiscoverStreamProvider.overrideWith(
        (ref) => Stream.value(<ListenBrainzDiscoverPlaylist>[
          for (final item in randomAlbums)
            if (item case HomeRandomShowcaseListenBrainz(
              :final ListenBrainzDiscoverPlaylist playlist,
            ))
              playlist,
        ]),
      ),
      homeRandomShowcaseProvider.overrideWith(
        (ref, filters) => AsyncData(
          mutableShowcase ? ref.watch(_showcaseFixture) : randomAlbums,
        ),
      ),
      homeLikedSongsProvider.overrideWithValue(AsyncData(homeLikedSongs)),
      likedSongsProvider.overrideWithValue(const AsyncData(<SongsTableData>[])),
      homeRecentlyAddedProvider.overrideWithValue(const AsyncData(<Album>[])),
      homeRecentlyPlayedAlbumsProvider.overrideWithValue(
        const AsyncData(<AlbumsTableData>[]),
      ),
      homeMostPlayedSongsProvider.overrideWithValue(
        const AsyncData(<SongsTableData>[]),
      ),
      songDownloadStateProvider.overrideWith(
        (ref, songId) => SongDownloadState.none,
      ),
      likedAlbumsRecentProvider.overrideWithValue(
        const AsyncData(<AlbumsTableData>[]),
      ),
      ...overrides,
    ],
  );
  // Weekly playlists open their real route, as in the app.
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => Builder(
          builder: (context) {
            Widget screen = const HomeScreen();
            if (nativeTouch || forceDesktop) {
              screen = AdaptiveContextScope(
                adaptiveContext: resolveAdaptiveContext(
                  desktopRuntime: forceDesktop,
                  viewportSize: MediaQuery.sizeOf(context),
                  safePadding: EdgeInsets.zero,
                ),
                child: screen,
              );
            }
            return homeActive == null
                ? screen
                : ValueListenableBuilder<bool>(
                    valueListenable: homeActive,
                    child: screen,
                    builder: (context, active, child) =>
                        HomeActivityScope(active: active, child: child!),
                  );
          },
        ),
      ),
      GoRoute(
        path: '${AppRoutes.library}/${AppRoutes.listenBrainzSegment}',
        builder: (context, state) => ListenBrainzWeeklyDetailScreen(
          sourcePatch: state.pathParameters['sourcePatch']!,
        ),
      ),
      GoRoute(
        path: AppRoutes.trending,
        builder: (context, state) => const TrendingDetailScreen(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: sectionOverrides,
      child: ValueListenableBuilder<ThemeData?>(
        valueListenable: themeNotifier ?? ValueNotifier(baseTheme),
        builder: (context, theme, _) => MaterialApp.router(
          theme: testTheme(theme),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pumpWeeklyDetail(
  WidgetTester tester, {
  required Stream<List<ListenBrainzDiscoverPlaylist>> playlists,
  String sourcePatch = 'weekly-jams',
  NavisDatabase? database,
  ThemeData? theme,
  List<Override> overrides = const <Override>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey<Stream<List<ListenBrainzDiscoverPlaylist>>>(playlists),
      overrides: database == null
          ? <Override>[
              ...overrides,
              listenBrainzDiscoverStreamProvider.overrideWith(
                (ref) => playlists,
              ),
              // The playlist artwork reads the cover shape setting.
              appSettingsProvider.overrideWithValue(
                const AsyncData(AppSettingsModel.defaults()),
              ),
            ]
          : withTestDatabase(
              database,
              overrides: <Override>[
                listenBrainzDiscoverStreamProvider.overrideWith(
                  (ref) => playlists,
                ),
              ],
            ),
      child: MaterialApp(
        theme: theme ?? testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ListenBrainzWeeklyDetailScreen(
          key: ValueKey<Stream<List<ListenBrainzDiscoverPlaylist>>>(playlists),
          sourcePatch: sourcePatch,
        ),
      ),
    ),
  );
}

Future<void> _pumpHomeWithAppSettings(
  WidgetTester tester, {
  required NavisDatabase database,
  AppSettingsModel appSettings = const AppSettingsModel.defaults(),
  List<SongsTableData> homeLikedSongs = const <SongsTableData>[],
  List<SongsTableData> likedSongs = const <SongsTableData>[],
  List<SongsTableData> mostPlayedSongs = const <SongsTableData>[],
  List<SongsTableData> recentlyPlayedSongs = const <SongsTableData>[],
  List<Override> overrides = const <Override>[],
  TextScaler? textScaler,
  AppNoticeController? notices,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          appSettingsProvider.overrideWithValue(AsyncData(appSettings)),
          connectivityProvider.overrideWith((ref) => const Stream.empty()),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(null),
          ),
          subsonicApiProvider.overrideWithValue(null),
          librarySyncControllerProvider.overrideWith(
            _StaticLibrarySyncController.new,
          ),
          homeLikedSongsProvider.overrideWithValue(AsyncData(homeLikedSongs)),
          likedSongsProvider.overrideWithValue(AsyncData(likedSongs)),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          downloadedContentIdsProvider.overrideWithValue(
            const AsyncData((albumIds: <String>{}, artistIds: <String>{})),
          ),
          homeRecentlyAddedProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeDownloadedRecentlyAddedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeDownloadedRecentlyPlayedAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<Album>[]),
          ),
          homeDownloadedRandomAlbumsProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          homeRandomShowcaseProvider.overrideWith(
            (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
          ),
          homeMostPlayedSongsProvider.overrideWithValue(
            AsyncData(mostPlayedSongs),
          ),
          homeDownloadedLikedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeDownloadedMostPlayedSongsProvider.overrideWithValue(
            const AsyncData(<SongsTableData>[]),
          ),
          homeRecentlyPlayedProvider.overrideWithValue(
            AsyncData(recentlyPlayedSongs),
          ),
          likedAlbumsRecentProvider.overrideWithValue(
            const AsyncData(<AlbumsTableData>[]),
          ),
          ...overrides,
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(disableAnimations: true, textScaler: textScaler),
          child: notices == null
              ? child!
              : AppNoticeScope(notifier: notices, child: child!),
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _testWidgetsWithCleanup(
  String description,
  WidgetTesterCallback callback,
) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpAndSettle();
    }
  });
}

void main() {
  late NavisDatabase database;

  setUpAll(() {
    database = createTestDatabase();
  });

  tearDownAll(() async {
    await database.close();
  });

  group('weekly detail phone header', () {
    const appBarKey = ValueKey<String>('albumDetailMobileExpandedArtAppBar');
    const playlist = ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams for alice',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[
          ListenBrainzPlaylistTrack(title: 'Header track'),
        ],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(title: 'Header track'),
          status: ListenBrainzRecommendationMatchStatus.pending,
        ),
      ],
    );

    Future<void> pump(WidgetTester tester, ThemeData theme) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await _pumpWeeklyDetail(
        tester,
        playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.value(
          const <ListenBrainzDiscoverPlaylist>[playlist],
        ),
        theme: theme,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
    }

    Finder inAppBar(Finder finder) =>
        find.descendant(of: find.byKey(appBarKey), matching: finder);
    final title = find.text('Weekly Jams');
    final gradient = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient != null,
    );

    testWidgets('overlays the title on a fade by default', (tester) async {
      await pump(tester, buildDarkTheme(Colors.teal));

      // The collapsed toolbar title and the overlay.
      expect(inAppBar(title), findsNWidgets(2));
      expect(inAppBar(gradient), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the art clear under Flat text over artwork', (
      tester,
    ) async {
      await pump(tester, buildDarkTheme(Colors.teal, flat: true));

      // Only the collapsed toolbar title stays in the app bar.
      expect(inAppBar(title), findsOneWidget);
      expect(inAppBar(gradient), findsNothing);
      expect(title, findsNWidgets(2));
      // The expanded art is as tall as the 390 px wide screen.
      expect(tester.getTopLeft(title.last).dy, greaterThanOrEqualTo(390));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('weekly detail uses a track skeleton while loading', (
    tester,
  ) async {
    final controller = StreamController<List<ListenBrainzDiscoverPlaylist>>();
    addTearDown(controller.close);

    await _pumpWeeklyDetail(tester, playlists: controller.stream);
    await tester.pump();

    expect(find.text('Weekly Jams'), findsOneWidget);
    expect(find.byType(ShimmerListTile), findsNWidgets(8));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('weekly detail gives empty and failed states a safe recovery', (
    tester,
  ) async {
    await _pumpWeeklyDetail(
      tester,
      playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.value(
        const <ListenBrainzDiscoverPlaylist>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No Weekly Playlist Available'), findsOneWidget);
    expect(find.text('Refresh to check for a new playlist.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    await _pumpWeeklyDetail(
      tester,
      playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.error(
        StateError('private implementation detail'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could Not Load Weekly Playlist'), findsOneWidget);
    expect(find.text('Check your connection and try again.'), findsOneWidget);
    expect(find.textContaining('private implementation detail'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
  });

  testWidgets('weekly unavailable-track states use localized recovery copy', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1366, 900));
    const playlist = ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams for alice',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[
          ListenBrainzPlaylistTrack(title: 'Pending track'),
          ListenBrainzPlaylistTrack(title: 'Ambiguous track'),
          ListenBrainzPlaylistTrack(title: 'Unavailable track'),
        ],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(title: 'Pending track'),
          status: ListenBrainzRecommendationMatchStatus.pending,
        ),
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(title: 'Ambiguous track'),
          status: ListenBrainzRecommendationMatchStatus.ambiguous,
        ),
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(title: 'Unavailable track'),
          status: ListenBrainzRecommendationMatchStatus.unmatched,
        ),
      ],
    );

    await _pumpWeeklyDetail(
      tester,
      playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.value(
        const <ListenBrainzDiscoverPlaylist>[playlist],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('Matching'), findsOneWidget);
    // Short labels on the title line; full wording in their tooltips.
    expect(find.text('Unclear Match'), findsOneWidget);
    expect(find.text('Not on Server'), findsOneWidget);
    // These tooltips exclude themselves from semantics, and find.byTooltip
    // reads such messages only from package:flutter's Tooltip type.
    Finder statusTooltip(String message) => find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == message,
    );
    expect(statusTooltip('Ambiguous Match'), findsOneWidget);
    expect(statusTooltip('Not available on your server'), findsOneWidget);
    expect(find.byTooltip('Matching'), findsOneWidget);
    expect(find.byTooltip('Search'), findsNWidgets(2));
  });

  testWidgets('weekly detail labels the Match action while a rematch runs', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 900));
    const playlist = ListenBrainzDiscoverPlaylist(
      playlist: ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams for alice',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[
          ListenBrainzPlaylistTrack(title: 'Unavailable track'),
        ],
      ),
      recommendations: <ListenBrainzResolvedRecommendation>[
        ListenBrainzResolvedRecommendation(
          track: ListenBrainzPlaylistTrack(title: 'Unavailable track'),
          status: ListenBrainzRecommendationMatchStatus.unmatched,
        ),
      ],
    );

    await _pumpWeeklyDetail(
      tester,
      playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.value(
        const <ListenBrainzDiscoverPlaylist>[playlist],
      ),
      overrides: <Override>[
        listenBrainzPlaylistRematchControllerProvider.overrideWith(
          _MatchingRematchController.new,
        ),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final matching = find.text('Matching');
    expect(matching, findsOneWidget);
    expect(find.text('Match'), findsNothing);
  });

  group('update tile', () {
    const update = UpdateInfo(
      sha256: null,
      size: null,
      tagName: 'v9.9.9',
      htmlUrl: 'https://example.com/release',
      delivery: UpdateDelivery.storeRedirect,
    );
    final tile = find.byKey(const ValueKey<String>('updateTileOpen'));
    late _DismissUpdateStore dismissStore;
    setUp(() => dismissStore = _DismissUpdateStore());

    Future<void> pumpWith(
      WidgetTester tester,
      AppSettingsModel settings, {
      UpdateInfo info = update,
      UpdateInfo Function()? currentUpdate,
    }) {
      return _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: settings,
        // The tile's own gate is under test, not the provider's.
        overrides: <Override>[
          updateCheckStoreProvider.overrideWithValue(dismissStore),
          updateProvider.overrideWith((ref) async {
            return currentUpdate?.call() ?? info;
          }),
        ],
      );
    }

    testWidgets('shows the version title, disc and tonal action', (
      tester,
    ) async {
      await pumpWith(tester, const AppSettingsModel.defaults());
      expect(tile, findsOneWidget);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.text('Navis v9.9.9 Is Ready'), findsOneWidget);
      expect(find.text('Update on Google Play'), findsOneWidget);
      expect(find.byIcon(Icons.system_update_outlined), findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(NoticeIconDisc)),
        findsOneWidget,
      );
      expect(find.text('Open in Play Store'), findsOneWidget);
      expect(find.text('Release Notes'), findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(FilledButton)),
        findsOneWidget,
      );
    });

    final labels = <String, (UpdateInfo, String, String)>{
      'self-update installs in the app': (
        const UpdateInfo(
          sha256: null,
          size: null,
          tagName: 'v1.5.0-dev.7',
          htmlUrl: 'https://example.com/release',
          delivery: UpdateDelivery.selfUpdate,
          downloadUrl: 'https://example.com/app.apk',
        ),
        'Install',
        'Installs in a minute.',
      ),
      'desktop with an asset installs': (
        const UpdateInfo(
          sha256: null,
          size: null,
          tagName: 'v1.5.0',
          htmlUrl: 'https://example.com/release',
          delivery: UpdateDelivery.desktopSelfUpdate,
          downloadUrl: 'https://example.com/app.zip',
        ),
        'Install',
        'Installs in a minute.',
      ),
      'desktop without an asset downloads': (
        const UpdateInfo(
          sha256: null,
          size: null,
          tagName: 'v1.5.0',
          htmlUrl: 'https://example.com/release',
          delivery: UpdateDelivery.desktopSelfUpdate,
        ),
        'Download',
        'Opens the download page.',
      ),
    };
    for (final entry in labels.entries) {
      testWidgets(entry.key, (tester) async {
        final (info, action, body) = entry.value;
        await pumpWith(tester, const AppSettingsModel.defaults(), info: info);
        expect(find.text('Navis ${info.tagName} Is Ready'), findsOneWidget);
        expect(find.text(body), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey<String>('updateTileAction')),
            matching: find.text(action),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets(
      'dismiss hides the current update and a newer build shows again',
      (tester) async {
        var current = update;
        await pumpWith(
          tester,
          const AppSettingsModel.defaults(),
          currentUpdate: () => current,
        );
        final container = ProviderScope.containerOf(tester.element(tile));
        await tester.tap(
          find.byKey(const ValueKey<String>('updateTileDismiss')),
        );
        await tester.pumpAndSettle();
        expect(tile, findsNothing);
        expect(await container.read(updateProvider.future), same(update));
        container.invalidate(updateProvider);
        await tester.pumpAndSettle();
        expect(tile, findsNothing);
        current = const UpdateInfo(
          tagName: 'v9.9.9',
          buildNumber: 2,
          htmlUrl: 'https://example.com/release',
          delivery: UpdateDelivery.storeRedirect,
          sha256: null,
          size: null,
        );
        container.invalidate(updateProvider);
        await tester.pumpAndSettle();
        expect(tile, findsOneWidget);
      },
    );

    for (final entry in <String, AppSettingsModel>{
      'automatic checks are off': const AppSettingsModel.defaults().copyWith(
        updateCheckEnabled: false,
      ),
      'the update service is off': const AppSettingsModel.defaults().copyWith(
        disabledIntegrations: '["updates"]',
      ),
      'the master switch is off': const AppSettingsModel.defaults().copyWith(
        externalIntegrationsEnabled: false,
      ),
    }.entries) {
      testWidgets('hides the tile when ${entry.key}', (tester) async {
        await pumpWith(tester, entry.value);
        expect(tile, findsNothing);
      });
    }
  });

  testWidgets('home does not show retired Listen Together entry point', (
    tester,
  ) async {
    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      appSettings: const AppSettingsModel.defaults(),
    );

    expect(find.text('Listen Together'), findsNothing);
    expect(find.textContaining('Voyage'), findsNothing);
  });

  testWidgets('major release notes stay in context on Home', (tester) async {
    final view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      overrides: <Override>[
        changelogToShowProvider.overrideWith(
          (ref) async => const ChangelogDiscovery(
            current: _majorRelease,
            featured: _majorRelease,
          ),
        ),
      ],
    );

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsOneWidget,
    );
    expect(find.text('Meet Navis 9.9 “Aurora”'), findsOneWidget);
    // One plain line names the highlights instead of a row of chips.
    expect(
      find.text('Equalizer, Speed and pitch, AutoEQ and 1 more'),
      findsOneWidget,
    );
    expect(find.text('+1'), findsNothing);
    // The card carries badges only, never the release's description.
    expect(find.text(_majorRelease.entries.first.text), findsNothing);
    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_changelog_discovery_card.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('changelogDiscoveryDismiss')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsNothing,
    );
  });

  testWidgets('the 1.5.0 Integrations notice takes the release notes row', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
    final changelog = changelogToShowProvider.overrideWith(
      (ref) async => const ChangelogDiscovery(
        current: _majorRelease,
        featured: _majorRelease,
      ),
    );

    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      overrides: <Override>[
        changelog,
        onboardingRequiredProvider.overrideWithValue(false),
      ],
    );
    expect(
      find.byKey(const ValueKey<String>('integrationsNoticeOpen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsNothing,
    );
    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_integrations_notice_card.png'),
    );

    // Seen, or before setup is complete: the release notes row is back.
    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      overrides: <Override>[
        changelog,
        onboardingRequiredProvider.overrideWithValue(true),
      ],
    );
    expect(
      find.byKey(const ValueKey<String>('integrationsNoticeOpen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsOneWidget,
    );
    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      appSettings: const AppSettingsModel.defaults().copyWith(
        integrationsNoticeDismissed: true,
      ),
      overrides: <Override>[
        changelog,
        onboardingRequiredProvider.overrideWithValue(false),
      ],
    );
    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsOneWidget,
    );
  });

  testWidgets(
    'the Integrations notice comes first, then the setup invitation, then the release notes',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });
      final changelog = changelogToShowProvider.overrideWith(
        (ref) async => const ChangelogDiscovery(
          current: _majorRelease,
          featured: _majorRelease,
        ),
      );
      final info = packageInfoProvider.overrideWith(
        (ref) async => PackageInfo(
          appName: 'Navis',
          packageName: 'test.navis',
          version: '1.5.0',
          buildNumber: '10500',
        ),
      );
      final setup = find.byKey(const ValueKey<String>('setupHighlightsOpen'));
      final integrations = find.byKey(
        const ValueKey<String>('integrationsNoticeOpen'),
      );
      final whatsNew = find.byKey(
        const ValueKey<String>('changelogDiscoveryOpen'),
      );

      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        overrides: <Override>[
          changelog,
          info,
          onboardingRequiredProvider.overrideWithValue(false),
        ],
      );
      expect(integrations, findsOneWidget);
      expect(setup, findsNothing);
      expect(whatsNew, findsNothing);

      // The Integrations notice seen: the setup invitation follows.
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: const AppSettingsModel.defaults().copyWith(
          integrationsNoticeDismissed: true,
        ),
        overrides: <Override>[
          changelog,
          info,
          onboardingRequiredProvider.overrideWithValue(false),
        ],
      );
      expect(integrations, findsNothing);
      expect(setup, findsOneWidget);
      expect(whatsNew, findsNothing);
      expect(find.text('New Appearance Options'), findsOneWidget);

      // Setup invitation dismissed or acknowledged: What's New returns.
      for (final settings in <AppSettingsModel>[
        const AppSettingsModel.defaults().copyWith(
          integrationsNoticeDismissed: true,
          setupCardDismissedRelease: '1.5.0',
        ),
        const AppSettingsModel.defaults().copyWith(
          integrationsNoticeDismissed: true,
          setupHighlightsSeenRelease: '1.5.0',
        ),
      ]) {
        await _pumpHomeWithAppSettings(
          tester,
          database: database,
          appSettings: settings,
          overrides: <Override>[
            changelog,
            info,
            onboardingRequiredProvider.overrideWithValue(false),
          ],
        );
        expect(setup, findsNothing);
        expect(integrations, findsNothing);
        expect(whatsNew, findsOneWidget);
      }

      // Integrations still unread with the setup invitation dismissed.
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: const AppSettingsModel.defaults().copyWith(
          setupHighlightsSeenRelease: '1.5.0',
        ),
        overrides: <Override>[
          changelog,
          info,
          onboardingRequiredProvider.overrideWithValue(false),
        ],
      );
      expect(setup, findsNothing);
      expect(integrations, findsOneWidget);
      expect(whatsNew, findsNothing);

      // Everything seen: the release notes row returns.
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: const AppSettingsModel.defaults().copyWith(
          setupHighlightsSeenRelease: '1.5.0',
          integrationsNoticeDismissed: true,
        ),
        overrides: <Override>[
          changelog,
          info,
          onboardingRequiredProvider.overrideWithValue(false),
        ],
      );
      expect(setup, findsNothing);
      expect(integrations, findsNothing);
      expect(whatsNew, findsOneWidget);
    },
  );

  testWidgets('patch release notes show a compact row on Home', (tester) async {
    const patch = ChangelogVersion(
      version: '9.9.1',
      entries: <ChangelogEntry>[
        ChangelogEntry('Fixed one thing', type: ChangelogEntryType.fix),
        ChangelogEntry('Fixed another thing', type: ChangelogEntryType.fix),
        ChangelogEntry('Improved a third thing'),
      ],
    );
    final view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      overrides: <Override>[
        changelogToShowProvider.overrideWith(
          (ref) async => const ChangelogDiscovery(current: patch),
        ),
      ],
    );

    expect(find.text('Updated to Navis 9.9.1'), findsOneWidget);
    expect(find.text('3 changes'), findsOneWidget);
    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_changelog_discovery_patch_card.png'),
    );
  });

  testWidgets('release-note discovery stays usable at 200 percent text scale', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      textScaler: const TextScaler.linear(2),
      overrides: <Override>[
        changelogToShowProvider.overrideWith(
          (ref) async => const ChangelogDiscovery(
            current: _majorRelease,
            featured: _majorRelease,
          ),
        ),
      ],
    );

    expect(
      find.byKey(const ValueKey<String>('changelogDiscoveryOpen')),
      findsOneWidget,
    );
    expect(find.byTooltip('Dismiss Update Notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home cards avoid RenderFlex overflow on constrained layouts', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(360, 640);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData<ServerConfigModel?>(null),
            ),
            subsonicApiProvider.overrideWithValue(null),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'song-1',
                  title:
                      'A very long song title that should ellipsize correctly',
                  artistName: 'An artist with a very long display name for overflow testing',
                  coverArt: 'cover-song-1',
                ),
              ]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            homeRecentlyAddedProvider.overrideWithValue(
              const AsyncData(<Album>[
                Album(
                  id: 'album-1',
                  name: 'A very long album title that should not overflow the card',
                  artist: 'An artist with a very long display name for overflow testing',
                  coverArt: 'cover-album-1',
                ),
              ]),
            ),
            homeRecentlyPlayedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[
                AlbumsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'album-2',
                  name: 'Another very long album title for recent section',
                  artistName: 'Overflow Tester',
                  coverArt: 'cover-album-2',
                  songsHydrated: false,
                  artists: <ArtistRef>[],
                ),
              ]),
            ),
            homeRandomAlbumsProvider.overrideWithValue(
              const AsyncData(<Album>[
                Album(
                  id: 'album-3',
                  name: 'Random long album title for constrained card layout',
                  artist: 'Overflow Tester',
                  coverArt: 'cover-album-3',
                ),
              ]),
            ),
            homeRandomShowcaseProvider.overrideWith(
              (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[
                HomeRandomShowcaseAlbum(
                  id: 'album-3',
                  name: 'Random long album title for constrained card layout',
                  artist: 'Overflow Tester',
                  coverArtId: 'cover-album-3',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
              ]),
            ),
            homeMostPlayedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'song-2',
                  title: 'A very long most-played song title to stress layout',
                  artistName: 'Overflow Tester',
                  coverArt: 'cover-song-2',
                ),
              ]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[
                AlbumsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'album-4',
                  name: 'Liked album title',
                  artistName: 'Favorite Artist',
                  coverArt: 'cover-album-4',
                  songsHydrated: false,
                  artists: <ArtistRef>[],
                ),
              ]),
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true,
              ),
              child: child!,
            );
          },
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -640));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home renders tablet layout without overflow', (tester) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData<ServerConfigModel?>(null),
            ),
            subsonicApiProvider.overrideWithValue(null),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            homeRecentlyAddedProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRecentlyPlayedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            homeRandomAlbumsProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRandomShowcaseProvider.overrideWith(
              (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
            ),
            homeMostPlayedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home applies desktop framing only at desktop-wide width boundaries',
    (tester) async {
      const desktopBrandRow = ValueKey<String>('homeDesktopBrandRow');
      setAdaptiveTestViewport(tester, const Size(599, 1000));
      await _pumpHomeWithSyncState(
        tester,
        const LibrarySyncState.idle(),
        database,
      );

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(desktopBrandRow), findsNothing);
      expect(tester.takeException(), isNull);

      final transitions = <({Size size, bool desktopHeader})>[
        (size: const Size(700, 1000), desktopHeader: false),
        (size: const Size(840, 1000), desktopHeader: false),
        (size: const Size(1200, 1000), desktopHeader: true),
        (size: const Size(900, 420), desktopHeader: false),
      ];

      for (final step in transitions) {
        tester.view.physicalSize = step.size;
        await tester.pumpAndSettle();
        expect(
          find.byKey(desktopBrandRow),
          step.desktopHeader ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('home switches header treatment by adaptive mode', (
    tester,
  ) async {
    const desktopBrandRow = ValueKey<String>('homeDesktopBrandRow');
    const compactWideHeaderRow = ValueKey<String>('homeCompactWideHeaderRow');
    const centeredLogoHeader = ValueKey<String>('homeCenteredLogoHeader');
    const mobileActionRow = ValueKey<String>('homeMobileActionRow');

    setAdaptiveTestViewport(tester, const Size(1000, 420));
    await _pumpHomeWithAppSettings(tester, database: database);

    expect(find.byKey(compactWideHeaderRow), findsOneWidget);
    expect(find.byKey(centeredLogoHeader), findsNothing);
    expect(find.byKey(mobileActionRow), findsNothing);
    expect(find.byKey(desktopBrandRow), findsNothing);

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();

    expect(find.byKey(desktopBrandRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);
    expect(find.byKey(centeredLogoHeader), findsNothing);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    expect(find.byKey(centeredLogoHeader), findsOneWidget);
    expect(find.byKey(mobileActionRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);

    tester.view.physicalSize = const Size(700, 1000);
    await tester.pumpAndSettle();

    expect(find.byKey(centeredLogoHeader), findsOneWidget);
    expect(find.byKey(mobileActionRow), findsOneWidget);
    expect(find.byKey(compactWideHeaderRow), findsNothing);
  });

  for (final entry in <RecommendationIssue, String>{
    RecommendationIssue.invalidKey:
        'Last.fm rejected the API key. Update it in Settings and retry.',
    RecommendationIssue.rateLimited:
        'Last.fm is limiting requests. Try again later.',
  }.entries) {
    testWidgets(
      'radio that started but could not use Last.fm says ${entry.key.name}',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(1000, 420));
        final radioDatabase = createTestDatabase();
        addTearDown(radioDatabase.close);
        await radioDatabase.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'One'),
        ]);
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        await _pumpHomeWithAppSettings(
          tester,
          database: radioDatabase,
          notices: notices,
          overrides: <Override>[
            personalRadioProvider.overrideWith(
              () => _LastFmIssueRadio(entry.key),
            ),
          ],
        );
        await tester.pump(const Duration(milliseconds: 200));

        await tester.tap(find.byIcon(Icons.radio_rounded));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(notices.notice?.message, entry.value);
        expect(notices.notice?.level, AppNoticeLevel.info);
        notices.dismiss();
      },
    );
  }

  testWidgets('compact-wide home actions toggle filters and disable radio', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1000, 420));
    await _pumpHomeWithAppSettings(tester, database: database);

    expect(
      find.byKey(const ValueKey<String>('homeCompactWideActionRow')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);

    final radioButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.radio_rounded),
    );
    expect(radioButton.onPressed, isNull);

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
  });

  testWidgets(
    'compact-wide song sections use two columns only above the width threshold',
    (tester) async {
      final songs = List<SongsTableData>.generate(
        6,
        (index) => _songRow(
          id: 'liked-${index + 1}',
          title: 'Liked Song ${index + 1}',
          albumId: 'liked-album',
        ),
      );
      final settings = const AppSettingsModel.defaults().copyWith(
        homeSectionOrder: <String>[HomeSectionIds.likedTracks],
        homeSectionsHidden: _hiddenExcept(<String>[HomeSectionIds.likedTracks]),
      );

      setAdaptiveTestViewport(tester, const Size(1000, 420));
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: settings,
        homeLikedSongs: songs,
        likedSongs: songs,
      );

      expect(
        find.byKey(const ValueKey<String>('homeSongListTwoColumnGrid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('homeSongListSingleColumn')),
        findsNothing,
      );

      tester.view.physicalSize = const Size(840, 420);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('homeSongListTwoColumnGrid')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('homeSongListSingleColumn')),
        findsOneWidget,
      );
    },
  );

  _testWidgetsWithCleanup(
    'desktop Home song rows use actions instead of navigation arrows',
    (tester) async {
      final settings = const AppSettingsModel.defaults().copyWith(
        homeSectionOrder: <String>[HomeSectionIds.likedTracks],
        homeSectionsHidden: _hiddenExcept(<String>[HomeSectionIds.likedTracks]),
      );
      final song = _songRow(
        id: 'desktop-home-song',
        title: 'Desktop Home Song',
        albumId: 'desktop-home-album',
      );
      setAdaptiveTestViewport(tester, const Size(1200, 900));
      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: settings,
        homeLikedSongs: <SongsTableData>[song],
        likedSongs: <SongsTableData>[song],
        overrides: <Override>[
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
      );

      expect(
        find.byKey(const ValueKey<String>('home-song-heart-desktop-home-song')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('home-song-menu-desktop-home-song')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    },
  );

  testWidgets(
    'liked track tap queues the full deduplicated liked playback list',
    (tester) async {
      final directSongs = <SongsTableData>[
        _songRow(id: 'liked-direct', title: 'Direct song', albumId: 'liked'),
        _songRow(id: 'liked-shared', title: 'Shared song', albumId: 'liked'),
      ];
      final settings = const AppSettingsModel.defaults().copyWith(
        homeSectionOrder: <String>[HomeSectionIds.likedTracks],
        homeSectionsHidden: _hiddenExcept(<String>[HomeSectionIds.likedTracks]),
      );

      await _pumpHomeWithAppSettings(
        tester,
        database: database,
        appSettings: settings,
        homeLikedSongs: directSongs,
        likedSongs: directSongs,
        overrides: <Override>[
          albumQueueEnabledProvider.overrideWithValue(true),
          likedQueueEnabledProvider.overrideWithValue(true),
          queueProvider.overrideWith(_QueueSpyController.new),
          likedAlbumSongsProvider.overrideWithValue(
            AsyncData(<SongsTableData>[
              _songRow(
                id: 'liked-shared',
                title: 'Shared song',
                albumId: 'liked',
              ),
              _songRow(
                id: 'liked-album-only',
                title: 'Album-only song',
                albumId: 'liked',
              ),
            ]),
          ),
        ],
      );

      await tester.tap(find.text('Shared song'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      );
      final queueSpy =
          container.read(queueProvider.notifier) as _QueueSpyController;
      expect(queueSpy.lastReplaceIds, <String>[
        'liked-direct',
        'liked-shared',
        'liked-album-only',
      ]);
      expect(queueSpy.lastStartIndex, 1);
      expect(queueSpy.lastAutoPlay, isTrue);
    },
  );

  testWidgets('Random Albums section renders its title and albums', (
    tester,
  ) async {
    final settings = const AppSettingsModel.defaults().copyWith(
      homeSectionOrder: <String>[HomeSectionIds.randomAlbumList],
      homeSectionsHidden: _hiddenExcept(<String>[
        HomeSectionIds.randomAlbumList,
      ]),
    );
    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      appSettings: settings,
      overrides: <Override>[
        homeRandomAlbumListProvider.overrideWithValue(
          const AsyncData(<Album>[Album(id: 'r1', name: 'Rolled Album')]),
        ),
      ],
    );

    expect(find.text('Random Albums'), findsOneWidget);
    expect(find.text('Rolled Album'), findsOneWidget);
  });

  for (final albumQueue in <bool>[true, false]) {
    for (final sectionId in <String>[
      HomeSectionIds.mostPlayed,
      HomeSectionIds.recentlyPlayedTracks,
    ]) {
      testWidgets(
        '$sectionId row tap ${albumQueue ? 'queues the list from it' : 'plays only it'} '
        'with Album Queue ${albumQueue ? 'on' : 'off'}',
        (tester) async {
          final songs = <SongsTableData>[
            _songRow(id: 'row-1', title: 'Row one', albumId: 'rows'),
            _songRow(id: 'row-2', title: 'Row two', albumId: 'rows'),
            _songRow(id: 'row-3', title: 'Row three', albumId: 'rows'),
          ];
          final settings = const AppSettingsModel.defaults().copyWith(
            homeSectionOrder: <String>[sectionId],
            homeSectionsHidden: _hiddenExcept(<String>[sectionId]),
          );

          await _pumpHomeWithAppSettings(
            tester,
            database: database,
            appSettings: settings,
            mostPlayedSongs: songs,
            recentlyPlayedSongs: songs,
            overrides: <Override>[
              albumQueueEnabledProvider.overrideWithValue(albumQueue),
              queueProvider.overrideWith(QueueReplaceSpy.new),
            ],
          );

          await tester.tap(find.text('Row two'));
          await tester.pumpAndSettle();

          final queueSpy = ProviderScope.containerOf(
            tester.element(find.byType(HomeScreen, skipOffstage: false)),
          ).read(queueProvider.notifier) as QueueReplaceSpy;
          expect(
            queueSpy.lastReplaceIds,
            albumQueue
                ? <String>['row-1', 'row-2', 'row-3']
                : <String>['row-2'],
          );
          expect(queueSpy.lastStartIndex, albumQueue ? 1 : 0);
        },
      );
    }
  }

  testWidgets(
    'default home shows default-on sections and keeps optional sections hidden',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              appSettingsProvider.overrideWithValue(
                const AsyncData(AppSettingsModel.defaults()),
              ),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
              librarySyncControllerProvider.overrideWith(
                _StaticLibrarySyncController.new,
              ),
              homeLikedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              homeRecentlyAddedProvider.overrideWithValue(
                const AsyncData(<Album>[]),
              ),
              homeRecentlyPlayedAlbumsProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
              homeRandomAlbumsProvider.overrideWithValue(
                const AsyncData(<Album>[]),
              ),
              homeRandomShowcaseProvider.overrideWith(
                (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
              ),
              homeMostPlayedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedAlbumsRecentProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
            ],
          ),
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const HomeScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Quick Actions are now always-visible icon toggles + Instant Radio button
      // below the logo, not a section.
      expect(find.text('Quick actions'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget); // Instant Radio
      // Instant Radio is a tonal button and the Liked toggle is outlined off,
      // tonal on, so on reads stronger than off.
      final data = NavisColorStyleData.of(
        tester.element(find.byType(FilledButton)),
      );
      final scheme = Theme.of(tester.element(find.byType(FilledButton)))
          .colorScheme;
      expect(
        tester
            .widget<FilledButton>(find.byType(FilledButton))
            .style!
            .backgroundColor!
            .resolve(<WidgetState>{}),
        data.tonalControlFill(scheme),
      );
      final liked = tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.favorite_border_rounded),
          )
          .style!;
      expect(
        liked.backgroundColor!.resolve(<WidgetState>{WidgetState.selected}),
        data.tonalControlFill(scheme),
      );
      expect(
        liked.backgroundColor!.resolve(<WidgetState>{}),
        Colors.transparent,
      );
      await tester.scrollUntilVisible(
        find.text('Recently Liked Albums'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Recently Liked Albums'), findsOneWidget);
      expect(find.text('Recently Played Tracks'), findsNothing);
    },
  );

  testWidgets(
    'random hero carousel does not auto-advance with reduced motion',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await _pumpRandomSectionHome(
        tester,
        database: database,
        nativeTouch: true,
        overrides: [
          homeRecommendationsAutoAdvanceProvider.overrideWithValue(true),
        ],
        randomAlbums: const <HomeRandomShowcaseItem>[
          HomeRandomShowcaseAlbum(
            id: 'reduced-hero-1',
            name: 'Hero One',
            artist: 'Artist One',
            coverArtId: 'cover-reduced-hero-1',
            source: HomeRandomShowcaseSource.serverRandom,
          ),
          HomeRandomShowcaseAlbum(
            id: 'reduced-hero-2',
            name: 'Hero Two',
            artist: 'Artist Two',
            coverArtId: 'cover-reduced-hero-2',
            source: HomeRandomShowcaseSource.serverRandom,
          ),
        ],
      );

      Finder pageKeyFinder() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('home-random-hero-carousel-page-');
      });
      String currentPageKey() {
        final key = tester.widget(pageKeyFinder()).key! as ValueKey<String>;
        return key.value;
      }

      final initialPage = currentPageKey();
      await tester.pump(const Duration(milliseconds: 20000));
      await tester.pump(const Duration(milliseconds: 600));
      expect(currentPageKey(), initialPage);
    },
  );

  testWidgets(
    'You Might Like keeps one page controller while the width keeps changing',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await _pumpRandomSectionHome(
        tester,
        database: database,
        nativeTouch: true,
        randomAlbums: <HomeRandomShowcaseItem>[
          for (var i = 0; i < 3; i++)
            HomeRandomShowcaseAlbum(
              id: 'resize-$i',
              name: 'Resize $i',
              artist: 'Artist $i',
              coverArtId: 'cover-resize-$i',
              source: HomeRandomShowcaseSource.serverRandom,
            ),
        ],
      );

      final carousel = find.byKey(
        const ValueKey<String>('home-random-hero-carousel'),
      );
      PageController controller() =>
          tester.widget<PageView>(carousel).controller!;
      final initial = controller();

      // A continuous resize, one width per frame, keeps the controller.
      for (var width = 390.0; width <= 560; width += 10) {
        view.physicalSize = Size(width, 844);
        await tester.pump(const Duration(milliseconds: 16));
        expect(identical(controller(), initial), isTrue);
      }

      // Once the width settles, the peek is corrected with a single swap.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      final settled = controller();
      expect(identical(settled, initial), isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      expect(identical(controller(), settled), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'You Might Like shows square covers with details and Play below',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await _pumpRandomSectionHome(
        tester,
        database: database,
        nativeTouch: true,
        randomAlbums: <HomeRandomShowcaseItem>[
          const HomeRandomShowcaseAlbum(
            id: 'flow-1',
            name: 'Flow One',
            artist: 'Artist One',
            coverArtId: 'cover-flow-1',
            year: 2023,
            songCount: 12,
            source: HomeRandomShowcaseSource.likedDiscovery,
          ),
          const HomeRandomShowcaseAlbum(
            id: 'flow-2',
            name: 'Flow Two',
            artist: 'Artist Two',
            coverArtId: 'cover-flow-2',
            source: HomeRandomShowcaseSource.serverRandom,
          ),
          HomeRandomShowcaseListenBrainz.loading(
            sourcePatch: 'weekly-jams',
            displayTitle: 'Weekly Jams',
          ),
        ],
      );

      final carousel = find.byKey(
        const ValueKey<String>('home-random-hero-carousel'),
      );
      final cover = find
          .descendant(of: carousel, matching: find.byType(HeroCoverArt))
          .first;
      final coverSize = tester.getSize(cover);
      expect(coverSize.width, coverSize.height);

      final info = find.byKey(const ValueKey<String>('home-showcase-info'));
      expect(
        find.descendant(of: info, matching: find.text('Flow One')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: info, matching: find.text('Artist One')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: info,
          matching: find.text('2023 • 12 songs · Similar to your likes'),
        ),
        findsOneWidget,
      );
      final play = find.byKey(const ValueKey<String>('home-showcase-play'));
      expect(play, findsOneWidget);
      expect(tester.widget<IconButton>(play).tooltip, 'Play Flow One');
      await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('goldens/home_you_might_like_phone_390.png'),
      );

      await tester.drag(carousel, const Offset(-240, 0));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: info, matching: find.text('Flow Two')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: info, matching: find.text('From your server')),
        findsOneWidget,
      );
      expect(play, findsOneWidget);

      await tester.drag(carousel, const Offset(-240, 0));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: info, matching: find.text('Weekly Jams')),
        findsOneWidget,
      );
      // Weekly playlists open their detail instead of playing directly.
      expect(play, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  group('You Might Like height and Flat look', () {
    const washKey = ValueKey<String>('home-showcase-wash');
    const scripts = <(String, String, String)>[
      ('latin', 'Midnight Drive', 'The Night Owls'),
      ('japanese', '夜に駆ける 〜 真夜中のドライブ', '宇多田ヒカル・米津玄師'),
      (
        'arabic',
        'ليلة في القاهرة الحبيبة والذكريات',
        'أم كلثوم وفرقة الموسيقى',
      ),
    ];

    List<HomeRandomShowcaseItem> albumsFor(String name, String artist) =>
        <HomeRandomShowcaseItem>[
          for (final i in <int>[1, 2])
            HomeRandomShowcaseAlbum(
              id: 'script-$i',
              name: name,
              artist: artist,
              coverArtId: 'cover-script-$i',
              year: 2023,
              songCount: 12,
              source: HomeRandomShowcaseSource.likedDiscovery,
            ),
        ];

    List<Override> overridesFor() => <Override>[
      backgroundCoverColourFieldProvider.overrideWith(
        (ref, id) async =>
            CoverColourField(List<Color>.filled(9, const Color(0xFFD32F2F))),
      ),
      albumProvider.overrideWith(
        (ref, albumId) => Stream.value(
          _albumWithSongs(albumId, 'Album', <SongsTableData>[
            for (var i = 1; i <= 4; i++)
              _songRow(
                id: '$albumId-song-$i',
                title: 'Song $i',
                albumId: albumId,
                discNumber: 1,
                track: i,
              ),
          ]),
        ),
      ),
      songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
      songStarredProvider.overrideWith((ref, songId) => Stream.value(false)),
    ];

    Future<void> pump(
      WidgetTester tester, {
      required bool desktop,
      required bool flat,
      double scale = 1,
      String name = 'Midnight Drive',
      String artist = 'The Night Owls',
    }) async {
      setAdaptiveTestViewport(
        tester,
        desktop ? const Size(1366, 900) : const Size(390, 844),
      );
      await _pumpRandomSectionHome(
        tester,
        database: database,
        nativeTouch: !desktop,
        baseTheme: buildDarkTheme(
          const Color(0xFF009688),
          style: NavisColorStyle.pastel,
          flat: flat,
        ),
        textScale: scale,
        overrides: overridesFor(),
        randomAlbums: albumsFor(name, artist),
      );
      expect(tester.takeException(), isNull);
    }

    Finder section({required bool desktop}) => find.byWidgetPredicate(
      (w) =>
          w.runtimeType.toString() ==
          (desktop ? '_DesktopRandomAlbumsPager' : '_RandomAlbumsHeroCarousel'),
    );

    // Each Latin run records the height the Japanese and Arabic runs of the
    // same setup must keep; the loops below run it first.
    final latinHeights = <String, double>{};
    for (final desktop in <bool>[false, true]) {
      for (final flat in <bool>[false, true]) {
        for (final scale in desktop ? <double>[1] : <double>[1, 2]) {
          for (final (script, name, artist) in scripts) {
            final setup =
                '${desktop ? 'desktop' : 'phone'} '
                '${flat ? 'flat' : 'colour'} ${scale}x';
            testWidgets('keeps one section height in $script ($setup)', (
              tester,
            ) async {
              await pump(
                tester,
                desktop: desktop,
                flat: flat,
                scale: scale,
                name: name,
                artist: artist,
              );
              final height = tester.getSize(section(desktop: desktop)).height;
              expect(
                height,
                closeTo(latinHeights.putIfAbsent(setup, () => height), 0.01),
              );
            });
          }
        }
      }
    }

    for (final desktop in <bool>[false, true]) {
      testWidgets(
        'Flat ${desktop ? 'desktop' : 'phone'} paints no band, wash, gradient '
        'or tint behind the section',
        (tester) async {
          await pump(tester, desktop: desktop, flat: true);
          final box = section(desktop: desktop);
          final rect = tester.getRect(box);
          expect(find.byKey(washKey), findsNothing);
          expect(
            find.descendant(
              of: box,
              matching: find.byWidgetPredicate(
                (w) => w is CustomPaint && w.painter is CoverColourFieldPainter,
              ),
            ),
            findsNothing,
          );
          // Nothing the size of the section is filled or shaded: whatever is
          // behind it is the page background.
          bool coversSection(Element e) {
            final size = (e.renderObject! as RenderBox).size;
            return size.width >= rect.width - 1 &&
                size.height >= rect.height - 1;
          }

          final fills = <Element>[
            ...find
                .descendant(of: box, matching: find.byType(ColoredBox))
                .evaluate(),
            ...find
                .descendant(of: box, matching: find.byType(DecoratedBox))
                .evaluate()
                .where((e) {
                  final decoration = (e.widget as DecoratedBox).decoration;
                  return decoration is! BoxDecoration ||
                      decoration.color != null ||
                      decoration.gradient != null;
                }),
          ];
          expect(fills.where(coversSection), isEmpty);
          // Caption text keeps the normal on-surface colours.
          final colours = Theme.of(tester.element(box)).colorScheme;
          final info = find.descendant(
            of: find.byKey(const ValueKey<String>('home-showcase-info')),
            matching: find.byType(Text),
          );
          if (!desktop) {
            final title = tester.renderObject<RenderParagraph>(info.first);
            expect(title.text.style?.color, anyOf(isNull, colours.onSurface));
          }
        },
      );
    }

    testWidgets(
      'the info lines have a forced strut, so scripts cannot grow them',
      (tester) async {
        // The test font has no fallback metrics, so pin the cause instead: every
        // info line is a fixed-height strut line.
        await pump(
          tester,
          desktop: false,
          flat: false,
          name: scripts[2].$2,
          artist: scripts[2].$3,
        );
        final lines = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(const ValueKey<String>('home-showcase-info')),
                matching: find.byType(Text),
              ),
            )
            .toList();
        expect(lines, hasLength(3));
        for (final line in lines) {
          expect(line.strutStyle?.forceStrutHeight, isTrue);
          expect(line.maxLines, 1);
        }
      },
    );

    testWidgets('colour mode keeps the wash behind the phone section', (
      tester,
    ) async {
      await pump(tester, desktop: false, flat: false);
      expect(find.byKey(washKey), findsOneWidget);
    });

    testWidgets('toggling Flat keeps the desktop pager on its page', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1366, 900));
      ThemeData theme({required bool flat}) => buildDarkTheme(
        const Color(0xFF009688),
        style: NavisColorStyle.pastel,
        flat: flat,
      );
      final notifier = ValueNotifier<ThemeData?>(theme(flat: false));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        forceDesktop: true,
        themeNotifier: notifier,
        overrides: overridesFor(),
        randomAlbums: <HomeRandomShowcaseItem>[
          for (final i in <int>[1, 2, 3])
            HomeRandomShowcaseAlbum(
              id: 'script-$i',
              name: 'Album $i',
              artist: 'Artist',
              coverArtId: 'cover-script-$i',
              year: 2023,
              songCount: 12,
              source: HomeRandomShowcaseSource.likedDiscovery,
            ),
        ],
      );
      final next = find.byKey(
        const ValueKey<String>('home-random-desktop-next'),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      final view = find.byKey(
        const ValueKey<String>('home-random-desktop-pageview'),
      );
      expect(tester.widget<PageView>(view).controller!.page, 2);
      notifier.value = theme(flat: true);
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(view).controller!.page, 2);
    });

    testWidgets('colour mode keeps the wash and card on desktop', (
      tester,
    ) async {
      await pump(tester, desktop: true, flat: false);
      expect(find.byKey(washKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('home-random-desktop-pager')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).border != null &&
                (w.decoration as BoxDecoration).borderRadius ==
                    NavisRadius.xlAll,
          ),
        ),
        findsWidgets,
      );
    });
  });

  testWidgets(
    'phone Home header is compact; tablet portrait keeps the old one',
    (tester) async {
      const header = ValueKey<String>('homeCenteredLogoHeader');
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await _pumpHomeWithAppSettings(tester, database: database);
      // 16 top + 104 logo + 4 bottom (was 48 + 96 + 14): a larger logo in the
      // same height, using the transparent margin inside the logo asset.
      expect(tester.getSize(find.byKey(header)).height, 124);
      final logoRect = tester.getRect(
        find.byKey(const ValueKey<String>('home-sync-logo')),
      );
      expect(logoRect.height, 104);
      final actionRow = find.byKey(
        const ValueKey<String>('homeMobileActionRow'),
      );
      expect(
        tester.getTopLeft(actionRow).dy,
        tester.getRect(find.byKey(header)).bottom,
      );
      // Filter buttons keep a 48 px tap target.
      expect(
        tester
            .getSize(
              find.widgetWithIcon(IconButton, Icons.favorite_border_rounded),
            )
            .height,
        greaterThanOrEqualTo(40),
      );

      tester.view.physicalSize = const Size(700, 1000);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(header)).height, 158);
    },
  );

  testWidgets('You Might Like fits a landscape phone without overflow', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(844, 390);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
    await _pumpRandomSectionHome(
      tester,
      database: database,
      nativeTouch: true,
      randomAlbums: const <HomeRandomShowcaseItem>[
        HomeRandomShowcaseAlbum(
          id: 'land-1',
          name: 'Landscape One',
          artist: 'Artist',
          coverArtId: 'cover-land-1',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'land-2',
          name: 'Landscape Two',
          artist: 'Artist',
          coverArtId: 'cover-land-2',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ],
    );
    final cover = find
        .descendant(
          of: find.byKey(const ValueKey<String>('home-random-hero-carousel')),
          matching: find.byType(HeroCoverArt),
        )
        .first;
    // The whole cover fits within the short landscape viewport.
    expect(tester.getSize(cover).height, lessThanOrEqualTo(390 * 0.42 + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('random section renders dedicated hero carousel', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                  homeSectionsHidden: _hiddenExcept(<String>[
                    HomeSectionIds.randomAlbums,
                  ]),
                ),
              ),
            ),
            librarySyncControllerProvider.overrideWith(
              _StaticLibrarySyncController.new,
            ),
            homeRandomShowcaseProvider.overrideWith(
              (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[
                HomeRandomShowcaseAlbum(
                  id: 'hero-1',
                  name: 'Hero One',
                  artist: 'Artist One',
                  coverArtId: 'cover-hero-1',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
                HomeRandomShowcaseAlbum(
                  id: 'hero-2',
                  name: 'Hero Two',
                  artist: 'Artist Two',
                  coverArtId: 'cover-hero-2',
                  source: HomeRandomShowcaseSource.serverRandom,
                ),
              ]),
            ),
            homeLikedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            homeRecentlyAddedProvider.overrideWithValue(
              const AsyncData(<Album>[]),
            ),
            homeRecentlyPlayedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            homeMostPlayedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home-random-hero-carousel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-random-hero-carousel-page-0')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'random hero carousel renders two ListenBrainz cards and opens detail sheets',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: <HomeRandomShowcaseItem>[
          HomeRandomShowcaseListenBrainz(
            playlist: _listenBrainzPlaylist(
              'exploration',
              'Weekly Exploration for alice, week of 2026-06-15',
            ),
          ),
          HomeRandomShowcaseListenBrainz(
            playlist: _listenBrainzPlaylist(
              'jams',
              'Weekly Jams for alice, week of 2026-06-15',
            ),
          ),
        ],
      );

      expect(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        findsOneWidget,
      );
      expect(find.text('Weekly Exploration'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Shuffle'), findsNothing);

      await tester.tap(find.text('Weekly Exploration'));
      await tester.pumpAndSettle();
      // The card opens the weekly playlist route, as it does in the app.
      expect(find.byType(ListenBrainzWeeklyDetailScreen), findsOneWidget);
      expect(find.text('Weekly Exploration'), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Weekly Jams'), findsWidgets);

      await tester.tap(find.text('Weekly Jams'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly Jams'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  Future<_QueueSpyController> openMixedWeeklyDetail(
    WidgetTester tester, {
    bool albumQueue = true,
  }) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    // Tall enough for every row of the playlist without scrolling.
    view.physicalSize = const Size(390, 1400);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz(playlist: _listenBrainzMixedPlaylist()),
      ],
      overrides: <Override>[
        queueProvider.overrideWith(_QueueSpyController.new),
        albumQueueEnabledProvider.overrideWithValue(albumQueue),
      ],
    );
    await tester.tap(find.text('Weekly Exploration'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen, skipOffstage: false)),
    );
    return container.read(queueProvider.notifier) as _QueueSpyController;
  }

  testWidgets(
    'weekly Play and Shuffle queue on-server and remote matches in order',
    (tester) async {
      final queueSpy = await openMixedWeeklyDetail(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Play').last);
      await tester.pumpAndSettle();

      // 1.4.0 queued only the on-server songs.
      expect(queueSpy.lastReplaceIds, const <String>[
        'weekly-song-1',
        'ext-deezer-song-2',
        'weekly-song-3',
      ]);
      expect(queueSpy.lastStartIndex, 0);
      expect(queueSpy.lastAutoPlay, isTrue);
      expect(queueSpy.lastExpandMatchFlows, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, 'Shuffle').last);
      await tester.pumpAndSettle();

      expect(
        queueSpy.lastReplaceIds,
        unorderedEquals(<String>[
          'weekly-song-1',
          'ext-deezer-song-2',
          'weekly-song-3',
        ]),
      );
      expect(queueSpy.lastExpandMatchFlows, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'with Album Queue on, a weekly row plays the playlist from that song',
    (tester) async {
      final queueSpy = await openMixedWeeklyDetail(tester);

      await tester.tap(find.text('Weekly Song 3').last);
      await tester.pumpAndSettle();

      expect(queueSpy.lastReplaceIds, const <String>[
        'weekly-song-1',
        'ext-deezer-song-2',
        'weekly-song-3',
      ]);
      expect(queueSpy.lastStartIndex, 2);
      expect(queueSpy.lastAutoPlay, isTrue);
      expect(queueSpy.lastExpandMatchFlows, isFalse);

      // A remote row starts the same queue at its own position.
      await tester.tap(find.text('Remote Song 2').last);
      await tester.pumpAndSettle();

      expect(queueSpy.lastReplaceIds, hasLength(3));
      expect(queueSpy.lastStartIndex, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('with Album Queue off, a weekly row plays only that song', (
    tester,
  ) async {
    final queueSpy = await openMixedWeeklyDetail(tester, albumQueue: false);

    await tester.tap(find.text('Weekly Song 3').last);
    await tester.pumpAndSettle();

    expect(queueSpy.lastReplaceIds, const <String>['weekly-song-3']);
    expect(queueSpy.lastStartIndex, 0);
    expect(queueSpy.lastExpandMatchFlows, isFalse);

    await tester.tap(find.text('Remote Song 2').last);
    await tester.pumpAndSettle();

    expect(queueSpy.lastReplaceIds, const <String>['ext-deezer-song-2']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'weekly detail remote row taps queue one API song without match-flow expansion',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: <HomeRandomShowcaseItem>[
          HomeRandomShowcaseListenBrainz(
            playlist: _listenBrainzPlaylist(
              'exploration',
              'Weekly Exploration for alice, week of 2026-06-15',
            ),
          ),
        ],
        overrides: <Override>[
          queueProvider.overrideWith(_QueueSpyController.new),
        ],
      );

      await tester.tap(find.text('Weekly Exploration'));
      await tester.pumpAndSettle();
      final remoteTitle = find.text('Remote Song').last;
      final remoteTile = find.ancestor(
        of: remoteTitle,
        matching: find.byType(AdaptiveTrackRow),
      );
      expect(
        find.descendant(
          of: remoteTile,
          matching: find.byKey(RemoteSourceIndicator.semanticsKey),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Remote Song').last);
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      );
      final queueSpy =
          container.read(queueProvider.notifier) as _QueueSpyController;
      expect(queueSpy.lastReplaceIds, const <String>['remote-song']);
      expect(queueSpy.lastStartIndex, 0);
      expect(queueSpy.lastAutoPlay, isTrue);
      expect(queueSpy.lastExpandMatchFlows, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('weekly recommendation marks the paused current song', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz(
          playlist: _listenBrainzPlaylistWithApiSongs(),
        ),
      ],
      overrides: <Override>[
        playerStateProvider.overrideWithValue(
          const PlaybackSnapshot(
            queueSongIds: <String>['remote-song-2'],
            currentSongId: 'remote-song-2',
            currentIndex: 0,
            playing: false,
            processingState: AudioProcessingState.ready,
            position: Duration.zero,
            duration: Duration(minutes: 3),
            bufferedPosition: Duration.zero,
            shuffleMode: AudioServiceShuffleMode.none,
            repeatMode: AudioServiceRepeatMode.none,
          ),
        ),
      ],
    );

    await tester.tap(find.text('Weekly Exploration'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    _expectWeeklyMarkerAlignedWithNumber(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.value == 'Now Playing',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('random hero carousel renders loading ListenBrainz cards', (
    tester,
  ) async {
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: const <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz.loading(
          sourcePatch: 'weekly-exploration',
          displayTitle: 'Weekly Exploration',
        ),
        HomeRandomShowcaseListenBrainz.loading(
          sourcePatch: 'weekly-jams',
          displayTitle: 'Weekly Jams',
        ),
      ],
      settle: false,
    );

    expect(find.text('Weekly Exploration'), findsOneWidget);
    expect(find.text('Fetching ListenBrainz playlist...'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    await tester.tap(find.text('Weekly Exploration'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Remote Song'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('opt-in carousel stops while the hero is below half visible', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      nativeTouch: true,
      reduceMotion: false,
      homeLikedSongs: [
        for (var i = 0; i < 30; i++)
          _songRow(
            id: 'visibility-$i',
            title: 'Visible song $i',
            albumId: 'visibility-album',
          ),
      ],
      sectionOrder: const [
        HomeSectionIds.randomAlbums,
        HomeSectionIds.likedTracks,
      ],
      overrides: [
        homeRecommendationsAutoAdvanceProvider.overrideWithValue(true),
      ],
      randomAlbums: const [
        HomeRandomShowcaseAlbum(
          id: 'visibility-one',
          name: 'One',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'visibility-two',
          name: 'Two',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ],
    );
    final scrollable = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(400);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    position.jumpTo(0);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-random-hero-carousel-page-0')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('home-random-hero-carousel-page-1')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'opt-in carousel pauses for inactive Home, player overlays and lifecycle',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await _pumpRandomSectionHome(
        tester,
        database: database,
        nativeTouch: true,
        reduceMotion: false,
        homeActive: active,
        overrides: [
          homeRecommendationsAutoAdvanceProvider.overrideWithValue(true),
        ],
        randomAlbums: const [
          HomeRandomShowcaseAlbum(
            id: 'eligible-one',
            name: 'One',
            source: HomeRandomShowcaseSource.serverRandom,
          ),
          HomeRandomShowcaseAlbum(
            id: 'eligible-two',
            name: 'Two',
            source: HomeRandomShowcaseSource.serverRandom,
          ),
        ],
      );
      String page() =>
          (tester
                      .widget(
                        find.byWidgetPredicate(
                          (widget) =>
                              widget.key is ValueKey<String> &&
                              (widget.key! as ValueKey<String>).value
                                  .startsWith(
                                    'home-random-hero-carousel-page-',
                                  ),
                        ),
                      )
                      .key!
                  as ValueKey<String>)
              .value;
      final initial = page();
      active.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(page(), initial);
      active.value = true;
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      );
      final homeContext = tester.element(find.byType(HomeScreen));
      showDialog<void>(
        context: homeContext,
        builder: (context) => const Dialog(child: Text('Covered Home')),
      ).ignore();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 20));
      expect(page(), initial);
      Navigator.of(homeContext).pop();
      await tester.pumpAndSettle();
      container.read(playerOverlayStackProvider.notifier).expand();
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(page(), initial);
      container.read(playerOverlayStackProvider.notifier).clear();
      container.read(quickSearchOverlayVisibleProvider.notifier).visible = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(page(), initial);
      container.read(quickSearchOverlayVisibleProvider.notifier).visible =
          false;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 20));
      expect(page(), initial);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 7));
      expect(page(), initial);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(page(), isNot(initial));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('recommendations are manual by default even with normal motion', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      nativeTouch: true,
      reduceMotion: false,
      randomAlbums: const [
        HomeRandomShowcaseAlbum(
          id: 'default-one',
          name: 'One',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'default-two',
          name: 'Two',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 30));
    expect(
      find.byKey(const ValueKey('home-random-hero-carousel-page-0')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('home-random-hero-carousel')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-random-hero-carousel-page-1')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'random hero carousel auto-advances and pauses after interaction',
    (tester) async {
      final view = tester.view;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(390, 844);
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              homeRecommendationsAutoAdvanceProvider.overrideWith(
                (ref) => ref.watch(_autoAdvancePreference),
              ),
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  const AppSettingsModel.defaults().copyWith(
                    homeSectionOrder: <String>[HomeSectionIds.randomAlbums],
                    homeSectionsHidden: _hiddenExcept(<String>[
                      HomeSectionIds.randomAlbums,
                    ]),
                  ),
                ),
              ),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
              librarySyncControllerProvider.overrideWith(
                _StaticLibrarySyncController.new,
              ),
              homeRandomShowcaseProvider.overrideWith(
                (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[
                  HomeRandomShowcaseAlbum(
                    id: 'hero-1',
                    name: 'Hero One',
                    artist: 'Artist One',
                    coverArtId: 'cover-hero-1',
                    source: HomeRandomShowcaseSource.serverRandom,
                  ),
                  HomeRandomShowcaseAlbum(
                    id: 'hero-2',
                    name: 'Hero Two',
                    artist: 'Artist Two',
                    coverArtId: 'cover-hero-2',
                    source: HomeRandomShowcaseSource.serverRandom,
                  ),
                  HomeRandomShowcaseAlbum(
                    id: 'hero-3',
                    name: 'Hero Three',
                    artist: 'Artist Three',
                    coverArtId: 'cover-hero-3',
                    source: HomeRandomShowcaseSource.serverRandom,
                  ),
                ]),
              ),
              homeLikedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              homeRecentlyAddedProvider.overrideWithValue(
                const AsyncData(<Album>[]),
              ),
              homeRecentlyPlayedAlbumsProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
              homeMostPlayedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedAlbumsRecentProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
            ],
          ),
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: false),
              child: child!,
            ),
            home: AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: false,
                viewportSize: const Size(390, 844),
                safePadding: EdgeInsets.zero,
              ),
              child: const HomeScreen(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      Finder pageKeyFinder() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('home-random-hero-carousel-page-');
      });
      String currentPageKey() {
        final widget = tester.widget(pageKeyFinder());
        final key = widget.key;
        expect(key, isA<ValueKey<String>>());
        return (key! as ValueKey<String>).value;
      }

      final initialPage = currentPageKey();
      expect(initialPage, 'home-random-hero-carousel-page-0');

      await tester.pump(const Duration(milliseconds: 8100));
      await tester.pump(const Duration(milliseconds: 520));
      final afterAutoAdvance = currentPageKey();
      expect(afterAutoAdvance, isNot(initialPage));

      await tester.drag(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        const Offset(-260, 0),
      );
      await tester.pumpAndSettle();
      final afterDrag = currentPageKey();

      await tester.pump(const Duration(milliseconds: 9000));
      expect(currentPageKey(), afterDrag);

      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 520));
      expect(currentPageKey(), isNot(afterDrag));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      );
      container
          .read(_autoAdvancePreference.notifier)
          .setEnabled(enabled: false);
      await tester.pump();
      final disabledPage = currentPageKey();
      await tester.pump(const Duration(seconds: 30));
      expect(currentPageKey(), disabledPage);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('hero carousel loaded after startup can scroll backwards', (
    tester,
  ) async {
    final items = [
      for (var i = 0; i < 6; i++)
        HomeRandomShowcaseAlbum(
          id: 'late-$i',
          name: 'Late $i',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
    ];
    final view = tester.view;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(390, 844);
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: const [],
      mutableShowcase: true,
    );
    final fixture = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen, skipOffstage: false)),
    ).read(_showcaseFixture.notifier);
    fixture.items = [items.first];
    await tester.pumpAndSettle();

    ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen, skipOffstage: false)),
    ).read(_showcaseFixture.notifier).items = items;
    await tester.pumpAndSettle();

    final carousel = find.byKey(
      const ValueKey<String>('home-random-hero-carousel'),
    );
    final pageView = tester.widget<PageView>(carousel);
    expect(pageView.controller!.page, greaterThanOrEqualTo(items.length));

    await tester.drag(carousel, const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.text('Late 5'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'desktop recommendations preserve selection across pane resizing and data refresh',
    (tester) async {
      const items = [
        HomeRandomShowcaseAlbum(
          id: 'resize-a',
          name: 'Resize A',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'resize-b',
          name: 'Resize B',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];
      setAdaptiveTestViewport(tester, const Size(1200, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: items,
        forceDesktop: true,
        mutableShowcase: true,
        overrides: [
          homeRecommendationsAutoAdvanceProvider.overrideWithValue(true),
        ],
      );
      final fixture = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      ).read(_showcaseFixture.notifier);
      fixture.items = items;
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('home-random-desktop-mini-cover-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album:resize-b')), findsOneWidget);
      tester.view.physicalSize = const Size(620, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album:resize-b')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 30));
      expect(find.byKey(const ValueKey('album:resize-b')), findsOneWidget);
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pumpAndSettle();
      fixture.items = [items[1], items[0]];
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album:resize-b')), findsOneWidget);
      fixture.items = [items[0]];
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album:resize-a')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'desktop-wide random section uses desktop pager and compact widths keep hero carousel',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseItem>[
        HomeRandomShowcaseAlbum(
          id: 'desk-1',
          name: 'Desktop Album',
          artist: 'Desk Artist',
          coverArtId: 'cover-desk-1',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(1200, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          albumProvider.overrideWith(
            (ref, albumId) => Stream.value(
              albumId == 'desk-1'
                  ? _albumWithSongs('desk-1', 'Desktop Album', <SongsTableData>[
                      _songRow(
                        id: 'desk-song-1',
                        title: 'Desktop Song',
                        albumId: 'desk-1',
                        discNumber: 1,
                        track: 1,
                      ),
                    ])
                  : null,
            ),
          ),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
      );

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        findsNothing,
      );

      tester.view.physicalSize = const Size(840, 900);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('home-random-hero-carousel')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'desktop random pager renders two ListenBrainz cards and opens detail sheets',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(1366, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: <HomeRandomShowcaseItem>[
          HomeRandomShowcaseListenBrainz(
            playlist: _listenBrainzPlaylist(
              'exploration',
              'Weekly Exploration for alice, week of 2026-06-15',
            ),
          ),
          HomeRandomShowcaseListenBrainz(
            playlist: _listenBrainzPlaylist(
              'jams',
              'Weekly Jams for alice, week of 2026-06-15',
            ),
          ),
        ],
      );

      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsOneWidget,
      );
      expect(find.text('Weekly Exploration'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Shuffle'), findsNothing);

      await tester.tap(find.text('Weekly Exploration'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly Exploration'), findsWidgets);
      expect(find.text('Remote Song'), findsWidgets);
      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('home-random-desktop-mini-cover-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Weekly Jams'), findsOneWidget);

      await tester.tap(find.text('Weekly Jams'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly Jams'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('desktop weekly panel rows follow Album Queue', (tester) async {
    setAdaptiveTestViewport(tester, const Size(1366, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz(
          playlist: _listenBrainzPlaylistWithApiSongs(),
        ),
      ],
      overrides: <Override>[
        queueProvider.overrideWith(_QueueSpyController.new),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen, skipOffstage: false)),
    );
    final queueSpy =
        container.read(queueProvider.notifier) as _QueueSpyController;

    await tester.tap(find.text('Remote Song 2').last);
    await tester.pumpAndSettle();

    expect(queueSpy.lastReplaceIds, const <String>[
      'remote-song-1',
      'remote-song-2',
    ]);
    expect(queueSpy.lastStartIndex, 1);
    expect(queueSpy.lastExpandMatchFlows, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('desktop weekly marker aligns with inactive track numbers', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1366, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz(
          playlist: _listenBrainzPlaylistWithApiSongs(),
        ),
      ],
      overrides: <Override>[
        playerStateProvider.overrideWithValue(
          const PlaybackSnapshot(
            queueSongIds: <String>['remote-song-2'],
            currentSongId: 'remote-song-2',
            currentIndex: 0,
            playing: true,
            processingState: AudioProcessingState.ready,
            position: Duration.zero,
            duration: Duration(minutes: 3),
            bufferedPosition: Duration.zero,
            shuffleMode: AudioServiceShuffleMode.none,
            repeatMode: AudioServiceRepeatMode.none,
          ),
        ),
      ],
    );

    expect(
      find.byKey(const ValueKey<String>('home-random-desktop-pager')),
      findsOneWidget,
    );
    _expectWeeklyMarkerAlignedWithNumber(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('desktop weekly track menu button opens the anchored menu', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1366, 900));
    await _pumpWeeklyDetail(
      tester,
      sourcePatch: 'weekly-exploration',
      database: database,
      playlists: Stream<List<ListenBrainzDiscoverPlaylist>>.value(
        <ListenBrainzDiscoverPlaylist>[_listenBrainzPlaylistWithTableSongs()],
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Weekly Song 1').last);
    await tester.pumpAndSettle();
    final moreButton = find.byIcon(Icons.more_vert).first;
    final tooltip = find.ancestor(
      of: moreButton,
      matching: find.byType(Tooltip),
    );
    expect(
      tester.widget<Tooltip>(tooltip).message,
      MaterialLocalizations.of(tester.element(moreButton)).showMenuTooltip,
    );
    expect(tooltip, findsOneWidget);
    await tester.tap(moreButton);
    await tester.pumpAndSettle();

    expect(find.text('Play Now'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tapAt(const Offset(12, 880));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('desktop random pager renders loading ListenBrainz text', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1366, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: const <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz.loading(
          sourcePatch: 'weekly-exploration',
          displayTitle: 'Weekly Exploration',
        ),
        HomeRandomShowcaseListenBrainz.loading(
          sourcePatch: 'weekly-jams',
          displayTitle: 'Weekly Jams',
        ),
      ],
      settle: false,
    );

    expect(
      find.byKey(const ValueKey<String>('home-random-desktop-pager')),
      findsOneWidget,
    );
    expect(find.text('Weekly Exploration'), findsOneWidget);
    expect(find.text('Fetching ListenBrainz playlist...'), findsOneWidget);

    await tester.tap(find.text('Weekly Exploration'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Remote Song'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'bounded desktop hero keeps all tracks reachable and supports manual paging',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseItem>[
        HomeRandomShowcaseAlbum(
          id: 'desk-a',
          name: 'Album A',
          artist: 'Artist A',
          coverArtId: 'cover-desk-a',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
        HomeRandomShowcaseAlbum(
          id: 'desk-b',
          name: 'Album B',
          artist: 'Artist B',
          coverArtId: 'cover-desk-b',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(1366, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          albumProvider.overrideWith((ref, albumId) {
            final songsA = List<SongsTableData>.generate(
              6,
              (index) => _songRow(
                id: 'desk-a-song-${index + 1}',
                title: 'A Song ${index + 1}',
                albumId: 'desk-a',
                discNumber: 1,
                track: index + 1,
              ),
            );
            final songsB = List<SongsTableData>.generate(
              3,
              (index) => _songRow(
                id: 'desk-b-song-${index + 1}',
                title: 'B Song ${index + 1}',
                albumId: 'desk-b',
                discNumber: 1,
                track: index + 1,
              ),
            );
            final data = switch (albumId) {
              'desk-a' => _albumWithSongs('desk-a', 'Album A', songsA),
              'desk-b' => _albumWithSongs('desk-b', 'Album B', songsB),
              _ => null,
            };
            return Stream.value(data);
          }),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(false),
          ),
        ],
      );

      Finder visibleRows() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('home-random-desktop-song-row-');
      });

      expect(
        find.byKey(const ValueKey<String>('album:desk-a')),
        findsOneWidget,
      );
      expect(find.text('A Song 1'), findsOneWidget);
      await tester.drag(
        find.byKey(
          const ValueKey<String>('home-random-desktop-song-list-desk-a'),
        ),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(find.text('A Song 6'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('home-random-desktop-mini-cover-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('album:desk-b')),
        findsOneWidget,
      );
      expect(visibleRows(), findsNWidgets(3));

      await tester.tap(find.byIcon(Icons.chevron_left_rounded).first);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('album:desk-a')),
        findsOneWidget,
      );
      expect(find.text('A Song 1'), findsOneWidget);
      await tester.drag(
        find.byKey(
          const ValueKey<String>('home-random-desktop-song-list-desk-a'),
        ),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(find.text('A Song 6'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'desktop random rows trigger queue replace, like toggle, and menu actions',
    (tester) async {
      const randomAlbums = <HomeRandomShowcaseItem>[
        HomeRandomShowcaseAlbum(
          id: 'desk-interact',
          name: 'Interactive Album',
          artist: 'Artist',
          coverArtId: 'cover-desk-interact',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ];

      setAdaptiveTestViewport(tester, const Size(2560, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: randomAlbums,
        overrides: <Override>[
          queueProvider.overrideWith(_QueueSpyController.new),
          albumProvider.overrideWith(
            (ref, albumId) => Stream.value(
              albumId == 'desk-interact'
                  ? _albumWithSongs(
                      'desk-interact',
                      'Interactive Album',
                      List<SongsTableData>.generate(
                        6,
                        (index) => _songRow(
                          id: 'interaction-song-${index + 1}',
                          title: 'Song ${index + 1}',
                          albumId: 'desk-interact',
                          discNumber: 1,
                          track: index + 1,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
          songStarredProvider.overrideWith(
            (ref, songId) => Stream.value(songId == 'interaction-song-1'),
          ),
        ],
      );

      await tester.tap(find.text('Song 3'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen, skipOffstage: false)),
      );
      final queueSpy =
          container.read(queueProvider.notifier) as _QueueSpyController;
      expect(queueSpy.lastReplaceIds, hasLength(6));
      expect(queueSpy.lastStartIndex, 2);
      expect(queueSpy.lastAutoPlay, isTrue);

      final heartButton = tester.widget<IconButton>(
        find.byKey(
          const ValueKey<String>(
            'home-random-desktop-heart-interaction-song-1',
          ),
        ),
      );
      final heartIcon = heartButton.icon as Icon;
      expect(heartIcon.icon, Icons.favorite);
      expect(heartButton.tooltip, 'Liked');

      final menuButton = tester.widget<IconButton>(
        find.byKey(
          const ValueKey<String>('home-random-desktop-menu-interaction-song-1'),
        ),
      );
      expect(menuButton.tooltip, 'More');

      await tester.tap(
        find.byKey(
          const ValueKey<String>('home-random-desktop-menu-interaction-song-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Play Now'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('desktop random pager avoids overflow at key desktop widths', (
    tester,
  ) async {
    const randomAlbums = <HomeRandomShowcaseItem>[
      HomeRandomShowcaseAlbum(
        id: 'desk-overflow',
        name: 'A very long desktop album title that should still fit without overflow',
        artist: 'Overflow Artist',
        coverArtId: 'cover-desk-overflow',
        source: HomeRandomShowcaseSource.serverRandom,
      ),
    ];

    setAdaptiveTestViewport(tester, const Size(1200, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: randomAlbums,
      overrides: <Override>[
        albumProvider.overrideWith(
          (ref, albumId) => Stream.value(
            albumId == 'desk-overflow'
                ? _albumWithSongs(
                    'desk-overflow',
                    'A very long desktop album title that should still fit without overflow',
                    List<SongsTableData>.generate(
                      6,
                      (index) => _songRow(
                        id: 'overflow-song-${index + 1}',
                        title:
                            'A long desktop song title ${index + 1} that should ellipsize cleanly',
                        albumId: 'desk-overflow',
                        discNumber: 1,
                        track: index + 1,
                        artist: 'An artist name with extended text to stress desktop layout spacing',
                      ),
                    ),
                  )
                : null,
          ),
        ),
        songByIdProvider.overrideWith((ref, songId) => Stream.value(null)),
        songStarredProvider.overrideWith((ref, songId) => Stream.value(false)),
      ],
    );

    final widths = <Size>[
      const Size(1200, 900),
      const Size(1366, 900),
      const Size(1600, 900),
    ];

    for (final size in widths) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('home-random-desktop-pager')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('Trending in the phone hero opens its ranked page', (
    tester,
  ) async {
    final trending = _trending();
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[trending],
      overrides: <Override>[
        homeTrendingProvider.overrideWith(
          (ref) => Stream.value(trending.tracks),
        ),
      ],
    );

    final panel = find.byKey(const ValueKey<String>('home-showcase-info'));
    expect(
      find.descendant(of: panel, matching: find.text('Trending Now')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('8 of 16 available')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('Popular on Deezer')),
      findsOneWidget,
    );
    // A playlist opens its page; only albums get a Play button.
    expect(
      find.byKey(const ValueKey<String>('home-showcase-play')),
      findsNothing,
    );

    await tester.tap(find.bySemanticsLabel('Trending Now').first);
    await tester.pumpAndSettle();

    expect(find.byType(TrendingDetailScreen), findsOneWidget);
    expect(
      find.text('Deezer chart • 16 songs • 8 of 16 available'),
      findsOneWidget,
    );
    expect(find.text('Chart Song 2'), findsOneWidget);
    // Unmatched chart songs keep their place: no gaps in the numbering.
    final missingRow = find.ancestor(
      of: find.text('Missing Song 1'),
      matching: find.byType(AdaptiveTrackRow),
    );
    expect(
      find.descendant(of: missingRow, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: missingRow, matching: find.text('Not on Server')),
      findsOneWidget,
    );
    // Rows are numbered by chart position.
    final secondRow = find.ancestor(
      of: find.text('Chart Song 2'),
      matching: find.byType(AdaptiveTrackRow),
    );
    expect(
      find.descendant(of: secondRow, matching: find.text('3')),
      findsOneWidget,
    );
  });

  for (final size in <Size>[const Size(1100, 800), const Size(1280, 900)]) {
    testWidgets(
      'desktop Trending Time column ends at one x on matched and unmatched '
      'rows at ${size.width} px',
      (tester) async {
        setAdaptiveTestViewport(tester, size);
        await _pumpRandomSectionHome(
          tester,
          database: database,
          randomAlbums: <HomeRandomShowcaseItem>[_trending()],
          forceDesktop: true,
        );

        Finder time(String key) => find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byWidgetPredicate(
            (widget) => widget is Text && widget.textAlign == TextAlign.right,
          ),
        );
        final matched = time('trending-desktop-row-chart-2');
        final unmatched = time('trending-desktop-row-rank-2');
        expect(matched, findsOneWidget);
        expect(unmatched, findsOneWidget);
        expect(
          tester.getTopRight(matched).dx,
          tester.getTopRight(unmatched).dx,
        );
      },
    );
  }

  testWidgets(
    'desktop Trending numbers songs by chart position and plays from a row',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(1280, 900));
      await _pumpRandomSectionHome(
        tester,
        database: database,
        randomAlbums: <HomeRandomShowcaseItem>[_trending()],
        forceDesktop: true,
        overrides: <Override>[
          queueProvider.overrideWith(_QueueSpyController.new),
          albumQueueEnabledProvider.overrideWithValue(true),
        ],
      );

      final row = find.byKey(
        const ValueKey<String>('trending-desktop-row-chart-2'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('3')),
        findsOneWidget,
      );
      // The unmatched song between them is listed, with a Search action.
      final missing = find.byKey(
        const ValueKey<String>('trending-desktop-row-rank-2'),
      );
      expect(
        find.descendant(of: missing, matching: find.text('Not on Server')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: missing,
          matching: find.byIcon(Icons.search_rounded),
        ),
        findsOneWidget,
      );
      // Matched and unmatched rows reserve the same action column, so the
      // Artist column starts at one x on every row.
      expect(
        tester
            .getTopLeft(
              find.descendant(of: row, matching: find.text('Chart Artist')),
            )
            .dx,
        tester
            .getTopLeft(
              find.descendant(of: missing, matching: find.text('Chart Artist')),
            )
            .dx,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();

      final queue = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      ).read(queueProvider.notifier) as _QueueSpyController;
      expect(queue.lastReplaceIds, <String>[
        for (var i = 1; i <= 8; i++) 'chart-$i',
      ]);
      expect(queue.lastStartIndex, 1);
      expect(queue.lastExpandMatchFlows, isFalse);
    },
  );

  testWidgets('every kind of hero item renders in the desktop strip', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 900));
    await _pumpRandomSectionHome(
      tester,
      database: database,
      randomAlbums: <HomeRandomShowcaseItem>[
        HomeRandomShowcaseListenBrainz(
          playlist: _listenBrainzPlaylist('jams', 'Weekly Jams'),
        ),
        _trending(),
        const HomeRandomShowcaseAlbum(
          id: 'album',
          name: 'Album',
          source: HomeRandomShowcaseSource.serverRandom,
        ),
      ],
      forceDesktop: true,
    );

    for (var index = 0; index < 3; index++) {
      expect(
        find.byKey(ValueKey<String>('home-random-desktop-mini-cover-$index')),
        findsOneWidget,
      );
    }
    await tester.tap(
      find.byKey(const ValueKey<String>('home-random-desktop-mini-cover-1')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('trending-desktop-row-chart-1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows determinate sync ring around logo while syncing', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
        processed: 3,
        total: 10,
      ),
      database,
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(
      find.byKey(const ValueKey<String>('homeLibrarySyncStatus')),
      findsNothing,
    );
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, closeTo(0.3, 0.001));
    expect(
      tester.getCenter(find.byKey(const ValueKey<String>('home-sync-logo'))),
      tester.getCenter(ring),
    );

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    expect(
      find.bySemanticsLabel(l10n.librarySyncRunningWithProgress(3, 10)),
      findsOneWidget,
    );
  });

  testWidgets(
    'keeps the Home sync ring indeterminate while scanning the song index',
    (tester) async {
      await _pumpHomeWithSyncState(
        tester,
        const LibrarySyncState(
          status: LibrarySyncStatus.running,
          stage: LibrarySyncStage.fetchingSongs,
          metadataReady: true,
          fastPathActive: true,
          songIndexEntriesScanned: 50000,
          processed: 0,
          total: 301,
        ),
        database,
      );

      final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
      expect(ring, findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(ring).value, isNull);
    },
  );

  testWidgets('home logo and sync ring use exact safe brand accent', (
    tester,
  ) async {
    const selectedAccent = Color(0xFF005BBB);
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
      ),
      database,
      theme: buildLightTheme(selectedAccent),
    );

    final context = tester.element(find.byType(HomeScreen));
    final accent = NavisAccentColors.of(context);
    final icon = tester.widget<NavisIcon>(find.byType(NavisIcon).first);
    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(
      find.byKey(const ValueKey<String>('homeLibrarySyncStatus')),
      findsNothing,
    );
    final indicator = tester.widget<CircularProgressIndicator>(ring);

    expect(icon.tintWithAccent, isTrue);
    expect(icon.tintColor, isNull);
    expect(accent.brand, selectedAccent);
    expect(indicator.color, selectedAccent);
    expect(indicator.backgroundColor, selectedAccent.withValues(alpha: 0.14));
  });

  testWidgets('unsafe white-on-light brand accent falls back visibly', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
      ),
      database,
      theme: buildLightTheme(defaultColorSchemeSeedColor),
    );

    final context = tester.element(find.byType(HomeScreen));
    final accent = NavisAccentColors.of(context);
    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    final indicator = tester.widget<CircularProgressIndicator>(ring);

    expect(accent.source, defaultColorSchemeSeedColor);
    expect(accent.brand, isNot(defaultColorSchemeSeedColor));
    expect(indicator.color, accent.brand);
  });

  testWidgets('shows indeterminate sync ring when progress is unknown', (
    tester,
  ) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.preparing,
      ),
      database,
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(
      find.byKey(const ValueKey<String>('homeLibrarySyncStatus')),
      findsNothing,
    );
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, isNull);

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    expect(find.bySemanticsLabel(l10n.librarySyncRunning), findsOneWidget);
  });

  testWidgets('shows subtle failure ring on sync failure', (tester) async {
    await _pumpHomeWithSyncState(
      tester,
      const LibrarySyncState(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.completed,
      ),
      database,
    );

    final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
    expect(ring, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.value, 1);

    final context = tester.element(find.byType(HomeScreen));
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    expect(indicator.color, theme.colorScheme.error.withValues(alpha: 0.65));
    expect(
      find.bySemanticsLabel(l10n.syncSettingsStatusFailed),
      findsOneWidget,
    );
  });

  testWidgets('hides sync ring when idle, succeeded, or skipped', (
    tester,
  ) async {
    final states = <LibrarySyncState>[
      const LibrarySyncState.idle(),
      const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      ),
      const LibrarySyncState(
        status: LibrarySyncStatus.skipped,
        stage: LibrarySyncStage.completed,
      ),
    ];

    for (final state in states) {
      await _pumpHomeWithSyncState(tester, state, database);
      final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
      expect(ring, findsOneWidget);
      final ringOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: ring, matching: find.byType(AnimatedOpacity)),
      );
      expect(ringOpacity.opacity, 0);
    }
  });

  testWidgets(
    'shows immediate indeterminate ring when pull-to-refresh triggers before sync state updates',
    (tester) async {
      if (isDesktopRuntime) {
        // Home custom pull-to-refresh is mobile/tablet-only.
        return;
      }
      final controller = _PendingRefreshLibrarySyncController();
      await _pumpHomeWithControllerOverride(
        tester,
        createController: () => controller,
        database: database,
      );

      await tester.drag(find.byType(ListView).first, const Offset(0, 340));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(controller.syncNowCalls, 1);
      final ring = find.byKey(const ValueKey<String>('home-sync-ring'));
      expect(ring, findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(ring);
      expect(indicator.value, isNull);

      final ringOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: ring, matching: find.byType(AnimatedOpacity)),
      );
      expect(ringOpacity.opacity, 1);

      controller.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      final ringOpacityAfter = tester.widget<AnimatedOpacity>(
        find.ancestor(of: ring, matching: find.byType(AnimatedOpacity)),
      );
      expect(ringOpacityAfter.opacity, 0);
    },
  );

  testWidgets('pull to refresh runs New Releases and Trending again', (
    tester,
  ) async {
    var trendingRuns = 0;
    var newReleasesRuns = 0;
    final updateStore = _PullUpdateStore();
    await _pumpHomeWithAppSettings(
      tester,
      database: database,
      overrides: <Override>[
        updateCheckStoreProvider.overrideWithValue(updateStore),
        homeTrendingProvider.overrideWith((ref) {
          ref.watch(homeTrendingRefreshProvider);
          trendingRuns++;
          return Stream.value(const <ResolvedArtistTopTrack>[]);
        }),
        homeNewReleasesProvider.overrideWith((ref) async {
          newReleasesRuns++;
          return const <HomeNewRelease>[];
        }),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    // The hero reads Trending; this test's hero is a fixed value.
    final subscription = container.listen(homeTrendingProvider, (_, _) {});
    addTearDown(subscription.close);
    await tester.pumpAndSettle();
    expect(trendingRuns, 1);
    expect(newReleasesRuns, 1);

    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(trendingRuns, 2);
    // A pull to refresh is a manual Trending refresh.
    expect(container.read(homeTrendingRefreshProvider).manual, isTrue);
    expect(newReleasesRuns, 2);
    expect(updateStore.forces.last, isTrue);
  });

  test('Trending keeps every chart song and indexes the playable ones', () {
    final trending = HomeRandomShowcaseTrending(
      tracks: const <ResolvedArtistTopTrack>[
        ResolvedArtistTopTrack(
          rank: 1,
          title: 'One',
          artist: 'A',
          resolvedSong: Song(id: 's1', title: 'One'),
        ),
        ResolvedArtistTopTrack(rank: 2, title: 'Gone', artist: 'A'),
        ResolvedArtistTopTrack(
          rank: 3,
          title: 'Three',
          artist: 'A',
          resolvedSong: Song(id: 's3', title: 'Three'),
        ),
      ],
    );
    expect(trending.tracks.map((track) => track.rank), <int>[1, 2, 3]);
    expect(trending.entries.map((entry) => entry.rank), <int>[1, 3]);
    expect(trending.songs.map((song) => song.id), <String>['s1', 's3']);
  });

  group('server album card shade', () {
    const album = Album(
      id: 'album-1',
      name: 'A very long album title that must stay on one line',
      artist: 'Artist',
      coverArt: 'cover-1',
    );

    Future<void> pumpRecentlyAdded(
      WidgetTester tester, {
      required AlbumTitleShade mode,
      bool flat = false,
    }) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: <Override>[
              appSettingsProvider.overrideWithValue(
                AsyncData(
                  const AppSettingsModel.defaults().copyWith(
                    homeSectionOrder: const <String>[
                      HomeSectionIds.recentlyAdded,
                    ],
                    homeSectionsHidden: _hiddenExcept(const <String>[
                      HomeSectionIds.recentlyAdded,
                    ]),
                  ),
                ),
              ),
              albumTitleShadeModeProvider.overrideWithValue(mode),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
              librarySyncControllerProvider.overrideWith(
                _StaticLibrarySyncController.new,
              ),
              homeRecentlyAddedProvider.overrideWithValue(
                const AsyncData(<Album>[album]),
              ),
              homeRecentlyPlayedAlbumsProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
              homeLikedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              homeRandomShowcaseProvider.overrideWith(
                (ref, filters) => const AsyncData(<HomeRandomShowcaseItem>[]),
              ),
              homeMostPlayedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedAlbumsRecentProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
            ],
          ),
          child: MaterialApp(
            theme: testTheme(buildDarkTheme(Colors.teal, flat: flat)),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    Finder key(String name) => find.byKey(ValueKey<String>(name));

    testWidgets('classic puts white text on the see-through style scrim', (
      tester,
    ) async {
      await pumpRecentlyAdded(tester, mode: AlbumTitleShade.classic);

      expect(key('albumCardDarkShade'), findsOneWidget);
      expect(key('albumCardTitleSurfaceFade'), findsNothing);
      expect(key('albumCardTintText'), findsNothing);
      expect(key('albumCardCaptionLayer'), findsNothing);
      expect(key('albumCardCaptionBelow'), findsNothing);
      final title = tester.widget<Text>(find.text(album.name));
      expect(title.style!.color!.a, greaterThan(0.9));
      expect(title.style!.color!.r, 1);
    });

    testWidgets('dark uses the staged page-colour shade', (tester) async {
      await pumpRecentlyAdded(tester, mode: AlbumTitleShade.dark);

      expect(key('albumCardTintFade'), findsOneWidget);
      expect(key('albumCardTintText'), findsOneWidget);
      expect(key('albumCardDarkShade'), findsNothing);
      expect(key('albumCardTitleSurfaceFade'), findsNothing);
      expect(key('albumCardCaptionLayer'), findsNothing);
    });

    testWidgets('color uses the cover-tinted caption layer', (tester) async {
      await pumpRecentlyAdded(tester, mode: AlbumTitleShade.color);

      expect(key('albumCardCaptionLayer'), findsOneWidget);
      expect(key('albumCardDarkShade'), findsNothing);
    });

    testWidgets('a long title is one scrolling line', (tester) async {
      await pumpRecentlyAdded(tester, mode: AlbumTitleShade.dark);

      expect(find.byType(MarqueeText), findsOneWidget);
      final title = tester.widget<Text>(find.text(album.name));
      expect(title.maxLines, 1);
      expect(title.softWrap, isFalse);
    });

    testWidgets('Flat text over artwork moves the title below the cover', (
      tester,
    ) async {
      await pumpRecentlyAdded(tester, mode: AlbumTitleShade.dark, flat: true);

      final caption = key('albumCardCaptionBelow');
      expect(caption, findsOneWidget);
      expect(key('albumCardDarkShade'), findsNothing);
      final cover = tester.getRect(
        find.descendant(
          of: find.byType(AlbumCardCaptionLayout),
          matching: find.byType(CoverArtImage),
        ),
      );
      expect(tester.getRect(caption).top, closeTo(cover.bottom, 0.01));
      expect(tester.takeException(), isNull);
    });
  });

  group('HomeSectionIds', () {
    test('defaultOrder contains all section IDs', () {
      expect(
        HomeSectionIds.defaultOrder,
        containsAll(<String>[
          HomeSectionIds.recentlyLikedAlbums,
          HomeSectionIds.likedTracks,
          HomeSectionIds.recentlyAdded,
          HomeSectionIds.recentlyPlayed,
          HomeSectionIds.randomAlbums,
          HomeSectionIds.mostPlayed,
          HomeSectionIds.recentlyPlayedTracks,
          HomeSectionIds.frequentAlbums,
        ]),
      );
      // quickActions is no longer a section — it's always-visible chips below
      // the home logo.
      expect(
        HomeSectionIds.defaultOrder,
        isNot(contains(HomeSectionIds.quickActions)),
      );
    });

    test('random albums is first in defaultOrder', () {
      expect(HomeSectionIds.defaultOrder.first, HomeSectionIds.randomAlbums);
    });

    test('defaultOrder has no duplicates', () {
      expect(
        HomeSectionIds.defaultOrder.toSet().length,
        HomeSectionIds.defaultOrder.length,
      );
    });

    test('defaultHidden marks optional sections as hidden', () {
      expect(
        HomeSectionIds.defaultHidden,
        containsAll(<String>[
          HomeSectionIds.recentlyPlayedTracks,
          HomeSectionIds.frequentAlbums,
        ]),
      );
      expect(
        HomeSectionIds.defaultHidden,
        isNot(contains(HomeSectionIds.quickActions)),
      );
    });
  });
}

const ChangelogVersion _majorRelease = ChangelogVersion(
  version: '9.9.0',
  codename: 'Aurora',
  entries: <ChangelogEntry>[
    ChangelogEntry(
      'Album navigation is now smoother and more reliable.',
      type: ChangelogEntryType.newFeature,
    ),
  ],
  highlights: <ChangelogHighlight>[
    ChangelogHighlight(
      icon: ChangelogHighlightIcon.equalizer,
      title: 'Equalizer',
      body: 'Shape the sound',
    ),
    ChangelogHighlight(
      icon: ChangelogHighlightIcon.speed,
      title: 'Speed and pitch',
      body: 'Precise control',
    ),
    ChangelogHighlight(
      icon: ChangelogHighlightIcon.headphones,
      title: 'AutoEQ',
      body: 'Headphone Profiles',
    ),
    ChangelogHighlight(
      icon: ChangelogHighlightIcon.performance,
      title: 'Faster',
      body: 'Big libraries',
    ),
  ],
);

class _PullUpdateStore extends UpdateCheckStore {
  @override
  Future<bool> selectSource(String identity) async => false;

  final forces = <bool>[];
  @override
  Future<bool> shouldCheck({bool force = false}) async {
    forces.add(force);
    return false;
  }
}

class _DismissUpdateStore extends UpdateCheckStore {
  @override
  Future<bool> selectSource(String identity) async => false;

  String? dismissed;
  @override
  Future<String?> readDismissedUpdate() async => dismissed;
  @override
  Future<void> recordDismissedUpdate(String identity) async =>
      dismissed = identity;
}
