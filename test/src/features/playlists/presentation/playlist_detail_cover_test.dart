import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

SongsTableData _song(String id, String? cover) => SongsTableData(
  id: id,
  title: id,
  coverArt: cover,
  isExternal: false,
  isProvisional: false,
);

void main() {
  Future<void> render(
    WidgetTester tester, {
    required PlaylistsTableData playlist,
    required List<SongsTableData> songs,
    required bool mobile,
  }) async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final size = mobile ? const Size(360, 1200) : const Size(1000, 900);
    setAdaptiveTestViewport(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            playlistByIdProvider(playlist.id)
                .overrideWith((ref) => Stream.value(playlist)),
            playlistSongsProvider(playlist.id)
                .overrideWith((ref) => Stream.value(songs)),
            playlistDetailSyncProvider(playlist.id)
                .overrideWith((ref) async {}),
          ],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: !mobile,
              viewportSize: size,
              safePadding: EdgeInsets.zero,
            ),
            child: PlaylistDetailScreen(playlistId: playlist.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const device = PlaylistsTableData(
    isLocal: true,
    id: 'local:mix',
    name: 'Mix',
    coverArt: 'art-a',
  );

  for (final mobile in [false, true]) {
    final layout = mobile ? 'mobile' : 'desktop';

    testWidgets('$layout device header tiles its songs\' distinct covers', (
      tester,
    ) async {
      await render(
        tester,
        playlist: device,
        mobile: mobile,
        songs: [
          _song('1', 'art-a'),
          _song('2', 'art-a'),
          _song('3', 'art-b'),
          _song('4', null),
        ],
      );
      final mosaic = tester.widget<PlaylistCoverMosaic>(
        find.byType(PlaylistCoverMosaic),
      );
      expect(mosaic.coverArtIds.toSet(), {'art-a', 'art-b'});
      expect(mosaic.size, mobile ? 180 : 220);
    });

    testWidgets('$layout server header keeps its own cover', (tester) async {
      await render(
        tester,
        playlist: const PlaylistsTableData(
          isLocal: false,
          id: 'srv',
          name: 'Server',
          coverArt: 'pl-srv',
        ),
        mobile: mobile,
        songs: [_song('1', 'art-a'), _song('2', 'art-b')],
      );
      expect(find.byType(PlaylistCoverMosaic), findsNothing);
      expect(
        tester
            .widgetList<CoverArtImage>(find.byType(CoverArtImage))
            .map((image) => image.coverArtId),
        contains('pl-srv'),
      );
    });

    testWidgets('$layout empty device header keeps the placeholder', (
      tester,
    ) async {
      await render(
        tester,
        playlist: const PlaylistsTableData(
          isLocal: true,
          id: 'local:empty',
          name: 'Empty',
        ),
        mobile: mobile,
        songs: const [],
      );
      expect(find.byType(PlaylistCoverMosaic), findsNothing);
      expect(find.byIcon(Icons.queue_music), findsOneWidget);
    });
  }
}
