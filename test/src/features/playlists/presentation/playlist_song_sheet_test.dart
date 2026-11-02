import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

const _id = 'pl';
const _playlist = PlaylistsTableData(
  isLocal: false,
  id: _id,
  name: 'Mix',
  owner: 'Navis',
);
const _songs = <SongsTableData>[
  SongsTableData(
    id: 's1',
    title: 'First song',
    artistId: 'ar1',
    artistName: 'Artist',
    albumId: 'al1',
    albumName: 'Album',
    isProvisional: false,
    isExternal: false,
  ),
  SongsTableData(
    id: 's2',
    title: 'Second song',
    artistId: 'ar1',
    artistName: 'Artist',
    albumId: 'al1',
    albumName: 'Album',
    isProvisional: false,
    isExternal: false,
  ),
];

class _Sync extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> requestTarget(
    LibrarySyncTarget target, {
    bool requireFresh = false,
  }) async => const LibrarySyncState.idle();
}

/// Mirrors the phone shell in `app_shell.dart`: the branch navigator sits above
/// a 64 dp mini-player spacer, with an 80 dp bottom bar below.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool miniPlayer,
  double textScale = 1.0,
}) async {
  setAdaptiveTestViewport(tester, size);
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.reset);
  final db = createTestDatabase();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        db,
        overrides: [
          librarySyncControllerProvider.overrideWith(_Sync.new),
          playlistViewerProvider.overrideWithValue('navis'),
          playlistByIdProvider(_id)
              .overrideWith((ref) => Stream.value(_playlist)),
          playlistSongsProvider(_id)
              .overrideWith((ref) => Stream.value(_songs)),
          playlistDetailSyncProvider(_id).overrideWith((ref) async {}),
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const PlaylistDetailScreen(playlistId: _id),
                  ),
                ),
              ),
              if (miniPlayer) const SizedBox(height: 64),
            ],
          ),
          bottomNavigationBar: const SizedBox(height: 80),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSheetAndScrollToRemove(WidgetTester tester) async {
  final row = find.text('First song');
  await tester.scrollUntilVisible(row, 100);
  await tester.longPress(row);
  await tester.pumpAndSettle();
  final remove = find.text('Remove from Playlist');
  expect(remove, findsOneWidget);
  await tester.ensureVisible(remove);
  await tester.pumpAndSettle();
}

void main() {
  for (final mini in [true, false]) {
    testWidgets('phone song sheet keeps Remove reachable (miniPlayer=$mini)', (
      tester,
    ) async {
      await _pump(tester, size: const Size(393, 851), miniPlayer: mini);
      await _openSheetAndScrollToRemove(tester);
      expect(tester.takeException(), isNull);
      final remove = find.text('Remove from Playlist');
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(tester.getRect(remove).bottom, lessThanOrEqualTo(sheet.bottom));
      expect(remove.hitTestable(), findsOneWidget);
    });
  }

  testWidgets('small phone with large text scrolls the sheet to Remove', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(360, 640),
      miniPlayer: true,
      textScale: 1.3,
    );
    await _openSheetAndScrollToRemove(tester);
    expect(tester.takeException(), isNull);
    final remove = find.text('Remove from Playlist');
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(tester.getRect(remove).bottom, lessThanOrEqualTo(sheet.bottom));
    expect(remove.hitTestable(), findsOneWidget);
  });
}
