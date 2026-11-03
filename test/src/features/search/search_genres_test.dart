import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart' show InternetRadioStation;
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/search/presentation/search_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import '../../../helpers/reachability_fakes.dart';
import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() {
    database = createTestDatabase();
    // Runs last: the screen is unmounted first (see pumpSearch), so a failing
    // test cannot hang closing a database that streams still watch.
    addTearDown(database.close);
  });

  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(id: 'a1', name: 'Jazz Cats'),
    ]);
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'al1',
        name: 'Blue Hour',
        artistId: const Value('a1'),
      ),
    ]);
    await database.libraryDao.upsertSongs([
      for (final n in [1, 2])
        SongsTableCompanion.insert(
          id: 's$n',
          title: 'Blue Song $n',
          albumId: const Value('al1'),
          genres: Value<List<String>?>(const ['Jazz']),
        ),
    ]);
  });

  Future<void> pumpSearch(
    WidgetTester tester, {
    bool genresPage = true,
    bool offline = false,
  }) async {
    final router = GoRouter(
      initialLocation: AppRoutes.search,
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.search,
          builder: (_, _) => const SearchScreen(),
        ),
        GoRoute(
          path: AppRoutes.library,
          builder: (_, _) => const SizedBox.shrink(),
          routes: <RouteBase>[
            GoRoute(
              path: AppRoutes.genreSegment,
              builder: (_, state) =>
                  Text('genre page ${state.pathParameters['key']}'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            showGenresPageProvider.overrideWithValue(genresPage),
            subsonicApiProvider.overrideWithValue(null),
            radioStationsProvider.overrideWith(
              (ref) async => const <InternetRadioStation>[],
            ),
            serverReachabilityControllerProvider.overrideWith(
              () => StaticReachabilityController(
                ServerReachabilityState(
                  status: offline
                      ? ServerReachabilityStatus.offline
                      : ServerReachabilityStatus.online,
                ),
              ),
            ),
          ],
        ),
        child: MaterialApp.router(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'jazz');
    await tester.pump(const Duration(milliseconds: 350));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('Genres group follows Artists and never matches song titles', (
    tester,
  ) async {
    await seed(tester);
    await pumpSearch(tester);

    expect(find.text('Genres'), findsOneWidget);
    expect(find.text('2 songs • 1 album'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Genres')).dy,
      greaterThan(tester.getTopLeft(find.text('Artists').last).dy),
    );
    // The songs are tagged Jazz but their titles do not say so.
    expect(find.text('Blue Song 1'), findsNothing);
  });

  testWidgets('Genres group works offline', (tester) async {
    await seed(tester);
    await pumpSearch(tester, offline: true);

    expect(
      find.byKey(const ValueKey<String>('searchGenre-jazz')),
      findsOneWidget,
    );
  });

  testWidgets('Genres group is hidden while the Genres page is disabled', (
    tester,
  ) async {
    await seed(tester);
    await pumpSearch(tester, genresPage: false);

    expect(find.text('Jazz Cats'), findsOneWidget);
    expect(find.text('Genres'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('searchGenre-jazz')),
      findsNothing,
    );
  });

  testWidgets('a genre only search still shows results and opens the page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'x1',
          title: 'Plain',
          genres: Value<List<String>?>(const ['Zydeco']),
        ),
      ]);
    });
    await pumpSearch(tester);
    await tester.enterText(find.byType(TextField).first, 'zyde');
    await tester.pump(const Duration(milliseconds: 350));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.byKey(const ValueKey<String>('searchGenre-zydeco')));
    await tester.pumpAndSettle();
    expect(find.text('genre page zydeco'), findsOneWidget);
  });
}
