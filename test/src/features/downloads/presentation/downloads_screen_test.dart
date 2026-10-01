import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
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
            downloadRelatedSongsProvider.overrideWith(
              (ref) => Stream.value({song.id: song}),
            ),
            songByIdProvider.overrideWith((ref, songId) => Stream.value(song)),
            playerStateProvider.overrideWithValue(_pausedSnapshot(song.id)),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
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

  testWidgets('mobile downloaded row keeps delete beside quality metadata', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    const song = SongsTableData(
      id: 'mobile-download',
      title: 'Downloaded Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 223,
      isProvisional: false,
      isExternal: false,
    );
    final track = CachedTracksTableData(
      songId: song.id,
      filePath: '/tmp/mobile-download.mp3',
      storageKind: 'filesystem',
      fileSize: 1000000,
      format: 'mp3',
      bitRate: 320,
      lastAccessedAt: DateTime(2026),
      cacheType: CacheType.permanent,
      downloadStatus: DownloadStatus.complete,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadQueueProvider.overrideWithValue(
              const AsyncData(<DownloadQueueTableData>[]),
            ),
            permanentCachedTracksProvider.overrideWithValue(AsyncData([track])),
            downloadRelatedSongsProvider.overrideWith(
              (ref) => Stream.value({song.id: song}),
            ),
            songByIdProvider.overrideWith((ref, id) => Stream.value(song)),
            playerStateProvider.overrideWithValue(_pausedSnapshot(song.id)),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: false,
              viewportSize: const Size(360, 800),
              safePadding: EdgeInsets.zero,
            ),
            child: const DownloadsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Downloaded'));
    await tester.pumpAndSettle();
    final row = find.byType(AdaptiveTrackRow);
    expect(row, findsOneWidget);
    final bounds = tester.getRect(row);
    expect(bounds.height, lessThan(96));
    expect(tester.widget<AdaptiveTrackRow>(row).actionExtent, 48);
    final delete = find.descendant(of: row, matching: find.byType(IconButton));
    expect(tester.getRect(delete).center.dy, bounds.center.dy);
    expect(tester.getSize(delete), const Size(48, 48));
    expect(find.text('3:43'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
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
          localizationsDelegates: navisLocalizationsDelegates,
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

  testWidgets(
    'desktop downloaded-track menu separates the destructive action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const song = SongsTableData(
        id: 'downloaded-song',
        title: 'Downloaded Song',
        artistName: 'Artist',
        isProvisional: false,
        isExternal: false,
      );
      final track = CachedTracksTableData(
        songId: song.id,
        filePath: '/tmp/downloaded-song.mp3',
        storageKind: 'filesystem',
        fileSize: 1000000,
        format: 'mp3',
        bitRate: 320,
        lastAccessedAt: DateTime(2026),
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              downloadQueueProvider.overrideWithValue(
                const AsyncData(<DownloadQueueTableData>[]),
              ),
              permanentCachedTracksProvider.overrideWithValue(
                AsyncData(<CachedTracksTableData>[track]),
              ),
              downloadRelatedSongsProvider.overrideWith(
                (ref) => Stream.value({song.id: song}),
              ),
              songByIdProvider.overrideWith(
                (ref, songId) => Stream.value(song),
              ),
              playerStateProvider.overrideWithValue(_pausedSnapshot(song.id)),
            ],
          ),
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AdaptiveContextScope(
              adaptiveContext: resolveAdaptiveContext(
                desktopRuntime: true,
                viewportSize: const Size(900, 700),
                safePadding: EdgeInsets.zero,
              ),
              child: const DownloadsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text(song.title)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuDivider), findsOneWidget);
      // Flutter's menu route renders entries through an internal wrapper;
      // preserve the visible destructive action and its separated grouping
      // without asserting that implementation detail.
      expect(find.text('Remove Download'), findsOneWidget);
    },
  );

  testWidgets('Downloads search empty state can restore the full queue', (
    tester,
  ) async {
    const song = SongsTableData(
      id: 'queued-song',
      title: 'Queued Song',
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
            downloadRelatedSongsProvider.overrideWith(
              (ref) => Stream.value({song.id: song}),
            ),
            songByIdProvider.overrideWith((ref, songId) => Stream.value(song)),
            playerStateProvider.overrideWithValue(_pausedSnapshot(song.id)),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DownloadsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();

    expect(find.textContaining('No results for "missing"'), findsOneWidget);
    expect(find.text('Show all'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();

    expect(find.text(song.title), findsOneWidget);
    expect(find.textContaining('No results for "missing"'), findsNothing);
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
