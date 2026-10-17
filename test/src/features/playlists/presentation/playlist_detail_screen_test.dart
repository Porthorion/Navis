import 'package:material_ui/material_ui.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/queue_replace_spy.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

const _playlistId = 'playlist-detail-test';

const _playlist = PlaylistsTableData(
  isLocal: false,
  id: _playlistId,
  name: 'A deliberately long desktop playlist title',
  owner: 'Navis',
);

class _MockPlaylistActions extends Mock implements PlaylistActions;

class _MockApi extends Mock implements SubsonicApiClient;

class _RecordingSync extends LibrarySyncController {
  final targets = <LibrarySyncTarget>[];

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> requestTarget(LibrarySyncTarget target) async {
    targets.add(target);
    return const LibrarySyncState.idle();
  }
}

const _twoSongs = <SongsTableData>[
  SongsTableData(
    id: 'playlist-1',
    title: 'First song',
    isProvisional: false,
    isExternal: false,
  ),
  SongsTableData(
    id: 'playlist-2',
    title: 'Second song',
    isProvisional: false,
    isExternal: false,
  ),
];

/// Pumps the mobile detail screen for [playlist] as seen by [viewer].
Future<AppNoticeController> _pumpEditableDetail(
  WidgetTester tester,
  PlaylistsTableData playlist, {
  String? viewer,
  required PlaylistActions actions,
}) async {
  setAdaptiveTestViewport(tester, const Size(390, 844));
  final database = createTestDatabase();
  addTearDown(database.close);
  final notices = AppNoticeController();
  addTearDown(notices.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: [
          playlistViewerProvider.overrideWithValue(viewer),
          playlistActionsProvider.overrideWithValue(actions),
          playlistByIdProvider(_playlistId)
              .overrideWith((ref) => Stream.value(playlist)),
          playlistSongsProvider(_playlistId)
              .overrideWith((ref) => Stream.value(_twoSongs)),
          playlistDetailSyncProvider(_playlistId).overrideWith((ref) async {}),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          songDownloadStateProvider.overrideWith(
            (ref, songId) => SongDownloadState.none,
          ),
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            AppNoticeScope(notifier: notices, child: child!),
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: false,
            viewportSize: const Size(390, 844),
            safePadding: EdgeInsets.zero,
          ),
          child: const PlaylistDetailScreen(playlistId: _playlistId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return notices;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_playlist);
    registerFallbackValue(<String>[]);
  });

  for (final albumQueue in <bool>[true, false]) {
    for (final fromMenu in <bool>[false, true]) {
      testWidgets(
        'playlist ${fromMenu ? 'Play now menu' : 'row tap'} with Album Queue '
        '${albumQueue ? 'on' : 'off'}',
        (tester) async {
          setAdaptiveTestViewport(tester, const Size(390, 844));
          final database = createTestDatabase();
          addTearDown(database.close);
          const songs = <SongsTableData>[
            SongsTableData(
              id: 'playlist-1',
              title: 'First song',
              isProvisional: false,
              isExternal: false,
            ),
            SongsTableData(
              id: 'playlist-2',
              title: 'Second song',
              isProvisional: false,
              isExternal: false,
            ),
            SongsTableData(
              id: 'playlist-3',
              title: 'Third song',
              isProvisional: false,
              isExternal: false,
            ),
          ];
          await tester.pumpWidget(
            ProviderScope(
              overrides: withTestDatabase(
                database,
                overrides: [
                  albumQueueEnabledProvider.overrideWithValue(albumQueue),
                  queueProvider.overrideWith(QueueReplaceSpy.new),
                  playlistByIdProvider(_playlistId)
                      .overrideWith((ref) => Stream.value(_playlist)),
                  playlistSongsProvider(_playlistId)
                      .overrideWith((ref) => Stream.value(songs)),
                  playlistDetailSyncProvider(_playlistId)
                      .overrideWith((ref) async {}),
                  appSettingsProvider.overrideWithValue(
                    const AsyncData(AppSettingsModel.defaults()),
                  ),
                  songDownloadStateProvider.overrideWith(
                    (ref, songId) => SongDownloadState.none,
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
                  child: const PlaylistDetailScreen(playlistId: _playlistId),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final queue = ProviderScope.containerOf(
            tester.element(find.byType(PlaylistDetailScreen)),
          ).read(queueProvider.notifier) as QueueReplaceSpy;

          if (fromMenu) {
            await tester.longPress(find.text('Second song'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Play now'));
          } else {
            await tester.tap(find.text('Second song'));
          }
          await tester.pumpAndSettle();

          // Song-menu playback retains its whole-playlist behavior.
          final queueAll = fromMenu || albumQueue;
          expect(
            queue.lastReplaceIds,
            queueAll
                ? <String>['playlist-1', 'playlist-2', 'playlist-3']
                : <String>['playlist-2'],
          );
          expect(queue.lastStartIndex, queueAll ? 1 : 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  testWidgets('desktop playlist detail uses a continuous tonal header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistViewerProvider.overrideWithValue(null),
          playlistByIdProvider(_playlistId)
              .overrideWith((ref) => Stream.value(_playlist)),
          playlistSongsProvider(_playlistId)
              .overrideWith((ref) => Stream.value(const <SongsTableData>[])),
          playlistDetailSyncProvider(_playlistId).overrideWith((ref) async {}),
          // The header cover reads the cover shape setting.
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(1000, 720),
              safePadding: EdgeInsets.zero,
            ),
            child: const PlaylistDetailScreen(playlistId: _playlistId),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final header = find.byKey(
      const ValueKey<String>('playlist-detail-desktop-header'),
    );
    expect(header, findsOneWidget);
    expect(find.byType(DesktopPanel), findsNothing);
    expect(tester.getRect(header).left, 0);
    expect(tester.getRect(header).width, 1000);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playlist_detail_desktop_header.png'),
    );
  });

  group('playlist edit gating', () {
    for (final readOnly in <PlaylistsTableData>[
      _playlist.copyWith(readOnly: const Value(true)),
      _playlist.copyWith(owner: const Value('alice')),
    ]) {
      testWidgets(
        'hides drag handles and Remove when ${readOnly.readOnly == true ? 'read-only' : 'owned by someone else'}',
        (tester) async {
          await _pumpEditableDetail(
            tester,
            readOnly,
            viewer: 'me',
            actions: _MockPlaylistActions(),
          );

          expect(find.byIcon(Icons.drag_handle), findsNothing);
          await tester.longPress(find.text('Second song'));
          await tester.pumpAndSettle();
          expect(find.text('Play now'), findsOneWidget);
          expect(find.text('Remove from playlist'), findsNothing);
        },
      );
    }

    testWidgets('remove goes through PlaylistActions and reports failure', (
      tester,
    ) async {
      final actions = _MockPlaylistActions();
      when(() => actions.removeAt(any(), any(), any()))
          .thenAnswer((_) async {});
      final notices = await _pumpEditableDetail(
        tester,
        _playlist,
        viewer: 'navis',
        actions: actions,
      );
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));

      await tester.longPress(find.text('Second song'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      verify(
        () => actions.removeAt(any(), <String>['playlist-1', 'playlist-2'], 1),
      ).called(1);
      expect(notices.notice?.message, 'Track removed');

      when(() => actions.removeAt(any(), any(), any()))
          .thenThrow(StateError('boom'));
      await tester.longPress(find.text('First song'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      expect(notices.notice?.message, 'Failed to remove track');
    });

    testWidgets('a failed reorder shows the reorder failure notice', (
      tester,
    ) async {
      final actions = _MockPlaylistActions();
      when(() => actions.reorder(any(), any(), any(), any()))
          .thenThrow(StateError('boom'));
      final notices = await _pumpEditableDetail(
        tester,
        _playlist,
        actions: actions,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.drag_handle).first),
      );
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      verify(
        () => actions.reorder(
          any(),
          <String>['playlist-1', 'playlist-2'],
          0,
          any(),
        ),
      ).called(1);
      expect(notices.notice?.message, 'Failed to reorder tracks');
    });
  });

  group('device playlist detail', () {
    testWidgets(
      'shows On this device, makes no server call and edits offline',
      (tester) async {
        setAdaptiveTestViewport(tester, const Size(390, 844));
        final database = createTestDatabase();
        addTearDown(database.close);
        final api = _MockApi();
        final sync = _RecordingSync();
        final notices = AppNoticeController();
        addTearDown(notices.dispose);
        final id = (await tester.runAsync(() async {
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 'a', title: 'First song'),
            SongsTableCompanion.insert(id: 'b', title: 'Second song'),
          ]);
          return database.playlistDao.createLocalPlaylist('Device', ['a', 'b']);
        }))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: withTestDatabase(
              database,
              overrides: [
                subsonicApiProvider.overrideWithValue(api),
                librarySyncControllerProvider.overrideWith(() => sync),
                playlistViewerProvider.overrideWithValue('me'),
                appSettingsProvider.overrideWithValue(
                  const AsyncData(AppSettingsModel.defaults()),
                ),
                songDownloadStateProvider.overrideWith(
                  (ref, songId) => SongDownloadState.none,
                ),
              ],
            ),
            child: MaterialApp(
              theme: testTheme(),
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) =>
                  AppNoticeScope(notifier: notices, child: child!),
              home: AdaptiveContextScope(
                adaptiveContext: resolveAdaptiveContext(
                  desktopRuntime: false,
                  viewportSize: const Size(390, 844),
                  safePadding: EdgeInsets.zero,
                ),
                child: PlaylistDetailScreen(playlistId: id),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('On this device · 2 songs'), findsOneWidget);
        expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
        expect(sync.targets, isEmpty);
        verifyZeroInteractions(api);

        await tester.longPress(find.text('Second song'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove from playlist'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        expect(find.text('On this device · 1 song'), findsOneWidget);
        final remaining = await tester.runAsync(
          () => database.playlistDao.watchPlaylistSongs(id).first,
        );
        expect(remaining!.map((song) => song.id), ['a']);
        expect(sync.targets, isEmpty);
        verifyZeroInteractions(api);
        notices.dismiss();
      },
      skip: !sqliteAvailable,
    );
  });

  testWidgets('an open device playlist moves to its server copy after upload', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final database = createTestDatabase();
    addTearDown(database.close);
    final router = GoRouter(
      initialLocation: AppRoutes.playlist('local:1'),
      routes: [
        GoRoute(
          path: '${AppRoutes.library}/playlists/:id',
          builder: (context, state) => AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: false,
              viewportSize: const Size(390, 844),
              safePadding: EdgeInsets.zero,
            ),
            child: PlaylistDetailScreen(
              key: ValueKey(state.pathParameters['id']),
              playlistId: state.pathParameters['id']!,
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          playlistDetailSyncProvider.overrideWith((ref, id) async {}),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          songDownloadStateProvider.overrideWith(
            (ref, songId) => SongDownloadState.none,
          ),
        ],
      ),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.state.pathParameters['id'], 'local:1');

    container
        .read(playlistMovedToServerProvider.notifier)
        .moved('local:1', 'srv1');
    await tester.pumpAndSettle();

    expect(router.state.pathParameters['id'], 'srv1');
  });
}
