import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_song_search_screen.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('MatchFlowSongSearchScreen', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('debounced search updates results without setState errors', (
      tester,
    ) async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'alpha', title: 'Alpha Song'),
        SongsTableCompanion.insert(id: 'beta', title: 'Beta Song'),
      ]);

      await tester.pumpWidget(_buildTestApp(database));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(SearchBar), 'Alpha');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Alpha Song'), findsOneWidget);
      expect(find.text('Beta Song'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('uses cached fuzzy song search', (tester) async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'bohemian-rhapsody',
          title: 'Bohemian Rhapsody',
        ),
        SongsTableCompanion.insert(id: 'another-song', title: 'Another Song'),
      ]);

      await tester.pumpWidget(_buildTestApp(database));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(SearchBar), 'boh rhap');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Bohemian Rhapsody'), findsOneWidget);
      expect(find.text('Another Song'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

Widget _buildTestApp(NavisDatabase database) {
  return ProviderScope(
    overrides: withTestDatabase(database),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const MatchFlowSongSearchScreen(flowId: 'flow-id'),
    ),
  );
}
