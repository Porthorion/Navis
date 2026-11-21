import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/list_filter_field.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_detail_screen.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/common_widgets/type_to_filter.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/queue_replace_spy.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

const _touch = Size(390, 1600);
const _desktop = Size(1280, 1600);

AlbumsTableData _album(String id, String name, {String? artistName}) =>
    AlbumsTableData(
      isProvisional: false,
      isExternal: false,
      id: id,
      name: name,
      artistName: artistName,
      artistId: 'artist-1',
      songsHydrated: true,
      artists: const <ArtistRef>[],
    );

ResolvedArtistTopTrack _top(int rank, String title) => ResolvedArtistTopTrack(
  rank: rank,
  title: title,
  artist: 'Artist 1',
  resolvedSong: Song(id: 'top-$rank', title: title, artist: 'Artist 1'),
);

SongsTableData _song(
  String id,
  String title, {
  String? artist,
  String? album,
}) => SongsTableData(
  id: id,
  title: title,
  artistName: artist,
  albumName: album,
  isProvisional: false,
  isExternal: false,
);

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Widget child,
  required List<Object?> overrides,
}) async {
  setAdaptiveTestViewport(tester, size);
  final database = createTestDatabase();
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        navisDatabaseProvider.overrideWithValue(database),
        serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        subsonicApiProvider.overrideWith((_) => null),
        connectivityProvider.overrideWith(
          (_) => Stream.value(const [ConnectivityResult.wifi]),
        ),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        artistTopTrackSeedsProvider.overrideWith(
          (ref, key) async => const <ArtistTopTrackSeed>[],
        ),
        artistDeezerIdProvider.overrideWith((ref, key) async => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        songDownloadStateProvider.overrideWith(
          (ref, songId) => SongDownloadState.none,
        ),
        ...overrides.cast(),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: size == _desktop,
            viewportSize: size,
            safePadding: EdgeInsets.zero,
          ),
          child: child,
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _pumpArtist(WidgetTester tester, Size size) => _pump(
  tester,
  size: size,
  child: const ArtistDetailScreen(artistId: 'artist-1'),
  overrides: [
    artistTopSongsAllowedProvider.overrideWithValue(true),
    artistByIdProvider('artist-1').overrideWithValue(
      const AsyncData(
        ArtistsTableData(
          isProvisional: false,
          isExternal: false,
          id: 'artist-1',
          name: 'Artist 1',
          albumCount: 3,
        ),
      ),
    ),
    artistAlbumSectionsProvider('artist-1').overrideWithValue(
      AsyncData(
        ArtistAlbumSections(
          albums: [_album('a1', 'Déjà Vu'), _album('a2', 'Lemonade')],
          featuredIn: [_album('a3', 'Dangerous Woman')],
        ),
      ),
    ),
    artistInfoProvider('artist-1')
        .overrideWithValue(const AsyncData(ArtistInfo(biography: 'Bio'))),
    artistTopTracksProvider((artistId: 'artist-1', name: 'Artist 1'))
        .overrideWith(
          (ref) => Stream.value([_top(1, 'Halo'), _top(2, 'Crazy in Love')]),
        ),
    songByIdProvider.overrideWith((ref, id) => Stream.value(_song(id, 'x'))),
  ],
);

final _playlistSongs = [
  _song('s1', 'Halo', artist: 'Beyoncé', album: 'I Am'),
  _song('s2', 'Crazy in Love', artist: 'Beyoncé', album: 'Dangerously'),
  _song('s3', 'Lemonade Song', artist: 'Someone', album: 'Café Sessions'),
];

Future<void> _pumpPlaylist(
  WidgetTester tester,
  Size size, {
  List<Object?> extraOverrides = const [],
}) => _pump(
  tester,
  size: size,
  child: const PlaylistDetailScreen(playlistId: 'pl'),
  overrides: [
    ...extraOverrides,
    playlistByIdProvider('pl').overrideWith(
      (ref) => Stream.value(
        const PlaylistsTableData(isLocal: false, id: 'pl', name: 'Mix'),
      ),
    ),
    playlistSongsProvider('pl')
        .overrideWith((ref) => Stream.value(_playlistSongs)),
    playlistDetailSyncProvider('pl').overrideWith((ref) async {}),
  ],
);

/// The artist page keeps a progress animation alive, so pumpAndSettle never
/// returns; a fixed pump is enough for these tests.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Types into the touch field and waits out its 250 ms debounce.
Future<void> _filter(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String text) async {
  for (final char in text.split('')) {
    final key = LogicalKeyboardKey.findKeyByKeyId(
      char.toLowerCase().codeUnitAt(0),
    );
    await tester.sendKeyEvent(key ?? LogicalKeyboardKey.keyA, character: char);
  }
  await _settle(tester);
}

void main() {
  group('artist page filter', () {
    testWidgets('touch field filters albums and top songs by title', (
      tester,
    ) async {
      await _pumpArtist(tester, _touch);
      expect(find.byType(ListFilterField), findsOneWidget);
      expect(find.text('Lemonade'), findsOneWidget);
      expect(find.text('Halo'), findsOneWidget);

      await _filter(tester, 'deja');
      expect(find.text('Déjà Vu'), findsOneWidget);
      expect(find.text('Lemonade'), findsNothing);
      expect(find.text('Dangerous Woman'), findsNothing);
      expect(find.text('Halo'), findsNothing);

      await _filter(tester, 'HALO');
      expect(find.text('Halo'), findsOneWidget);
      expect(find.text('Crazy in Love'), findsNothing);
      expect(find.text('Lemonade'), findsNothing);

      await _filter(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
    });

    testWidgets('desktop typing filters without a field; Esc restores', (
      tester,
    ) async {
      await _pumpArtist(tester, _desktop);
      expect(find.byType(ListFilterField), findsNothing);

      await _type(tester, 'lemon');
      expect(find.text('Filtering: "lemon"'), findsOneWidget);
      expect(find.text('Lemonade'), findsOneWidget);
      expect(find.text('Déjà Vu'), findsNothing);
      expect(find.text('Halo'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Filtering: "lemon"'), findsNothing);
      expect(find.text('Déjà Vu'), findsOneWidget);
      expect(find.text('Halo'), findsOneWidget);

      await _type(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
    });
  });

  group('playlist page filter', () {
    testWidgets(
      'touch field matches title, artist and album, folding accents',
      (tester) async {
        await _pumpPlaylist(tester, _touch);
        expect(find.byType(ListFilterField), findsOneWidget);
        expect(find.text('Lemonade Song'), findsOneWidget);
        expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));

        await _filter(tester, 'beyonce');
        expect(find.text('Halo'), findsOneWidget);
        expect(find.text('Crazy in Love'), findsOneWidget);
        expect(find.text('Lemonade Song'), findsNothing);

        await _filter(tester, 'cafe');
        expect(find.text('Lemonade Song'), findsOneWidget);
        expect(find.text('Halo'), findsNothing);

        await _filter(tester, 'dangerously');
        expect(find.text('Crazy in Love'), findsOneWidget);
        expect(find.text('Halo'), findsNothing);

        // Reordering is off while filtering.
        expect(find.byIcon(Icons.drag_handle), findsNothing);

        await _filter(tester, 'zzz');
        expect(find.text('No results for "zzz"'), findsOneWidget);
      },
    );

    testWidgets('desktop typing filters without a field; Esc restores', (
      tester,
    ) async {
      await _pumpPlaylist(tester, _desktop);
      expect(find.byType(ListFilterField), findsNothing);

      await _type(tester, 'beyonce');
      expect(find.text('Filtering: "beyonce"'), findsOneWidget);
      expect(find.text('Halo'), findsOneWidget);
      expect(find.text('Lemonade Song'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Lemonade Song'), findsOneWidget);

      await _type(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
    });
  });

  group('playlist filter edge cases', () {
    testWidgets('a punctuation-only query is no filter', (tester) async {
      await _pumpPlaylist(tester, _desktop);
      await _type(tester, '..');
      expect(find.textContaining('Filtering:'), findsNothing);
      expect(find.text('Halo'), findsOneWidget);
      expect(find.text('Crazy in Love'), findsOneWidget);
      expect(find.text('Lemonade Song'), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('touch punctuation-only query is no filter', (tester) async {
      await _pumpPlaylist(tester, _touch);
      await _filter(tester, '..');
      expect(find.text('Lemonade Song'), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    });

    testWidgets('tapping a row on a filtered playlist queues the matches', (
      tester,
    ) async {
      await _pumpPlaylist(
        tester,
        _touch,
        extraOverrides: [
          albumQueueEnabledProvider.overrideWithValue(true),
          queueProvider.overrideWith(QueueReplaceSpy.new),
        ],
      );
      await _filter(tester, 'beyonce');
      await tester.tap(find.text('Crazy in Love'));
      await _settle(tester);
      final queue = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistDetailScreen)),
      ).read(queueProvider.notifier) as QueueReplaceSpy;
      expect(queue.lastReplaceIds, <String>['s1', 's2']);
      expect(queue.lastStartIndex, 1);
    });

    testWidgets('disposing within the fade window clears the active flag', (
      tester,
    ) async {
      await _pumpPlaylist(tester, _desktop);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlaylistDetailScreen)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
      await tester.pump();
      expect(container.read(libraryTypeFilterActiveProvider), isTrue);
      // The fade timer (900 ms) is still pending: leave the page now.
      unawaited(
        Navigator.of(tester.element(find.byType(PlaylistDetailScreen)))
            .pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const SizedBox()),
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(PlaylistDetailScreen), findsNothing);
      expect(container.read(libraryTypeFilterActiveProvider), isFalse);
    });
  });

  group('type filter active flag is per page', () {
    testWidgets('a root timer does not clear a pushed page\'s filter', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: _FilterProbe(root: true, label: 'root')),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_FilterProbe)),
      );
      final rootState = tester.state<_FilterProbeState>(
        find.byType(_FilterProbe),
      );
      rootState.updateTypeFilter('ab');
      await tester.pump();
      expect(container.read(libraryTypeFilterActiveProvider), isTrue);

      unawaited(
        Navigator.of(rootState.context).push(
          MaterialPageRoute<void>(
            builder: (_) => _FilterProbe(root: false, label: 'detail'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final detail = tester.state<_FilterProbeState>(
        find.byWidgetPredicate((w) => w is _FilterProbe && !w.root),
      );
      detail.updateTypeFilter('cd');

      // The root's 900 ms timer (started ~300 ms earlier) fires while the
      // detail page, 650 ms into its own, still filters.
      await tester.pump(const Duration(milliseconds: 650));
      expect(container.read(libraryTypeFilterActiveProvider), isTrue);

      detail.clearTypeFilter();
      await tester.pump();
      expect(container.read(libraryTypeFilterActiveProvider), isFalse);
    });
  });

  group('liked albums page filter', () {
    final albums = [
      _album('l1', 'Lemonade', artistName: 'Beyoncé'),
      _album('l2', 'Café Sessions', artistName: 'Someone'),
      _album('l3', 'Dangerously', artistName: 'Else'),
    ];
    Future<void> pumpPage(WidgetTester tester, Size size) => _pump(
      tester,
      size: size,
      child: const LikedAlbumsAllScreen(),
      overrides: [likedAlbumsProvider.overrideWithValue(AsyncData(albums))],
    );

    testWidgets('touch field matches title and artist, folding accents', (
      tester,
    ) async {
      await pumpPage(tester, _touch);
      expect(find.byType(ListFilterField), findsOneWidget);
      expect(find.text('Lemonade'), findsOneWidget);

      await _filter(tester, 'cafe');
      expect(find.text('Café Sessions'), findsOneWidget);
      expect(find.text('Lemonade'), findsNothing);

      await _filter(tester, 'beyonce');
      expect(find.text('Lemonade'), findsOneWidget);
      expect(find.text('Dangerously'), findsNothing);

      await _filter(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('filterClearAction')));
      await _settle(tester);
      expect(find.text('Lemonade'), findsOneWidget);
      expect(find.text('Dangerously'), findsOneWidget);
    });

    testWidgets('desktop typing filters without a field; Esc restores', (
      tester,
    ) async {
      await pumpPage(tester, _desktop);
      expect(find.byType(ListFilterField), findsNothing);

      await _type(tester, 'danger');
      expect(find.text('Filtering: "danger"'), findsOneWidget);
      expect(find.text('Dangerously'), findsOneWidget);
      expect(find.text('Lemonade'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Lemonade'), findsOneWidget);

      await _type(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('filterClearAction')));
      await _settle(tester);
      expect(find.text('Lemonade'), findsOneWidget);
    });
  });

  group('liked artists page filter', () {
    const artists = [
      ArtistsTableData(
        isProvisional: false,
        isExternal: false,
        id: 'r1',
        name: 'Beyoncé',
      ),
      ArtistsTableData(
        isProvisional: false,
        isExternal: false,
        id: 'r2',
        name: 'Rihanna',
      ),
    ];
    Future<void> pumpPage(WidgetTester tester, Size size) => _pump(
      tester,
      size: size,
      child: const LikedArtistsAllScreen(),
      overrides: [
        likedArtistsProvider.overrideWithValue(const AsyncData(artists)),
      ],
    );

    testWidgets('touch field filters by name, folding accents', (tester) async {
      await pumpPage(tester, _touch);
      expect(find.byType(ListFilterField), findsOneWidget);
      expect(find.text('Rihanna'), findsOneWidget);

      await _filter(tester, 'BEYONCE');
      expect(find.text('Beyoncé'), findsOneWidget);
      expect(find.text('Rihanna'), findsNothing);

      await _filter(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('filterClearAction')));
      await _settle(tester);
      expect(find.text('Rihanna'), findsOneWidget);
      expect(find.text('Beyoncé'), findsOneWidget);
    });

    testWidgets('desktop typing filters without a field; Esc restores', (
      tester,
    ) async {
      await pumpPage(tester, _desktop);
      expect(find.byType(ListFilterField), findsNothing);

      await _type(tester, 'rih');
      expect(find.text('Filtering: "rih"'), findsOneWidget);
      expect(find.text('Rihanna'), findsOneWidget);
      expect(find.text('Beyoncé'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('Beyoncé'), findsOneWidget);

      await _type(tester, 'zzz');
      expect(find.text('No results for "zzz"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('filterClearAction')));
      await _settle(tester);
      expect(find.text('Beyoncé'), findsOneWidget);
    });
  });
}

class _FilterProbe extends ConsumerStatefulWidget {
  const _FilterProbe({required this.root, required this.label});

  final bool root;
  final String label;

  @override
  ConsumerState<_FilterProbe> createState() => _FilterProbeState();
}

class _FilterProbeState extends ConsumerState<_FilterProbe>
    with TypeToFilter<_FilterProbe> {
  @override
  bool get typeFilterPageActive => widget.root
      ? !Navigator.of(context).canPop()
      : super.typeFilterPageActive;

  @override
  Widget build(BuildContext context) => Text(widget.label);
}
