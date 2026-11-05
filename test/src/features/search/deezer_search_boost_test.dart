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

    test('live, language and remix copies do not share the studio rank', () {
      const result = SearchResult3(
        songs: <Song>[
          Song(id: 'live', title: 'Hello (Live)', artist: 'Adele'),
          Song(id: 'es', title: 'Hello (Spanish Version)', artist: 'Adele'),
          Song(id: 'rmx', title: 'Hello (Remix)', artist: 'Adele'),
          Song(id: 'studio', title: 'Hello', artist: 'Adele'),
          Song(id: 'studio2', title: 'Hello', artist: 'Adele', album: 'Hits'),
          Song(id: 'richie', title: 'Hello', artist: 'Lionel Richie'),
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
      expect(boost.popularity.songs, <String, int>{
        'studio': 0,
        'studio2': 0,
        'richie': 1,
      });
      expect(_topIds(boost).first, 'song:studio');
    });

    test('hyphens alone are not a cover marker, " - Piano Covers" is', () {
      for (final (title, hitTitle, ranked) in <(String, String, bool)>[
        ('Under-Cover Lover', 'Under Cover Lover', true),
        ('Jay-Z Cover Girl', 'Jay Z Cover Girl', true),
        ('Hello - Piano Covers', 'Hello', false),
        ('Hello (Cover Art Version)', 'Hello', false),
      ]) {
        final boost = matchDeezerSearchHits(
          result: SearchResult3(
            songs: <Song>[Song(id: 'c', title: title, artist: 'Adele')],
          ),
          hits: DeezerSearchHits(tracks: [_track(1, hitTitle, 'Adele')]),
        );
        expect(boost.popularity.songs.isNotEmpty, ranked, reason: title);
      }
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

    group('on All (one per kind)', () {
      const library = SearchResult3(
        artists: <Artist>[
          Artist(id: 'ar1', name: 'Pablo Honey Band'),
          Artist(id: 'ar2', name: 'Radiohead'),
        ],
        albums: <Album>[
          Album(id: 'al', name: 'The Bends', artist: 'Radiohead'),
        ],
        songs: <Song>[
          Song(id: 's1', title: 'Creep', artist: 'Radiohead'),
          Song(id: 's2', title: 'Karma Police', artist: 'Radiohead'),
        ],
      );

      DeezerSearchBoost match(DeezerSearchHits hits, [String query = 'q']) =>
          matchDeezerSearchHits(
            result: library,
            hits: hits,
            query: query,
            onePerKind: true,
          );

      test('keep the best hit of each kind, never a second artist', () {
        final boost = match(
          DeezerSearchHits(
            artists: [
              const DeezerArtist(id: 1, name: 'Radiohead'),
              const DeezerArtist(id: 2, name: 'Pablo Honey Band'),
            ],
            albums: [_album(3, 'The Bends', 'Radiohead')],
          ),
        );
        expect(_topIds(boost), <String>['artist:ar2', 'album:al']);
      });

      test('an exact song title leads an artist ranked higher by Deezer', () {
        final boost = match(
          DeezerSearchHits(
            artists: [const DeezerArtist(id: 1, name: 'Radiohead')],
            tracks: [
              _track(10, 'Unknown', 'Nobody'),
              _track(11, 'Unknown', 'Nobody'),
              _track(12, 'Unknown', 'Nobody'),
              _track(13, 'Unknown', 'Nobody'),
              _track(14, 'Creep', 'Radiohead'),
            ],
          ),
          'creep',
        );
        expect(_topIds(boost).first, 'song:s1');
        expect(_topIds(boost), contains('artist:ar2'));
        expect(_topIds(boost), hasLength(2));
      });

      test('case, punctuation and diacritics still count as exact', () {
        final boost = match(
          DeezerSearchHits(
            artists: [const DeezerArtist(id: 1, name: 'Radiohead')],
            albums: [_album(3, 'The Bends', 'Radiohead')],
          ),
          '  THE bends! ',
        );
        expect(_topIds(boost), <String>['album:al', 'artist:ar2']);
      });

      test('without an exact match the order is Deezer position', () {
        final boost = match(
          DeezerSearchHits(
            artists: [
              const DeezerArtist(id: 7, name: 'Nobody'),
              const DeezerArtist(id: 1, name: 'Radiohead'),
            ],
            albums: [
              _album(2, 'Nope', 'Nobody'),
              _album(8, 'Nope', 'Nobody'),
              _album(3, 'The Bends', 'Radiohead'),
            ],
            tracks: [_track(6, 'Creep', 'Radiohead')],
          ),
          'radio',
        );
        expect(_topIds(boost), <String>['song:s1', 'artist:ar2', 'album:al']);
      });

      test('ties on position go artist, album, song', () {
        final boost = match(
          DeezerSearchHits(
            artists: [const DeezerArtist(id: 1, name: 'Radiohead')],
            albums: [_album(2, 'The Bends', 'Radiohead')],
            tracks: [_track(3, 'Creep', 'Radiohead')],
          ),
        );
        expect(_topIds(boost), <String>['artist:ar2', 'album:al', 'song:s1']);
      });

      test('several exact matches keep position, then artist, album, song', () {
        const same = SearchResult3(
          artists: <Artist>[Artist(id: 'ar', name: 'Creep')],
          albums: <Album>[Album(id: 'al', name: 'Creep', artist: 'X')],
          songs: <Song>[Song(id: 's', title: 'Creep', artist: 'X')],
        );
        final boost = matchDeezerSearchHits(
          result: same,
          hits: DeezerSearchHits(
            artists: [
              const DeezerArtist(id: 1, name: 'Other'),
              const DeezerArtist(id: 2, name: 'Creep'),
            ],
            albums: [_album(3, 'Creep', 'X')],
            tracks: [_track(4, 'Other', 'Z'), _track(5, 'Creep', 'X')],
          ),
          query: 'Creep',
          onePerKind: true,
        );
        // artist and album are at position 1 and 0; the song at 1.
        expect(_topIds(boost), <String>['album:al', 'artist:ar', 'song:s']);
      });
    });

    test('a type filter keeps the first three of one kind in order', () {
      final boost = matchDeezerSearchHits(
        result: const SearchResult3(
          albums: <Album>[
            Album(id: 'a1', name: 'One', artist: 'X'),
            Album(id: 'a2', name: 'Two', artist: 'X'),
            Album(id: 'a3', name: 'Three', artist: 'X'),
            Album(id: 'a4', name: 'Four', artist: 'X'),
          ],
        ),
        hits: DeezerSearchHits(
          albums: [
            _album(1, 'Two', 'X'),
            _album(2, 'One', 'X'),
            _album(3, 'Three', 'X'),
            _album(4, 'Four', 'X'),
          ],
        ),
        query: 'one',
      );
      expect(_topIds(boost), <String>['album:a2', 'album:a1', 'album:a3']);
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
