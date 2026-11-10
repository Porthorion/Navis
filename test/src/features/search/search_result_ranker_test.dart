import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';

void main() {
  test('relevance remains more important than source', () {
    final result = rankSearchResult(
      const SearchResult3(
        songs: <Song>[
          Song(id: 'server-prefix', title: 'Aurora Live', isExternal: false),
          Song(id: 'remote-exact', title: 'Aurora', isExternal: true),
        ],
      ),
      'Aurora',
    );

    expect(result.songs.map((song) => song.id), <String>[
      'remote-exact',
      'server-prefix',
    ]);
  });

  test('on-server items lead within the same relevance tier', () {
    final result = rankSearchResult(
      const SearchResult3(
        artists: <Artist>[
          Artist(id: 'remote-first', name: 'Aurora One', isExternal: true),
          Artist(id: 'server-second', name: 'Aurora Two', isExternal: false),
          Artist(id: 'server-third', name: 'Aurora Three', isExternal: false),
          Artist(id: 'remote-fourth', name: 'Aurora Four', isExternal: true),
        ],
      ),
      'Aurora',
    );

    expect(result.artists.map((artist) => artist.id), <String>[
      'server-second',
      'server-third',
      'remote-first',
      'remote-fourth',
    ]);
  });

  test(
    'source fallback follows the shared explicit-value-first classifier',
    () {
      final result = rankSearchResult(
        const SearchResult3(
          albums: <Album>[
            Album(id: 'ordinary-remote', name: 'Aurora A', isExternal: true),
            Album(id: 'remote-imported', name: 'Aurora B', isExternal: false),
            Album(id: 'ext-fallback', name: 'Aurora C'),
            Album(id: 'ordinary-fallback', name: 'Aurora D'),
          ],
        ),
        'Aurora',
      );

      expect(result.albums.map((album) => album.id), <String>[
        'remote-imported',
        'ordinary-fallback',
        'ordinary-remote',
        'ext-fallback',
      ]);
    },
  );

  test('merge deduplicates by ID and accepts authoritative API provenance', () {
    final result = mergeAndRankSearchResults(
      local: const SearchResult3(
        songs: <Song>[
          Song(id: 'same-id', title: 'Aurora Local', isExternal: false),
        ],
      ),
      api: const SearchResult3(
        songs: <Song>[
          Song(id: 'same-id', title: 'Replacement', isExternal: true),
          Song(id: 'server-api', title: 'Aurora API', isExternal: false),
        ],
      ),
      query: 'Aurora',
    );

    expect(result.songs, hasLength(2));
    expect(result.songs.first.id, 'server-api');
    expect(result.songs.last.id, 'same-id');
    expect(result.songs.last.title, 'Aurora Local');
    expect(result.songs.last.isExternal, isTrue);
  });

  test('token matches rank ahead of unrelated results', () {
    expect(
      searchRelevanceTier('Live at Aurora Hall', 'Aurora Live'),
      SearchRelevanceTier.tokens,
    );
    expect(
      searchRelevanceTier('Unrelated', 'Aurora Live'),
      SearchRelevanceTier.other,
    );
  });

  test('relevance tiers fold accents', () {
    expect(
      searchRelevanceTier('Café Del Mar', 'cafe'),
      SearchRelevanceTier.prefix,
    );
    expect(
      searchRelevanceTier('Beyoncé', 'BEYONCE'),
      SearchRelevanceTier.exact,
    );
    expect(
      searchRelevanceTier('Édith Piaf', 'dith'),
      SearchRelevanceTier.substring,
    );
  });

  group('popularity', () {
    const karaoke = Song(id: 'karaoke', title: 'Hello', isExternal: false);
    const adele = Song(id: 'adele', title: 'Hello', isExternal: false);
    const cover = Song(id: 'cover', title: 'Hello', isExternal: false);
    const songs = SearchResult3(songs: <Song>[karaoke, cover, adele]);

    List<String> ids(SearchResult3 result) =>
        result.songs.map((song) => song.id).toList();

    test('equal-tier songs reorder by popularity, unranked last', () {
      final result = rankSearchResult(
        songs,
        'Hello',
        popularity: const SearchPopularity(
          songs: <String, int>{'cover': 1, 'adele': 0},
        ),
      );
      expect(ids(result), <String>['adele', 'cover', 'karaoke']);
    });

    test("without popularity the order is exactly today's", () {
      final today = rankSearchResult(songs, 'Hello');
      expect(ids(today), <String>['karaoke', 'cover', 'adele']);
      expect(
        ids(rankSearchResult(songs, 'Hello', popularity: null)),
        ids(today),
      );
      expect(
        ids(
          rankSearchResult(
            songs,
            'Hello',
            popularity: const SearchPopularity(),
          ),
        ),
        ids(today),
      );
    });

    test('popularity never lifts an item over a better text tier', () {
      final result = rankSearchResult(
        const SearchResult3(
          songs: <Song>[
            Song(id: 'prefix-hit', title: 'Hello World'),
            Song(id: 'exact', title: 'Hello'),
          ],
        ),
        'Hello',
        popularity: const SearchPopularity(
          songs: <String, int>{'prefix-hit': 0},
        ),
      );
      expect(ids(result), <String>['exact', 'prefix-hit']);
    });

    test('popularity outranks source inside a tier', () {
      final result = rankSearchResult(
        const SearchResult3(
          albums: <Album>[
            Album(id: 'on-server', name: 'Hello', isExternal: false),
            Album(id: 'remote-hit', name: 'Hello', isExternal: true),
          ],
        ),
        'Hello',
        popularity: const SearchPopularity(
          albums: <String, int>{'remote-hit': 0},
        ),
      );
      expect(result.albums.map((album) => album.id), <String>[
        'remote-hit',
        'on-server',
      ]);
    });

    test('each type reads its own map', () {
      final result = rankSearchResult(
        const SearchResult3(
          artists: <Artist>[
            Artist(id: '1', name: 'Hello'),
            Artist(id: '2', name: 'Hello'),
          ],
        ),
        'Hello',
        popularity: const SearchPopularity(
          songs: <String, int>{'2': 0},
          albums: <String, int>{'2': 0},
        ),
      );
      expect(result.artists.map((artist) => artist.id), <String>['1', '2']);
    });
  });
}
