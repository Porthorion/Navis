import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/presentation/playlist_detail_screen.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/test_theme.dart';

const _playlistId = 'playlist-detail-test';

const _playlist = PlaylistsTableData(
  id: _playlistId,
  name: 'A deliberately long desktop playlist title',
  owner: 'Navis',
);

void main() {
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
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
