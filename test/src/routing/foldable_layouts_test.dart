// Foldable and tablet layout fixes (issue #410, I27). The whole app is pumped
// at the sizes of the iPhone Duo (466x678 folded, 669x951 and 951x669
// unfolded) and of an iPad split view.
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/presentation/integrations_notice_card.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/app_shell.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../helpers/reachability_fakes.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

class _StaticLibrarySync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncNow({
    bool allowMeteredBroadOverride = false,
  }) async => const LibrarySyncState.idle();
}

class _NoopScrobble extends ScrobbleDispatchController {
  @override
  int build() => 0;
}

class _IdleDownloads extends Fake implements DownloadService {
  @override
  Stream<DownloadFolderProblem?> get folderChanges => Stream.value(null);

  @override
  Stream<DownloadFolderProblem> get folderNotices => const Stream.empty();
}

/// Covers never load, and the real manager's database is never opened.
class _NoCacheManager extends Fake implements CacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => StreamController<FileResponse>().stream;

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => null;

  @override
  Future<void> dispose() async {}
}

class _StaticBindings extends DesktopShortcutBindingsNotifier {
  @override
  Map<DesktopCommandAction, DesktopShortcutBinding?> build() =>
      defaultDesktopShortcutBindings();
}

const _playing = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2', 'song-3'],
  currentSongId: 'song-1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3, seconds: 30),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

typedef _Viewport = ({Size size, EdgeInsets padding});

// iPhone Duo: the folded cover with the status strip on its right edge, and
// the two unfolded orientations.
const _duoFolded = (
  size: Size(466, 678),
  padding: EdgeInsets.fromLTRB(0, 0, 84, 34),
);
const _duoPortrait = (
  size: Size(669, 951),
  padding: EdgeInsets.only(bottom: 34),
);
const _duoLandscape = (
  size: Size(951, 669),
  padding: EdgeInsets.only(bottom: 21),
);
// Unfolded landscape with the status strip on the right (I27b): the rail was
// 270 + 84 wide. The bottom inset is the measured home indicator band.
const _duoLandscapeStrip = (
  size: Size(951, 669),
  padding: EdgeInsets.fromLTRB(0, 0, 84, 34),
);
// A left notch or strip: the rail's background still runs to the screen edge.
const _duoLandscapeNotch = (
  size: Size(951, 669),
  padding: EdgeInsets.fromLTRB(48, 0, 0, 34),
);
const _phone = (
  size: Size(393, 852),
  padding: EdgeInsets.only(top: 59, bottom: 34),
);
const _phoneLandscape = (
  size: Size(844, 390),
  padding: EdgeInsets.fromLTRB(47, 0, 47, 21),
);
// Short landscape phones (I28): iPhone SE, a notched iPhone mini/X, and the
// Duo cover rotated with the status strip on a long edge.
const _phoneSE = (size: Size(667, 375), padding: EdgeInsets.zero);
const _phoneMiniNotch = (
  size: Size(812, 375),
  padding: EdgeInsets.fromLTRB(44, 0, 44, 21),
);
const _phoneLandscapeLarge = (
  size: Size(932, 430),
  padding: EdgeInsets.fromLTRB(59, 0, 59, 21),
);
const _duoCoverLandscapeBottomStrip = (
  size: Size(678, 466),
  padding: EdgeInsets.only(bottom: 118),
);
const _duoCoverLandscapeTopStrip = (
  size: Size(678, 466),
  padding: EdgeInsets.only(top: 84, bottom: 34),
);
// A narrow portrait phone: the Now Playing transport row is 302 dp wide.
const _phoneNarrowPortrait = (
  size: Size(350, 740),
  padding: EdgeInsets.only(top: 47, bottom: 34),
);
// On the rail-fit boundary: 500 - 34 - 44 = 422 < 436 with the home indicator,
// 456 without it (the keyboard drops padding.bottom, not viewPadding.bottom).
const _phoneBoundary = (
  size: Size(700, 500),
  padding: EdgeInsets.only(bottom: 34),
);
// iPad landscape with the rail: the Now Playing pane is 706 and 862 wide.
const _ipadLandscape = (
  size: Size(1024, 768),
  padding: EdgeInsets.only(bottom: 20),
);
const _ipadLandscapeLarge = (
  size: Size(1180, 820),
  padding: EdgeInsets.only(bottom: 20),
);
const _ipadSplitNarrow = (
  size: Size(507, 768),
  padding: EdgeInsets.only(bottom: 20),
);
const _ipadSplitWide = (
  size: Size(678, 1024),
  padding: EdgeInsets.only(bottom: 20),
);

const _artistNames = <String>[
  'Aphex Twin',
  'Beach House',
  'Bonobo',
  'Burial',
  'Caribou',
  'Four Tet',
  'Jon Hopkins',
  'Massive Attack',
  'Moonchild',
  'Nils Frahm',
  'Portishead',
  'Radiohead',
  'Sade',
  'Thom Yorke',
  'Tycho',
  'Zero 7',
];

Album _album(int i) => Album(
  id: 'album-$i',
  name: 'Moon Album $i',
  artist: _artistNames[i % _artistNames.length],
  artistId: 'artist-${i % _artistNames.length}',
  songCount: 12,
  year: 2000 + i,
  coverArt: 'cover-$i',
);

Future<NavisDatabase> _seed() async {
  final db = createTestDatabase();
  for (var a = 0; a < _artistNames.length; a++) {
    await db
        .into(db.artistsTable)
        .insert(
          ArtistsTableCompanion.insert(
            id: 'artist-$a',
            name: _artistNames[a],
            albumCount: const Value(3),
            starred: a < 10
                ? Value(DateTime(2026, 3, 1 + a))
                : const Value.absent(),
          ),
        );
  }
  for (var i = 0; i < 40; i++) {
    final album = _album(i);
    await db
        .into(db.albumsTable)
        .insert(
          AlbumsTableCompanion.insert(
            id: album.id,
            name: album.name,
            artistId: Value(album.artistId),
            artistName: Value(album.artist),
            year: Value(album.year),
            starred: i < 10
                ? Value(DateTime(2026, 1, 1 + i))
                : const Value.absent(),
            songCount: const Value(12),
            coverArt: Value(album.coverArt),
            songsHydrated: const Value(true),
          ),
        );
  }
  for (var s = 1; s <= 12; s++) {
    await db
        .into(db.songsTable)
        .insert(
          SongsTableCompanion.insert(
            id: 'song-$s',
            title: s == 1 ? 'Opening Track' : 'Moon Track $s',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
            artistName: const Value('Beach House'),
            albumName: const Value('Moon Album 1'),
            starred: Value(DateTime(2026, 2, s)),
            track: Value(s),
            duration: const Value(210),
            coverArt: const Value('cover-1'),
          ),
        );
  }
  for (var p = 0; p < 30; p++) {
    await db
        .into(db.playlistsTable)
        .insert(
          PlaylistsTableCompanion.insert(
            id: 'pl-$p',
            name: 'Playlist number $p',
            songCount: Value(8 + p),
          ),
        );
  }
  return db;
}

List<Override> _overrides(
  NavisDatabase db,
  PlaybackSnapshot? playback, {
  bool desktopRuntime = false,
}) => <Override>[
  navisDatabaseProvider.overrideWithValue(db),
  downloadServiceProvider.overrideWith((ref) => _IdleDownloads()),
  coverArtCacheManagerProvider.overrideWithValue(_NoCacheManager()),
  onboardingVersionProvider.overrideWithValue(
    const AsyncData(currentOnboardingVersion),
  ),
  changelogToShowProvider.overrideWith((ref) async => null),
  integrationsNoticeVisibleProvider.overrideWithValue(false),
  initialSyncRequiredProvider.overrideWithValue(const AsyncData(false)),
  desktopPresentationRuntimeProvider.overrideWithValue(desktopRuntime),
  networkTypeProvider.overrideWithValue(NetworkType.wifi),
  desktopShortcutBindingsProvider.overrideWith(_StaticBindings.new),
  serverConfigStateProvider.overrideWithValue(
    const AsyncData(
      ServerConfigModel(
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
    ),
  ),
  serverReachabilityControllerProvider.overrideWith(
    () => StaticReachabilityController(
      const ServerReachabilityState(status: ServerReachabilityStatus.online),
    ),
  ),
  librarySyncControllerProvider.overrideWith(_StaticLibrarySync.new),
  homeRecentlyPlayedProvider.overrideWithValue(
    const AsyncData(<SongsTableData>[]),
  ),
  homeRecentlyAddedProvider.overrideWithValue(
    AsyncData(<Album>[for (var i = 0; i < 10; i++) _album(i)]),
  ),
  homeFrequentAlbumsProvider.overrideWithValue(
    AsyncData(<Album>[for (var i = 10; i < 20; i++) _album(i)]),
  ),
  homeRandomAlbumsProvider.overrideWithValue(
    AsyncData(<Album>[for (var i = 20; i < 30; i++) _album(i)]),
  ),
  listenBrainzDiscoverStreamProvider.overrideWithValue(
    const AsyncData(<ListenBrainzDiscoverPlaylist>[]),
  ),
  artistInfoProvider.overrideWith((ref, artistId) async => null),
  scrobbleDispatchControllerProvider.overrideWith(_NoopScrobble.new),
  playbackSnapshotProvider.overrideWith(
    (ref) => playback == null
        ? Stream<PlaybackSnapshot>.value(const PlaybackSnapshot.idle())
        : Stream.value(playback),
  ),
  lyricsProvider.overrideWith(
    (ref, songId) async => const LyricsResolution(
      lyrics: LyricsList(),
      source: LyricsSource.serverPlain,
      instrumental: false,
    ),
  ),
  showPlaylistsPageProvider.overrideWithValue(true),
  showArtistsPageProvider.overrideWithValue(true),
  showRadioPageProvider.overrideWithValue(true),
];

void _setView(WidgetTester tester, _Viewport viewport) {
  const ratio = 3.0;
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = viewport.size * ratio;
  final pad = viewport.padding;
  final padding = FakeViewPadding(
    left: pad.left * ratio,
    top: pad.top * ratio,
    right: pad.right * ratio,
    bottom: pad.bottom * ratio,
  );
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
}

Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps the whole app at [viewport]; a null [playback] leaves the player idle.
Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  _Viewport viewport, {
  PlaybackSnapshot? playback = _playing,
  double textScale = 1,
  bool desktopRuntime = false,
  List<Override> extraOverrides = const <Override>[],
}) async {
  _setView(tester, viewport);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final db = (await tester.runAsync(_seed))!;
  final container = ProviderContainer(
    overrides: <Override>[
      ..._overrides(db, playback, desktopRuntime: desktopRuntime),
      ...extraOverrides,
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: testNavisApp),
  );
  await _settle(tester, 20);
  // The first frame is the sign-in route; its redirect needs a navigation.
  await _go(tester, AppRoutes.home);
  return container;
}

Future<void> _go(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
  await _settle(tester, 15);
}

Future<void> _resize(WidgetTester tester, _Viewport viewport) async {
  _setView(tester, viewport);
  await tester.pump();
  await _settle(tester, 20);
}

/// The vertical scrollable with the longest extent: the page's own list.
ScrollableState _pageScrollable(WidgetTester tester) {
  ScrollableState? best;
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    if (state.position.axis != Axis.vertical) {
      continue;
    }
    if (best == null ||
        state.position.maxScrollExtent > best.position.maxScrollExtent) {
      best = state;
    }
  }
  return best!;
}

/// The mini player strip: the outermost ink well above its skip button.
Finder _miniPlayerStrip() => find
    .ancestor(
      of: find.byIcon(Icons.skip_next_rounded),
      matching: find.byType(InkWell),
    )
    .last;

Future<void> _openNowPlaying(
  WidgetTester tester,
  ProviderContainer container,
) async {
  container.read(playerOverlayStackProvider.notifier).expand();
  await _settle(tester, 20);
}

/// The transport and the action row are on screen, above the system inset.
void _expectNowPlayingControlsFit(WidgetTester tester, _Viewport viewport) {
  final bottom = viewport.size.height - viewport.padding.bottom;
  for (final icon in <IconData>[Icons.pause, Icons.queue_music_outlined]) {
    final finder = find.byIcon(icon);
    expect(finder, findsOneWidget, reason: '$icon');
    final rect = tester.getRect(finder);
    expect(rect.bottom, lessThanOrEqualTo(bottom), reason: '$icon $rect');
    expect(rect.top, greaterThanOrEqualTo(0), reason: '$icon $rect');
    expect(
      rect.right,
      lessThanOrEqualTo(viewport.size.width - viewport.padding.right),
      reason: '$icon $rect',
    );
  }
}

/// A widget test that tears the app down inside the test, so the timers of
/// the shell are gone before the framework checks for pending ones.
void _testApp(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    }
  });
}

final _topResults = <SearchTopResult>[
  const TopSongResult(
    Song(
      id: 'song-1',
      title: 'Lovely',
      artist: 'Bill Withers',
      album: 'Menagerie',
      duration: 235,
    ),
  ),
  const TopAlbumResult(
    Album(
      id: 'album-1',
      name: 'Moon Album 1',
      artist: 'Beach House',
      year: 2001,
    ),
  ),
  const TopArtistResult(
    Artist(id: 'artist-1', name: 'Beach House', albumCount: 3),
  ),
];

List<Override> _searchOverrides() => <Override>[
  debouncedSearchProvider.overrideWith(
    (ref) => Stream.value(
      SearchResultsState(
        result: SearchResult3(
          songs: <Song>[
            for (var i = 0; i < 4; i++)
              Song(
                id: 'song-${i + 1}',
                title: 'Lovely Moon $i',
                artist: 'Beach House',
                album: 'Moon Album 1',
                duration: 200,
              ),
          ],
        ),
        isWaitingForApi: false,
        isLocalOnly: false,
        remoteSearchFailed: false,
        topResults: _topResults,
      ),
    ),
  ),
];

/// Lines a paragraph is laid out on: the distinct tops of its selection boxes.
int _lineCount(RenderParagraph paragraph) => paragraph
    .getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    )
    .map((box) => box.top.round())
    .toSet()
    .length;

void main() {
  group('A1 artist letter tracking', () {
    _testApp('scrolling the artist grid moves the active letter', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _duoPortrait);
      await container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .updateArtistViewMode('grid');
      await _go(tester, AppRoutes.librarySection('artists'));
      await _settle(tester);

      String? activeLetter() {
        final finder = find.byKey(const Key('artistRailActiveLetter'));
        return finder.evaluate().isEmpty
            ? null
            : tester.widget<Text>(finder).data;
      }

      expect(activeLetter(), 'A');
      // Drag in steps: the tracker reads the previous frame's layout.
      for (var i = 0; i < 4; i++) {
        await tester.dragFrom(const Offset(300, 600), const Offset(0, -350));
        await _settle(tester, 2);
      }

      expect(tester.takeException(), isNull);
      expect(activeLetter(), isNot('A'));
    });
  });

  group('A1 rail jump', () {
    _testApp('tapping a letter on the rail still scrolls the grid there', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _duoPortrait);
      await container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .updateArtistViewMode('grid');
      await _go(tester, AppRoutes.librarySection('artists'));
      await _settle(tester);

      final rail = tester.getRect(find.byKey(const Key('artistAlphabetRail')));
      await tester.tapAt(Offset(rail.center.dx, rail.bottom - 4));
      await _settle(tester, 4);

      expect(tester.takeException(), isNull);
      expect(_pageScrollable(tester).position.pixels, greaterThan(500));
    });
  });

  group('A2 scroll offset survives a layout class change', () {
    // Each keyed scroll view of the Library: a fold rebuilds its subtree.
    for (final (name, section, mode) in <(String, String, String)>[
      ('albums', 'albums', 'grid'),
      ('artists grid', 'artists', 'grid'),
      ('liked', 'liked', 'grid'),
      ('playlists', 'playlists', 'grid'),
    ]) {
      _testApp('library $name keeps its offset across a fold', (tester) async {
        final container = await _pumpApp(tester, _duoFolded);
        await container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .updateArtistViewMode(mode);
        await _go(tester, AppRoutes.librarySection(section));
        final position = _pageScrollable(tester).position;
        expect(position.maxScrollExtent, greaterThan(300), reason: name);
        position.jumpTo(250);
        await _settle(tester, 4);

        await _resize(tester, _duoPortrait);
        expect(tester.takeException(), isNull);
        expect(_pageScrollable(tester).position.pixels, closeTo(250, 1));

        await _resize(tester, _duoFolded);
        expect(_pageScrollable(tester).position.pixels, closeTo(250, 1));
      });
    }

    // Jumps into the middle of the list: near its end a taller pane
    // legitimately shows earlier artists, and a PageStorageKey restored the
    // wrong artist after a jump (Jon Hopkins became Massive Attack).
    for (final jump in <double>[0.3, 0.5]) {
      _testApp(
        'library artists list keeps its artist after a rail jump $jump',
        (tester) async {
          final container = await _pumpApp(tester, _duoFolded);
          await container
              .read(navisDatabaseProvider)
              .appSettingsDao
              .updateArtistViewMode('list');
          await _go(tester, AppRoutes.librarySection('artists'));

          // Jump with the alphabet rail, then drag a little.
          final rail = tester.getRect(
            find.byKey(const Key('artistAlphabetRail')),
          );
          await tester.tapAt(
            Offset(rail.center.dx, rail.top + rail.height * jump),
          );
          await _settle(tester, 4);
          await tester.dragFrom(const Offset(200, 380), const Offset(0, -130));
          await _settle(tester, 4);

          String firstVisibleArtist() {
            final cards = find
                .byType(ArtistCard)
                .evaluate()
                .map((e) => e.widget)
                .cast<ArtistCard>();
            // The rail spans the list's height, 8 dp inside it.
            final listTop =
                tester
                    .getRect(find.byKey(const Key('artistAlphabetRail')))
                    .top -
                8;
            final onScreen = cards.where(
              (c) => tester.getRect(find.byWidget(c)).top >= listTop - 1,
            );
            return onScreen
                .reduce(
                  (a, b) =>
                      tester.getRect(find.byWidget(a)).top <=
                          tester.getRect(find.byWidget(b)).top
                      ? a
                      : b,
                )
                .artist
                .name;
          }

          final before = firstVisibleArtist();
          expect(before, isNot('Aphex Twin'));
          await _resize(tester, _duoPortrait);
          expect(tester.takeException(), isNull);
          expect(firstVisibleArtist(), before);

          await _resize(tester, _duoFolded);
          expect(firstVisibleArtist(), before);
        },
      );
    }
  });

  group('A3/B2 Now Playing fits its pane', () {
    for (final (name, viewport) in <(String, _Viewport)>[
      ('unfolded portrait 669x951', _duoPortrait),
      ('unfolded landscape 951x669 with the rail', _duoLandscape),
    ]) {
      _testApp('transport and actions are on screen: $name', (tester) async {
        final container = await _pumpApp(tester, viewport);
        await _openNowPlaying(tester, container);

        expect(tester.takeException(), isNull);
        _expectNowPlayingControlsFit(tester, viewport);
      });
    }

    _testApp('text scale 1.3 keeps the controls on screen', (tester) async {
      final container = await _pumpApp(tester, _duoLandscape, textScale: 1.3);
      await _openNowPlaying(tester, container);

      expect(tester.takeException(), isNull);
      _expectNowPlayingControlsFit(tester, _duoLandscape);
    });

    for (final (name, viewport) in <(String, _Viewport)>[
      ('phone 393x852', _phone),
      ('iPad split view 507 pt', _ipadSplitNarrow),
      ('iPad split view 678 pt', _ipadSplitWide),
      ('Duo folded 466x678', _duoFolded),
      ('iPad landscape 1024x768', _ipadLandscape),
      ('iPad landscape 1180x820 (standard width pane)', _ipadLandscapeLarge),
    ]) {
      _testApp('controls stay on screen: $name', (tester) async {
        final container = await _pumpApp(tester, viewport);
        await _openNowPlaying(tester, container);

        expect(tester.takeException(), isNull);
        _expectNowPlayingControlsFit(tester, viewport);
      });
    }

    _testApp('compact wide landscape phone still shows its transport', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _phoneLandscape);
      await _openNowPlaying(tester, container);

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });

  group('A4 right system strip on the Duo cover', () {
    const stripLeft = 466.0 - 84;

    _testApp('artist alphabet rail stays left of the strip', (tester) async {
      await _pumpApp(tester, _duoFolded);
      await _go(tester, AppRoutes.librarySection('artists'));

      final rail = tester.getRect(find.byKey(const Key('artistAlphabetRail')));
      expect(rail.right, lessThanOrEqualTo(stripLeft));
    });

    _testApp('artist alphabet rail in grid mode stays left of the strip', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _duoFolded);
      await container
          .read(navisDatabaseProvider)
          .appSettingsDao
          .updateArtistViewMode('grid');
      await _go(tester, AppRoutes.librarySection('artists'));

      final rail = tester.getRect(find.byKey(const Key('artistAlphabetRail')));
      expect(rail.right, lessThanOrEqualTo(stripLeft));
    });

    _testApp('mini player buttons stay left of the strip', (tester) async {
      await _pumpApp(tester, _duoFolded);

      final like = tester.getRect(find.byIcon(Icons.favorite_border));
      expect(like.right, lessThanOrEqualTo(stripLeft));
      // The strip itself runs edge to edge.
      expect(tester.getRect(_miniPlayerStrip()).right, 466);
    });

    _testApp('Playlists FAB stays left of the strip', (tester) async {
      await _pumpApp(tester, _duoFolded);
      await _go(tester, AppRoutes.librarySection('playlists'));

      final fab = tester.getRect(find.byType(FloatingActionButton));
      expect(fab.right, lessThanOrEqualTo(stripLeft));
    });

    _testApp('Radio button stays left of the strip', (tester) async {
      await _pumpApp(tester, _duoFolded);
      await _go(tester, AppRoutes.librarySection('radio'));

      final fab = tester.getRect(find.byKey(const ValueKey('radioAddFab')));
      expect(fab.right, lessThanOrEqualTo(stripLeft));
    });

    _testApp('compact wide landscape phone keeps its single inset', (
      tester,
    ) async {
      await _pumpApp(tester, _phoneLandscape);
      await _go(tester, AppRoutes.librarySection('artists'));
      await _go(tester, AppRoutes.librarySection('playlists'));

      // The shell already pads this layout by the system inset; the FAB and
      // rail must not add it a second time.
      final fab = tester.getRect(find.byType(FloatingActionButton));
      expect(fab.right, 844 - 47 - 16);
    });

    _testApp('phone without a right inset keeps the 16 dp FAB margin', (
      tester,
    ) async {
      await _pumpApp(tester, _phone);
      await _go(tester, AppRoutes.librarySection('playlists'));

      final fab = tester.getRect(find.byType(FloatingActionButton));
      expect(fab.right, 393 - 16);
    });
  });

  group('I27b', () {
    const stripLeft = 466.0 - 84;
    const paneRight = 951.0 - 84;

    /// The right edge of the furthest widget a finder matches.
    double maxRight(WidgetTester tester, Finder finder) {
      // Hit-testable: a TabBarView also lays out its neighbouring pages.
      final visible = finder.hitTestable();
      expect(visible, findsWidgets);
      return visible
          .evaluate()
          .map((e) => tester.getRect(find.byElementPredicate((x) => x == e)))
          .map((r) => r.right)
          .reduce((a, b) => a > b ? a : b);
    }

    void expectLeftOfStrip(WidgetTester tester, Finder finder, String name) {
      expect(
        maxRight(tester, finder),
        lessThanOrEqualTo(stripLeft),
        reason: name,
      );
    }

    final radioStations = <InternetRadioStation>[
      for (var i = 0; i < 4; i++)
        InternetRadioStation(
          id: 'st-$i',
          name: 'Late Night Station $i',
          streamUrl: 'https://radio.example.com/$i',
        ),
    ];

    // D1: the shell owns the horizontal safe area, so no page has to. Each
    // case measures a widget that ran under the strip before the fix: album
    // cards, the Liked strip, artist heart buttons and rows, playlist rows.
    for (final (name, section, mode) in <(String, String, String)>[
      ('albums', 'albums', 'grid'),
      ('liked', 'liked', 'grid'),
      ('artists grid', 'artists', 'grid'),
      ('artists list', 'artists', 'list'),
      ('playlists', 'playlists', 'grid'),
    ]) {
      _testApp('D1 library $name clears the strip on the Duo cover', (
        tester,
      ) async {
        final container = await _pumpApp(tester, _duoFolded);
        await container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .updateArtistViewMode(mode);
        await _go(tester, AppRoutes.librarySection(section));

        expect(tester.takeException(), isNull);
        final content = switch (name) {
          'albums' => find.byType(AlbumCard),
          // Liked leads with a strip of albums that scrolls sideways.
          'liked' => find.byWidgetPredicate(
            (w) => w is ListView && w.scrollDirection == Axis.horizontal,
          ),
          'artists grid' => find.byType(IconButton),
          'artists list' => find.byType(ListTile),
          _ => find.byType(ListTile),
        };
        expectLeftOfStrip(tester, content, name);
        if (section == 'albums') {
          expectLeftOfStrip(
            tester,
            find.byKey(const ValueKey<String>('libraryAlbumSortControl')),
            'albums sort control',
          );
        }
      });
    }

    _testApp('D1 radio clears the strip on the Duo cover', (tester) async {
      await _pumpApp(
        tester,
        _duoFolded,
        extraOverrides: <Override>[
          radioStationsProvider.overrideWith((ref) async => radioStations),
        ],
      );
      await _go(tester, AppRoutes.librarySection('radio'));

      expect(tester.takeException(), isNull);
      expectLeftOfStrip(tester, find.byType(TextField), 'filter field');
      expectLeftOfStrip(
        tester,
        find.byKey(const ValueKey<String>('radioStation-st-0')),
        'station card',
      );
      expectLeftOfStrip(
        tester,
        find.byIcon(Icons.play_arrow_rounded),
        'station play button',
      );
    });

    _testApp('D1 search clears the strip on the Duo cover', (tester) async {
      final container = await _pumpApp(
        tester,
        _duoFolded,
        extraOverrides: _searchOverrides(),
      );
      await _go(tester, AppRoutes.search);
      container.read(searchQueryProvider.notifier).submit('love');
      await _settle(tester, 15);

      expect(tester.takeException(), isNull);
      expectLeftOfStrip(
        tester,
        find.byKey(const ValueKey<String>('search-top-result-0')),
        'top result',
      );
      expectLeftOfStrip(tester, find.byType(ChoiceChip), 'filter chips');
      expectLeftOfStrip(tester, find.byType(TextField), 'search field');
    });

    for (final (name, route) in <(String, String)>[
      ('home', AppRoutes.home),
      ('settings', AppRoutes.settings),
    ]) {
      _testApp('D1 $name still clears the strip (regression guard)', (
        tester,
      ) async {
        await _pumpApp(tester, _duoFolded);
        await _go(tester, route);

        expect(tester.takeException(), isNull);
        final texts = find.byType(Text);
        expectLeftOfStrip(tester, texts, name);
      });
    }

    _testApp('D1 library albums stay left of the strip in the rail pane', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip);
      await _go(tester, AppRoutes.librarySection('albums'));

      expect(tester.takeException(), isNull);
      expect(
        maxRight(tester, find.byType(AlbumCard)),
        lessThanOrEqualTo(paneRight),
      );
      expect(
        maxRight(
          tester,
          find.byKey(const ValueKey<String>('libraryAlbumSortControl')),
        ),
        lessThanOrEqualTo(paneRight),
      );
    });

    // D2: the rail no longer takes the right strip as its own left padding.
    _testApp('D2 rail is 270 wide beside a right strip', (tester) async {
      await _pumpApp(tester, _duoLandscapeStrip);

      final railColor = Theme.of(tester.element(find.byType(Scaffold).first))
          .colorScheme
          .surfaceContainerLow;
      final rail = tester.getRect(
        find
            .ancestor(
              of: find.text('Home').first,
              matching: find.byWidgetPredicate(
                (w) => w is Material && w.color == railColor,
              ),
            )
            .first,
      );
      expect(rail.left, 0);
      expect(rail.width, 270);
    });

    // D3: a collapsed Now Playing overlay is clipped to the pane.
    _testApp('D3 collapsed Now Playing does not paint into the bottom inset', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip);

      final clip = find.ancestor(
        of: find.byType(NowPlayingScreen),
        matching: find.byType(ClipRect),
      );
      final bottoms = clip
          .evaluate()
          .map((e) => tester.getRect(find.byElementPredicate((x) => x == e)))
          .map((r) => r.bottom);
      expect(bottoms, contains(669 - 34));
    });
  });

  group('I27b review fixes', () {
    const stripLeft = 466.0 - 84;
    // The page's side margin (the albums grid uses 12).
    const gutter = 12.0;

    Rect railBox(WidgetTester tester) {
      final railColor = Theme.of(tester.element(find.byType(Scaffold).first))
          .colorScheme
          .surfaceContainerLow;
      return tester.getRect(
        find
            .ancestor(
              of: find.text('Home').first,
              matching: find.byWidgetPredicate(
                (w) => w is Material && w.color == railColor,
              ),
            )
            .first,
      );
    }

    _testApp('rail background reaches a left notch and its content clears it', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeNotch);

      expect(tester.takeException(), isNull);
      expect(railBox(tester).left, 0);
      expect(
        tester.getRect(find.text('Home').first).left,
        greaterThanOrEqualTo(48),
      );
    });

    _testApp('a right strip does not widen the rail, and the pane clears it', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip);
      await _go(tester, AppRoutes.librarySection('albums'));

      final rail = railBox(tester);
      expect(rail.left, 0);
      expect(rail.width, 270);
      expect(
        tester.getRect(find.byType(TabBarView)).right,
        lessThanOrEqualTo(951 - 84),
      );
    });

    _testApp('mounting the sheet already open hides the bar on frame one', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _duoLandscape);
      await _openNowPlaying(tester, container);
      // Fold: exactly one frame builds the bottom-navigation shell.
      _setView(tester, _duoFolded);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(NavigationBar)).top,
        greaterThanOrEqualTo(678),
        reason: 'the bar must not flash over the open player',
      );
    });

    for (final mode in <String>['grid', 'list']) {
      _testApp('alphabet rail keeps a gap before the strip: artists $mode', (
        tester,
      ) async {
        final container = await _pumpApp(tester, _duoFolded);
        await container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .updateArtistViewMode(mode);
        await _go(tester, AppRoutes.librarySection('artists'));

        final rail = tester.getRect(
          find.byKey(const Key('artistAlphabetRail')),
        );
        expect(rail.right, stripLeft - gutter);
      });
    }

    _testApp('alphabet rail stays put on a phone without a side inset', (
      tester,
    ) async {
      await _pumpApp(tester, _phone);
      await _go(tester, AppRoutes.librarySection('artists'));

      expect(
        tester.getRect(find.byKey(const Key('artistAlphabetRail'))).right,
        393,
      );
    });

    _testApp('alphabet rail keeps its gap beside the rail pane', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip);
      await _go(tester, AppRoutes.librarySection('artists'));

      expect(
        tester.getRect(find.byKey(const Key('artistAlphabetRail'))).right,
        951 - 84 - gutter,
      );
    });

    // The rail keeps a gap before the strip, so the grid and the list must
    // reserve that gap too: no avatar or name may sit under the rail.
    for (final (name, viewport) in <(String, _Viewport)>[
      ('Duo cover', _duoFolded),
      ('unfolded landscape with the strip', _duoLandscapeStrip),
    ]) {
      for (final mode in <String>['grid', 'list']) {
        _testApp('artists $mode content clears the alphabet rail: $name', (
          tester,
        ) async {
          final container = await _pumpApp(tester, viewport);
          await container
              .read(navisDatabaseProvider)
              .appSettingsDao
              .updateArtistViewMode(mode);
          await _go(tester, AppRoutes.librarySection('artists'));

          final rail = tester.getRect(
            find.byKey(const Key('artistAlphabetRail')),
          );
          final content = <Finder>[
            find.descendant(
              of: find.byType(ArtistCard),
              matching: find.byType(CoverArtImage),
            ),
            find.descendant(
              of: find.byType(ArtistCard),
              matching: find.byType(Text),
            ),
          ];
          for (final finder in content) {
            final visible = finder.hitTestable();
            expect(visible, findsWidgets);
            for (final element in visible.evaluate()) {
              final box = tester.getRect(
                find.byElementPredicate((e) => e == element),
              );
              expect(
                box.right,
                lessThanOrEqualTo(rail.left),
                reason: '$mode content $box under the rail $rail',
              );
            }
          }
        });
      }
    }

    _testApp('other right edge controls already leave a gap on the cover', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        _duoFolded,
        extraOverrides: <Override>[
          radioStationsProvider.overrideWith(
            (ref) async => <InternetRadioStation>[],
          ),
        ],
      );
      await _go(tester, AppRoutes.librarySection('playlists'));
      expect(
        tester.getRect(find.byType(FloatingActionButton)).right,
        lessThanOrEqualTo(stripLeft - gutter),
      );
      await _go(tester, AppRoutes.librarySection('radio'));
      expect(
        tester.getRect(find.byKey(const ValueKey<String>('radioAddFab'))).right,
        lessThanOrEqualTo(stripLeft - gutter),
      );
      await _go(tester, AppRoutes.librarySection('albums'));
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('libraryAlbumSortControl')),
            )
            .right,
        lessThanOrEqualTo(stripLeft - gutter),
      );
    });
  });

  group('I27b pane drops the rail-side inset', () {
    for (final (name, viewport) in <(String, _Viewport)>[
      (
        'no inset',
        (size: Size(951, 669), padding: EdgeInsets.only(bottom: 34)),
      ),
      ('left notch 48', _duoLandscapeNotch),
    ]) {
      _testApp('page content offset from the rail: $name', (tester) async {
        await _pumpApp(tester, viewport);
        await _go(tester, AppRoutes.settings);

        expect(tester.takeException(), isNull);
        final railColor = Theme.of(tester.element(find.byType(Scaffold).first))
            .colorScheme
            .surfaceContainerLow;
        final rail = tester.getRect(
          find
              .ancestor(
                of: find.text('Home').first,
                matching: find.byWidgetPredicate(
                  (w) => w is Material && w.color == railColor,
                ),
              )
              .first,
        );
        // The pane's leftmost text, past the rail.
        final texts = find
            .byType(Text)
            .hitTestable()
            .evaluate()
            .where(
              (e) =>
                  tester.getRect(find.byElementPredicate((x) => x == e)).left >
                  rail.right,
            );
        final first = texts.reduce(
          (a, b) =>
              tester.getRect(find.byElementPredicate((x) => x == a)).left <=
                  tester.getRect(find.byElementPredicate((x) => x == b)).left
              ? a
              : b,
        );
        final left = tester
            .getRect(find.byElementPredicate((x) => x == first))
            .left;
        // The page's 16 dp margin, with no inset added by the rail's side.
        expect(left - rail.right, 16);
        final context = first;
        expect(MediaQuery.paddingOf(context).left, 0);
        expect(MediaQuery.paddingOf(context).right, 0);
      });
    }

    // The full app only has an English locale, so the right-to-left shell
    // cannot be pumped: the same composition is built from its pieces.
    _testApp('right to left: each side takes only its own inset', (
      tester,
    ) async {
      EdgeInsets? railPadding;
      EdgeInsets? panePadding;
      const insets = EdgeInsets.fromLTRB(0, 0, 84, 0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(951, 669), padding: insets),
            child: Row(
              children: <Widget>[
                // RTL: the rail is on the right, the pane on the left.
                Expanded(
                  child: SafeArea(
                    left: true,
                    right: false,
                    child: SideInsetsConsumed(
                      enabled: true,
                      child: Builder(
                        builder: (context) {
                          panePadding = MediaQuery.paddingOf(context);
                          return const SizedBox();
                        },
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 270,
                  child: SafeArea(
                    left: false,
                    right: true,
                    child: SideInsetsConsumed(
                      enabled: true,
                      child: Builder(
                        builder: (context) {
                          railPadding = MediaQuery.paddingOf(context);
                          return const SizedBox();
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(railPadding, EdgeInsets.zero);
      expect(panePadding, EdgeInsets.zero);
    });
  });

  group('I27b tabs, search and album', () {
    /// Every tab label of the Library is on one line, not squeezed.
    void expectTabsUnclipped(WidgetTester tester) {
      final tabs = find.byType(Tab);
      expect(tabs, findsWidgets);
      for (final element in tabs.evaluate()) {
        final text = find.descendant(
          of: find.byElementPredicate((e) => e == element),
          matching: find.byType(Text),
        );
        final paragraph = tester.renderObject<RenderParagraph>(text.first);
        final label = (text.evaluate().first.widget as Text).data;
        expect(_lineCount(paragraph), 1, reason: '$label wraps');
        expect(paragraph.didExceedMaxLines, isFalse, reason: '$label');
        // A label that does not fit is faded out, not wrapped.
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.5),
          reason: '$label is clipped',
        );
      }
    }

    bool? scrollable(WidgetTester tester) =>
        tester.widget<TabBar>(find.byType(TabBar).first).isScrollable;

    _testApp('D4 Library tab labels fit beside the rail', (tester) async {
      await _pumpApp(tester, _duoLandscapeStrip);
      await _go(tester, AppRoutes.librarySection('albums'));

      expect(tester.takeException(), isNull);
      expectTabsUnclipped(tester);
    });

    _testApp('D4 larger text scrolls the tabs (regression guard)', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip, textScale: 1.6);
      await _go(tester, AppRoutes.librarySection('albums'));

      expect(tester.takeException(), isNull);
      expectTabsUnclipped(tester);
      expect(scrollable(tester), isTrue);
    });

    // The bar fits or scrolls by the page's own width, so no size clips a
    // label. (The test font is wider than a real one: only the absence of
    // clipping is asserted, not which mode a size picks.)
    for (final (name, viewport) in <(String, _Viewport)>[
      ('phone 393x852', _phone),
      ('Duo folded', _duoFolded),
      ('Duo portrait 669', _duoPortrait),
      ('iPad landscape 1024', _ipadLandscape),
    ]) {
      _testApp('D4 tabs are not clipped (regression guard): $name', (
        tester,
      ) async {
        await _pumpApp(tester, viewport);
        await _go(tester, AppRoutes.librarySection('albums'));

        expect(tester.takeException(), isNull);
        expectTabsUnclipped(tester);
      });
    }

    // The Top Results section is 509 dp wide beside the rail on the Duo with
    // its right strip, 593 without it, 666 on a 1024 iPad and 671 in the
    // narrowest desktop window: the row layout starts at 560.
    for (final (name, viewport, desktop, row)
        in <(String, _Viewport, bool, bool)>[
          (
            'Duo landscape with the strip (509 dp)',
            _duoLandscapeStrip,
            false,
            false,
          ),
          ('Duo landscape (593 dp)', _duoLandscape, false, true),
          ('iPad landscape 1024 (666 dp)', _ipadLandscape, false, true),
          (
            'narrowest desktop window (671 dp)',
            (size: const Size(800, 600), padding: EdgeInsets.zero),
            true,
            true,
          ),
        ]) {
      _testApp(
        row
            ? 'D5 Top Results keep the row (regression guard): $name'
            : 'D5 Top Results fit: $name',
        (tester) async {
          final container = await _pumpApp(
            tester,
            viewport,
            desktopRuntime: desktop,
            extraOverrides: _searchOverrides(),
          );
          await _go(tester, AppRoutes.search);
          container.read(searchQueryProvider.notifier).submit('love');
          await _settle(tester, 15);

          expect(tester.takeException(), isNull);
          final hero = find.byKey(
            const ValueKey<String>('search-top-result-0'),
          );
          final tile = find.byKey(
            const ValueKey<String>('search-top-result-1'),
          );
          final title = tester.renderObject<RenderParagraph>(
            find.descendant(of: hero, matching: find.text('Lovely')).first,
          );
          expect(_lineCount(title), 1);
          // One row of three, or the hero over two tiles.
          expect(tester.getTopLeft(hero).dy == tester.getTopLeft(tile).dy, row);
        },
      );
    }

    _testApp('D6 folded album title stays left of the strip', (tester) async {
      await _pumpApp(tester, _duoFolded);
      await _go(tester, AppRoutes.album('album-1'));

      expect(tester.takeException(), isNull);
      final title = find.descendant(
        of: find.byType(FlexibleSpaceBar),
        matching: find.text('Moon Album 1'),
      );
      expect(tester.getRect(title.first).right, lessThanOrEqualTo(382));
      expect(tester.getRect(find.byType(FlexibleSpaceBar)).width, 382);
    });

    Rect playButton(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(EntityActionBar),
            matching: find.byType(IconButton),
          )
          .first,
    );

    _testApp('D6 unfolded album Play lines up with the text inset', (
      tester,
    ) async {
      await _pumpApp(tester, _duoLandscapeStrip);
      await _go(tester, AppRoutes.album('album-1'));

      expect(tester.takeException(), isNull);
      final pane = tester.getRect(find.byType(FlexibleSpaceBar));
      expect(playButton(tester).left - pane.left, 16);
    });

    _testApp('D6 phone album Play keeps its 4 dp inset', (tester) async {
      await _pumpApp(tester, _phone);
      await _go(tester, AppRoutes.album('album-1'));

      expect(tester.takeException(), isNull);
      expect(playButton(tester).left, 4);
    });

    _testApp('D7 folding with Now Playing open does not throw', (tester) async {
      final container = await _pumpApp(tester, _duoLandscape);
      await _openNowPlaying(tester, container);
      await _resize(tester, _duoFolded);

      expect(tester.takeException(), isNull);
      expect(container.read(playerOverlayStackProvider).isNotEmpty, isTrue);
    });
  });

  group('I28 short landscape phones use the compact wide shell', () {
    const shortViewports = <(String, _Viewport)>[
      ('iPhone SE 667x375', _phoneSE),
      ('iPhone 812x375 notch', _phoneMiniNotch),
      ('Duo cover 678x466 strip at the bottom', _duoCoverLandscapeBottomStrip),
      ('Duo cover 678x466 strip at the top', _duoCoverLandscapeTopStrip),
    ];

    for (final (name, viewport) in shortViewports) {
      _testApp('compact rail replaces the bottom bar: $name', (tester) async {
        await _pumpApp(tester, viewport);

        expect(tester.takeException(), isNull);
        for (var i = 0; i < 4; i++) {
          expect(
            find.byKey(ValueKey<String>('compactRailNavTile-$i')),
            findsOne,
          );
        }
        expect(find.byType(NavigationBar), findsNothing);
      });
    }

    _testApp('the keyboard keeps the compact rail on the mode boundary', (
      tester,
    ) async {
      await _pumpApp(tester, _phoneBoundary);
      expect(
        find.byKey(const ValueKey<String>('compactRailNavTile-0')),
        findsOne,
      );

      // The keyboard zeroes padding.bottom; viewPadding.bottom stays 34.
      tester.view.padding = FakeViewPadding.zero;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200 * 3);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await _settle(tester, 10);

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('compactRailNavTile-0')),
        findsOne,
      );
      expect(find.byType(NavigationBar), findsNothing);
    });

    _testApp('narrow portrait Now Playing transport fits (350x740)', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _phoneNarrowPortrait);
      await _openNowPlaying(tester, container);

      expect(tester.takeException(), isNull);
      _expectNowPlayingControlsFit(tester, _phoneNarrowPortrait);
    });

    for (final (name, viewport, scale) in <(String, _Viewport, double)>[
      ('844x390', _phoneLandscape, 1),
      ('932x430', _phoneLandscapeLarge, 1),
      ('812x375', _phoneMiniNotch, 1),
      ('667x375', _phoneSE, 1),
      ('678x466 strip bottom', _duoCoverLandscapeBottomStrip, 1),
      ('678x466 strip top', _duoCoverLandscapeTopStrip, 1),
      ('667x375 text 1.3', _phoneSE, 1.3),
    ]) {
      _testApp('Now Playing fits: $name', (tester) async {
        final container = await _pumpApp(tester, viewport, textScale: scale);
        await _openNowPlaying(tester, container);

        expect(tester.takeException(), isNull);
        _expectNowPlayingControlsFit(tester, viewport);
      });
    }

    _testApp('car Now Playing counts the side inset once (812x375)', (
      tester,
    ) async {
      final container = await _pumpApp(tester, _phoneMiniNotch);
      await _openNowPlaying(tester, container);

      // The shell pads the pane by the 44 dp notch; the page adds only 20/12.
      final page = tester.getRect(
        find.byKey(const ValueKey<String>('compact-wide-player-page')),
      );
      final row = tester.getRect(
        find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('compact-wide-player-page'),
              ),
              matching: find.byType(Row),
            )
            .first,
      );
      expect(row.left - page.left, 20);
      expect(page.right - row.right, 12);
      expect(page.right, 812 - 44);
    });

    for (final (name, viewport, scale) in <(String, _Viewport, double)>[
      ('667x375', _phoneSE, 1),
      ('812x375 notch', _phoneMiniNotch, 1),
      ('678x466 strip bottom', _duoCoverLandscapeBottomStrip, 1),
      ('678x466 strip top', _duoCoverLandscapeTopStrip, 1),
      ('667x375 text 1.3', _phoneSE, 1.3),
    ]) {
      for (final (page, location) in <(String, String)>[
        ('home', AppRoutes.home),
        ('albums', AppRoutes.librarySection('albums')),
        ('artists', AppRoutes.librarySection('artists')),
        ('search', AppRoutes.search),
        ('settings', AppRoutes.settings),
        ('album detail', AppRoutes.album('album-1')),
      ]) {
        _testApp('$page clears the strips: $name', (tester) async {
          await _pumpApp(tester, viewport, textScale: scale);
          await _go(tester, location);

          expect(tester.takeException(), isNull);
          // Nothing tappable sits under a status strip.
          final tappables = find.byWidgetPredicate(
            (w) => w is IconButton || w is ListTile || w is Tab,
          );
          for (final element in tappables.evaluate()) {
            final rect = tester.getRect(find.byWidget(element.widget));
            if (rect.bottom <= 0 || rect.top >= viewport.size.height) continue;
            expect(
              rect.top,
              greaterThanOrEqualTo(viewport.padding.top),
              reason: '${element.widget.runtimeType} $rect',
            );
          }
          final skip = tester.getRect(find.byIcon(Icons.skip_next_rounded));
          expect(
            skip.bottom,
            lessThanOrEqualTo(viewport.size.height - viewport.padding.bottom),
            reason: 'mini player skip $skip',
          );
        });
      }
    }

    // Rotation or a fold swaps the bottom-nav and compact-wide branches.
    for (final (name, portrait, landscape) in <(String, _Viewport, _Viewport)>[
      (
        'phone 375x667 and 667x375',
        (size: const Size(375, 667), padding: EdgeInsets.zero),
        _phoneSE,
      ),
      (
        'Duo cover 466x678 and 678x466',
        _duoFolded,
        _duoCoverLandscapeBottomStrip,
      ),
    ]) {
      for (final queue in <bool>[false, true]) {
        _testApp('rotating keeps state, ${queue ? 'queue' : 'player'} open: '
            '$name', (tester) async {
          final container = await _pumpApp(tester, portrait);
          await _go(tester, AppRoutes.librarySection('playlists'));
          final location = GoRouter.of(
            tester.element(find.byType(Scaffold).first),
          ).routeInformationProvider.value.uri.toString();
          final overlay = container.read(playerOverlayStackProvider.notifier);
          queue ? overlay.showQueue() : overlay.expand();
          await _settle(tester, 20);

          for (final viewport in <_Viewport>[landscape, portrait, landscape]) {
            await _resize(tester, viewport);
            expect(tester.takeException(), isNull, reason: '$viewport');
            final stack = container.read(playerOverlayStackProvider);
            expect(stack.isNotEmpty, true);
            if (viewport == landscape) {
              // Compact wide offers the queue as an in-pane panel instead.
              expect(stack, <PlayerOverlayRoute>[
                PlayerOverlayRoute.nowPlaying,
              ]);
            }
            expect(
              GoRouter.of(tester.element(find.byType(Scaffold).first))
                  .routeInformationProvider
                  .value
                  .uri
                  .toString(),
              location,
            );
          }
        });
      }

      _testApp('rotating keeps the page scroll offset: $name', (tester) async {
        final container = await _pumpApp(tester, portrait);
        await container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .updateArtistViewMode('grid');
        await _go(tester, AppRoutes.librarySection('albums'));
        final position = _pageScrollable(tester).position;
        expect(position.maxScrollExtent, greaterThan(300));
        position.jumpTo(250);
        await _settle(tester, 4);

        await _resize(tester, landscape);
        expect(tester.takeException(), isNull);
        expect(_pageScrollable(tester).position.pixels, closeTo(250, 1));
        await _resize(tester, portrait);
        expect(_pageScrollable(tester).position.pixels, closeTo(250, 1));
      });
    }
  });

  group('B1 album detail hero on tablet layouts', () {
    for (final (name, viewport) in <(String, _Viewport)>[
      ('unfolded portrait 669x951', _duoPortrait),
      ('unfolded landscape 951x669', _duoLandscape),
    ]) {
      _testApp('first song row is above the mini player: $name', (
        tester,
      ) async {
        await _pumpApp(tester, viewport);
        await _go(tester, AppRoutes.album('album-1'));

        // The mini player shows the same title, so look inside the page list.
        final row = find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.text('Opening Track'),
        );
        expect(row, findsOneWidget);
        final miniTop = tester.getRect(_miniPlayerStrip()).top;
        expect(tester.getRect(row).bottom, lessThanOrEqualTo(miniTop));
      });
    }

    for (final (name, viewport) in <(String, _Viewport)>[
      ('unfolded portrait', _duoPortrait),
      ('unfolded landscape', _duoLandscape),
      ('iPad split view 678 pt', _ipadSplitWide),
    ]) {
      _testApp('hero is at most 45 percent of the height: $name', (
        tester,
      ) async {
        await _pumpApp(tester, viewport);
        await _go(tester, AppRoutes.album('album-1'));

        final hero = tester.getRect(find.byType(FlexibleSpaceBar));
        expect(hero.height, lessThanOrEqualTo(viewport.size.height * 0.45 + 1));
      });
    }

    _testApp('desktop runtime keeps its own album header', (tester) async {
      await _pumpApp(tester, (
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      ), desktopRuntime: true);
      await _go(tester, AppRoutes.album('album-1'));

      // The capped cover hero belongs to the mobile page only.
      expect(find.byType(FlexibleSpaceBar), findsNothing);
      expect(find.text('Moon Album 1'), findsWidgets);
    });

    for (final (name, viewport, hero) in <(String, _Viewport, double)>[
      ('phone 393x852', _phone, 393),
      ('Duo folded 466x678 (382 beside the strip)', _duoFolded, 382),
    ]) {
      _testApp('phones keep the square hero: $name', (tester) async {
        await _pumpApp(tester, viewport);
        await _go(tester, AppRoutes.album('album-1'));

        // The app bar also covers the status bar inset.
        expect(
          tester.getRect(find.byType(FlexibleSpaceBar)).height,
          hero + viewport.padding.top,
        );
      });
    }
  });
}
