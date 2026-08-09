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

    expect(
      result.songs.map((song) => song.id),
      <String>['remote-exact', 'server-prefix'],
    );
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

    expect(
      result.artists.map((artist) => artist.id),
      <String>[
        'server-second',
        'server-third',
        'remote-first',
        'remote-fourth',
      ],
    );
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

      expect(
        result.albums.map((album) => album.id),
        <String>[
          'remote-imported',
          'ordinary-fallback',
          'ordinary-remote',
          'ext-fallback',
        ],
      );
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
}
