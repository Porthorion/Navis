import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/normal_playback_metadata_navigation.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('NormalPlaybackMetadataNavigationResolver', () {
    late NavisDatabase database;
    late NormalPlaybackMetadataNavigationResolver resolver;

    setUp(() {
      database = createTestDatabase();
      resolver = NormalPlaybackMetadataNavigationResolver(database.libraryDao);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'opens artist directly from song artist id',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveArtist(
          NormalPlaybackMetadataContext(song: _song(artistId: 'artist-1')),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.artist);
        expect(destination?.id, 'artist-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'opens album directly from media item album id',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveAlbum(
          const NormalPlaybackMetadataContext(
            mediaItem: MediaItem(
              id: 'media-1',
              title: 'Track',
              extras: <String, dynamic>{'albumId': 'album-1'},
            ),
          ),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.album);
        expect(destination?.id, 'album-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'falls back to exact normalized artist name when id is missing',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveArtist(
          const NormalPlaybackMetadataContext(artistName: '  THE   ARTIST  '),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.artist);
        expect(destination?.id, 'artist-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'falls back to exact normalized album name with artist context',
      () async {
        await _seedLibrary(database);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-other',
            name: 'The Album',
            artistId: const Value('artist-2'),
            artistName: const Value('Other Artist'),
          ),
        ]);

        final destination = await resolver.resolveAlbum(
          const NormalPlaybackMetadataContext(
            albumName: 'The Album (Deluxe)',
            artistId: 'artist-1',
          ),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.album);
        expect(destination?.id, 'album-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'ambiguous artist names fall back to artist-filtered search',
      () async {
        await _seedLibrary(database);
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'artist-duplicate',
            name: 'The Artist (Live)',
          ),
        ]);

        final destination = await resolver.resolveArtist(
          const NormalPlaybackMetadataContext(artistName: 'The Artist'),
        );

        _expectFilteredSearch(
          destination,
          query: 'The Artist',
          filter: SearchResultType.artists,
        );
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'title tap opens current song album',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveTitle(
          NormalPlaybackMetadataContext(
            song: _song(albumId: 'album-1', title: 'Anything'),
          ),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.album);
        expect(destination?.id, 'album-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'title tap exact-matches cached song and opens its album',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveTitle(
          const NormalPlaybackMetadataContext(
            title: 'The Track',
            artistName: 'The Artist',
          ),
        );

        expect(destination?.type, NormalPlaybackMetadataDestinationType.album);
        expect(destination?.id, 'album-1');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'title tap falls back to song-filtered search when no album match exists',
      () async {
        await _seedLibrary(database);

        final destination = await resolver.resolveTitle(
          const NormalPlaybackMetadataContext(title: 'Missing Track'),
        );

        _expectFilteredSearch(
          destination,
          query: 'Missing Track',
          filter: SearchResultType.songs,
        );
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );
  });
}

Future<void> _seedLibrary(NavisDatabase database) async {
  await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
    ArtistsTableCompanion.insert(id: 'artist-1', name: 'The Artist'),
    ArtistsTableCompanion.insert(id: 'artist-2', name: 'Other Artist'),
  ]);
  await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
    AlbumsTableCompanion.insert(
      id: 'album-1',
      name: 'The Album',
      artistId: const Value('artist-1'),
      artistName: const Value('The Artist'),
    ),
  ]);
  await database.libraryDao.upsertSongs(<SongsTableCompanion>[
    SongsTableCompanion.insert(
      id: 'song-1',
      title: 'The Track',
      albumId: const Value('album-1'),
      albumName: const Value('The Album'),
      artistId: const Value('artist-1'),
      artistName: const Value('The Artist'),
    ),
  ]);
}

SongsTableData _song({
  String id = 'song-current',
  String title = 'The Track',
  String? albumId,
  String? artistId,
}) {
  return SongsTableData(
    id: id,
    title: title,
    albumId: albumId,
    artistId: artistId,
    artistName: 'The Artist',
    albumName: 'The Album',
    track: null,
    discNumber: null,
    duration: null,
    bitRate: null,
    sampleRate: null,
    contentType: null,
    suffix: null,
    size: null,
    coverArt: null,
    starred: null,
    userRating: null,
    playCount: null,
    createdAt: null,
    replayGainTrackGain: null,
    replayGainAlbumGain: null,
    replayGainTrackPeak: null,
    replayGainAlbumPeak: null,
  );
}

void _expectFilteredSearch(
  NormalPlaybackMetadataDestination? destination, {
  required String query,
  required SearchResultType filter,
}) {
  expect(
    destination?.type,
    NormalPlaybackMetadataDestinationType.filteredSearch,
  );
  expect(destination?.query, query);
  expect(destination?.filter, filter);
}
