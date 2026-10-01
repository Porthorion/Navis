import 'package:drift/drift.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artist_grid_card.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';

void main() {
  testWidgets('shared artist album and track cards mark remote sources', (
    tester,
  ) async {
    if (!sqliteAvailable) return;
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.libraryDao.upsertProvisionalArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(
        id: 'ext-artist',
        name: 'Remote Artist',
        isExternal: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertProvisionalAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'ext-album',
        name: 'Remote Album',
        artistId: const Value('ext-artist'),
        isExternal: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'ext-song',
        title: 'Remote Song',
        artistId: const Value('ext-artist'),
        albumId: const Value('ext-album'),
        isExternal: const Value(true),
      ),
    ]);
    final artist = (await database.libraryDao.getArtistById('ext-artist'))!;
    final album = (await database.libraryDao.getAlbumById('ext-album'))!;
    final song = (await database.libraryDao.getSongById('ext-song'))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...withTestDatabase(database),
          subsonicApiProvider.overrideWithValue(null),
          coverArtShapeProvider.overrideWithValue('rounded'),
          artistCardShapeProvider.overrideWithValue('rounded'),
        ],
        child: MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                ColoredBox(
                  key: const ValueKey<String>('local-track-row'),
                  color: Colors.transparent,
                  child: TrackListTile(
                    song: song.copyWith(
                      id: 'local-song',
                      title: 'Local Song',
                      isExternal: false,
                    ),
                    showAlbumArt: true,
                  ),
                ),
                ColoredBox(
                  key: const ValueKey<String>('remote-track-row'),
                  color: Colors.transparent,
                  child: TrackListTile(song: song, showAlbumArt: true),
                ),
                SizedBox(
                  width: 150,
                  height: 150,
                  child: AlbumCard(album: album),
                ),
                SizedBox(
                  width: 150,
                  height: 180,
                  child: ArtistGridCard(artist: artist),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsNWidgets(3));
    expect(
      tester.getSize(find.byKey(const ValueKey('local-track-row'))).height,
      tester.getSize(find.byKey(const ValueKey('remote-track-row'))).height,
    );
  });
}
