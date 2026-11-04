import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/genre_detail_screen.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/library_section_navigation_scope.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

class _IdleSync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> syncIfStale() async => state;
}

class _QueueSpy extends QueueController {
  List<String>? ids;
  int? startIndex;
  List<String>? originalOrder;

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
    List<String>? originalOrder,
  }) async {
    ids = songs.map((song) => song.id).toList();
    this.startIndex = startIndex;
    this.originalOrder = originalOrder;
  }
}

class _Epoch extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final _epoch = NotifierProvider<_Epoch, int>(_Epoch.new);

const _hipHop = GenreSummary(
  key: 'hiphop',
  name: 'Hip-Hop',
  songCount: 12,
  albumCount: 3,
);
const _rock = GenreSummary(
  key: 'rock',
  name: 'Rock',
  songCount: 40,
  albumCount: 5,
);
const _jpop = GenreSummary(
  key: 'ジェイポップ',
  name: 'ジェイポップ',
  songCount: 2,
  albumCount: 1,
);

late NavisDatabase _db;
final List<GenreListRequest> _requests = <GenreListRequest>[];
final List<String> _summaryKeys = <String>[];

List<Object?> _commonOverrides({
  required List<GenreSummary> genres,
  bool pendingSync = false,
  bool genresPage = true,
}) => <Object?>[
  showGenresPageProvider.overrideWithValue(genresPage),
  showRadioPageProvider.overrideWithValue(false),
  showPlaylistsPageProvider.overrideWithValue(false),
  showAlbumsPageProvider.overrideWithValue(false),
  showLikedPageProvider.overrideWithValue(false),
  showArtistsPageProvider.overrideWithValue(false),
  serverConfigStateProvider.overrideWithValue(
    const AsyncData<ServerConfigModel?>(null),
  ),
  subsonicApiProvider.overrideWithValue(null),
  librarySyncControllerProvider.overrideWith(_IdleSync.new),
  genresPendingSyncProvider.overrideWith((ref) => Stream.value(pendingSync)),
  genreListProvider.overrideWith((ref, request) async {
    _requests.add(request);
    final query = request.query.toLowerCase();
    final shown = [
      for (final genre in genres)
        if (query.isEmpty || genre.key.contains(query)) genre,
    ];
    return switch (request.sort) {
      GenreSortOrder.name => (shown..sort((a, b) => a.key.compareTo(b.key))),
      GenreSortOrder.songs =>
        (shown..sort((a, b) => b.songCount - a.songCount)),
      GenreSortOrder.albums =>
        (shown..sort((a, b) => b.albumCount - a.albumCount)),
    };
  }),
];

Widget _app(
  List<Object?> overrides, {
  String? initial,
  AdaptiveContext? adaptiveContext,
}) {
  final router = GoRouter(
    initialLocation: initial ?? AppRoutes.library,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (context, state) => const LibraryScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.genreSegment,
            builder: (context, state) =>
                GenreDetailScreen(genreKey: state.pathParameters['key']!),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: withTestDatabase(_db, overrides: overrides.cast()),
    child: MaterialApp.router(
      theme: testTheme(),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => LibrarySectionNavigationScope(
        sidebarAllowsSections: false,
        sectionsFit: ValueNotifier<bool>(true),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: adaptiveContext == null
              ? child!
              : AdaptiveContextScope(
                  adaptiveContext: adaptiveContext,
                  child: child!,
                ),
        ),
      ),
      routerConfig: router,
    ),
  );
}

Future<void> _openSongsTab(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text('Songs')),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => _db = createTestDatabase());
  tearDownAll(() => _db.close());
  setUp(() {
    _requests.clear();
    _summaryKeys.clear();
  });

  testWidgets('Genres tab shows rows with counts and opens the genre page', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _app(<Object?>[
        ..._commonOverrides(genres: const [_hipHop, _rock]),
        genreSummaryProvider.overrideWith((ref, key) async => _hipHop),
        genreAlbumsProvider.overrideWith((ref, request) async => const []),
        genreSongsProvider.overrideWith((ref, request) async => const []),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genres'), findsOneWidget);
    // The most songs first by default.
    expect(
      tester.getTopLeft(find.text('Rock')).dy,
      lessThan(tester.getTopLeft(find.text('Hip-Hop')).dy),
    );
    expect(find.text('40 songs • 5 albums'), findsOneWidget);
    expect(find.text('12 songs • 3 albums'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('genre-row-hiphop')));
    await tester.pumpAndSettle();
    expect(find.text('12 songs • 3 albums'), findsOneWidget);
    expect(find.text('Hip-Hop'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Songs'), findsOneWidget);
  });

  const many = <GenreSummary>[
    _hipHop,
    _rock,
    GenreSummary(key: 'jazz', name: 'Jazz', songCount: 9, albumCount: 2),
    GenreSummary(key: 'folk', name: 'Folk', songCount: 8, albumCount: 2),
    GenreSummary(
      key: 'a-very-long-genre-name-that-must-ellipsize-on-one-line',
      name: 'A very long genre name that must ellipsize on one line',
      songCount: 7,
      albumCount: 1,
    ),
  ];

  group('wide windows', () {
    Finder card(String key) => find.byKey(ValueKey<String>('genre-row-$key'));

    testWidgets('show uniform cards in a grid and open the genre', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1400, 900));
      await tester.pumpWidget(
        _app(<Object?>[
          ..._commonOverrides(genres: many),
          genreSummaryProvider.overrideWith((ref, key) async => _hipHop),
          genreAlbumsProvider.overrideWith((ref, request) async => const []),
          genreSongsProvider.overrideWith((ref, request) async => const []),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      final sizes = <Size>{
        for (final genre in many) tester.getSize(card(genre.key)),
      };
      expect(sizes, hasLength(1));
      expect(sizes.single.width, inInclusiveRange(220, 260));
      expect(sizes.single.height, 92);
      // More than one column, and the cards sit on the page inset.
      final tops = <double>{
        for (final genre in many) tester.getTopLeft(card(genre.key)).dy,
      };
      expect(tops.length, lessThan(many.length));
      final geometry = ContentLayout.genres(1400 - 48);
      expect(
        <double>[
          for (final genre in many) tester.getTopLeft(card(genre.key)).dx,
        ].reduce((a, b) => a < b ? a : b),
        closeTo(24 + (1352 - geometry.occupiedWidth) / 2, 0.01),
      );
      expect(find.text('40 songs • 5 albums'), findsOneWidget);

      await tester.tap(card('hiphop'));
      await tester.pumpAndSettle();
      expect(find.text('Albums'), findsOneWidget);
      expect(find.text('Songs'), findsOneWidget);
    });

    testWidgets('a single genre is one card, and name sort keeps letters', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1400, 900));
      await tester.pumpWidget(
        _app(_commonOverrides(genres: const [_rock, _hipHop])),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('genresSortControl')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name (A-Z)').last);
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      expect(card('rock'), findsOneWidget);
      expect(tester.getSize(card('rock')), tester.getSize(card('hiphop')));
      expect(find.byKey(const Key('genreAlphabetRail')), findsOneWidget);
    });

    testWidgets('large text makes the cards taller, not clipped', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1400, 900));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_app(_commonOverrides(genres: many)));
      await tester.pumpAndSettle();
      expect(tester.getSize(card('rock')).height, 184);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('searching asks for the typed text and can be cleared', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _app(_commonOverrides(genres: const [_hipHop, _rock])),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ro');
    await tester.pumpAndSettle();
    expect(_requests.last.query, 'ro');
    expect(find.text('Rock'), findsOneWidget);
    expect(find.text('Hip-Hop'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No results for "zzz"'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('genresClearFiltersAction')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hip-Hop'), findsOneWidget);
    expect(_requests.last.query, '');
  });

  testWidgets('sorting by name groups under letters, non-Latin under #', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _app(_commonOverrides(genres: const [_hipHop, _rock, _jpop])),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('genreAlphabetRail')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('genresSortControl')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (A-Z)').last);
    await tester.pumpAndSettle();

    expect(_requests.last.sort, GenreSortOrder.name);
    expect(find.byKey(const Key('genreAlphabetRail')), findsOneWidget);
    final rail = find.byKey(const Key('genreAlphabetRail'));
    for (final letter in ['#', 'H', 'R']) {
      expect(
        find.descendant(of: rail, matching: find.text(letter)),
        findsOneWidget,
        reason: letter,
      );
    }
  });

  group('empty states', () {
    testWidgets('explain that genres come from the server tags', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_app(_commonOverrides(genres: const [])));
      await tester.pumpAndSettle();

      expect(find.text('No Genres Yet'), findsOneWidget);
      expect(find.textContaining("server's songs"), findsOneWidget);
      expect(find.text('Reading Genres'), findsNothing);
    });

    testWidgets('say the library is still syncing before the first read', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(_commonOverrides(genres: const [], pendingSync: true)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Reading Genres'), findsOneWidget);
      expect(find.text('No Genres Yet'), findsNothing);
    });
  });

  testWidgets('a hidden Genres page leaves the Library tabs', (tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _app(_commonOverrides(genres: const [_rock], genresPage: false)),
    );
    await tester.pumpAndSettle();
    // Every page is hidden, so the Library offers the recovery state.
    expect(find.text('Rock'), findsNothing);
    expect(find.text('No Library Pages Enabled'), findsOneWidget);
  });

  group('genre page', () {
    Future<_QueueSpy> pumpDetail(
      WidgetTester tester, {
      String key = 'hiphop',
      bool songsTab = false,
      bool exists = true,
      List<SongsTableData> pageSongs = const [],
    }) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final queue = _QueueSpy();
      await tester.pumpWidget(
        _app(<Object?>[
          ..._commonOverrides(genres: const [_hipHop]),
          queueProvider.overrideWith(() => queue),
          genreSummaryProvider.overrideWith((ref, k) async {
            _summaryKeys.add(k);
            return exists ? _hipHop : null;
          }),
          genreAlbumsProvider.overrideWith((ref, request) async => const []),
          genreSongsProvider.overrideWith((ref, request) async => pageSongs),
        ], initial: AppRoutes.genre(key)),
      );
      await tester.pumpAndSettle();
      if (songsTab) await _openSongsTab(tester);
      return queue;
    }

    testWidgets('opens by a key with a slash and shows its header', (
      tester,
    ) async {
      await pumpDetail(tester, key: 'drum/bass');
      expect(_summaryKeys, contains('drum/bass'));
      expect(find.text('12 songs • 3 albums'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('genrePlayAction')),
        findsOneWidget,
      );
    });

    testWidgets('is framed like other detail pages on a desktop window', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        _app(
          <Object?>[
            ..._commonOverrides(genres: const [_hipHop]),
            genreSummaryProvider.overrideWith((ref, k) async => _hipHop),
            genreAlbumsProvider.overrideWith((ref, request) async => const []),
            genreSongsProvider.overrideWith((ref, request) async => const []),
          ],
          initial: AppRoutes.genre('hiphop'),
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: true,
            viewportSize: const Size(1280, 800),
            safePadding: EdgeInsets.zero,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DesktopFrame), findsOneWidget);
    });

    testWidgets('can open on the Songs tab', (tester) async {
      await pumpDetail(tester, songsTab: true);
      expect(
        tester
            .widget<TabBar>(
              find.descendant(
                of: find.byType(GenreDetailScreen),
                matching: find.byType(TabBar),
              ),
            )
            .controller!
            .index,
        1,
      );
      expect(
        find.byKey(const ValueKey<String>('genreSongsSortControl')),
        findsOneWidget,
      );
    });

    testWidgets('a sync epoch change keeps the tab and typed search', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(<Object?>[
          ..._commonOverrides(genres: const [_hipHop]),
          genreDataEpochProvider.overrideWith((ref) => ref.watch(_epoch)),
          genreSummaryProvider.overrideWith((ref, k) async {
            ref.watch(genreDataEpochProvider);
            return _hipHop;
          }),
          genreAlbumsProvider.overrideWith((ref, request) async => const []),
          genreSongsProvider.overrideWith((ref, request) async => const []),
        ], initial: AppRoutes.genre('hiphop')),
      );
      await tester.pumpAndSettle();
      await _openSongsTab(tester);
      final field = find.descendant(
        of: find.byType(GenreDetailScreen),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'boom');
      await tester.pump();

      ProviderScope.containerOf(tester.element(find.byType(GenreDetailScreen)))
          .read(_epoch.notifier)
          .bump();
      await tester.pump();

      expect(tester.widget<TextField>(field).controller!.text, 'boom');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'boom');
      expect(
        tester
            .widget<TabBar>(
              find.descendant(
                of: find.byType(GenreDetailScreen),
                matching: find.byType(TabBar),
              ),
            )
            .controller!
            .index,
        1,
      );
    });

    testWidgets('an unknown genre says it is gone', (tester) async {
      await pumpDetail(tester, key: 'nope', exists: false);
      expect(
        find.text('This genre is no longer in your library.'),
        findsOneWidget,
      );
    });

    testWidgets('Play and Shuffle queue every song of the genre', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await _db.libraryDao.upsertSongs([
          for (final n in [1, 2, 3])
            SongsTableCompanion.insert(
              id: 'g$n',
              title: 'Song $n',
              genres: Value<List<String>?>(const ['Hip-Hop']),
            ),
        ]);
      });
      final queue = await pumpDetail(tester);

      await tester.tap(find.byKey(const ValueKey<String>('genrePlayAction')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(queue.ids, ['g1', 'g2', 'g3']);
      expect(queue.originalOrder, isNull);

      await tester.tap(
        find.byKey(const ValueKey<String>('genreShuffleAction')),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(queue.ids!.toSet(), {'g1', 'g2', 'g3'});
      expect(queue.originalOrder, ['g1', 'g2', 'g3']);
    });
  });

  group('genre page content (real providers)', () {
    Future<void> settleDb(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    Future<_QueueSpy> pumpReal(
      WidgetTester tester, {
      required String key,
      bool songsTab = false,
      Size size = const Size(390, 844),
    }) async {
      setAdaptiveTestViewport(tester, size);
      final queue = _QueueSpy();
      await tester.pumpWidget(
        _app(<Object?>[
          ..._commonOverrides(genres: const []),
          queueProvider.overrideWith(() => queue),
        ], initial: AppRoutes.genre(key)),
      );
      await settleDb(tester);
      if (songsTab) {
        await _openSongsTab(tester);
        await settleDb(tester);
      }
      return queue;
    }

    Future<void> seedSongs(WidgetTester tester, String genre, int count) =>
        tester.runAsync(
          () => _db.libraryDao.upsertSongs([
            for (var n = 1; n <= count; n++)
              SongsTableCompanion.insert(
                id: '$genre-$n',
                title: '$genre ${n.toString().padLeft(3, '0')}',
                genres: Value<List<String>?>(<String>[genre]),
              ),
          ]),
        );

    Future<void> seedJazz(WidgetTester tester) => tester.runAsync(() async {
      await _db.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(id: 'jz-al1', name: 'Blue Hour'),
        AlbumsTableCompanion.insert(id: 'jz-al2', name: 'Alpha Moon'),
      ]);
      await _db.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'jz-1',
          title: 'Blue Song',
          albumId: const Value('jz-al1'),
          artistName: const Value('Abe'),
          genres: Value<List<String>?>(const ['Jazz']),
        ),
        SongsTableCompanion.insert(
          id: 'jz-2',
          title: 'Alpha Song',
          albumId: const Value('jz-al2'),
          artistName: const Value('Zed'),
          genres: Value<List<String>?>(const ['Jazz']),
        ),
      ]);
    });

    double top(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dy;

    Future<void> typeSearch(WidgetTester tester, String text) async {
      await tester.enterText(
        find.descendant(
          of: find.byType(GenreDetailScreen),
          matching: find.byType(TextField),
        ),
        text,
      );
    }

    testWidgets('Albums tab lists the genre\'s albums and searches within', (
      tester,
    ) async {
      await seedJazz(tester);
      await pumpReal(tester, key: 'jazz');

      final blue = find.byKey(const ValueKey<String>('genre-album-jz-al1'));
      final alpha = find.byKey(const ValueKey<String>('genre-album-jz-al2'));
      expect(blue, findsOneWidget);
      expect(alpha, findsOneWidget);
      expect(top(tester, alpha), lessThanOrEqualTo(top(tester, blue)));

      await typeSearch(tester, 'blue');
      await tester.pump(const Duration(milliseconds: 100));
      expect(alpha, findsOneWidget, reason: 'the search waits for a pause');
      await tester.pump(const Duration(milliseconds: 200));
      await settleDb(tester);
      expect(blue, findsOneWidget);
      expect(alpha, findsNothing);

      await typeSearch(tester, 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await settleDb(tester);
      expect(find.byType(AlbumCard), findsNothing);
    });

    testWidgets('Albums tab follows downloaded-only', (tester) async {
      await seedJazz(tester);
      await tester.runAsync(
        () => _db.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'jz-1',
            filePath: '/music/jz-1.mp3',
            fileSize: 1,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime(2026),
          ),
        ),
      );
      await pumpReal(tester, key: 'jazz');
      await tester.tap(find.text('Downloaded'));
      await settleDb(tester);
      expect(
        find.byKey(const ValueKey<String>('genre-album-jz-al1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('genre-album-jz-al2')),
        findsNothing,
      );
      await tester.tap(find.text('Downloaded'));
      await settleDb(tester);
    });

    testWidgets('Songs tab sorts and searches within the genre', (
      tester,
    ) async {
      await seedJazz(tester);
      await pumpReal(tester, key: 'jazz', songsTab: true);

      final blue = find.text('Blue Song');
      final alpha = find.text('Alpha Song');
      expect(top(tester, alpha), lessThan(top(tester, blue)));

      await tester.tap(
        find.byKey(const ValueKey<String>('genreSongsSortControl')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Artist').last);
      await settleDb(tester);
      // By artist, Abe's Blue Song now leads Zed's Alpha Song.
      expect(top(tester, blue), lessThan(top(tester, alpha)));

      await typeSearch(tester, 'blue');
      await tester.pump(const Duration(milliseconds: 300));
      await settleDb(tester);
      expect(blue, findsOneWidget);
      expect(alpha, findsNothing);
    });

    testWidgets('Songs tab loads the next page on scroll and restarts on a '
        'filter change', (tester) async {
      await seedSongs(tester, 'Pager', 130);
      final limits = <int>[];
      setAdaptiveTestViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        _app(<Object?>[
          ..._commonOverrides(genres: const []),
          genreSongsProvider.overrideWith((ref, request) {
            limits.add(request.limit);
            ref.watch(genreDataEpochProvider);
            return _db.libraryDao.getSongsByGenre(
              request.key,
              sort: request.sort,
              downloadedOnly: request.downloadedOnly,
              query: request.query,
              limit: request.limit,
            );
          }),
        ], initial: AppRoutes.genre('pager')),
      );
      await settleDb(tester);
      await _openSongsTab(tester);
      await settleDb(tester);
      expect(limits, <int>[100]);

      for (
        var i = 0;
        i < 60 && find.text('Pager 130').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, -2000),
        );
        await settleDb(tester);
      }
      expect(limits, contains(200));
      expect(find.text('Pager 130'), findsOneWidget);

      // Nothing is downloaded, so toggling the filter empties the list; the
      // next read starts again at the first page.
      await tester.fling(
        find.byType(CustomScrollView).last,
        const Offset(0, 20000),
        20000,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Downloaded'));
      await settleDb(tester);
      expect(limits.last, 100);
    });

    testWidgets('tapping a song queues the whole genre, not the loaded page', (
      tester,
    ) async {
      await seedSongs(tester, 'Rock', 130);
      final queue = await pumpReal(tester, key: 'rock', songsTab: true);

      await tester.tap(find.text('Rock 003'));
      await settleDb(tester);

      expect(queue.ids, hasLength(130));
      expect(queue.ids![queue.startIndex!], 'Rock-3');
    });
  });
}
