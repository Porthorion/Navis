import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
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

void main() {
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
}
