import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';

DeezerTrack _track(
  int id,
  String title,
  String artist, {
  int? rank,
  String? album,
}) => DeezerTrack(
  id: id,
  title: title,
  artist: DeezerArtist(id: id, name: artist),
  rank: rank,
  album: album == null ? null : DeezerAlbum(id: id, title: album),
);

DeezerAlbum _album(int id, String title, String artist) => DeezerAlbum(
  id: id,
  title: title,
  artist: DeezerArtist(id: id, name: artist),
);

List<String> _topIds(DeezerSearchBoost boost) => [
  for (final top in boost.topResults)
    switch (top) {
      TopArtistResult(:final artist) => 'artist:${artist.id}',
      TopAlbumResult(:final album) => 'album:${album.id}',
      TopSongResult(:final song) => 'song:${song.id}',
    },
];

void main() {
  group('songs', () {
    test('a library row named ext-deezer-song-<id> matches directly', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(id: 'ext-deezer-song-3135556', title: 'Completely different'),
          ],
        ),
        hits: DeezerSearchHits(tracks: [_track(3135556, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, <String, int>{
        'ext-deezer-song-3135556': 0,
      });
    });

    test('title and artist match through the track matcher', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(id: 'karaoke', title: 'Hello', artist: 'Karaoke Stars'),
            Song(id: 'adele', title: 'Hello (Remastered)', artist: 'Adele'),
            Song(id: 'other', title: 'Rolling in the Deep', artist: 'Adele'),
          ],
        ),
        hits: DeezerSearchHits(
          tracks: [
            _track(1, 'Easy On Me', 'Adele'),
            _track(2, 'Hello', 'Adele', album: '25'),
            _track(3, 'Rolling in the Deep', 'Adele'),
          ],
        ),
      );
      // Position 0 matched nothing; positions keep Deezer's order.
      expect(boost.popularity.songs, <String, int>{'adele': 1, 'other': 2});
    });

    test('an unmatched hit is dropped and adds nothing', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[Song(id: 'a', title: 'Hello', artist: 'Someone Else')],
        ),
        hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, isEmpty);
      expect(boost.topResults, isEmpty);
    });

    test('of several library copies, the on-server one wins over remote', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(
              id: 'remote-copy',
              title: 'Hello',
              artist: 'Adele',
              isExternal: true,
            ),
            Song(
              id: 'library-copy',
              title: 'Hello',
              artist: 'Adele',
              isExternal: false,
            ),
          ],
        ),
        hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, <String, int>{'library-copy': 0});
      expect(_topIds(boost), <String>['song:library-copy']);
    });

    test('a remote copy still matches when the library has none', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(
              id: 'remote-copy',
              title: 'Hello',
              artist: 'Adele',
              isExternal: true,
            ),
          ],
        ),
        hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, <String, int>{'remote-copy': 0});
    });
  });

  group('artists and albums', () {
    test('artists match by normalized name or the ext-deezer-artist id', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          artists: <Artist>[
            Artist(id: 'tribute', name: 'Radiohead Tribute Band'),
            Artist(id: 'a1', name: 'radiohead'),
            Artist(id: 'ext-deezer-artist-9', name: 'Odd Name'),
          ],
        ),
        hits: DeezerSearchHits(
          artists: [
            const DeezerArtist(id: 399, name: 'Radiohead'),
            const DeezerArtist(id: 9, name: 'Somebody'),
          ],
        ),
      );
      expect(boost.popularity.artists, <String, int>{
        'a1': 0,
        'ext-deezer-artist-9': 1,
      });
    });

    test('albums need the title and the artist to match', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          albums: <Album>[
            Album(id: 'cover-band', name: 'OK Computer', artist: 'Cover Band'),
            Album(id: 'real', name: 'OK Computer', artist: 'Radiohead'),
            Album(id: 'ext-deezer-album-5', name: 'Whatever', artist: 'X'),
          ],
        ),
        hits: DeezerSearchHits(
          albums: [
            _album(1, 'OK Computer', 'Radiohead'),
            _album(5, 'Anything', 'Anyone'),
          ],
        ),
      );
      expect(boost.popularity.albums, <String, int>{
        'real': 0,
        'ext-deezer-album-5': 1,
      });
    });

    test('names that normalize to nothing never match', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          artists: <Artist>[Artist(id: 'a', name: '(live)')],
        ),
        hits: DeezerSearchHits(
          artists: [const DeezerArtist(id: 1, name: '(demo)')],
        ),
      );
      expect(boost.popularity.artists, isEmpty);
    });
  });

  group('top results', () {
    const result = SearchResult3(
      artists: <Artist>[Artist(id: 'ar', name: 'Adele')],
      albums: <Album>[Album(id: 'al', name: '25', artist: 'Adele')],
      songs: <Song>[
        Song(id: 's1', title: 'Hello', artist: 'Adele'),
        Song(id: 's2', title: 'Easy On Me', artist: 'Adele'),
      ],
    );

    test(
      'are matched hits in Deezer order, artist before album before song',
      () {
        final boost = matchDeezerSearchHits(
          result: result,
          hits: DeezerSearchHits(
            artists: [const DeezerArtist(id: 1, name: 'Adele')],
            albums: [_album(2, '25', 'Adele')],
            tracks: [
              _track(3, 'Unknown track', 'Nobody'),
              _track(4, 'Hello', 'Adele'),
            ],
          ),
        );
        expect(_topIds(boost), <String>['artist:ar', 'album:al', 'song:s1']);
      },
    );

    test('hold at most three', () {
      final boost = matchDeezerSearchHits(
        result: result,
        hits: DeezerSearchHits(
          artists: [const DeezerArtist(id: 1, name: 'Adele')],
          albums: [_album(2, '25', 'Adele')],
          tracks: [
            _track(3, 'Hello', 'Adele'),
            _track(4, 'Easy On Me', 'Adele'),
          ],
        ),
      );
      expect(_topIds(boost), <String>['artist:ar', 'album:al', 'song:s1']);
      expect(boost.popularity.songs, <String, int>{'s1': 0, 's2': 1});
    });

    test('are empty when nothing matches, and without hits', () {
      expect(
        matchDeezerSearchHits(
          result: result,
          hits: DeezerSearchHits(tracks: [_track(1, 'Nope', 'Nobody')]),
        ).topResults,
        isEmpty,
      );
      final empty = matchDeezerSearchHits(
        result: result,
        hits: const DeezerSearchHits(),
      );
      expect(empty.topResults, isEmpty);
      expect(empty.popularity.songs, isEmpty);
    });
  });
}
