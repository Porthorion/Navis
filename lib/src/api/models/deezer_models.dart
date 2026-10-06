/// The parts of Deezer's public API objects that Navis uses.
///
/// Hand-written like the ListenBrainz models: the responses are small, only a
/// few fields matter, and `toJson` round-trips through the integration cache.
/// Field names in JSON are Deezer's own, so a cached value and a live response
/// parse the same way.
library;

/// A Deezer artist (`/search/artist`, `/artist/{id}`, a track's `artist`).
class DeezerArtist {
  const new({
    required this.id,
    required this.name,
    this.pictureSmall,
    this.pictureMedium,
    this.pictureBig,
    this.pictureXl,
    this.albumCount,
    this.fanCount,
  });

  factory fromJson(Map<String, dynamic> json) => DeezerArtist(
    id: _int(json['id']) ?? 0,
    name: _string(json['name']) ?? '',
    pictureSmall: _string(json['picture_small']),
    pictureMedium: _string(json['picture_medium']),
    pictureBig: _string(json['picture_big']),
    pictureXl: _string(json['picture_xl']),
    albumCount: _int(json['nb_album']),
    fanCount: _int(json['nb_fan']),
  );

  final int id;
  final String name;
  final String? pictureSmall;
  final String? pictureMedium;
  final String? pictureBig;
  final String? pictureXl;

  /// `nb_album`; absent on the artist embedded in a track.
  final int? albumCount;

  /// `nb_fan`; absent on the artist embedded in a track.
  final int? fanCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'picture_small': ?pictureSmall,
    'picture_medium': ?pictureMedium,
    'picture_big': ?pictureBig,
    'picture_xl': ?pictureXl,
    'nb_album': ?albumCount,
    'nb_fan': ?fanCount,
  };
}

/// A Deezer album (`/artist/{id}/albums`, a track's `album`).
class DeezerAlbum {
  const new({
    required this.id,
    required this.title,
    this.coverSmall,
    this.coverMedium,
    this.coverBig,
    this.coverXl,
    this.releaseDate,
    this.recordType,
    this.trackCount,
  });

  factory fromJson(Map<String, dynamic> json) {
    return DeezerAlbum(
      id: _int(json['id']) ?? 0,
      title: _string(json['title']) ?? '',
      coverSmall: _string(json['cover_small']),
      coverMedium: _string(json['cover_medium']),
      coverBig: _string(json['cover_big']),
      coverXl: _string(json['cover_xl']),
      releaseDate: _string(json['release_date']),
      recordType: _string(json['record_type']),
      trackCount: _int(json['nb_tracks']),
    );
  }

  final int id;
  final String title;
  final String? coverSmall;
  final String? coverMedium;
  final String? coverBig;
  final String? coverXl;

  /// `YYYY-MM-DD` as Deezer sends it; absent on the album embedded in a track.
  final String? releaseDate;

  /// `album`, `single`, `ep` or `compile`.
  final String? recordType;
  final int? trackCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'cover_small': ?coverSmall,
    'cover_medium': ?coverMedium,
    'cover_big': ?coverBig,
    'cover_xl': ?coverXl,
    'release_date': ?releaseDate,
    'record_type': ?recordType,
    'nb_tracks': ?trackCount,
  };
}

/// A Deezer track (`/artist/{id}/top`, `/search/track`, `/chart/0/tracks`).
class DeezerTrack {
  const new({
    required this.id,
    required this.title,
    required this.artist,
    this.titleShort,
    this.titleVersion,
    this.isrc,
    this.durationSeconds,
    this.rank,
    this.album,
  });

  factory fromJson(Map<String, dynamic> json) {
    final artist = json['artist'];
    final album = json['album'];
    return DeezerTrack(
      id: _int(json['id']) ?? 0,
      title: _string(json['title']) ?? '',
      titleShort: _string(json['title_short']),
      titleVersion: _string(json['title_version']),
      isrc: _string(json['isrc']),
      durationSeconds: _int(json['duration']),
      rank: _int(json['rank']),
      artist: artist is Map
          ? DeezerArtist.fromJson(Map<String, dynamic>.from(artist))
          : const DeezerArtist(id: 0, name: ''),
      album: album is Map
          ? DeezerAlbum.fromJson(Map<String, dynamic>.from(album))
          : null,
    );
  }

  final int id;

  /// The full title, including the version ("Wonder (Japanese Version)").
  final String title;
  final String? titleShort;
  final String? titleVersion;
  final String? isrc;
  final int? durationSeconds;

  /// Deezer's popularity score; higher is more popular.
  final int? rank;
  final DeezerArtist artist;
  final DeezerAlbum? album;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'title_short': ?titleShort,
    'title_version': ?titleVersion,
    'isrc': ?isrc,
    'duration': ?durationSeconds,
    'rank': ?rank,
    'artist': artist.toJson(),
    if (album case final album?) 'album': album.toJson(),
  };
}

int? _int(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text),
  _ => null,
};

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
