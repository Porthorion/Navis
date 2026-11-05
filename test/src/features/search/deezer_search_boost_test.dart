import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';

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

    test(
      'of several copies, all share the rank and the on-server one leads',
      () {
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
        expect(boost.popularity.songs, <String, int>{
          'library-copy': 0,
          'remote-copy': 0,
        });
        expect(_topIds(boost), <String>['song:library-copy']);
      },
    );

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

  group('copies of one song', () {
    test('a remote direct-id copy never outranks the library copy', () {
      const result = SearchResult3(
        songs: <Song>[
          Song(
            id: 'local1',
            title: 'Hello',
            artist: 'Adele',
            isExternal: false,
          ),
          Song(
            id: 'ext-deezer-song-5',
            title: 'Hello',
            artist: 'Adele',
            isExternal: true,
          ),
          Song(
            id: 'local2',
            title: 'Hello',
            artist: 'Lionel Richie',
            isExternal: false,
          ),
        ],
      );
      final boost = matchDeezerSearchHits(
        result: result,
        hits: DeezerSearchHits(
          tracks: [
            _track(5, 'Hello', 'Adele'),
            _track(6, 'Hello', 'Lionel Richie'),
          ],
        ),
      );
      expect(boost.popularity.songs, <String, int>{
        'local1': 0,
        'ext-deezer-song-5': 0,
        'local2': 1,
      });
      expect(_topIds(boost).first, 'song:local1');
      final ranked = rankSearchResult(
        result,
        'Hello',
        popularity: boost.popularity,
      );
      expect(ranked.songs.map((song) => song.id), <String>[
        'local1',
        'ext-deezer-song-5',
        'local2',
      ]);
    });

    test('every duplicate copy in the library shares the rank', () {
      const result = SearchResult3(
        songs: <Song>[
          Song(id: 'l1', title: 'Hello', artist: 'Adele', album: '25'),
          Song(id: 'l3', title: 'Hello', artist: 'Lionel Richie'),
          Song(
            id: 'l2',
            title: 'Hello',
            artist: 'Adele',
            album: 'Greatest Hits',
          ),
        ],
      );
      final boost = matchDeezerSearchHits(
        result: result,
        hits: DeezerSearchHits(
          tracks: [
            _track(1, 'Hello', 'Adele'),
            _track(2, 'Hello', 'Lionel Richie'),
          ],
        ),
      );
      expect(boost.popularity.songs, <String, int>{'l1': 0, 'l2': 0, 'l3': 1});
      final ranked = rankSearchResult(
        result,
        'Hello',
        popularity: boost.popularity,
      );
      expect(ranked.songs.map((song) => song.id), <String>['l1', 'l2', 'l3']);
    });

    test('cover versions in any bracket or dash suffix are skipped', () {
      for (final title in <String>[
        'Hello (Piano Cover)',
        'Hello - Piano Cover',
        'Hello (Acoustic Cover)',
        'Hello [Cover]',
      ]) {
        final boost = matchDeezerSearchHits(
          result: SearchResult3(
            songs: <Song>[Song(id: 'c', title: title, artist: 'Adele')],
          ),
          hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
        );
        expect(boost.popularity.songs, isEmpty, reason: title);
      }
    });

    test('a bare title containing "cover" still matches', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(id: 'cm', title: 'Cover Me', artist: 'Bruce Springsteen'),
          ],
        ),
        hits: DeezerSearchHits(
          tracks: [_track(1, 'Cover Me', 'Bruce Springsteen')],
        ),
      );
      expect(boost.popularity.songs, <String, int>{'cm': 0});
    });

    test('a karaoke or tribute copy is not the song Deezer ranked', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(
              id: 'karaoke',
              title: 'Hello (Karaoke Version)',
              artist: 'Adele',
            ),
            Song(
              id: 'tribute',
              title: 'Hello - Tribute to Adele',
              artist: 'Adele',
            ),
            Song(id: 'instr', title: 'Hello [Instrumental]', artist: 'Adele'),
          ],
        ),
        hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, isEmpty);
      expect(boost.topResults, isEmpty);
    });

    test('a karaoke marker the Deezer title shares is no reason to skip', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(id: 'k', title: 'Hello (Karaoke Version)', artist: 'Adele'),
          ],
        ),
        hits: DeezerSearchHits(
          tracks: [_track(1, 'Hello (Karaoke Version)', 'Adele')],
        ),
      );
      expect(boost.popularity.songs, <String, int>{'k': 0});
    });

    test('the original is picked when a karaoke copy sits beside it', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          songs: <Song>[
            Song(
              id: 'karaoke',
              title: 'Hello (Karaoke Version)',
              artist: 'Adele',
            ),
            Song(id: 'original', title: 'Hello', artist: 'Adele'),
          ],
        ),
        hits: DeezerSearchHits(tracks: [_track(1, 'Hello', 'Adele')]),
      );
      expect(boost.popularity.songs, <String, int>{'original': 0});
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
