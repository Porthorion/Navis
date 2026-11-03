import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/genre_chips.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

void main() {
  group('albumGenres', () {
    test('merges spellings by key, most common first', () {
      expect(
        albumGenres(<List<String>?>[
          ['Hip Hop', 'Rock'],
          ['Hip-Hop'],
          ['Hip-Hop', 'Jazz'],
          null,
          ['Rock'],
          ['-'],
        ]),
        ['Hip-Hop', 'Rock', 'Jazz'],
      );
    });

    test('is empty when no song has genres', () {
      expect(albumGenres(<List<String>?>[null, const []]), isEmpty);
    });
  });

  group('GenreChips', () {
    final notices = AppNoticeController();
    late GoRouter router;

    Future<void> pump(
      WidgetTester tester, {
      required bool genresPage,
      List<String> genres = const ['Hip Hop', 'Rock'],
      bool inSheet = false,
    }) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final db = createTestDatabase();
      addTearDown(db.close);
      router = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: inSheet
                  ? Center(
                      child: TextButton(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          builder: (_) => GenreChips(genres: genres),
                        ),
                        child: const Text('Open sheet'),
                      ),
                    )
                  : GenreChips(genres: genres),
            ),
          ),
          GoRoute(
            path: '/library/genres/:key',
            builder: (context, state) =>
                Text('genre page ${state.pathParameters['key']}'),
          ),
          GoRoute(
            path: '/settings/appearance',
            builder: (context, state) =>
                Text('appearance focus=${state.uri.queryParameters['focus']}'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            db,
            overrides: [showGenresPageProvider.overrideWithValue(genresPage)],
          ),
          child: MaterialApp.router(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => AppNoticeScope(
              notifier: notices,
              child: Stack(
                children: <Widget>[
                  child!,
                  AppNoticeHost(controller: notices),
                ],
              ),
            ),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a chip opens the genre page by its merge key', (tester) async {
      await pump(tester, genresPage: true);
      await tester.tap(find.text('Hip Hop'));
      await tester.pumpAndSettle();
      expect(find.text('genre page hiphop'), findsOneWidget);
    });

    testWidgets('with the page hidden a chip offers the Appearance setting', (
      tester,
    ) async {
      await pump(tester, genresPage: false);
      await tester.tap(find.text('Rock'));
      await tester.pump();

      expect(find.text('Genre page disabled'), findsOneWidget);
      expect(find.text('genre page rock'), findsNothing);

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('appearance focus=libraryPages'), findsOneWidget);
    });

    testWidgets('Show still works after the sheet holding the chip closed', (
      tester,
    ) async {
      await pump(tester, genresPage: false, inSheet: true);
      await tester.tap(find.text('Open sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rock'));
      await tester.pump();
      expect(find.text('Genre page disabled'), findsOneWidget);

      Navigator.of(tester.element(find.text('Rock'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Rock'), findsNothing);

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('appearance focus=libraryPages'), findsOneWidget);
    });

    testWidgets('ten or more genres wrap onto further rows', (tester) async {
      await pump(
        tester,
        genresPage: true,
        genres: [for (var i = 0; i < 12; i++) 'Genre number $i'],
      );
      final tops = {
        for (var i = 0; i < 12; i++)
          tester.getTopLeft(find.text('Genre number $i')).dy,
      };
      expect(tops.length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song without genres shows nothing', (tester) async {
      await pump(tester, genresPage: true, genres: const []);
      expect(find.byType(ActionChip), findsNothing);
    });
  });
}
