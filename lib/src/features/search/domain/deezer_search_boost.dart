import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/library/data/artist_top_track_resolver.dart'
    show pickBestArtistTopTrackMatch;
import 'package:navis/src/features/library/data/local_track_matcher.dart'
    show TrackMatchQuery;
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Most Top Results Search shows.
const int kMaxTopResults = 3;

/// What Deezer's search returned for the query, each list in Deezer's order
/// (most relevant and popular first). An endpoint that was not asked is empty.
class DeezerSearchHits {
  const new({
    this.artists = const <DeezerArtist>[],
    this.albums = const <DeezerAlbum>[],
    this.tracks = const <DeezerTrack>[],
  });

  final List<DeezerArtist> artists;
  final List<DeezerAlbum> albums;
  final List<DeezerTrack> tracks;
}

/// A Deezer hit that matched a library item, for the Top Results section.
sealed class SearchTopResult {
  const new();
}

final class TopArtistResult extends SearchTopResult {
  const new(this.artist);

  final Artist artist;
}

final class TopAlbumResult extends SearchTopResult {
  const new(this.album);

  final Album album;
}

final class TopSongResult extends SearchTopResult {
  const new(this.song);

  final Song song;
}

/// What Deezer's answer changes in Search: the popularity ranks for
/// [rankSearchResult] and the Top Results.
class DeezerSearchBoost {
  const new({required this.popularity, required this.topResults});

  final SearchPopularity popularity;
  final List<SearchTopResult> topResults;
}

/// Matches Deezer's [hits] to the items already in [result] (the merged
/// library and server answer). It only ranks: nothing is added that [result]
/// does not hold, and a hit with no match is dropped.
///
/// A rank is the hit's position in its own Deezer list. Songs match by the
/// `ext-deezer-song-<id>` id, else by the track matcher the top songs use;
/// artists by id or name; albums by id or by title and artist. Every copy of
/// a hit shares its rank; for Top Results an item on the server beats a remote
/// one, then the first in [result]'s order.
///
/// Top Results are the matched hits in Deezer order (an artist, album and song
/// at the same position in that order), each item once. With [onePerKind]
/// (the All tab) they are one hero and its relatives, see [_topResultsOfAllKinds].
/// Otherwise (a type filter, where [result] holds one kind) they are the
/// first [kMaxTopResults].
DeezerSearchBoost matchDeezerSearchHits({
  required SearchResult3 result,
  required DeezerSearchHits hits,
  String query = '',
  bool onePerKind = false,
}) {
  final top = <_Match>[];

  final artists = _libraryFirst(
    result.artists,
    (artist) => artist.id,
    (artist) => artist.isExternal,
  );
  final artistRanks = <String, int>{};
  final seenArtists = <String>{};
  for (final (position, hit) in hits.artists.indexed) {
    final matches = [
      for (final artist in artists)
        if (artist.id == remoteDeezerArtistId(hit.id) ||
            artistNamesMatchLoosely(
              artist.name,
              hit.name,
              allowSpacingAndPunctuation: false,
            ))
          artist,
    ];
    for (final artist in matches) {
      artistRanks.putIfAbsent(artist.id, () => position);
    }
    if (matches.isNotEmpty && seenArtists.add(matches.first.id)) {
      top.add((
        position: position,
        type: 0,
        item: TopArtistResult(matches.first),
        hit: hit,
      ));
    }
  }

  final albums = _libraryFirst(
    result.albums,
    (album) => album.id,
    (album) => album.isExternal,
  );
  final albumRanks = <String, int>{};
  final seenAlbums = <String>{};
  for (final (position, hit) in hits.albums.indexed) {
    final title = normalizeMetadata(hit.title);
    final matches = [
      for (final album in albums)
        if (album.id == remoteDeezerAlbumId(hit.id) ||
            (title.isNotEmpty &&
                normalizeMetadata(album.name) == title &&
                _sameArtist(album, hit.artist)))
          album,
    ];
    for (final album in matches) {
      albumRanks.putIfAbsent(album.id, () => position);
    }
    if (matches.isNotEmpty && seenAlbums.add(matches.first.id)) {
      top.add((
        position: position,
        type: 1,
        item: TopAlbumResult(matches.first),
        hit: hit,
      ));
    }
  }

  final songs = _libraryFirst(
    result.songs,
    (song) => song.id,
    (song) => song.isExternal,
  );
  final songRanks = <String, int>{};
  final seenSongs = <String>{};
  for (final (position, hit) in hits.tracks.indexed) {
    final matches = _matchSongs(songs, hit);
    for (final song in matches) {
      songRanks.putIfAbsent(song.id, () => position);
    }
    if (matches.isNotEmpty && seenSongs.add(matches.first.id)) {
      top.add((
        position: position,
        type: 2,
        item: TopSongResult(matches.first),
        hit: hit,
      ));
    }
  }

  top.sort((a, b) {
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0 ? byPosition : a.type.compareTo(b.type);
  });
  return DeezerSearchBoost(
    popularity: SearchPopularity(
      artists: artistRanks,
      albums: albumRanks,
      songs: songRanks,
    ),
    topResults: onePerKind
        ? _topResultsOfAllKinds(result, top, normalizeMetadata(query))
        : [for (final entry in top.take(kMaxTopResults)) entry.item],
  );
}

/// A Deezer hit that matched an item: its position in its own Deezer list,
/// the kind (0 artist, 1 album, 2 song: the tie order), the item and the hit.
typedef _Match = ({int position, int type, SearchTopResult item, Object hit});

/// The All tab's Top Results: a hero and its relatives, at most
/// [kMaxTopResults]. [top] is the matched hits in Deezer order and [wanted]
/// the normalized query (may be empty).
///
/// The hero: with items named like the query in two or more kinds, the exact
/// item Deezer's first song points at (the song itself, else its artist, else
/// its album), unless that is remote while the server holds an exact one;
/// then the server's exact items decide, a song first. Otherwise the best hit
/// of any kind, one named like the query first, then Deezer order.
///
/// The others relate to the hero: a song's artist and album, an artist's top
/// song and album, an album's artist and top song. A song's or album's
/// artist and album that [result] lacks are built from the ids the song
/// carries; their art loads when shown.
List<SearchTopResult> _topResultsOfAllKinds(
  SearchResult3 result,
  List<_Match> top,
  String wanted,
) {
  if (top.isEmpty) return const <SearchTopResult>[];
  bool exact(SearchTopResult item) =>
      wanted.isNotEmpty && normalizeMetadata(_nameOf(item)) == wanted;
  final exactMatches = [
    for (final match in top)
      if (exact(match.item)) match,
  ];
  final topSong = top.where((match) => match.type == 2).firstOrNull;

  SearchTopResult? hero;
  if ({for (final match in exactMatches) match.type}.length >= 2) {
    final exactItems = [for (final match in exactMatches) match.item];
    final onServer = [
      for (final item in exactItems)
        if (!_isRemote(item)) item,
    ];
    final pool = onServer.isEmpty ? exactItems : onServer;
    SearchTopResult? pointed;
    if (topSong != null) {
      final song = (topSong.item as TopSongResult).song;
      pointed = [
        topSong.item,
        _artistOfSong(result, song),
        _albumOfSong(result, song),
      ].nonNulls.where(exact).firstOrNull;
    }
    hero = pointed != null && pool.any((item) => _sameItem(item, pointed!))
        ? pointed
        : pool.whereType<TopSongResult>().firstOrNull ?? pool.firstOrNull;
  }
  hero ??= _bestHit(top, exact);

  final seen = <String>{};
  return [
    for (final item in [hero, ..._relatives(result, top, hero)])
      if (seen.add('${item.runtimeType}:${_idOf(item)}')) item,
  ].take(kMaxTopResults).toList();
}

/// The first hit in [top] (Deezer order): one named like the query if any,
/// else the first.
SearchTopResult _bestHit(
  List<_Match> top,
  bool Function(SearchTopResult) exact,
) {
  final named = top.where((match) => exact(match.item));
  return (named.isEmpty ? top : named).first.item;
}

/// What relates to [hero], most useful first.
List<SearchTopResult> _relatives(
  SearchResult3 result,
  List<_Match> top,
  SearchTopResult hero,
) {
  switch (hero) {
    case TopSongResult(:final song):
      return [
        ?_artistOfSong(result, song) ?? _artistFromSong(song),
        ?_albumOfSong(result, song) ?? _albumFromSong(song),
      ];
    case TopArtistResult(:final artist):
      return [
        ?_firstHitBy(top, 2, artist.name),
        ?_firstHitBy(top, 1, artist.name),
      ];
    case TopAlbumResult(:final album):
      return [
        ?_artistOfAlbum(result, album) ?? _artistFromAlbum(album),
        ?top
            .where(
              (match) =>
                  match.type == 2 &&
                  normalizeMetadata(
                        (match.hit as DeezerTrack).album?.title ?? '',
                      ) ==
                      normalizeMetadata(album.name) &&
                  _sameName(
                    (match.hit as DeezerTrack).artist.name,
                    album.artist,
                  ),
            )
            .firstOrNull
            ?.item,
      ];
  }
}

/// The first hit of [type] in [top] by the artist named [name].
SearchTopResult? _firstHitBy(List<_Match> top, int type, String name) {
  for (final match in top) {
    if (match.type != type) continue;
    final hitArtist = switch (match.hit) {
      DeezerAlbum(:final artist) => artist?.name,
      DeezerTrack(:final artist) => artist.name,
      _ => null,
    };
    if (hitArtist != null &&
        artistNamesMatchLoosely(
          hitArtist,
          name,
          allowSpacingAndPunctuation: false,
        )) {
      return match.item;
    }
  }
  return null;
}

bool _sameName(String? left, String? right) =>
    left != null &&
    right != null &&
    artistNamesMatchLoosely(left, right, allowSpacingAndPunctuation: false);

/// [song]'s artist in [result] (by id, else name), the server's copy first.
TopArtistResult? _artistOfSong(SearchResult3 result, Song song) {
  final found = _libraryFirst(
    [
      for (final artist in result.artists)
        if (artist.id == song.artistId) artist,
      for (final artist in result.artists)
        if (_sameName(artist.name, song.artist)) artist,
    ],
    (artist) => artist.id,
    (artist) => artist.isExternal,
  );
  return found.isEmpty ? null : TopArtistResult(found.first);
}

/// [song]'s album in [result] (by id, else title and artist), the server's
/// copy first.
TopAlbumResult? _albumOfSong(SearchResult3 result, Song song) {
  final title = normalizeMetadata(song.album ?? '');
  final found = _libraryFirst(
    [
      for (final album in result.albums)
        if (album.id == song.albumId ||
            (title.isNotEmpty &&
                normalizeMetadata(album.name) == title &&
                _sameName(album.artist, song.artist)))
          album,
    ],
    (album) => album.id,
    (album) => album.isExternal,
  );
  return found.isEmpty ? null : TopAlbumResult(found.first);
}

/// The artist of [album] in [result], the server's copy first.
TopArtistResult? _artistOfAlbum(SearchResult3 result, Album album) {
  final found = _libraryFirst(
    [
      for (final artist in result.artists)
        if (artist.id == album.artistId || _sameName(artist.name, album.artist))
          artist,
    ],
    (artist) => artist.id,
    (artist) => artist.isExternal,
  );
  return found.isEmpty ? null : TopArtistResult(found.first);
}

/// An artist tile for the artist [song] names, when its id and name are known.
/// It has no art id: the tile finds it the way the artist page does.
TopArtistResult? _artistFromSong(Song song) {
  return _builtArtist(song.artistId, song.artist);
}

/// An album tile for the album [song] names, when its id and name are known.
TopAlbumResult? _albumFromSong(Song song) {
  final id = song.albumId;
  final name = song.album;
  return _blank(id) || _blank(name)
      ? null
      : TopAlbumResult(
          Album(
            id: id!,
            name: name!,
            artist: song.artist,
            artistId: song.artistId,
            year: song.year,
          ),
        );
}

TopArtistResult? _artistFromAlbum(Album album) {
  return _builtArtist(album.artistId, album.artist);
}

/// An artist tile from an id and a name, none when either is missing or blank.
TopArtistResult? _builtArtist(String? id, String? name) =>
    _blank(id) || _blank(name)
    ? null
    : TopArtistResult(Artist(id: id!, name: name!));

bool _blank(String? value) => value == null || value.trim().isEmpty;

String _nameOf(SearchTopResult item) => switch (item) {
  TopArtistResult(:final artist) => artist.name,
  TopAlbumResult(:final album) => album.name,
  TopSongResult(:final song) => song.title,
};

String _idOf(SearchTopResult item) => switch (item) {
  TopArtistResult(:final artist) => artist.id,
  TopAlbumResult(:final album) => album.id,
  TopSongResult(:final song) => song.id,
};

bool _isRemote(SearchTopResult item) => switch (item) {
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

bool _sameItem(SearchTopResult left, SearchTopResult right) =>
    left.runtimeType == right.runtimeType && _idOf(left) == _idOf(right);

/// [items] with those on the server ahead of remote ones, each group in its
/// own order.
List<T> _libraryFirst<T>(
  List<T> items,
  String Function(T) id,
  bool? Function(T) isExternal,
) => [
  for (final source in CatalogSource.values)
    for (final item in items)
      if (classifyCatalogSource(
            id: id(item),
            apiIsExternal: isExternal(item),
          ) ==
          source)
        item,
];

/// Karaoke, instrumental, tribute and cover versions: the matcher folds
/// their "(Karaoke Version)" into the title, so they would match the original.
final RegExp _derivativeMarker = RegExp(
  r'\b(karaoke|instrumental|tribute|backing track|made famous|'
  r'originally performed|in the style of|cover version)\b|'
  r'(?:[(\[]|\s[-–—]\s)[^)\]]*\bcovers?\b',
  caseSensitive: false,
);

/// Every copy in [songs] (library-first order) of the track [hit]: the
/// `ext-deezer-song-<id>` row, and the best fuzzy match of each source group.
/// A copy that is a karaoke, instrumental, tribute or cover version is skipped
/// unless Deezer's own title says so too. All copies share the hit's rank, so
/// the source tie-break keeps the library copy first, and the first copy is
/// the one Top Results shows.
List<Song> _matchSongs(List<Song> songs, DeezerTrack hit) {
  final direct = remoteDeezerSongId(hit.id);
  final hitIsDerivative = _derivativeMarker.hasMatch(hit.title);
  final query = TrackMatchQuery(
    title: hit.title,
    artist: hit.artist.name,
    album: hit.album?.title,
    durationSeconds: hit.durationSeconds,
  );
  final ids = <String>{
    for (final song in songs)
      if (song.id == direct) song.id,
  };
  for (final source in CatalogSource.values) {
    final group = [
      for (final song in songs)
        if (classifyCatalogSource(
                  id: song.id,
                  apiIsExternal: song.isExternal,
                ) ==
                source &&
            (hitIsDerivative || !_derivativeMarker.hasMatch(song.title)))
          song,
    ];
    final match = pickBestArtistTopTrackMatch(track: query, candidates: group);
    if (match == null) continue;
    // The matcher picks one; a duplicate of it (same title, edition and artist,
    // say another album) is the same song and shares the rank. A live, remix
    // or language version is another recording.
    final title = normalizeMetadataKeepingEdition(match.title);
    final artist = normalizeMetadata(match.artist ?? '');
    for (final song in group) {
      if (normalizeMetadataKeepingEdition(song.title) == title &&
          normalizeMetadata(song.artist ?? '') == artist) {
        ids.add(song.id);
      }
    }
  }
  return [
    for (final song in songs)
      if (ids.contains(song.id)) song,
  ];
}

bool _sameArtist(Album album, DeezerArtist? artist) {
  if (artist == null) return false;
  return [
    album.artist,
    for (final ref in album.artists) ref.name,
  ].any((name) => name != null && artistNamesMatchLoosely(name, artist.name));
}
