import 'package:freezed_annotation/freezed_annotation.dart';

part 'share_content.freezed.dart';

@freezed
sealed class ShareContent with _$ShareContent {
  const ShareContent._();

  const factory ShareContent.song({
    required String title,
    required String artist,
    String? album,
    String? coverArtId,
  }) = ShareSong;

  const factory ShareContent.album({
    required String name,
    required String artist,
    String? coverArtId,
  }) = ShareAlbum;

  const factory ShareContent.artist({
    required String name,
    String? coverArtId,
  }) = ShareArtist;

  const factory ShareContent.playlist({
    required String name,
    String? owner,
    String? coverArtId,
  }) = SharePlaylist;

  /// Builds a navis:// URI for deep linking.
  ///
  /// Examples:
  ///   navis://song?title=Bohemian+Rhapsody&artist=Queen&album=A+Night+at+the+Opera
  ///   navis://album?name=OK+Computer&artist=Radiohead
  ///   navis://artist?name=Pink+Floyd
  ///   navis://playlist?name=Chill+Vibes
  Uri toUri() {
    return switch (this) {
      ShareSong(:final title, :final artist, :final album) => Uri(
        scheme: 'navis',
        host: 'song',
        queryParameters: {
          'title': title,
          'artist': artist,
          if (album != null) 'album': album,
        },
      ),
      ShareAlbum(:final name, :final artist) => Uri(
        scheme: 'navis',
        host: 'album',
        queryParameters: {'name': name, 'artist': artist},
      ),
      ShareArtist(:final name) => Uri(
        scheme: 'navis',
        host: 'artist',
        queryParameters: {'name': name},
      ),
      SharePlaylist(:final name, :final owner) => Uri(
        scheme: 'navis',
        host: 'playlist',
        queryParameters: {
          'name': name,
          if (owner != null) 'owner': owner,
        },
      ),
    };
  }

  /// Parses a navis:// URI back into a ShareContent.
  /// Returns null if the URI is invalid or not a navis:// scheme.
  static ShareContent? fromUri(Uri uri) {
    if (uri.scheme != 'navis') return null;
    final params = uri.queryParameters;

    return switch (uri.host) {
      'song' when params['title'] != null && params['artist'] != null =>
        ShareContent.song(
          title: params['title']!,
          artist: params['artist']!,
          album: params['album'],
        ),
      'album' when params['name'] != null && params['artist'] != null =>
        ShareContent.album(
          name: params['name']!,
          artist: params['artist']!,
        ),
      'artist' when params['name'] != null => ShareContent.artist(
        name: params['name']!,
      ),
      'playlist' when params['name'] != null => ShareContent.playlist(
        name: params['name']!,
        owner: params['owner'],
      ),
      _ => null,
    };
  }

  /// Human-readable formatted text for sharing.
  String toShareText({String? publicUrl}) {
    final buffer = StringBuffer();

    switch (this) {
      case ShareSong(:final title, :final artist, :final album):
        buffer.writeln('$title — $artist');
        if (album != null) buffer.writeln(album);
      case ShareAlbum(:final name, :final artist):
        buffer.writeln('$name — $artist');
      case ShareArtist(:final name):
        buffer.writeln(name);
      case SharePlaylist(:final name):
        buffer.writeln(name);
    }

    buffer.writeln();
    if (publicUrl != null) {
      buffer.writeln('Listen: $publicUrl');
      buffer.writeln();
    }
    buffer.writeln('Open in Navis: ${toUri()}');

    return buffer.toString().trimRight();
  }

  /// Search query for finding this content on the recipient's server.
  String get searchQuery => switch (this) {
    ShareSong(:final title, :final artist) => '$artist $title',
    ShareAlbum(:final name, :final artist) => '$artist $name',
    ShareArtist(:final name) => name,
    SharePlaylist(:final name) => name,
  };
}
