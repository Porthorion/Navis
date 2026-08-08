import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artist_grid_card.dart';
import 'package:navis/src/common_widgets/external_source_badge.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';

void main() {
  testWidgets('shared artist album and track cards badge external rows', (
    tester,
  ) async {
    if (!sqliteAvailable) return;
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.libraryDao.upsertProvisionalArtists(
      <ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'ext-artist',
          name: 'Remote Artist',
          isExternal: const Value(true),
        ),
      ],
    );
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ListView(
              children: <Widget>[
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
                TrackListTile(song: song, showAlbumArt: true),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(ExternalSourceBadge.semanticsKey), findsNWidgets(3));
  });
}
