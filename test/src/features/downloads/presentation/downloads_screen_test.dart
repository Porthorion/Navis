import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:path/path.dart' as p;

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/domain/backfill_progress.dart';
import 'package:navis/src/features/downloads/domain/download_metadata_gaps.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:navis/src/features/downloads/presentation/download_missing_section.dart';
import 'package:navis/src/features/downloads/presentation/custom_download_folder_controller.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/queue_replace_spy.dart';
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

  for (final albumQueue in <bool>[true, false]) {
    for (final fromMenu in <bool>[false, true]) {
      testWidgets(
        'download ${fromMenu ? 'Play now menu' : 'row tap'} with Album Queue '
        '${albumQueue ? 'on' : 'off'}',
        (tester) async {
          setAdaptiveTestViewport(tester, const Size(390, 844));
          const songs = <SongsTableData>[
            SongsTableData(
              id: 'download-1',
              title: 'First download',
              isProvisional: false,
              isExternal: false,
            ),
            SongsTableData(
              id: 'download-2',
              title: 'Second download',
              isProvisional: false,
              isExternal: false,
            ),
            SongsTableData(
              id: 'download-3',
              title: 'Third download',
              isProvisional: false,
              isExternal: false,
            ),
          ];
          final tracks = songs
              .map(
                (song) => CachedTracksTableData(
                  songId: song.id,
                  filePath: '/tmp/${song.id}.mp3',
                  storageKind: 'filesystem',
                  fileSize: 1000000,
                  format: 'mp3',
                  bitRate: 320,
                  lastAccessedAt: DateTime(2026),
                  cacheType: CacheType.permanent,
                  downloadStatus: DownloadStatus.complete,
                ),
              )
              .toList(growable: false);
          await tester.pumpWidget(
            ProviderScope(
              overrides: withTestDatabase(
                database,
                overrides: [
                  downloadFolderProblemProvider.overrideWithValue(
                    const AsyncData(null),
                  ),
                  albumQueueEnabledProvider.overrideWithValue(albumQueue),
                  queueProvider.overrideWith(QueueReplaceSpy.new),
                  downloadQueueProvider.overrideWithValue(
                    const AsyncData(<DownloadQueueTableData>[]),
                  ),
                  permanentCachedTracksProvider.overrideWithValue(
                    AsyncData(tracks),
                  ),
                  downloadRelatedSongsProvider.overrideWith(
                    (ref) => Stream.value({for (final s in songs) s.id: s}),
                  ),
                  songByIdProvider.overrideWith(
                    (ref, id) =>
                        Stream.value(songs.firstWhere((s) => s.id == id)),
                  ),
                ],
              ),
              child: MaterialApp(
                theme: testTheme(),
                localizationsDelegates: navisLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: AdaptiveContextScope(
                  adaptiveContext: resolveAdaptiveContext(
                    desktopRuntime: false,
                    viewportSize: const Size(390, 844),
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
          final queue = ProviderScope.containerOf(
            tester.element(find.byType(DownloadsScreen)),
          ).read(queueProvider.notifier) as QueueReplaceSpy;

          if (fromMenu) {
            await tester.longPress(find.text('Second download'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Play now'));
          } else {
            await tester.tap(find.text('Second download'));
          }
          await tester.pumpAndSettle();

          expect(
            queue.lastReplaceIds,
            albumQueue
                ? <String>['download-1', 'download-2', 'download-3']
                : <String>['download-2'],
          );
          expect(queue.lastStartIndex, albumQueue ? 1 : 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  for (final size in [
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    testWidgets('folder hold banner persists and recovers at $size', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, size);
      final service = _MockDownloadService();
      when(() => service.configureCustomDownloadFolder(enabled: false))
          .thenAnswer((_) async {});
      final problem = StreamController<DownloadFolderProblem?>.broadcast();
      addTearDown(problem.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              downloadServiceProvider.overrideWithValue(service),
              downloadFolderProblemProvider.overrideWith(
                (ref) => problem.stream,
              ),
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
            home: const DownloadsScreen(),
          ),
        ),
      );
      problem.add(DownloadFolderProblem.unset);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('downloadsFolderHoldBanner')),
        findsOneWidget,
      );
      expect(find.text('Choose folder'), findsOneWidget);
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FakeFilePicker(null);
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();
      verifyNever(
        () => service.configureCustomDownloadFolder(
          enabled: true,
          path: any(named: 'path'),
        ),
      );
      expect(
        find.byKey(const ValueKey('downloadsFolderHoldBanner')),
        findsOneWidget,
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('downloadsFolderHoldBanner')),
        findsOneWidget,
      );
      await tester.tap(find.text('Use app storage'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      verify(() => service.configureCustomDownloadFolder(enabled: false))
          .called(1);
      problem.add(null);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('downloadsFolderHoldBanner')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Use app storage with no configured folder resumes the real queue without a dialog',
    (tester) async {
      setAdaptiveTestViewport(tester, const Size(390, 844));
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('navis_folder_widget_'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final dio = _MockDownloadDio();
      var transfers = 0;
      registerFallbackValue(Uri.parse('https://example.com/rest/stream.view'));
      registerFallbackValue(CancelToken());
      when(
        () => dio.downloadUri(
          any<Uri>(),
          any<dynamic>(),
          cancelToken: any<CancelToken?>(named: 'cancelToken'),
          onReceiveProgress: any<ProgressCallback?>(named: 'onReceiveProgress'),
        ),
      ).thenAnswer((invocation) async {
        transfers++;
        final path = invocation.positionalArguments[1] as String;
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes([1, 2, 3, 4]);
        return Response<void>(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          headers: Headers.fromMap({
            Headers.contentTypeHeader: ['audio/mpeg'],
          }),
        );
      });
      final api = _MockDownloadApi();
      when(
        () => api.streamUrl(
          id: any(named: 'id'),
          maxBitRate: any(named: 'maxBitRate'),
          format: any(named: 'format'),
          estimateContentLength: any(named: 'estimateContentLength'),
        ),
      ).thenReturn(Uri.parse('https://example.com/rest/stream.view'));
      when(() => api.getLyricsBySongId(any()))
          .thenThrow(StateError('No lyrics in this fixture'));
      late AppSettingsTableData settings;
      final service = DownloadService(
        appSettingsDao: database.appSettingsDao,
        cacheDao: database.cacheDao,
        downloadQueueDao: database.downloadQueueDao,
        libraryDao: database.libraryDao,
        readApiClient: () => api,
        readWifiOnly: () => false,
        readIsWifi: () => false,
        readFreeBytes: (_) async => null,
        readCustomDownloadFolderEnabled: () =>
            settings.customDownloadFolderEnabled,
        readCustomDownloadFolderPath: () => settings.customDownloadFolderPath,
        lrclibClient: LrclibClient(),
        readCoverArtCacheManager: _MockDownloadCacheManager.new,
        readApplicationSupportDirectory: () async => root,
        dio: dio,
        isAndroid: true,
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadServiceProvider.overrideWithValue(service),
            customDownloadFolderEnabledProvider.overrideWithValue(true),
            customDownloadFolderPathProvider.overrideWithValue(null),
          ],
        ),
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await database.appSettingsDao.getSettings();
        await database.appSettingsDao.updateCustomDownloadFolderEnabled(
          enabled: true,
        );
        settings = (await database.appSettingsDao.getSettings())!;
        // Create the controller's serialized future in the real async zone,
        // just like the filesystem service below.
        container.read(customDownloadFolderControllerProvider);
        final subscription = database.appSettingsDao.watchSettings().listen(
          (value) => settings = value!,
        );
        addTearDown(subscription.cancel);
        await database.libraryDao.upsertSongs([
          for (var i = 0; i < 2; i++)
            SongsTableCompanion.insert(
              id: 'held-$i',
              title: 'Held $i',
              suffix: const Value('mp3'),
            ),
        ]);
        await service.start();
        for (var i = 0; i < 2; i++) {
          await service.enqueueSong('held-$i', quality: '192', format: 'mp3');
        }
        await service.processQueuedDownloads();
        expect(service.folderProblem, DownloadFolderProblem.unset);
        expect(
          await database.select(database.downloadQueueTable).get(),
          hasLength(2),
        );
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DownloadsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use app storage'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      var queueDrained = false;
      for (var i = 0; i < 800; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        if (transfers == 2 &&
            service.activeQueueIds.isEmpty &&
            !settings.customDownloadFolderEnabled) {
          queueDrained = true;
          break;
        }
      }
      expect(queueDrained, isTrue);
      await tester.runAsync(() async {
        expect(
          await database.select(database.downloadQueueTable).get(),
          isEmpty,
        );
        final settings = (await database.appSettingsDao.getSettings())!;
        expect(settings.customDownloadFolderEnabled, isFalse);
        expect(settings.customDownloadFolderPath, isNull);
        final downloads = await database.cacheDao.getPermanentEntries();
        expect(downloads, hasLength(2));
        for (final entry in downloads) {
          expect(
            p.isWithin(p.join(root.path, 'audio', 'permanent'), entry.filePath),
            isTrue,
          );
          expect(await File(entry.filePath).length(), 4);
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('downloadsFolderHoldBanner')),
        findsNothing,
      );
      expect(service.folderProblem, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(service.dispose);
    },
    skip: !sqliteAvailable,
  );

  for (final previouslyEnabled in [false, true]) {
    testWidgets(
      'cancelling custom folder selection preserves previous location enabled=$previouslyEnabled',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(800, 1800));
        await tester.runAsync(() async {
          await database.appSettingsDao.updateCustomDownloadFolderPath(
            previouslyEnabled ? '/previous' : null,
          );
          await database.appSettingsDao.updateCustomDownloadFolderEnabled(
            enabled: previouslyEnabled,
          );
        });
        final previous = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _FakeFilePicker(null);
        addTearDown(() => FilePickerPlatform.instance = previous);
        await tester.pumpWidget(
          ProviderScope(
            overrides: withTestDatabase(
              database,
              overrides: [
                downloadFolderProblemProvider.overrideWithValue(
                  const AsyncData(null),
                ),
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
              home: const DownloadsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        if (previouslyEnabled) {
          await tester.tap(find.text('Choose Folder'));
        } else {
          await tester.tap(
            find.byKey(const ValueKey('downloadsCustomFolderSwitch')),
          );
        }
        await tester.pumpAndSettle();
        final row = (await tester.runAsync(
          database.appSettingsDao.getSettings,
        ))!;
        expect(row.customDownloadFolderEnabled, previouslyEnabled);
        expect(
          row.customDownloadFolderPath,
          previouslyEnabled ? '/previous' : null,
        );
      },
    );
  }

  testWidgets(
    'a custom folder finishes setting up when the Settings tab is left',
    (tester) async {
      // Tall enough for every folder setting below the download options.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final picker = _FakeFilePicker('/music/navis');
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final service = _FolderService(database);

      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(
            database,
            overrides: [
              downloadFolderProblemProvider.overrideWithValue(
                const AsyncData(null),
              ),
              downloadServiceProvider.overrideWithValue(service),
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
            home: const DownloadsScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Custom Folder'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Moving downloaded tracks...'), findsOneWidget);

      // Leaving the tab disposes it while the folder is still being scanned.
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();
      service.previewGate.complete();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Custom Folder'),
      );
      expect(toggle.value, isTrue);
      expect(find.text('/music/navis'), findsWidgets);
      final matching = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Manual Matching'),
      );
      expect(matching.enabled, isTrue);
      expect(service.calls, <String>[
        'preview /music/navis',
        'configure true /music/navis',
        'import /music/navis',
      ]);
    },
  );

  testWidgets('failed downloads explain the reason and Retry clears it', (
    tester,
  ) async {
    final id = await tester.runAsync(
      () => database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('failed-song'),
          status: DownloadStatus.failed,
          addedAt: DateTime(2026),
          retryCount: const Value(3),
          failureReason: const Value(DownloadFailureReason.truncated),
          failureDetail: const Value('4 / 10 bytes'),
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
            permanentCachedTracksProvider.overrideWithValue(
              const AsyncData(<CachedTracksTableData>[]),
            ),
            downloadRelatedSongsProvider.overrideWith(
              (ref) => Stream.value(<String, SongsTableData>{}),
            ),
            songByIdProvider.overrideWith((ref, id) => Stream.value(null)),
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
    expect(find.text('The download was cut short. Try again.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh).last);
    await tester.pumpAndSettle();
    final item = (await tester.runAsync(
      () => database.downloadQueueDao.watchQueue().first,
    ))!.single;
    expect(item.id, id);
    expect(item.status, DownloadStatus.queued);
    expect(item.failureReason, isNull);
    expect(item.failureDetail, isNull);
    expect(item.retryCount, 0);
    expect(find.text('The download was cut short. Try again.'), findsNothing);
  }, skip: !sqliteAvailable);

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
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
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
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
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
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
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
              downloadFolderProblemProvider.overrideWithValue(
                const AsyncData(null),
              ),
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
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
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

  testWidgets('turning off the custom folder asks first', (tester) async {
    final service = _MockDownloadService();
    when(
      () => service.configureCustomDownloadFolder(
        enabled: any(named: 'enabled'),
        path: any(named: 'path'),
      ),
    ).thenAnswer((_) async {});
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            downloadFolderProblemProvider.overrideWithValue(
              const AsyncData(null),
            ),
            downloadServiceProvider.overrideWithValue(service),
            customDownloadFolderEnabledProvider.overrideWithValue(true),
            customDownloadFolderPathProvider.overrideWithValue('/music/Navis'),
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
              desktopRuntime: false,
              viewportSize: const Size(800, 600),
              safePadding: EdgeInsets.zero,
            ),
            child: const DownloadsScreen(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final folderSwitch = find.widgetWithText(SwitchListTile, 'Custom Folder');

    await tester.tap(folderSwitch);
    await tester.pumpAndSettle();
    expect(find.text('Turn Off Custom Folder?'), findsOneWidget);
    expect(
      find.textContaining('Files in this folder stay where they are'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(
      () => service.configureCustomDownloadFolder(
        enabled: any(named: 'enabled'),
        path: any(named: 'path'),
      ),
    );

    await tester.tap(folderSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn Off'));
    await tester.pumpAndSettle();
    verify(() => service.configureCustomDownloadFolder(enabled: false))
        .called(1);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }

  Widget mobileDownloads(List<Object> overrides) => ProviderScope(
    overrides: withTestDatabase(
      database,
      overrides: [
        downloadFolderProblemProvider.overrideWithValue(const AsyncData(null)),
        ...overrides.cast(),
      ],
    ),
    child: MaterialApp(
      theme: testTheme(),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AdaptiveContextScope(
        adaptiveContext: resolveAdaptiveContext(
          desktopRuntime: false,
          viewportSize: const Size(800, 1200),
          safePadding: EdgeInsets.zero,
        ),
        child: const DownloadsScreen(),
      ),
    ),
  );

  testWidgets('download settings save the quality, format and concurrency', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final service = _MockDownloadService();
    when(() => service.setMaxConcurrentDownloads(any()))
        .thenAnswer((_) async {});
    await tester.pumpWidget(
      mobileDownloads([
        downloadServiceProvider.overrideWithValue(service),
        downloadQueueProvider.overrideWithValue(
          const AsyncData(<DownloadQueueTableData>[]),
        ),
        permanentCachedTracksProvider.overrideWithValue(
          const AsyncData(<CachedTracksTableData>[]),
        ),
      ]),
    );
    await tester.tap(find.text('Settings'));
    await settle(tester);

    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('Ask every time'), findsOneWidget);
    expect(find.textContaining('2 downloads at a time'), findsOneWidget);

    await tester.tap(find.text('Ask every time'));
    await settle(tester);
    await tester.tap(find.text('192 kbps MP3').last);
    await settle(tester);
    var preference = (await tester.runAsync(
      () => database.appSettingsDao.getDownloadQualityPreference(),
    ))!;
    expect(preference.mode, DownloadQualityMode.transcode);
    expect(preference.bitRate, 192);
    // Choosing here answers the one-time question.
    expect(preference.prompted, isTrue);

    await tester.tap(find.text('MP3'));
    await settle(tester);
    await tester.tap(find.text('OPUS').last);
    await settle(tester);
    preference = (await tester.runAsync(
      () => database.appSettingsDao.getDownloadQualityPreference(),
    ))!;
    expect(preference.format, 'opus');
    expect(find.text('192 kbps OPUS'), findsOneWidget);

    await tester.tap(find.text('192 kbps OPUS'));
    await settle(tester);
    await tester.tap(find.text('Original quality').last);
    await settle(tester);
    preference = (await tester.runAsync(
      () => database.appSettingsDao.getDownloadQualityPreference(),
    ))!;
    expect(preference.mode, DownloadQualityMode.original);
    final formatField = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('downloadFormat:opus')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(formatField.onChanged, isNull);

    final slider = find.byKey(
      const ValueKey<String>('downloadsConcurrentSlider'),
    );
    await tester.drag(slider, const Offset(400, 0));
    await settle(tester);
    verify(() => service.setMaxConcurrentDownloads(4)).called(1);
  });

  group('Missing artwork and lyrics', () {
    const gaps = DownloadMetadataGaps(
      songsMissingLyrics: [
        (
          songId: 's1',
          title: 'Silent Song',
          artist: 'Quiet Artist',
          album: 'Hush',
          albumId: 'al1',
          coverArt: 'c1',
          hasSyncedLyrics: false,
          hasPlainLyrics: false,
        ),
        (
          songId: 's2',
          title: 'Wordless',
          artist: null,
          album: null,
          albumId: null,
          coverArt: null,
          hasSyncedLyrics: false,
          hasPlainLyrics: false,
        ),
      ],
      albumsMissingArtwork: [
        (albumId: 'al1', coverArt: 'c1', name: 'Hush', artist: 'Quiet Artist'),
      ],
      totalSongs: 5,
      totalAlbums: 3,
    );
    const none = DownloadMetadataGaps(
      songsMissingLyrics: [],
      albumsMissingArtwork: [],
      totalSongs: 5,
      totalAlbums: 3,
    );

    late StreamController<BackfillProgress> progress;
    late _MockDownloadService service;
    var gapBuilds = 0;

    setUp(() {
      progress = StreamController<BackfillProgress>();
      service = _MockDownloadService();
      gapBuilds = 0;
    });
    tearDown(() {
      unawaited(progress.close());
    });

    Future<void> openSettings(
      WidgetTester tester,
      Future<DownloadMetadataGaps> Function() load, {
      BackfillProgress initial = const BackfillProgress(),
      bool hasApiClient = true,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      progress.add(initial);
      await tester.pumpWidget(
        mobileDownloads([
          downloadServiceProvider.overrideWithValue(service),
          subsonicApiProvider.overrideWithValue(
            hasApiClient ? _MockDownloadApi() : null,
          ),
          downloadMetadataGapsProvider.overrideWith((ref) {
            gapBuilds++;
            return load();
          }),
          downloadBackfillProgressProvider.overrideWith(
            (ref) => progress.stream,
          ),
          downloadQueueProvider.overrideWithValue(
            const AsyncData(<DownloadQueueTableData>[]),
          ),
          permanentCachedTracksProvider.overrideWithValue(
            const AsyncData(<CachedTracksTableData>[]),
          ),
        ]),
      );
      await tester.tap(find.text('Settings'));
      await settle(tester);
    }

    Finder backfillButton() =>
        find.widgetWithText(FilledButton, 'Backfill now');

    testWidgets('shows counts and opens the song and album lists', (
      tester,
    ) async {
      await openSettings(tester, () async => gaps);

      expect(find.text('Missing artwork and lyrics'), findsOneWidget);
      expect(find.text('2 songs without lyrics'), findsOneWidget);
      expect(find.text('1 album without artwork'), findsOneWidget);

      await tester.tap(find.text('2 songs without lyrics'));
      await settle(tester);
      expect(find.text('Silent Song'), findsOneWidget);
      expect(find.text('Quiet Artist'), findsOneWidget);
      expect(find.text('Wordless'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);

      await tester.tap(find.text('1 album without artwork'));
      await settle(tester);
      expect(find.text('Hush'), findsOneWidget);
      expect(find.text('Quiet Artist'), findsOneWidget);
    });

    testWidgets('says nothing is missing when both counts are zero', (
      tester,
    ) async {
      await openSettings(tester, () async => none);

      expect(find.text('Nothing missing'), findsOneWidget);
      expect(find.textContaining('without lyrics'), findsNothing);
      expect(find.textContaining('without artwork'), findsNothing);
    });

    testWidgets('a pending gaps load shows a quiet loading row', (
      tester,
    ) async {
      final load = Completer<DownloadMetadataGaps>();
      await openSettings(tester, () => load.future);
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.text('Nothing missing'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      load.complete(none);
      await settle(tester);
      expect(find.text('Nothing missing'), findsOneWidget);
      expect(find.text('Loading…'), findsNothing);
    });

    testWidgets('signed out or no API client disables Backfill now', (
      tester,
    ) async {
      await openSettings(tester, () async => gaps, hasApiClient: false);
      expect(tester.widget<FilledButton>(backfillButton()).onPressed, isNull);
      verifyNever(() => service.runBackfillNow());
    });

    testWidgets('an offline block keeps Backfill now available for retry', (
      tester,
    ) async {
      when(() => service.runBackfillNow()).thenAnswer((_) async {});
      await openSettings(
        tester,
        () async => gaps,
        initial: const BackfillProgress(
          blockedReason: BackfillBlockedReason.offline,
        ),
      );
      expect(
        tester.widget<FilledButton>(backfillButton()).onPressed,
        isNotNull,
      );
      await tester.tap(backfillButton());
      verify(() => service.runBackfillNow()).called(1);
    });

    testWidgets('a failed gaps load stays quiet', (tester) async {
      await openSettings(tester, () async => throw StateError('disk'));

      expect(find.text('Missing artwork and lyrics'), findsOneWidget);
      expect(
        find.text("Couldn't check missing artwork and lyrics"),
        findsOneWidget,
      );
      expect(find.textContaining('without lyrics'), findsNothing);
      expect(find.text('Nothing missing'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Backfill now runs once, shows progress and refreshes', (
      tester,
    ) async {
      final run = Completer<void>();
      when(() => service.runBackfillNow()).thenAnswer((_) => run.future);
      await openSettings(tester, () async => gaps);
      expect(gapBuilds, 1);
      expect(
        tester.widget<FilledButton>(backfillButton()).onPressed,
        isNotNull,
      );

      await tester.tap(backfillButton());
      progress.add(
        const BackfillProgress(phase: BackfillPhase.lyrics, done: 3, total: 7),
      );
      await settle(tester);

      verify(() => service.runBackfillNow()).called(1);
      expect(tester.widget<FilledButton>(backfillButton()).onPressed, isNull);
      expect(find.text('Finding lyrics'), findsOneWidget);
      expect(find.text('3 of 7'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      run.complete();
      progress.add(
        const BackfillProgress(
          lastResult: (lyricsResolved: 2, artworkStored: 1),
        ),
      );
      await settle(tester);

      expect(gapBuilds, 2);
      expect(
        tester.widget<FilledButton>(backfillButton()).onPressed,
        isNotNull,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('lyrics cooldown shows a live resume countdown', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 10, 18);
      final deadline = now.add(const Duration(seconds: 65));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadMetadataGapsProvider.overrideWith((ref) async => gaps),
            subsonicApiProvider.overrideWithValue(_MockDownloadApi()),
            downloadBackfillProgressProvider.overrideWith(
              (ref) => Stream.value(
                BackfillProgress(
                  blockedReason: BackfillBlockedReason.rateLimited,
                  resumeAt: deadline,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DownloadMissingSection(now: () => now)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Lyrics paused, resuming in 1:05'), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Lyrics paused, resuming in 1:04'), findsOneWidget);
      now = deadline.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Lyrics paused, resuming in 0:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final (reason, text) in [
      (BackfillBlockedReason.offline, 'Offline'),
      (BackfillBlockedReason.wifiOnly, 'Waiting for Wi-Fi'),
      (BackfillBlockedReason.rateLimited, 'Lyrics paused, resuming in'),
    ]) {
      testWidgets('shows the $reason reason', (tester) async {
        await openSettings(
          tester,
          () async => gaps,
          initial: BackfillProgress(blockedReason: reason),
        );

        expect(find.textContaining(text), findsOneWidget);
      });
    }
  });

  testWidgets('the queue pauses, resumes and cancels through the service', (
    tester,
  ) async {
    final service = _MockDownloadService();
    when(() => service.setPaused(paused: any(named: 'paused')))
        .thenAnswer((_) async {});
    when(() => service.cancelQueueItem(any())).thenAnswer((_) async {});
    const song = SongsTableData(
      id: 'song-1',
      title: 'Queued Song',
      artistName: 'Artist',
      isProvisional: false,
      isExternal: false,
    );
    Widget build({required bool paused}) => mobileDownloads([
      downloadServiceProvider.overrideWithValue(service),
      downloadsPausedProvider.overrideWithValue(AsyncData(paused)),
      downloadQueueProvider.overrideWithValue(
        AsyncData(<DownloadQueueTableData>[
          DownloadQueueTableData(
            id: 7,
            songId: song.id,
            status: DownloadStatus.downloading,
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
    ]);

    await tester.pumpWidget(build(paused: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // A transfer without a known length shows an indeterminate bar.
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
    expect(
      find.byKey(const ValueKey<String>('downloadsPausedBanner')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('downloadsPauseToggle')),
    );
    await tester.pump();
    verify(() => service.setPaused(paused: true)).called(1);

    await tester.tap(find.byTooltip('Cancel Download'));
    await tester.pump();
    verify(() => service.cancelQueueItem(7)).called(1);

    await tester.pumpWidget(build(paused: true));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('downloadsPausedBanner')),
      findsOneWidget,
    );
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('downloadsPauseToggle')),
    );
    await tester.pump();
    verify(() => service.setPaused(paused: false)).called(1);
  });
}

class _MockDownloadService extends Mock implements DownloadService;

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

class _FakeFilePicker extends FilePickerPlatform {
  new(this.path);

  final String? path;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => path;
}

/// Stands in for the folder steps of [DownloadService], saving the folder in
/// the test database as the real service does.
class _FolderService extends Fake implements DownloadService {
  new(this.database);

  final NavisDatabase database;
  final List<String> calls = <String>[];
  final Completer<void> previewGate = Completer<void>();

  @override
  Future<PermanentDownloadImportPreview> previewCustomDownloadFolder(
    String path,
  ) async {
    calls.add('preview $path');
    await previewGate.future;
    return PermanentDownloadImportPreview(
      rootPath: path,
      items: const <PermanentDownloadImportItem>[
        PermanentDownloadImportItem(
          relativePath: 'unknown.flac',
          fileSize: 1,
          format: 'flac',
          disposition: PermanentDownloadImportDisposition.unmatched,
        ),
      ],
    );
  }

  @override
  Future<void> configureCustomDownloadFolder({
    required bool enabled,
    String? path,
  }) async {
    calls.add('configure $enabled $path');
    await database.appSettingsDao.updateCustomDownloadFolderPath(path);
    await database.appSettingsDao.updateCustomDownloadFolderEnabled(
      enabled: enabled,
    );
  }

  @override
  Future<PermanentDownloadImportResult> importCustomDownloadFolder(
    PermanentDownloadImportPreview preview, {
    Map<String, String> manualSongIds = const <String, String>{},
    bool includeRecognized = true,
  }) async {
    calls.add('import ${preview.rootPath}');
    return const PermanentDownloadImportResult(
      importedCount: 0,
      skippedCount: 0,
    );
  }
}

class _MockDownloadDio extends Mock implements Dio;

class _MockDownloadCacheManager extends Mock implements BaseCacheManager;

class _MockDownloadApi extends Mock implements SubsonicApiClient;
