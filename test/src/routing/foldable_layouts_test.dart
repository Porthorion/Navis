// Foldable and tablet layout fixes (issue #410, I27). The whole app is pumped
// at the sizes of the iPhone Duo (466x678 folded, 669x951 and 951x669
// unfolded) and of an iPad split view.
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
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
const _phone = (
  size: Size(393, 852),
  padding: EdgeInsets.only(top: 59, bottom: 34),
);
const _phoneLandscape = (
  size: Size(844, 390),
  padding: EdgeInsets.fromLTRB(47, 0, 47, 21),
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
}) async {
  _setView(tester, viewport);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final db = (await tester.runAsync(_seed))!;
  final container = ProviderContainer(
    overrides: _overrides(db, playback, desktopRuntime: desktopRuntime),
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

      // Unchanged by I27: this size already reports a 6 px row overflow that
      // belongs to the compact wide landscape shell, so it is cleared here.
      tester.takeException();
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
      ('Duo folded 466x678', _duoFolded, 466),
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
