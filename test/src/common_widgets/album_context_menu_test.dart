import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

class _MockPlaylistActions extends Mock implements PlaylistActions {}

const _mine = PlaylistsTableData(
  isLocal: false,
  id: 'mine',
  name: 'My Mix',
  owner: 'me',
  songCount: 0,
);

const _album = AlbumsTableData(
  isProvisional: false,
  isExternal: false,
  id: 'album-1',
  name: 'Night Album',
  songsHydrated: true,
  artists: [],
);

SongsTableData _song(String id) =>
    SongsTableData(id: id, title: id, isProvisional: false, isExternal: false);

Future<_MockPlaylistActions> _pump(
  WidgetTester tester, {
  required bool desktop,
  List<SongsTableData> songs = const [],
}) async {
  final actions = _MockPlaylistActions();
  when(() => actions.addSongs(any(), any()))
      .thenAnswer((_) async => (added: 1, alreadyThere: 0, failed: 0));
  final database = createTestDatabase();
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          subsonicApiProvider.overrideWithValue(null),
          playlistViewerProvider.overrideWithValue('me'),
          playlistActionsProvider.overrideWithValue(actions),
          playlistListProvider.overrideWithValue(
            const AsyncData(<PlaylistsTableData>[_mine]),
          ),
          albumProvider.overrideWith(
            (ref, id) =>
                Stream.value(AlbumWithSongs(album: _album, songs: songs)),
          ),
        ],
      ),
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () => showAlbumContextMenu(
                  context,
                  ref,
                  'album-1',
                  anchor: desktop ? const Offset(400, 200) : null,
                ),
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_mine);
    registerFallbackValue(<String>[]);
  });

  for (final desktop in <bool>[false, true]) {
    final kind = desktop ? 'desktop' : 'mobile';

    testWidgets('$kind album menu adds the album songs to a playlist', (
      tester,
    ) async {
      final actions = await _pump(
        tester,
        desktop: desktop,
        songs: [_song('s1'), _song('s2')],
      );

      await tester.tap(find.text('Add to Playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My Mix'));
      await tester.pumpAndSettle();

      verify(() => actions.addSongs(_mine, const <String>['s1', 's2']))
          .called(1);
    });

    testWidgets('$kind album menu disables Add to Playlist with no songs', (
      tester,
    ) async {
      final actions = await _pump(tester, desktop: desktop);

      await tester.tap(find.text('Add to Playlist'));
      await tester.pumpAndSettle();

      expect(find.text('My Mix'), findsNothing);
      verifyNever(() => actions.addSongs(any(), any()));
    });
  }
}
