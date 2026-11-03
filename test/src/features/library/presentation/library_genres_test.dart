import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
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
import 'package:navis/src/routing/app_routes.dart';
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
    this.originalOrder = originalOrder;
  }
}

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
  genresPendingSyncProvider.overrideWith((ref) async => pendingSync),
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

Widget _app(List<Object?> overrides, {String? initial}) {
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
          child: child!,
        ),
      ),
      routerConfig: router,
    ),
  );
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
}
