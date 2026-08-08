import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_screen.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  group('MatchFlowScreen', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    testWidgets('expands disabled contents with muted controls', (
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

      expect(find.text('Song A'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Opacity && widget.opacity < 1,
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('reorders songs without widget exceptions', (tester) async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-a', title: 'Song A'),
        SongsTableCompanion.insert(id: 'song-b', title: 'Song B'),
        SongsTableCompanion.insert(id: 'song-c', title: 'Song C'),
      ]);
      final flowId = await database.matchFlowDao.createFlow(name: 'Warmup');
      await database.matchFlowDao.addSong(flowId, 'song-a');
      await database.matchFlowDao.addSong(flowId, 'song-b');
      await database.matchFlowDao.addSong(flowId, 'song-c');

      await tester.pumpWidget(_buildTestApp(database));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Flow Contents'));
      await tester.pump(const Duration(milliseconds: 250));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.drag_handle).first),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('marks the paused song inside expanded flow contents', (
      tester,
    ) async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-a', title: 'Song A'),
        SongsTableCompanion.insert(id: 'song-b', title: 'Song B'),
      ]);
      final flowId = await database.matchFlowDao.createFlow(name: 'Warmup');
      await database.matchFlowDao.addSong(flowId, 'song-a');
      await database.matchFlowDao.addSong(flowId, 'song-b');

      await tester.pumpWidget(
        _buildTestApp(
          database,
          playbackSnapshot: const PlaybackSnapshot(
            queueSongIds: <String>['song-b'],
            currentSongId: 'song-b',
            currentIndex: 0,
            playing: false,
            processingState: AudioProcessingState.ready,
            position: Duration.zero,
            duration: Duration(minutes: 3),
            bufferedPosition: Duration.zero,
            shuffleMode: AudioServiceShuffleMode.none,
            repeatMode: AudioServiceRepeatMode.none,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Flow Contents'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.selected == true &&
              widget.properties.value == 'Now Playing',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('renames flow without disposed controller exceptions', (
      tester,
    ) async {
      await database.matchFlowDao.createFlow(name: 'Warmup');

      await tester.pumpWidget(_buildTestApp(database));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('Warmup'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cooldown');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('Cooldown'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}

Widget _buildTestApp(
  NavisDatabase database, {
  PlaybackSnapshot? playbackSnapshot,
}) {
  return ProviderScope(
    overrides: withTestDatabase(
      database,
      overrides: [
        if (playbackSnapshot != null)
          playerStateProvider.overrideWithValue(playbackSnapshot),
      ],
    ),
    child: MaterialApp(
      theme: testTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const MatchFlowScreen(),
    ),
  );
}
