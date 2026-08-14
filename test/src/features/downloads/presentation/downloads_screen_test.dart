import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  late NavisDatabase database;

  setUp(() {
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('download queue marks the paused current song', (tester) async {
    const song = SongsTableData(
      id: 'song-1',
      title: 'Downloaded Song',
      artistName: 'Artist',
      isProvisional: false,
      isExternal: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadQueueProvider.overrideWithValue(
              AsyncData(<DownloadQueueTableData>[
                DownloadQueueTableData(
                  id: 1,
                  songId: song.id,
                  status: DownloadStatus.queued,
                  progress: 0,
                  addedAt: DateTime(2026),
                  priority: 0,
                  retryCount: 0,
                ),
              ]),
            ),
            permanentCachedTracksProvider.overrideWithValue(
              const AsyncData(<CachedTracksTableData>[]),
            ),
            songByIdProvider.overrideWith(
              (ref, songId) => Stream.value(song),
            ),
            playerStateProvider.overrideWithValue(_pausedSnapshot(song.id)),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DownloadsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(song.title), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    final selectedTiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((tile) => tile.selected);
    expect(selectedTiles, hasLength(1));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.value == 'Now Playing',
      ),
      findsOneWidget,
    );
  });

  testWidgets('desktop Downloads combines navigation and search in one strip', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadQueueProvider.overrideWithValue(
              const AsyncData(<DownloadQueueTableData>[]),
            ),
            permanentCachedTracksProvider.overrideWithValue(
              const AsyncData(<CachedTracksTableData>[]),
            ),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(800, 600),
              safePadding: EdgeInsets.zero,
            ),
            child: const DownloadsScreen(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('downloadsDesktopCommandStrip')),
      findsOneWidget,
    );
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktopDownloadsBackButton')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

PlaybackSnapshot _pausedSnapshot(String songId) {
  return PlaybackSnapshot(
    queueSongIds: <String>[songId],
    currentSongId: songId,
    currentIndex: 0,
    playing: false,
    processingState: AudioProcessingState.ready,
    position: Duration.zero,
    duration: const Duration(minutes: 3),
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.none,
  );
}
