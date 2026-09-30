import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _FakeLibrarySyncController extends LibrarySyncController {
  _FakeLibrarySyncController(
    this._initialState, {
    this.onSyncNow,
    this.onCancel,
    this.onTargetIfStale,
  });

  final LibrarySyncState _initialState;
  final VoidCallback? onSyncNow;
  final VoidCallback? onCancel;
  final void Function(LibrarySyncTarget target)? onTargetIfStale;

  @override
  LibrarySyncState build() => _initialState;

  @override
  Future<LibrarySyncState> syncIfStale() async => _initialState;

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async {
    onSyncNow?.call();
    return _initialState;
  }

  @override
  Future<LibrarySyncState> requestTargetIfStale(
    LibrarySyncTarget target,
  ) async {
    onTargetIfStale?.call(target);
    return _initialState;
  }

  @override
  void cancelSync() => onCancel?.call();
}

class _ShowRadioToggle extends Notifier<bool> {
  @override
  bool build() => true;
}

class _DownloadedOnlyEnabledController extends DownloadedOnlyFilterController {
  @override
  bool build() => true;
}

class _QueueSpyController extends QueueController {
  List<String>? lastReplaceIds;
  int? lastStartIndex;
  bool? lastAutoPlay;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async {
    lastReplaceIds = songs.map((song) => song.id).toList(growable: false);
    lastStartIndex = startIndex;
    lastAutoPlay = autoPlay;
    state = List<String>.unmodifiable(lastReplaceIds!);
  }
}

AlbumsTableData _likedAlbum({
  required String id,
  required String name,
  String artistName = 'Artist',
}) {
  return AlbumsTableData(
    isProvisional: false,
    isExternal: false,
    id: id,
    name: name,
    artistName: artistName,
    songsHydrated: true,
    artists: const <ArtistRef>[],
  );
}

SongsTableData _likedSong({
  required String id,
  required String title,
  required String albumId,
  String artistName = 'Artist',
  String albumName = 'Album',
  int track = 1,
}) {
  return SongsTableData(
    isProvisional: false,
    isExternal: false,
    id: id,
    title: title,
    albumId: albumId,
    artistName: artistName,
    albumName: albumName,
    track: track,
    duration: 210,
    coverArt: 'cover-$albumId',
  );
}

ListenBrainzDiscoverPlaylist _virtualPlaylist({
  required String identifier,
  required String title,
  required String sourcePatch,
  List<String> coverArts = const <String>[],
}) {
  return ListenBrainzDiscoverPlaylist(
    playlist: ListenBrainzPlaylist(
      identifier: identifier,
      title: title,
      sourcePatch: sourcePatch,
      tracks: <ListenBrainzPlaylistTrack>[
        ListenBrainzPlaylistTrack(title: '$title Track'),
      ],
    ),
    recommendations: coverArts.isEmpty
        ? <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: '$title Track'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ]
        : <ListenBrainzResolvedRecommendation>[
            for (var i = 0; i < coverArts.length; i++)
              ListenBrainzResolvedRecommendation(
                track: ListenBrainzPlaylistTrack(title: '$title Track $i'),
                status: ListenBrainzRecommendationMatchStatus.matched,
                song: Song(
                  id: '$identifier-$i',
                  title: '$title Track $i',
                  coverArt: coverArts[i],
                ),
              ),
          ],
    matchingComplete: true,
  );
}

Widget _buildLibraryScreen({
  required List<Object?> overrides,
  bool showPlaylistsPage = false,
  bool desktopIconsOnly = false,
  TextScaler? textScaler,
  String artistViewMode = 'list',
  AdaptiveContext? adaptiveContext,
}) {
  return ProviderScope(
    overrides: withTestDatabase(
      _testDatabase,
      overrides: [
        showRadioPageProvider.overrideWithValue(false),
        showArtistsPageProvider.overrideWithValue(true),
        showPlaylistsPageProvider.overrideWithValue(showPlaylistsPage),
        artistViewModeProvider.overrideWithValue(artistViewMode),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData<ServerConfigModel?>(null),
        ),
        subsonicApiProvider.overrideWithValue(null),
        ...overrides.cast(),
      ],
    ),
    child: MaterialApp(
      theme: testTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: adaptiveContext == null
          ? null
          : (context, child) => AdaptiveContextScope(
              adaptiveContext: adaptiveContext,
              child: child!,
            ),
      home: DesktopNavigationPresentationScope(
        iconsOnly: desktopIconsOnly,
        child: Builder(
          builder: (context) => textScaler == null
              ? const LibraryScreen()
              : MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: textScaler,
                  ),
                  child: const LibraryScreen(),
                ),
        ),
      ),
    ),
  );
}

Widget _buildLibraryScreenRouter({
  required List<Object?> overrides,
  bool showPlaylistsPage = false,
  bool showRadioPage = false,
  bool showArtistsPage = true,
}) {
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => const LibraryScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'library/liked-artists',
            builder: (context, state) => const LikedArtistsAllScreen(),
          ),
          GoRoute(
            path: 'library/listenbrainz/:sourcePatch',
            builder: (context, state) => Text(
              'ListenBrainz detail ${state.pathParameters['sourcePatch']}',
            ),
          ),
          GoRoute(
            path: 'library/playlists/:playlistId',
            builder: (context, state) => Text(
              'Playlist detail ${state.pathParameters['playlistId']}',
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/settings/appearance',
        builder: (context, state) => const Text('Appearance settings'),
      ),
    ],
  );

  return ProviderScope(
    overrides: withTestDatabase(
      _testDatabase,
      overrides: [
        showRadioPageProvider.overrideWithValue(showRadioPage),
        showArtistsPageProvider.overrideWithValue(showArtistsPage),
        showPlaylistsPageProvider.overrideWithValue(showPlaylistsPage),
        artistViewModeProvider.overrideWithValue('list'),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData<ServerConfigModel?>(null),
        ),
        subsonicApiProvider.overrideWithValue(null),
        ...overrides.cast(),
      ],
    ),
    child: MaterialApp.router(
      theme: testTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

late NavisDatabase _testDatabase;

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

Future<void> _pumpLibraryScreen(
  WidgetTester tester, {
  required List<Object?> overrides,
  bool showPlaylistsPage = false,
  bool desktopIconsOnly = false,
  TextScaler? textScaler,
  bool settle = true,
  String artistViewMode = 'list',
  AdaptiveContext? adaptiveContext,
}) async {
  await tester.pumpWidget(
    _buildLibraryScreen(
      overrides: overrides,
      showPlaylistsPage: showPlaylistsPage,
      desktopIconsOnly: desktopIconsOnly,
      textScaler: textScaler,
      artistViewMode: artistViewMode,
      adaptiveContext: adaptiveContext,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _switchToArtistsTab(WidgetTester tester) async {
  if (find.byKey(const Key('artistAlphabetRail')).evaluate().isNotEmpty) {
    return;
  }
  await tester.tap(find.text('Artists'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    _testDatabase = createTestDatabase();
  });

  _testWidgetsWithCleanup(
    'artist view toggle describes the view it will switch to',
    (tester) async {
      final artists = <ArtistsTableData>[
        ArtistsTableData(
          isProvisional: false,
          isExternal: false,
          id: 'artist-toggle-test',
          name: 'Toggle Artist',
          albumCount: 1,
        ),
      ];

      await _pumpLibraryScreen(
        tester,
        overrides: [
          artistsProvider.overrideWithValue(AsyncData(artists)),
          albumCountProvider.overrideWithValue(const AsyncData(0)),
          pagedAlbumsProvider.overrideWith(
            (ref, request) => Stream.value(const <AlbumsTableData>[]),
          ),
        ],
      );
      await _switchToArtistsTab(tester);

      expect(find.byTooltip('Switch to artist grid view'), findsOneWidget);

      await _pumpLibraryScreen(
        tester,
        artistViewMode: 'grid',
        overrides: [
          artistsProvider.overrideWithValue(AsyncData(artists)),
          albumCountProvider.overrideWithValue(const AsyncData(0)),
          pagedAlbumsProvider.overrideWith(
            (ref, request) => Stream.value(const <AlbumsTableData>[]),
          ),
        ],
      );
      await _switchToArtistsTab(tester);

      expect(find.byTooltip('Switch to artist list view'), findsOneWidget);
    },
  );

  tearDownAll(() async {
    await _testDatabase.close();
  });

  _testWidgetsWithCleanup(
    'disabled library pages offer a direct Appearance settings recovery',
    (tester) async {
      await tester.pumpWidget(
        _buildLibraryScreenRouter(
          overrides: <Object?>[
            showAlbumsPageProvider.overrideWithValue(false),
            showLikedPageProvider.overrideWithValue(false),
          ],
          showArtistsPage: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Library Pages Enabled'), findsOneWidget);
      final recovery = find.widgetWithText(
        FilledButton,
        'Open Appearance Settings',
      );
      expect(recovery, findsOneWidget);

      await tester.tap(recovery);
      await tester.pumpAndSettle();
      expect(find.text('Appearance settings'), findsOneWidget);
    },
  );

  group('LibraryScreen', () {
    _testWidgetsWithCleanup(
      'Liked artist See all works when Artists is hidden',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showArtistsPage: false,
            overrides: [
              showLikedPageProvider.overrideWithValue(true),
              likedArtistsProvider.overrideWithValue(
                const AsyncData([
                  ArtistsTableData(
                    id: 'hidden-artist',
                    name: 'Hidden page artist',
                    isExternal: false,
                    isProvisional: false,
                  ),
                ]),
              ),
              likedAlbumsRecentProvider.overrideWithValue(
                const AsyncData(<AlbumsTableData>[]),
              ),
              likedSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              likedAlbumSongsProvider.overrideWithValue(
                const AsyncData(<SongsTableData>[]),
              ),
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('See all'));
        await tester.pumpAndSettle();
        expect(find.byType(LikedArtistsAllScreen), findsOneWidget);
        expect(find.text('Hidden page artist'), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LikedArtistsAllScreen)),
        );
        expect(container.read(showArtistsPageProvider), isFalse);
      },
    );

    _testWidgetsWithCleanup(
      'Liked download filter finds an album after the former first six',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            downloadedOnlyFilterProvider.overrideWith(
              _DownloadedOnlyEnabledController.new,
            ),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData((
                albumIds: <String>{'later-liked-9'},
                artistIds: <String>{},
              )),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{}),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              AsyncData([
                for (var i = 0; i < 12; i++)
                  _likedAlbum(id: 'later-liked-$i', name: 'Recent album $i'),
              ]),
            ),
            likedArtistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
          ],
        );
        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();
        expect(find.text('Recent album 9'), findsOneWidget);
        expect(find.text('Recent album 0'), findsNothing);
        final shelf = tester.widget<ContentShelf>(
          find.byKey(const ValueKey('liked-albums-shelf')),
        );
        expect(shelf.itemCount, 1);
        expect(find.text('See all'), findsOneWidget);
      },
    );
    _testWidgetsWithCleanup(
      'diagnostics scrolls the selected Liked collection through its existing owner',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        final songs = List.generate(
          30,
          (i) => _likedSong(
            id: 'scroll-$i',
            title: 'Scrollable $i',
            albumId: 'album',
          ),
        );
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            likedAlbumsRecentProvider.overrideWithValue(const AsyncData([])),
            likedArtistsProvider.overrideWithValue(const AsyncData([])),
            likedSongsProvider.overrideWithValue(AsyncData(songs)),
          ],
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryScreen)),
        );
        container
            .read(librarySectionProvider.notifier)
            .setSection(LibrarySection.liked);
        await tester.pumpAndSettle();
        final scroll = container
            .read(libraryScrollDiagnosticsProvider.notifier)
            .scroll(500);
        await tester.pumpAndSettle();
        expect(await scroll, 500);
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'phone Liked has two compact shelves and songs within one swipe',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        final albums = List.generate(
          20,
          (i) => _likedAlbum(id: 'liked-$i', name: 'Liked album $i'),
        );
        final artists = List.generate(
          20,
          (i) => ArtistsTableData(
            isProvisional: false,
            isExternal: false,
            id: 'liked-artist-$i',
            name: 'Liked artist $i',
          ),
        );
        final song = _likedSong(
          id: 'first-liked-song',
          title: 'First liked song',
          albumId: 'liked-0',
        );
        await _pumpLibraryScreen(
          tester,
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: false,
            viewportSize: const Size(390, 844),
            safePadding: EdgeInsets.zero,
          ),
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(AsyncData(albums)),
            likedArtistsProvider.overrideWithValue(AsyncData(artists)),
            likedSongsProvider.overrideWithValue(AsyncData([song])),
            likedAlbumSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
          ],
        );
        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();
        final shelves = tester
            .widgetList<ContentShelf>(find.byType(ContentShelf))
            .toList();
        expect(shelves.length, 2);
        expect(shelves[0].extent, 80);
        expect(shelves[1].extent, 128);
        expect(shelves[0].showNextTooltip, isTrue);
        expect(shelves[1].showNextTooltip, isFalse);
        expect(shelves[1].itemCount, 6);
        final scroll = find.ancestor(
          of: find.text('First liked song'),
          matching: find.byType(CustomScrollView),
        );
        final start = tester.getRect(scroll).top;
        final firstSongTop = tester.getRect(find.text('First liked song')).top;
        final row = find.ancestor(
          of: find.text('First liked song'),
          matching: find.byType(AdaptiveTrackRow),
        );
        expect(tester.getSize(row).height, 64);
        final more = find.descendant(
          of: row,
          matching: find.byIcon(Icons.more_vert),
        );
        expect(tester.getRect(more).center.dy, tester.getRect(row).center.dy);
        expect(firstSongTop - start, lessThanOrEqualTo(440));
        expect(find.text('See all'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'underfilled album page loads a viewport buffer without scrolling',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(3440, 1440));
        final requests = <int>[];
        final albums = List.generate(
          240,
          (i) => _likedAlbum(id: 'album-$i', name: 'Album $i'),
        );
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(240)),
            pagedAlbumsProvider.overrideWith((ref, request) {
              requests.add(request.limit);
              return Stream.value(albums.take(request.limit).toList());
            }),
          ],
        );
        expect(requests.first, 60);
        expect(requests.length, greaterThan(1));
        expect(requests.toSet().length, requests.length);
        expect(requests.last, lessThanOrEqualTo(240));
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'album paging stops on error and retains the first page',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(3440, 1440));
        final requests = <int>[];
        final albums = List.generate(
          60,
          (i) => _likedAlbum(id: 'album-$i', name: 'Album $i'),
        );
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(240)),
            pagedAlbumsProvider.overrideWith((ref, request) {
              requests.add(request.limit);
              return request.limit == 60
                  ? Stream.value(albums)
                  : Stream.error(StateError('fixture failure'));
            }),
          ],
        );
        await tester.pump(const Duration(seconds: 1));
        expect(requests, [60, 120]);
        expect(find.text('Album 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'portrait phone Library keeps space above its tabs',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        final appBar = tester.widget<AppBar>(find.byType(AppBar));
        expect(appBar.toolbarHeight, 12);
        expect(
          tester.getRect(find.byType(TabBar)),
          const Rect.fromLTWH(0, 12, 390, 48),
        );
      },
    );

    _testWidgetsWithCleanup(
      'phone Library tabs and filters remain usable at 200 percent text scale',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        await _pumpLibraryScreen(
          tester,
          textScaler: const TextScaler.linear(2),
          showPlaylistsPage: true,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        expect(find.byType(TabBar), findsOneWidget);
        expect(find.text('Library'), findsNothing);
        expect(find.text('Albums'), findsOneWidget);
        expect(find.text('Downloaded'), findsOneWidget);
        expect(find.text('Recently Added'), findsOneWidget);
        final downloadedFilter = find.widgetWithText(
          FilterChip,
          'Downloaded',
        );
        final sortDropdown = find.byKey(
          const ValueKey<String>('libraryAlbumSortControl'),
        );
        expect(
          tester.getRect(sortDropdown).top,
          greaterThan(tester.getRect(downloadedFilter).bottom),
        );
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'phone landscape retains the Library title above its tabs',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(844, 390));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('Library'), findsOneWidget);
        expect(find.byType(TabBar), findsOneWidget);
      },
    );

    _testWidgetsWithCleanup(
      'desktop library uses the integrated workspace frame',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(1200, 900));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
          desktopIconsOnly: true,
        );

        expect(
          find.byKey(const ValueKey<String>('libraryDesktopWorkspaceToolbar')),
          findsOneWidget,
        );
        expect(find.text('Library'), findsOneWidget);
        expect(find.byType(DesktopPanel), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'desktop library omits a duplicate header with a labeled rail',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(1200, 900));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        expect(
          find.byKey(const ValueKey<String>('libraryDesktopWorkspaceToolbar')),
          findsNothing,
        );
        expect(find.byType(DesktopPanel), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'renders two tabs and switches between local data lists',
      (
        tester,
      ) async {
        var syncNowCalls = 0;
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onSyncNow: () => syncNowCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[
                ArtistsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'artist-1',
                  name: 'Artist 1',
                  albumCount: 1,
                ),
              ]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(1)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(
                const <AlbumsTableData>[
                  AlbumsTableData(
                    isProvisional: false,
                    isExternal: false,
                    id: 'album-1',
                    name: 'Album 1',
                    artistName: 'Artist 1',
                    songsHydrated: true,
                    artists: <ArtistRef>[],
                  ),
                ],
              ),
            ),
          ],
        );

        expect(find.text('Artists'), findsOneWidget);
        expect(find.text('Albums'), findsOneWidget);
        expect(find.text('Songs'), findsNothing);
        expect(find.text('Genres'), findsNothing);
        expect(find.text('Album 1'), findsOneWidget);

        await tester.tap(find.text('Artists'));
        await tester.pumpAndSettle();
        expect(find.text('Artist 1'), findsOneWidget);
        expect(syncNowCalls, 0);
      },
    );

    _testWidgetsWithCleanup('shows empty states across all tabs', (
      tester,
    ) async {
      await _pumpLibraryScreen(
        tester,
        overrides: [
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
          ),
          artistsProvider.overrideWithValue(
            const AsyncData(<ArtistsTableData>[]),
          ),
          albumCountProvider.overrideWithValue(const AsyncData(0)),
          pagedAlbumsProvider.overrideWith(
            (ref, request) => Stream.value(const <AlbumsTableData>[]),
          ),
        ],
      );

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No Albums Found'), findsOneWidget);

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('No Artists Found'), findsOneWidget);
    });

    _testWidgetsWithCleanup(
      'filtered-empty Library offers Show all and clears the active filter',
      (tester) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            downloadedOnlyFilterProvider.overrideWith(
              _DownloadedOnlyEnabledController.new,
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        expect(find.text('No Downloaded Content'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('libraryClearFiltersAction')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('libraryClearFiltersAction')),
        );
        await tester.pumpAndSettle();

        expect(find.text('No Albums Found'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('libraryClearFiltersAction')),
          findsNothing,
        );
      },
    );

    _testWidgetsWithCleanup(
      'shows error state and retry action triggers syncNow',
      (
        tester,
      ) async {
        var syncNowCalls = 0;
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onSyncNow: () => syncNowCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              AsyncError<List<ArtistsTableData>>(
                Exception('artists failed'),
                StackTrace.empty,
              ),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );

        await _switchToArtistsTab(tester);
        expect(find.byType(ErrorState), findsOneWidget);
        expect(find.text('Could Not Load Artists'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        expect(syncNowCalls, 1);
      },
    );

    _testWidgetsWithCleanup('pull-to-refresh dispatches syncNow', (
      tester,
    ) async {
      var syncNowCalls = 0;
      await _pumpLibraryScreen(
        tester,
        overrides: [
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(
              const LibrarySyncState.idle(),
              onSyncNow: () => syncNowCalls++,
            ),
          ),
          artistsProvider.overrideWithValue(
            const AsyncData(<ArtistsTableData>[
              ArtistsTableData(
                isProvisional: false,
                isExternal: false,
                id: 'artist-1',
                name: 'Artist 1',
                albumCount: 1,
              ),
            ]),
          ),
          albumCountProvider.overrideWithValue(const AsyncData(0)),
          pagedAlbumsProvider.overrideWith(
            (ref, request) => Stream.value(const <AlbumsTableData>[]),
          ),
          songsBySortProvider.overrideWith(
            (ref, sort) => Stream.value(const <SongsTableData>[]),
          ),
        ],
      );

      final refreshIndicator = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator).first,
      );
      await refreshIndicator.onRefresh();

      expect(syncNowCalls, 1);
    });

    _testWidgetsWithCleanup(
      'sync banner shows a live song-index reference without a progress bar',
      (
        tester,
      ) async {
        await _pumpLibraryScreen(
          tester,
          settle: false,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.fetchingSongs,
                  metadataReady: true,
                  fastPathActive: true,
                  songIndexEntriesScanned: 50000,
                  processed: 0,
                  total: 301,
                  pendingHydrationCount: 301,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );

        expect(
          find.text('Metadata ready. Scanning song index (50000 songs found)'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('library-sync-status-progress')),
          findsNothing,
        );
      },
    );

    _testWidgetsWithCleanup(
      'sync banner shows metadata-ready hydration progress',
      (
        tester,
      ) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.fetchingSongs,
                  metadataReady: true,
                  processed: 5,
                  total: 10,
                  pendingHydrationCount: 5,
                  hydrationThroughputAlbumsPerSecond: 2.5,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );

        expect(
          find.text(
            'Metadata ready. Fetching remaining album details (5/10, 5 remaining, 2.5 albums/s)',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('library-sync-status-banner')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(
                  const ValueKey<String>('library-sync-status-progress'),
                ),
              )
              .value,
          0.5,
        );
      },
    );

    _testWidgetsWithCleanup(
      'idle backlog renders a hydration pill while album details are missing',
      (tester) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                LibrarySyncState(
                  status: LibrarySyncStatus.idle,
                  stage: LibrarySyncStage.idle,
                  lastSyncedAt: DateTime(2026, 9, 21, 8),
                  pendingHydrationCount: 3,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );

        expect(
          find.byKey(const ValueKey<String>('library-sync-status-backlog')),
          findsOneWidget,
        );
        expect(
          find.text('Library synced, 3 albums are still loading details'),
          findsOneWidget,
        );
      },
    );

    _testWidgetsWithCleanup(
      'idle state without backlog shows no hydration pill',
      (tester) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                LibrarySyncState(
                  status: LibrarySyncStatus.idle,
                  stage: LibrarySyncStage.idle,
                  lastSyncedAt: DateTime(2026, 9, 21, 8),
                  pendingHydrationCount: 0,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );

        expect(
          find.byKey(const ValueKey<String>('library-sync-status-backlog')),
          findsNothing,
        );
      },
    );

    _testWidgetsWithCleanup(
      'sync banner keeps candidate discovery progress indeterminate',
      (tester) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.fetchingAlbums,
                  candidateGeneration: 4,
                  candidateStatus: 'collecting',
                  processed: 500,
                  total: 1000,
                ),
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
          settle: false,
        );

        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(
                  const ValueKey<String>('library-sync-status-progress'),
                ),
              )
              .value,
          isNull,
        );
      },
    );

    _testWidgetsWithCleanup(
      'running sync status strip exposes cancel action',
      (tester) async {
        var cancelCalls = 0;
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.running,
                  stage: LibrarySyncStage.preparing,
                ),
                onCancel: () => cancelCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
          settle: false,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('library-sync-status-cancel')),
        );
        expect(cancelCalls, 1);
      },
    );

    _testWidgetsWithCleanup(
      'failed sync status strip exposes retry action',
      (tester) async {
        var retryCalls = 0;
        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState(
                  status: LibrarySyncStatus.failed,
                  stage: LibrarySyncStage.completed,
                  errorMessage: 'Connection lost',
                ),
                onSyncNow: () => retryCalls++,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );

        expect(find.text('Last sync failed'), findsOneWidget);
        expect(find.text('Connection lost'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('library-sync-status-retry')),
        );
        await tester.pump();
        expect(retryCalls, 1);

        await tester.tap(
          find.byKey(const ValueKey<String>('library-sync-status-dismiss')),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('library-sync-status-banner')),
          findsNothing,
        );
      },
    );

    _testWidgetsWithCleanup(
      'artist alphabet rail drag jumps to later sections',
      (
        tester,
      ) async {
        final artists = <ArtistsTableData>[
          for (var i = 0; i < 26; i++)
            ArtistsTableData(
              isProvisional: false,
              isExternal: false,
              id: 'artist-$i',
              name: '${String.fromCharCode(65 + i)} Artist',
              albumCount: 1,
            ),
        ];

        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );
        await _switchToArtistsTab(tester);

        final rail = find.byKey(const Key('artistAlphabetRail'));
        final railTopLeft = tester.getTopLeft(rail);
        final railSize = tester.getSize(rail);
        final railCenterX = railTopLeft.dx + (railSize.width / 2);
        final start = Offset(railCenterX, railTopLeft.dy + 4);
        final end = Offset(
          railCenterX,
          railTopLeft.dy + railSize.height - 4,
        );

        final gesture = await tester.startGesture(start);
        await gesture.moveTo(end);
        await gesture.up();
        await tester.pumpAndSettle();

        final jumpedToLateSection =
            find.text('X Artist').evaluate().isNotEmpty ||
            find.text('Y Artist').evaluate().isNotEmpty ||
            find.text('Z Artist').evaluate().isNotEmpty;
        expect(jumpedToLateSection, isTrue);
      },
    );

    _testWidgetsWithCleanup(
      'artist alphabet rail shows scrub overlay while dragging',
      (
        tester,
      ) async {
        final artists = <ArtistsTableData>[
          for (var i = 0; i < 10; i++)
            ArtistsTableData(
              isProvisional: false,
              isExternal: false,
              id: 'artist-$i',
              name: '${String.fromCharCode(65 + i)} Artist',
              albumCount: 1,
            ),
        ];

        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );
        await _switchToArtistsTab(tester);

        final rail = find.byKey(const Key('artistAlphabetRail'));
        final railTopLeft = tester.getTopLeft(rail);
        final railSize = tester.getSize(rail);
        final railCenterX = railTopLeft.dx + (railSize.width / 2);
        final start = Offset(railCenterX, railTopLeft.dy + 4);

        final gesture = await tester.startGesture(start);
        await tester.pump();
        expect(find.byKey(const Key('artistAlphabetOverlay')), findsOneWidget);

        await gesture.moveBy(const Offset(0, 80));
        await tester.pump();
        expect(find.byKey(const Key('artistAlphabetOverlay')), findsOneWidget);

        await gesture.up();
        await tester.pump();
        expect(find.byKey(const Key('artistAlphabetOverlay')), findsNothing);
      },
    );

    _testWidgetsWithCleanup(
      'artist alphabet rail only shows available artist initials',
      (
        tester,
      ) async {
        final artists = <ArtistsTableData>[
          const ArtistsTableData(
            isProvisional: false,
            isExternal: false,
            id: 'artist-a',
            name: 'A Artist',
            albumCount: 1,
          ),
          const ArtistsTableData(
            isProvisional: false,
            isExternal: false,
            id: 'artist-m',
            name: 'M Artist',
            albumCount: 1,
          ),
        ];

        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            songsBySortProvider.overrideWith(
              (ref, sort) => Stream.value(const <SongsTableData>[]),
            ),
          ],
        );
        await _switchToArtistsTab(tester);

        expect(find.text('A'), findsWidgets);
        expect(find.text('M'), findsWidgets);
        expect(find.text('B'), findsNothing);
      },
    );

    _testWidgetsWithCleanup('manual artist scroll updates active rail letter', (
      tester,
    ) async {
      final artists = <ArtistsTableData>[
        for (var i = 0; i < 26; i++)
          ArtistsTableData(
            isProvisional: false,
            isExternal: false,
            id: 'artist-$i',
            name: '${String.fromCharCode(65 + i)} Artist',
            albumCount: 1,
          ),
      ];

      await _pumpLibraryScreen(
        tester,
        overrides: [
          librarySyncControllerProvider.overrideWith(
            () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
          ),
          artistsProvider.overrideWithValue(AsyncData(artists)),
          albumCountProvider.overrideWithValue(const AsyncData(0)),
          pagedAlbumsProvider.overrideWith(
            (ref, request) => Stream.value(const <AlbumsTableData>[]),
          ),
        ],
      );
      await _switchToArtistsTab(tester);

      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();

      final active = tester.widget<Text>(
        find.byKey(const Key('artistRailActiveLetter')),
      );
      expect(active.data, isNot('A'));
    });

    _testWidgetsWithCleanup(
      'tapping an artist rail letter jumps to its section',
      (
        tester,
      ) async {
        final artists = <ArtistsTableData>[
          for (var i = 0; i < 26; i++)
            ArtistsTableData(
              isProvisional: false,
              isExternal: false,
              id: 'artist-$i',
              name: '${String.fromCharCode(65 + i)} Artist',
              albumCount: 1,
            ),
        ];

        await _pumpLibraryScreen(
          tester,
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(AsyncData(artists)),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
          ],
        );
        await _switchToArtistsTab(tester);

        final rail = find.byKey(const Key('artistAlphabetRail'));
        final railM = find.descendant(of: rail, matching: find.text('M'));
        expect(railM, findsOneWidget);

        await tester.tap(railM);
        await tester.pumpAndSettle();

        final active = tester.widget<Text>(
          find.byKey(const Key('artistRailActiveLetter')),
        );
        expect(active.data, 'M');
        expect(find.text('M Artist'), findsWidgets);
      },
    );

    _testWidgetsWithCleanup('shows radio tab when enabled by settings', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            _testDatabase,
            overrides: [
              showRadioPageProvider.overrideWithValue(true),
              showArtistsPageProvider.overrideWithValue(true),
              showPlaylistsPageProvider.overrideWithValue(false),
              artistViewModeProvider.overrideWithValue('list'),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              radioStationsProvider.overrideWith(
                (ref) async => const <InternetRadioStation>[],
              ),
            ],
          ),
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Radio'), findsOneWidget);
    });

    _testWidgetsWithCleanup(
      'diagnostic Library filter reaches Radio and Show all stations restores it',
      (tester) async {
        final container = ProviderContainer(
          overrides: withTestDatabase(
            _testDatabase,
            overrides: [
              showRadioPageProvider.overrideWithValue(true),
              showArtistsPageProvider.overrideWithValue(true),
              showPlaylistsPageProvider.overrideWithValue(false),
              artistViewModeProvider.overrideWithValue('list'),
              serverConfigStateProvider.overrideWithValue(
                const AsyncData<ServerConfigModel?>(null),
              ),
              subsonicApiProvider.overrideWithValue(null),
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              radioStationsProvider.overrideWith(
                (ref) async => const <InternetRadioStation>[
                  InternetRadioStation(
                    id: 'radio-test',
                    name: 'Navis Test Radio',
                    streamUrl: 'https://example.com/radio',
                  ),
                ],
              ),
            ],
          ),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: testTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LibraryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Radio'));
        await tester.pumpAndSettle();
        container
            .read(libraryTypeFilterDiagnosticsProvider.notifier)
            .setQuery('lofi');
        await tester.pumpAndSettle();

        expect(find.text('No Stations Match \u201clofi\u201d'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('radioClearTypeFilterAction')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Navis Test Radio'), findsOneWidget);

        await tester.tap(find.text('Artists'));
        await tester.pumpAndSettle();
        container
            .read(libraryTypeFilterDiagnosticsProvider.notifier)
            .setQuery('guest');
        await tester.pumpAndSettle();

        expect(find.text('No results for "guest"'), findsOneWidget);
        expect(find.text('Filtering: "guest"'), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      },
    );

    _testWidgetsWithCleanup(
      'playlists tab renders ListenBrainz playlists before normal playlists with divider',
      (tester) async {
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showPlaylistsPage: true,
            overrides: [
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              playlistSyncProvider.overrideWith((ref) async {}),
              playlistLibraryItemsProvider.overrideWithValue(
                AsyncData<List<PlaylistLibraryItem>>(
                  <PlaylistLibraryItem>[
                    PlaylistLibraryItem.virtual(
                      _virtualPlaylist(
                        identifier: 'jams',
                        title: 'Weekly Jams',
                        sourcePatch: 'weekly-jams',
                      ),
                    ),
                    const PlaylistLibraryItem.normal(
                      PlaylistsTableData(
                        id: 'server-mix',
                        name: 'Server Mix',
                        songCount: 3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();

        expect(find.text('Weekly Jams'), findsOneWidget);
        expect(find.text('0 of 1 available · ListenBrainz'), findsOneWidget);
        expect(find.text('Server Mix'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('listenBrainzPlaylistDivider')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.text('Weekly Jams')).dy,
          lessThan(tester.getTopLeft(find.text('Server Mix')).dy),
        );
      },
    );

    _testWidgetsWithCleanup(
      'playlists tab omits ListenBrainz divider without following normal playlists',
      (tester) async {
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showPlaylistsPage: true,
            overrides: [
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              playlistSyncProvider.overrideWith((ref) async {}),
              playlistLibraryItemsProvider.overrideWithValue(
                AsyncData<List<PlaylistLibraryItem>>(
                  <PlaylistLibraryItem>[
                    PlaylistLibraryItem.virtual(
                      _virtualPlaylist(
                        identifier: 'exploration',
                        title: 'Weekly Exploration',
                        sourcePatch: 'weekly-exploration',
                        coverArts: const <String>[
                          'cover-1',
                          'cover-2',
                          'cover-3',
                          'cover-4',
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();

        expect(find.text('Weekly Exploration'), findsOneWidget);
        expect(find.byType(ListenBrainzPlaylistArtwork), findsOneWidget);
        expect(find.byType(CoverArtImage), findsNWidgets(4));
        expect(
          find.byKey(const ValueKey<String>('listenBrainzPlaylistDivider')),
          findsNothing,
        );
      },
    );

    _testWidgetsWithCleanup(
      'desktop playlist More opens the anchored owner-action menu',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1366, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showPlaylistsPage: true,
            overrides: [
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              playlistSyncProvider.overrideWith((ref) async {}),
              playlistLibraryItemsProvider.overrideWithValue(
                const AsyncData<List<PlaylistLibraryItem>>(
                  <PlaylistLibraryItem>[
                    PlaylistLibraryItem.normal(
                      PlaylistsTableData(
                        id: 'server-mix',
                        name: 'Server Mix',
                        songCount: 3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();

        expect(find.text('Rename Playlist'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
      },
    );

    _testWidgetsWithCleanup(
      'playlists tab keeps ListenBrainz rows read-only',
      (tester) async {
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showPlaylistsPage: true,
            overrides: [
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              playlistSyncProvider.overrideWith((ref) async {}),
              playlistLibraryItemsProvider.overrideWithValue(
                AsyncData<List<PlaylistLibraryItem>>(
                  <PlaylistLibraryItem>[
                    PlaylistLibraryItem.virtual(
                      _virtualPlaylist(
                        identifier: 'jams',
                        title: 'Weekly Jams',
                        sourcePatch: 'weekly-jams',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();

        await tester.longPress(find.text('Weekly Jams'));
        await tester.pumpAndSettle();

        expect(find.text('Rename playlist'), findsNothing);
        expect(find.text('Delete playlist?'), findsNothing);
      },
    );

    _testWidgetsWithCleanup(
      'playlists tab navigates ListenBrainz rows to detail',
      (tester) async {
        await tester.pumpWidget(
          _buildLibraryScreenRouter(
            showPlaylistsPage: true,
            overrides: [
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              playlistSyncProvider.overrideWith((ref) async {}),
              playlistLibraryItemsProvider.overrideWithValue(
                AsyncData<List<PlaylistLibraryItem>>(
                  <PlaylistLibraryItem>[
                    PlaylistLibraryItem.virtual(
                      _virtualPlaylist(
                        identifier: 'jams',
                        title: 'Weekly Jams',
                        sourcePatch: 'weekly-jams',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Weekly Jams'));
        await tester.pumpAndSettle();

        expect(find.text('ListenBrainz detail weekly-jams'), findsOneWidget);
      },
    );

    _testWidgetsWithCleanup(
      'removing radio tab while selected clamps tab index without crashing',
      (tester) async {
        final showRadioToggleProvider =
            NotifierProvider<_ShowRadioToggle, bool>(
              _ShowRadioToggle.new,
            );
        final container = ProviderContainer(
          overrides: withTestDatabase(
            _testDatabase,
            overrides: [
              showRadioPageProvider.overrideWith(
                (ref) => ref.watch(showRadioToggleProvider),
              ),
              showArtistsPageProvider.overrideWithValue(true),
              showPlaylistsPageProvider.overrideWithValue(false),
              librarySyncControllerProvider.overrideWith(
                () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
              ),
              artistsProvider.overrideWithValue(
                const AsyncData(<ArtistsTableData>[]),
              ),
              albumCountProvider.overrideWithValue(const AsyncData(0)),
              pagedAlbumsProvider.overrideWith(
                (ref, request) => Stream.value(const <AlbumsTableData>[]),
              ),
              radioStationsProvider.overrideWith(
                (ref) async => const <InternetRadioStation>[],
              ),
            ],
          ),
        );
        addTearDown(container.dispose);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: testTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LibraryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Radio'), findsOneWidget);

        await tester.tap(find.text('Radio'));
        await tester.pumpAndSettle();

        container.read(showRadioToggleProvider.notifier).state = false;
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text('Radio'), findsNothing);
        expect(find.text('Artists'), findsOneWidget);
        expect(find.text('Albums'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    _testWidgetsWithCleanup(
      'opening Liked reads local data without requesting stale synchronization',
      (
        tester,
      ) async {
        final staleTargetRequests = <LibrarySyncTarget>[];
        setAdaptiveTestViewport(tester, const Size(700, 1200));
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(
                const LibrarySyncState.idle(),
                onTargetIfStale: staleTargetRequests.add,
              ),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            likedAlbumsProvider.overrideWithValue(
              const AsyncData(<AlbumsTableData>[]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[
                SongsTableData(
                  isProvisional: false,
                  isExternal: false,
                  id: 'liked-song-1',
                  title: 'Desktop Liked Song',
                  artistName: 'Desktop Artist',
                  albumName: 'Desktop Album',
                  duration: 245,
                ),
              ]),
            ),
          ],
        );

        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();

        expect(staleTargetRequests, isEmpty);

        expect(find.byType(TrackListTile), findsOneWidget);
        expect(find.byType(DesktopListRow), findsNothing);
        final compactMoreButton = find.ancestor(
          of: find.descendant(
            of: find.byType(TrackListTile),
            matching: find.byIcon(Icons.more_vert),
          ),
          matching: find.byType(IconButton),
        );
        expect(
          tester.widget<IconButton>(compactMoreButton).tooltip,
          MaterialLocalizations.of(
            tester.element(compactMoreButton),
          ).showMenuTooltip,
        );

        tester.view.physicalSize = const Size(1200, 1200);
        await tester.pumpAndSettle();

        expect(find.byType(TrackListTile), findsOneWidget);
        expect(find.byType(DesktopListRow), findsNothing);
        expect(find.text('Desktop Liked Song'), findsOneWidget);
        final desktopMoreButton = find.ancestor(
          of: find.descendant(
            of: find.byType(TrackListTile),
            matching: find.byIcon(Icons.more_horiz_rounded),
          ),
          matching: find.byType(IconButton),
        );
        expect(
          tester.widget<IconButton>(desktopMoreButton).tooltip,
          'More',
        );
        await tester.tap(desktopMoreButton);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Play now'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.tapAt(const Offset(8, 8));
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    _testWidgetsWithCleanup(
      'liked tab play renders and queues songs from liked albums only',
      (
        tester,
      ) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            queueProvider.overrideWith(_QueueSpyController.new),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            likedArtistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-1', name: 'Liked Album 1'),
              ]),
            ),
            likedAlbumsProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-1', name: 'Liked Album 1'),
              ]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumSongsProvider.overrideWithValue(
              AsyncData(<SongsTableData>[
                _likedSong(
                  id: 'album-song-1',
                  title: 'Album Song 1',
                  albumId: 'liked-album-1',
                  albumName: 'Liked Album 1',
                  track: 1,
                ),
                _likedSong(
                  id: 'album-song-2',
                  title: 'Album Song 2',
                  albumId: 'liked-album-1',
                  albumName: 'Liked Album 1',
                  track: 2,
                ),
              ]),
            ),
          ],
        );

        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Shuffle'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Play'));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryScreen)),
        );
        final queueSpy =
            container.read(queueProvider.notifier) as _QueueSpyController;
        expect(queueSpy.lastReplaceIds, <String>[
          'album-song-1',
          'album-song-2',
        ]);
        expect(queueSpy.lastStartIndex, 0);
        expect(queueSpy.lastAutoPlay, isTrue);
      },
    );

    _testWidgetsWithCleanup(
      'liked song tap queues combined deduplicated liked playback list',
      (
        tester,
      ) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            albumQueueEnabledProvider.overrideWithValue(true),
            likedQueueEnabledProvider.overrideWithValue(true),
            queueProvider.overrideWith(_QueueSpyController.new),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            likedArtistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-overlap', name: 'Overlap Album'),
              ]),
            ),
            likedAlbumsProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-overlap', name: 'Overlap Album'),
              ]),
            ),
            likedSongsProvider.overrideWithValue(
              AsyncData(<SongsTableData>[
                _likedSong(
                  id: 'liked-song-1',
                  title: 'Visible Song',
                  albumId: 'liked-album-overlap',
                  albumName: 'Overlap Album',
                  track: 1,
                ),
                _likedSong(
                  id: 'shared-song',
                  title: 'Shared Song',
                  albumId: 'liked-album-overlap',
                  albumName: 'Overlap Album',
                  track: 2,
                ),
              ]),
            ),
            likedAlbumSongsProvider.overrideWithValue(
              AsyncData(<SongsTableData>[
                _likedSong(
                  id: 'shared-song',
                  title: 'Shared Song',
                  albumId: 'liked-album-overlap',
                  albumName: 'Overlap Album',
                  track: 2,
                ),
                _likedSong(
                  id: 'album-only-song',
                  title: 'Album Only Song',
                  albumId: 'liked-album-overlap',
                  albumName: 'Overlap Album',
                  track: 3,
                ),
              ]),
            ),
          ],
        );

        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shared Song'));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryScreen)),
        );
        final queueSpy =
            container.read(queueProvider.notifier) as _QueueSpyController;
        expect(
          queueSpy.lastReplaceIds,
          <String>['liked-song-1', 'shared-song', 'album-only-song'],
        );
        expect(queueSpy.lastStartIndex, 1);
        expect(queueSpy.lastAutoPlay, isTrue);
      },
    );

    _testWidgetsWithCleanup(
      'liked shuffle respects downloaded-only filtering for liked album tracks',
      (
        tester,
      ) async {
        await _pumpLibraryScreen(
          tester,
          overrides: [
            showLikedPageProvider.overrideWithValue(true),
            downloadedOnlyFilterProvider.overrideWith(
              _DownloadedOnlyEnabledController.new,
            ),
            queueProvider.overrideWith(_QueueSpyController.new),
            librarySyncControllerProvider.overrideWith(
              () => _FakeLibrarySyncController(const LibrarySyncState.idle()),
            ),
            artistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            albumCountProvider.overrideWithValue(const AsyncData(0)),
            pagedAlbumsProvider.overrideWith(
              (ref, request) => Stream.value(const <AlbumsTableData>[]),
            ),
            likedArtistsProvider.overrideWithValue(
              const AsyncData(<ArtistsTableData>[]),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{'downloaded-album-song'}),
            ),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData(
                (
                  albumIds: <String>{'liked-album-filter'},
                  artistIds: <String>{},
                ),
              ),
            ),
            likedAlbumsRecentProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-filter', name: 'Filtered Album'),
              ]),
            ),
            likedAlbumsProvider.overrideWithValue(
              AsyncData(<AlbumsTableData>[
                _likedAlbum(id: 'liked-album-filter', name: 'Filtered Album'),
              ]),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(<SongsTableData>[]),
            ),
            likedAlbumSongsProvider.overrideWithValue(
              AsyncData(<SongsTableData>[
                _likedSong(
                  id: 'downloaded-album-song',
                  title: 'Downloaded Album Song',
                  albumId: 'liked-album-filter',
                  albumName: 'Filtered Album',
                  track: 1,
                ),
                _likedSong(
                  id: 'stream-only-song',
                  title: 'Stream Only Song',
                  albumId: 'liked-album-filter',
                  albumName: 'Filtered Album',
                  track: 2,
                ),
              ]),
            ),
          ],
        );

        await tester.tap(find.text('Liked'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Shuffle'));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryScreen)),
        );
        final queueSpy =
            container.read(queueProvider.notifier) as _QueueSpyController;
        expect(queueSpy.lastReplaceIds, <String>['downloaded-album-song']);
      },
    );
  });
}
