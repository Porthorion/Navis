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
/// artists by id or name; albums by id or by title and artist. Of several
/// copies, an item on the server beats a remote one, then the first in
/// [result]'s order. Top Results are the matched hits in Deezer order (an
/// artist, album and song at the same position in that order), at most
/// [kMaxTopResults], each item once.
DeezerSearchBoost matchDeezerSearchHits({
  required SearchResult3 result,
  required DeezerSearchHits hits,
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
    final song = _matchSong(songs, hit);
    if (song == null) continue;
    songRanks.putIfAbsent(song.id, () => position);
    if (seenSongs.add(song.id)) {
      top.add((position: position, type: 2, item: TopSongResult(song)));
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
    topResults: [for (final entry in top.take(kMaxTopResults)) entry.item],
  );
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

Song? _matchSong(List<Song> songs, DeezerTrack hit) {
  final direct = remoteDeezerSongId(hit.id);
  for (final song in songs) {
    if (song.id == direct) return song;
  }
  final query = TrackMatchQuery(
    title: hit.title,
    artist: hit.artist.name,
    album: hit.album?.title,
    durationSeconds: hit.durationSeconds,
  );
  for (final source in CatalogSource.values) {
    final match = pickBestArtistTopTrackMatch(
      track: query,
      candidates: [
        for (final song in songs)
          if (classifyCatalogSource(
                id: song.id,
                apiIsExternal: song.isExternal,
              ) ==
              source)
            song,
      ],
    );
    if (match != null) return match;
  }
  return null;
}

bool _sameArtist(Album album, DeezerArtist? artist) {
  if (artist == null) return false;
  return [
    album.artist,
    for (final ref in album.artists) ref.name,
  ].any((name) => name != null && artistNamesMatchLoosely(name, artist.name));
}
