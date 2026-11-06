// Regression table for the All tab's Top Results: real Deezer and server
// answers saved in test/fixtures/search_top_results (the search3 answer as the
// app merges it, and Deezer's artist, album and track search), and the hero and
// tiles each must give.
//
// Cell format: `kind: name [— artist] [S|R][~]`. S is on the server, R is
// remote. `~` marks a tile built from the hero song's ids because the search
// answer did not hold it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/utils/catalog_source.dart';

const _fixtureDir = 'test/fixtures/search_top_results';

/// Query -> hero, then tiles.
const _expected = <String, List<String>>{
  'AIRTIME': [
    'song: AIRTIME — ZEXSING [S]',
    'artist: ZEXSING [S~]',
    'album: AIRTIME — ZEXSING [S]',
  ],
  'Bad': [
    'song: Bad — Michael Jackson [S]',
    'artist: Michael Jackson [S~]',
    'album: Bad — Michael Jackson [S]',
  ],
  'Despacito': [
    'song: Despacito — Luis Fonsi [R]',
    'artist: Luis Fonsi [R~]',
    'album: VIDA — Luis Fonsi [R~]',
  ],
  'hello': [
    'song: Hello — Adele [S]',
    'artist: Adele [S~]',
    'album: 25 — Adele [S~]',
  ],
  'Heroes': [
    'song: Heroes — Shinedown [S]',
    'artist: Shinedown [S~]',
    'album: Us and Them (Deluxe Edition) — Shinedown [S~]',
  ],
  'Keichi': ['artist: Keiichi Okabe [R]'],
  'Lose Yourself': [
    'song: Lose Yourself — Eminem [S]',
    'artist: Eminem [S~]',
    'album: 8 Mile (CD1) — Eminem [S~]',
  ],
  'Love': [
    'song: Love — SDM [R]',
    'artist: SDM [R~]',
    'album: OCHO (Deluxe) — SDM [R~]',
  ],
  'Me Necesita': [
    'song: Me Necesita — Ovy On The Drums [S]',
    'artist: Ovy On The Drums [S~]',
    'album: Me Necesita — Ovy On The Drums [S]',
  ],
  'Muse': [
    'artist: Muse [S]',
    'song: Uprising — Muse [S]',
    'album: The Wow! Signal — Muse [S]',
  ],
  'Nirvana': [
    'artist: Nirvana [S]',
    'song: The Man Who Sold The World (Live) — Nirvana [S]',
    'album: MTV Unplugged In New York — Nirvana [R]',
  ],
  'radiohead': [
    'artist: Radiohead [S]',
    'song: Creep — Radiohead [S]',
    'album: OK Computer — Radiohead [S]',
  ],
  'Set Fire to the Rain': [
    'song: Set Fire to the Rain — Adele [S]',
    'artist: Adele [S~]',
    'album: 21 — Adele [S~]',
  ],
  'Thriller': [
    'song: Thriller — Michael Jackson [S]',
    'artist: Michael Jackson [S~]',
    'album: Thriller — Michael Jackson [S]',
  ],
  'Yesterday': [
    'song: YESTERDAY — Hamza [R]',
    'artist: Hamza [R~]',
    'album: MANIA — Hamza [R~]',
  ],
  '夜に駆ける': [
    'song: 夜に駆ける — YOASOBI [R]',
    'artist: YOASOBI [R~]',
    'album: 夜に駆ける — YOASOBI [R]',
  ],
};

({String query, SearchResult3 merged, DeezerSearchHits hits}) _load(File file) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final query = json['query'] as String;
  List<T> list<T>(Object? raw, T Function(Map<String, dynamic>) from) => [
    for (final item in raw! as List<dynamic>)
      from(Map<String, dynamic>.from(item as Map)),
  ];
  final server = json['server'] as Map<String, dynamic>;
  // As the search controller merges them; the local index holds nothing the
  // server answer lacks, so it is empty here.
  final merged = mergeAndRankSearchResults(
    local: const SearchResult3(),
    api: rankSearchResult(
      SearchResult3(
        artists: list(server['artist'], Artist.fromJson),
        albums: list(server['album'], Album.fromJson),
        songs: list(server['song'], Song.fromJson),
      ),
      query,
    ),
    query: query,
  );
  final deezer = json['deezer'] as Map<String, dynamic>;
  return (
    query: query,
    merged: merged,
    hits: DeezerSearchHits(
      artists: list(deezer['artists'], DeezerArtist.fromJson),
      albums: list(deezer['albums'], DeezerAlbum.fromJson),
      tracks: list(deezer['tracks'], DeezerTrack.fromJson),
    ),
  );
}

String _describe(SearchTopResult item, SearchResult3 result) {
  final (name, id, remote, held) = switch (item) {
    TopArtistResult(:final artist) => (
      'artist: ${artist.name}',
      artist.id,
      artist.isExternal,
      result.artists.any((a) => a.id == artist.id),
    ),
    TopAlbumResult(:final album) => (
      'album: ${album.name} — ${album.artist ?? '?'}',
      album.id,
      album.isExternal,
      result.albums.any((a) => a.id == album.id),
    ),
    TopSongResult(:final song) => (
      'song: ${song.title} — ${song.artist ?? '?'}',
      song.id,
      song.isExternal,
      result.songs.any((s) => s.id == song.id),
    ),
  };
  final source = isExternalCatalogSource(id: id, apiIsExternal: remote)
      ? 'R'
      : 'S';
  return '$name [$source${held ? '' : '~'}]';
}

void main() {
  final files =
      Directory(_fixtureDir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final fixtures = [for (final file in files) _load(file)];

  test('every fixture has an expected row, and the other way round', () {
    expect({
      for (final fixture in fixtures) fixture.query,
    }, _expected.keys.toSet());
  });

  for (final fixture in fixtures) {
    test('All tab picks for "${fixture.query}"', () {
      final boost = matchDeezerSearchHits(
        result: fixture.merged,
        hits: fixture.hits,
        query: fixture.query,
        onePerKind: true,
      );
      expect([
        for (final top in boost.topResults) _describe(top, fixture.merged),
      ], _expected[fixture.query]);
    });
  }

  test('a type filter keeps the first three hits in Deezer order', () {
    for (final fixture in fixtures) {
      final boost = matchDeezerSearchHits(
        result: fixture.merged,
        hits: fixture.hits,
        query: fixture.query,
      );
      expect(boost.topResults.length, lessThanOrEqualTo(kMaxTopResults));
    }
  });
}
