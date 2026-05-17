import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_screen.dart';
import '../../../../helpers/test_database.dart';

void main() {
  group('MatchFlowScreen', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('expands, collapses, and locks contents while disabled', (
      tester,
    ) async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-a', title: 'Song A'),
        SongsTableCompanion.insert(id: 'song-b', title: 'Song B'),
      ]);
      final flowId = await database.matchFlowDao.createFlow(name: 'Warmup');
      await database.matchFlowDao.addSong(flowId, 'song-a');
      await database.matchFlowDao.addSong(flowId, 'song-b');

      await tester.pumpWidget(_buildTestApp(database));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Warmup'), findsOneWidget);
      expect(find.text('Song A'), findsNothing);

      await tester.tap(find.text('Flow Contents'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Song B'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Song A'), findsNothing);

      await tester.tap(find.text('Flow Contents'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Song A'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}

Widget _buildTestApp(NavisDatabase database) {
  return ProviderScope(
    overrides: withTestDatabase(database),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const MatchFlowScreen(),
    ),
  );
}
