import 'package:navis/src/features/auto/domain/android_auto_constants.dart';

/// Maps a Siri `INPlayMediaIntent` search (the `playMedia` channel arguments)
/// onto the query and extras of Android Auto's voice search, so both
/// platforms share one parser and one local search.
///
/// A typed request without a usable name (a song with only an artist) falls
/// through to the generic rules; nothing at all is an instant-radio request.
({String query, Map<String, dynamic> extras}) siriPlayMediaRequest(
  Map<Object?, Object?> args,
) {
  String? text(String key) {
    final value = args[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  final name = text('mediaName');
  final artist = text('artistName');
  final album = text('albumName');
  final genre = text('genreName');

  ({String query, Map<String, dynamic> extras}) request(
    String focus,
    String query,
    Map<String, String?> extras,
  ) => (
    query: query,
    extras: <String, dynamic>{
      AndroidAutoConstants.mediaFocusKey: focus,
      for (final MapEntry(:key, :value) in extras.entries) key: ?value,
    },
  );

  switch (text('mediaType')) {
    case 'song' when name != null:
      return request(AndroidAutoConstants.mediaFocusSong, name, {
        AndroidAutoConstants.mediaTitleKey: name,
        AndroidAutoConstants.mediaArtistKey: artist,
        AndroidAutoConstants.mediaAlbumKey: album,
      });
    case 'album' when (name ?? album) != null:
      return request(AndroidAutoConstants.mediaFocusAlbum, (name ?? album)!, {
        AndroidAutoConstants.mediaAlbumKey: name ?? album,
        AndroidAutoConstants.mediaArtistKey: artist,
      });
    case 'artist' when (name ?? artist) != null:
      return request(AndroidAutoConstants.mediaFocusArtist, (name ?? artist)!, {
        AndroidAutoConstants.mediaArtistKey: name ?? artist,
      });
    case 'playlist' when name != null:
      return request(AndroidAutoConstants.mediaFocusPlaylist, name, {
        AndroidAutoConstants.mediaPlaylistKey: name,
      });
    case 'genre' when (name ?? genre) != null:
      return request(AndroidAutoConstants.mediaFocusGenre, (name ?? genre)!, {
        AndroidAutoConstants.mediaGenreKey: name ?? genre,
      });
  }

  if (name != null) return (query: name, extras: <String, dynamic>{});
  if (artist != null) {
    return request(AndroidAutoConstants.mediaFocusArtist, artist, {
      AndroidAutoConstants.mediaArtistKey: artist,
    });
  }
  if (album != null) {
    return request(AndroidAutoConstants.mediaFocusAlbum, album, {
      AndroidAutoConstants.mediaAlbumKey: album,
    });
  }
  if (genre != null) {
    return request(AndroidAutoConstants.mediaFocusGenre, genre, {
      AndroidAutoConstants.mediaGenreKey: genre,
    });
  }
  return (query: '', extras: <String, dynamic>{});
}
