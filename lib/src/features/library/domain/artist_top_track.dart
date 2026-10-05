import 'package:navis/src/api/models/song.dart';

/// Where an artist's top songs came from.
enum ArtistTopTrackSource { deezer, lastFm }

/// One of an artist's top songs as an external service ranks it, before it
/// is matched to the library.
class ArtistTopTrackSeed {
  const new({
    required this.rank,
    required this.title,
    required this.artist,
    required this.source,
    this.popularity,
    this.listeners,
    this.album,
    this.durationSeconds,
    this.deezerTrackId,
  });

  factory fromJson(Map<String, dynamic> json) => ArtistTopTrackSeed(
    rank: (json['rank'] as num).toInt(),
    title: json['title'] as String,
    artist: json['artist'] as String,
    source: ArtistTopTrackSource.values.byName(json['source'] as String),
    popularity: (json['popularity'] as num?)?.toInt(),
    listeners: (json['listeners'] as num?)?.toInt(),
    album: json['album'] as String?,
    durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
    deezerTrackId: (json['deezerTrackId'] as num?)?.toInt(),
  );

  /// 1-based position in the list.
  final int rank;
  final String title;
  final String artist;
  final ArtistTopTrackSource source;

  /// The source's own popularity score (Deezer `rank`), used for ordering
  /// only; never shown.
  final int? popularity;

  /// Last.fm listener count; null for other sources, so only Last.fm songs
  /// show a number.
  final int? listeners;
  final String? album;
  final int? durationSeconds;

  /// The Deezer track id, for the `ext-deezer-song-<id>` library shortcut.
  final int? deezerTrackId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rank': rank,
    'title': title,
    'artist': artist,
    'source': source.name,
    'popularity': ?popularity,
    'listeners': ?listeners,
    'album': ?album,
    'durationSeconds': ?durationSeconds,
    'deezerTrackId': ?deezerTrackId,
  };
}

/// A top song with the library song it was matched to, if any.
class ResolvedArtistTopTrack {
  const new({
    required this.rank,
    required this.title,
    required this.artist,
    this.listeners,
    this.resolvedSong,
  });

  new fromSeed(ArtistTopTrackSeed seed, {Song? song})
    : this(
        rank: seed.rank,
        title: seed.title,
        artist: seed.artist,
        listeners: seed.listeners,
        resolvedSong: song,
      );

  /// 1-based chart position.
  final int rank;
  final String title;
  final String artist;

  /// Last.fm listeners; null for other sources.
  final int? listeners;

  /// The library (or server-provided remote) song, or null when no confident
  /// match was found.
  final Song? resolvedSong;

  bool get isLocallyResolved => resolvedSong != null;
}
