// Phase 1 harness for item A (Top Results ranking v2). Scratch: none of this
// ships. It replays saved real answers (test/fixtures/search_top_results) and
// compares the shipped rule with candidate rules.
//
// The matching is NOT re-implemented: every Deezer hit is run alone through
// the shipped [matchDeezerSearchHits], so each hit reports the item the app
// would match it to (server copy first).
import 'dart:convert';
import 'dart:io';

import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

const _fixtureDir = 'test/fixtures/search_top_results';

class Fixture {
  new(this.name, this.query, this.merged, this.hits);

  final String name;
  final String query;

  /// The server answer merged the way the search controller does.
  final SearchResult3 merged;
  final DeezerSearchHits hits;
}

List<Fixture> loadFixtures() {
  final files =
      Directory(_fixtureDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final file in files) _load(file)];
}

Fixture _load(File file) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final query = json['query'] as String;
  List<T> list<T>(Object? raw, T Function(Map<String, dynamic>) from) => [
    for (final item in raw! as List<dynamic>)
      from(Map<String, dynamic>.from(item as Map)),
  ];
  final server = json['server'] as Map<String, dynamic>;
  final api = rankSearchResult(
    SearchResult3(
      artists: list(server['artist'], Artist.fromJson),
      albums: list(server['album'], Album.fromJson),
      songs: list(server['song'], Song.fromJson),
    ),
    query,
  );
  // The controller merges the local index and the server answer; the local
  // index holds nothing the server answer lacks, so it is empty here.
  final merged = mergeAndRankSearchResults(
    local: const SearchResult3(),
    api: api,
    query: query,
  );
  final deezer = json['deezer'] as Map<String, dynamic>;
  return Fixture(
    file.uri.pathSegments.last.replaceAll('.json', ''),
    query,
    merged,
    DeezerSearchHits(
      artists: list(deezer['artists'], DeezerArtist.fromJson),
      albums: list(deezer['albums'], DeezerAlbum.fromJson),
      tracks: list(deezer['tracks'], DeezerTrack.fromJson),
    ),
  );
}

/// A Deezer hit and the item the shipped matcher gives it.
class Cand {
  new(this.position, this.type, this.item, this.hit);

  final int position;

  /// 0 artist, 1 album, 2 song: the shipped tie order.
  final int type;
  final SearchTopResult item;
  final Object hit;
}

int kindOf(SearchTopResult item) => switch (item) {
  TopArtistResult() => 0,
  TopAlbumResult() => 1,
  TopSongResult() => 2,
};

String idOf(SearchTopResult item) => switch (item) {
  TopArtistResult(:final artist) => artist.id,
  TopAlbumResult(:final album) => album.id,
  TopSongResult(:final song) => song.id,
};

String nameOf(SearchTopResult item) => switch (item) {
  TopArtistResult(:final artist) => artist.name,
  TopAlbumResult(:final album) => album.name,
  TopSongResult(:final song) => song.title,
};

bool isRemote(SearchTopResult item) => switch (item) {
  TopArtistResult(:final artist) => isExternalCatalogSource(
    id: artist.id,
    apiIsExternal: artist.isExternal,
  ),
  TopAlbumResult(:final album) => isExternalCatalogSource(
    id: album.id,
    apiIsExternal: album.isExternal,
  ),
  TopSongResult(:final song) => isExternalCatalogSource(
    id: song.id,
    apiIsExternal: song.isExternal,
  ),
};

/// The matched hits in Deezer order (position, then artist, album, song), each
/// item once: the shipped `top` list before it is cut down.
List<Cand> candidates(Fixture f) {
  final out = <Cand>[];
  final seen = <String>{};
  void add(int position, int type, Object hit, DeezerSearchHits one) {
    final boost = matchDeezerSearchHits(result: f.merged, hits: one);
    if (boost.topResults.isEmpty) return;
    final item = boost.topResults.first;
    if (seen.add('$type:${idOf(item)}')) {
      out.add(Cand(position, type, item, hit));
    }
  }

  for (final (i, hit) in f.hits.artists.indexed) {
    add(i, 0, hit, DeezerSearchHits(artists: [hit]));
  }
  for (final (i, hit) in f.hits.albums.indexed) {
    add(i, 1, hit, DeezerSearchHits(albums: [hit]));
  }
  for (final (i, hit) in f.hits.tracks.indexed) {
    add(i, 2, hit, DeezerSearchHits(tracks: [hit]));
  }
  out.sort((a, b) {
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0 ? byPosition : a.type.compareTo(b.type);
  });
  return out;
}

class Ctx {
  new(this.fixture)
    : cands = candidates(fixture),
      wanted = normalizeMetadata(fixture.query);

  final Fixture fixture;
  final List<Cand> cands;
  final String wanted;

  SearchResult3 get result => fixture.merged;

  /// The shipped rule's answer (All tab).
  late final List<SearchTopResult> current = matchDeezerSearchHits(
    result: fixture.merged,
    hits: fixture.hits,
    query: fixture.query,
    onePerKind: true,
  ).topResults;

  bool exact(SearchTopResult item) =>
      wanted.isNotEmpty && normalizeMetadata(nameOf(item)) == wanted;

  /// Kinds that hold an item named like the query.
  Set<int> get exactKinds => {
    for (final c in cands)
      if (exact(c.item)) c.type,
  };

  /// Deezer's first track that matched an item.
  Cand? get topSong => _first(2);
  Cand? _first(int type) {
    for (final c in cands) {
      if (c.type == type) return c;
    }
    return null;
  }

  DeezerTrack? get topTrack => topSong?.hit as DeezerTrack?;

  /// [current] with the entries of [item]'s kind replaced by [item], first.
  List<SearchTopResult> heroThenCurrent(SearchTopResult item) => [
    item,
    for (final c in current)
      if (kindOf(c) != kindOf(item)) c,
  ];

  bool _sameName(String? a, String? b) =>
      a != null &&
      b != null &&
      artistNamesMatchLoosely(a, b, allowSpacingAndPunctuation: false);

  /// The artist of [song] in the result, server copy first.
  TopArtistResult? artistOfSong(Song song) {
    final byId = [
      for (final a in result.artists)
        if (song.artistId != null && a.id == song.artistId) a,
    ];
    final byName = [
      for (final a in result.artists)
        if (_sameName(a.name, song.artist)) a,
    ];
    final all = [...byId, ...byName];
    if (all.isEmpty) return null;
    // Server copy before a remote one.
    all.sort(
      (a, b) =>
          (isExternalCatalogSource(id: a.id, apiIsExternal: a.isExternal)
                  ? 1
                  : 0)
              .compareTo(
                isExternalCatalogSource(id: b.id, apiIsExternal: b.isExternal)
                    ? 1
                    : 0,
              ),
    );
    return TopArtistResult(all.first);
  }

  /// The album of [song] in the result, server copy first.
  TopAlbumResult? albumOfSong(Song song) {
    final all = [
      for (final a in result.albums)
        if ((song.albumId != null && a.id == song.albumId) ||
            (song.album != null &&
                normalizeMetadata(a.name) == normalizeMetadata(song.album!) &&
                _sameName(a.artist, song.artist)))
          a,
    ];
    if (all.isEmpty) return null;
    all.sort(
      (a, b) =>
          (isExternalCatalogSource(id: a.id, apiIsExternal: a.isExternal)
                  ? 1
                  : 0)
              .compareTo(
                isExternalCatalogSource(id: b.id, apiIsExternal: b.isExternal)
                    ? 1
                    : 0,
              ),
    );
    return TopAlbumResult(all.first);
  }

  /// Deezer's first matched [type] hit by artist [name].
  SearchTopResult? firstBy(int type, String name) {
    for (final c in cands) {
      if (c.type != type) continue;
      final hitArtist = switch (c.hit) {
        DeezerAlbum(:final artist) => artist?.name,
        DeezerTrack(:final artist) => artist.name,
        _ => null,
      };
      if (_sameName(hitArtist, name)) return c.item;
    }
    return null;
  }

  /// Deezer's first matched song whose album is the album named [title].
  SearchTopResult? firstSongOnAlbum(String title) {
    for (final c in cands) {
      if (c.type == 2 &&
          normalizeMetadata((c.hit as DeezerTrack).album?.title ?? '') ==
              normalizeMetadata(title)) {
        return c.item;
      }
    }
    return null;
  }

  /// What relates to [hero], most useful first, at most two entries.
  List<SearchTopResult> relatives(SearchTopResult hero, {bool synth = false}) {
    final out = <SearchTopResult?>[];
    switch (hero) {
      case TopSongResult(:final song):
        out
          ..add(artistOfSong(song) ?? (synth ? _synthArtist(song) : null))
          ..add(albumOfSong(song) ?? (synth ? _synthAlbum(song) : null));
      case TopArtistResult(:final artist):
        out
          ..add(firstBy(2, artist.name))
          ..add(firstBy(1, artist.name));
      case TopAlbumResult(:final album):
        out
          ..add(
            result.artists
                .where((a) => _sameName(a.name, album.artist))
                .map(TopArtistResult.new)
                .firstOrNull,
          )
          ..add(firstSongOnAlbum(album.name));
    }
    return [for (final r in out) ?r];
  }

  /// The song's own artist as a tile, built from the song's ids when the
  /// search result does not hold the artist (no cover art is known).
  TopArtistResult? _synthArtist(Song song) {
    final id = song.artistId;
    final name = song.artist;
    if (id == null || name == null) return null;
    return TopArtistResult(Artist(id: id, name: name));
  }

  /// The song's own album as a tile, built from the song's ids.
  TopAlbumResult? _synthAlbum(Song song) {
    final id = song.albumId;
    final name = song.album;
    if (id == null || name == null) return null;
    return TopAlbumResult(
      Album(
        id: id,
        name: name,
        artist: song.artist,
        artistId: song.artistId,
        coverArt: song.coverArt,
        year: song.year,
      ),
    );
  }

  /// Exact-named candidates, on-server ones only when there are any.
  List<SearchTopResult> exactPool() {
    final all = [
      for (final cand in cands)
        if (exact(cand.item)) cand.item,
    ];
    final server = [
      for (final item in all)
        if (!isRemote(item)) item,
    ];
    return server.isEmpty ? all : server;
  }

  /// The exact-named item that Deezer's top song points at: the song itself,
  /// else its artist, else its album. Null without a top song or a pointer.
  SearchTopResult? exactTheTopSongPointsAt() {
    final top = topSong;
    if (top == null) return null;
    final song = (top.item as TopSongResult).song;
    final candidates = [
      top.item,
      artistOfSong(song),
      albumOfSong(song),
    ].whereType<SearchTopResult>();
    for (final c in candidates) {
      if (exact(c)) return c;
    }
    return null;
  }
}

/// A rule: the hero first, then the tiles (at most three entries).
typedef Variant = List<SearchTopResult> Function(Ctx c);

List<SearchTopResult> _cap(Iterable<SearchTopResult> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add('${kindOf(item)}:${idOf(item)}')) item,
  ].take(kMaxTopResults).toList();
}

final Map<String, Variant> variants = {
  'current': (c) => c.current,
  // V1: with an exact-name tie between kinds, Deezer's #1 song is the hero.
  'V1': _v1,
  // V2: with a tie, the exact item that Deezer's #1 song points at is the hero
  // (the song, its artist or its album); tiles as today.
  'V2': (c) {
    if (c.exactKinds.length < 2) return c.current;
    final hero = c.exactTheTopSongPointsAt();
    return hero == null ? c.current : _cap(c.heroThenCurrent(hero));
  },
  // V3: V1's hero, and the tiles are only the hero's artist and album (or the
  // hero artist's top song and album).
  'V3': (c) {
    final hero = _v1(c).firstOrNull;
    if (hero == null) return c.current;
    return _cap([hero, ...c.relatives(hero)]);
  },
  // V4: V2's hero but the server's exact items beat a remote one; tiles are the
  // hero's relatives, built from the hero song's ids when the result lacks them.
  'V4': (c) => _v4(c, serverGuard: true),
  // V5: V4 without the server guard.
  'V5': (c) => _v4(c, serverGuard: false),
};

List<SearchTopResult> _v1(Ctx c) {
  if (c.exactKinds.length < 2) return c.current;
  final hero = c.topSong?.item;
  return hero == null ? c.current : _cap(c.heroThenCurrent(hero));
}

/// V4 and V5: the item Deezer's first song points at decides. V4 only lets a
/// remote item win that way if the server holds no exact-named item; otherwise
/// the server's exact items win, a song first.
List<SearchTopResult> _v4(Ctx c, {required bool serverGuard}) {
  SearchTopResult? hero;
  if (c.exactKinds.length >= 2) {
    final pool = c.exactPool();
    final pointed = c.exactTheTopSongPointsAt();
    hero =
        pointed != null &&
            (!serverGuard ||
                pool.any(
                  (p) =>
                      kindOf(p) == kindOf(pointed) && idOf(p) == idOf(pointed),
                ))
        ? pointed
        : pool.whereType<TopSongResult>().firstOrNull ?? pool.firstOrNull;
  }
  hero ??= c.current.firstOrNull;
  if (hero == null) return c.current;
  return _cap([hero, ...c.relatives(hero, synth: true)]);
}

/// The text of one cell: kind, name, artist, source; `~` marks a tile built
/// from the hero song's ids because the search result does not hold it.
String describe(SearchTopResult? item, [SearchResult3? result]) {
  if (item == null) return '–';
  final source = isRemote(item) ? 'R' : 'S';
  final synth =
      result != null &&
      !switch (item) {
        TopArtistResult(:final artist) => result.artists.any(
          (a) => a.id == artist.id,
        ),
        TopAlbumResult(:final album) => result.albums.any(
          (a) => a.id == album.id,
        ),
        TopSongResult(:final song) => result.songs.any((a) => a.id == song.id),
      };
  final mark = '$source${synth ? '~' : ''}';
  return switch (item) {
    TopArtistResult(:final artist) => 'artist: ${artist.name} [$mark]',
    TopAlbumResult(:final album) =>
      'album: ${album.name} — ${album.artist ?? '?'} [$mark]',
    TopSongResult(:final song) =>
      'song: ${song.title} — ${song.artist ?? '?'} [$mark]',
  };
}
