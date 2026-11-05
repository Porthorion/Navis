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
/// (the All tab) they are the best hit of each kind, at most one artist, one
/// album and one song, and one whose name equals [query] (normalized) leads.
/// Otherwise (a type filter, where [result] holds one kind) they are the
/// first [kMaxTopResults].
DeezerSearchBoost matchDeezerSearchHits({
  required SearchResult3 result,
  required DeezerSearchHits hits,
  String query = '',
  bool onePerKind = false,
}) {
  final top = <({int position, int type, SearchTopResult item})>[];

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
        ? _bestOfEachKind(top, normalizeMetadata(query))
        : [for (final entry in top.take(kMaxTopResults)) entry.item],
  );
}

/// The first entry of each kind in [sorted] (Deezer order), those named
/// [wanted] (already normalized, may be empty) first.
List<SearchTopResult> _bestOfEachKind(
  List<({int position, int type, SearchTopResult item})> sorted,
  String wanted,
) {
  final best =
      {for (final entry in sorted.reversed) entry.type: entry}.values.toList()
        ..sort((a, b) {
          final byPosition = a.position.compareTo(b.position);
          return byPosition != 0 ? byPosition : a.type.compareTo(b.type);
        });
  bool exact(SearchTopResult item) =>
      wanted.isNotEmpty &&
      normalizeMetadata(switch (item) {
            TopArtistResult(:final artist) => artist.name,
            TopAlbumResult(:final album) => album.name,
            TopSongResult(:final song) => song.title,
          }) ==
          wanted;
  return [
    for (final entry in best)
      if (exact(entry.item)) entry.item,
    for (final entry in best)
      if (!exact(entry.item)) entry.item,
  ];
}

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
