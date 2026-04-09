import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/subsonic_logging_interceptor.dart';
import 'package:navis/src/api/subsonic_retry_interceptor.dart';
import 'package:uuid/uuid.dart';

/// Typed Subsonic/OpenSubsonic API wrapper.
class SubsonicApiClient {
  SubsonicApiClient({
    required String baseUrl,
    required this.authConfig,
    Dio? dio,
    this.enableLogging = true,
    this.maxConnectionsPerHost,
  }) : _uuid = const Uuid(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: _normalizeBaseUrl(baseUrl),
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 15),
             ),
           ) {
    _configureTransport();
    _dio.interceptors.add(SubsonicAuthInterceptor(config: authConfig));
    if (enableLogging) {
      _dio.interceptors.add(SubsonicLoggingInterceptor());
    }
    _dio.interceptors.add(SubsonicRetryInterceptor(dio: _dio));
  }

  final Dio _dio;
  final Uuid _uuid;
  final SubsonicAuthConfig authConfig;
  final bool enableLogging;
  final int? maxConnectionsPerHost;

  static String _normalizeBaseUrl(String baseUrl) => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  void _configureTransport() {
    final maxConnections = maxConnectionsPerHost;
    if (maxConnections == null || maxConnections < 1) {
      return;
    }
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.maxConnectionsPerHost = maxConnections;
        return client;
      },
    );
  }

  Future<String> ping({CancelToken? cancelToken}) async {
    final root = await _readRoot('/rest/ping.view', cancelToken: cancelToken);
    final version = root['version'] as String?;
    if (version == null || version.isEmpty) {
      return authConfig.apiVersion;
    }
    return version;
  }

  Future<ServerCapabilities> getOpenSubsonicExtensions({
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getOpenSubsonicExtensions.view',
      cancelToken: cancelToken,
    );

    final extensionsRoot = _asMap(root['openSubsonicExtensions']);
    final extensions = _asMapList(
      extensionsRoot['openSubsonicExtension'],
    ).map(OpenSubsonicExtension.fromJson).toList(growable: false);

    return ServerCapabilities(extensions: extensions);
  }

  Future<List<Artist>> getArtists({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getArtists.view',
      cancelToken: cancelToken,
    );
    final artistsNode = _asMap(root['artists']);
    final indexEntries = _asMapList(artistsNode['index']);

    final artists = <Artist>[];
    for (final indexEntry in indexEntries) {
      artists.addAll(
        _asMapList(indexEntry['artist']).map(Artist.fromJson),
      );
    }

    if (artists.isEmpty) {
      artists.addAll(_asMapList(artistsNode['artist']).map(Artist.fromJson));
    }

    return artists;
  }

  Future<Artist> getArtist(String id, {CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getArtist.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    return Artist.fromJson(_asMap(root['artist']));
  }

  Future<Album> getAlbum(String id, {CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getAlbum.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    final album = _asMap(root['album']);
    return Album.fromJson(<String, dynamic>{
      ...album,
      // Subsonic uses `song` for album track payloads. Normalize it so
      // Album.fromJson always receives the expected `songs` list key.
      'songs': _asMapList(album['song']),
    });
  }

  Future<Song> getSong(String id, {CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getSong.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    return Song.fromJson(_asMap(root['song']));
  }

  Future<ArtistInfo> getArtistInfo2(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getArtistInfo2.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    final json = _asMap(root['artistInfo2']);

    return ArtistInfo(
      biography: json['biography'] as String?,
      musicBrainzId: json['musicBrainzId'] as String?,
      lastFmUrl: json['lastFmUrl'] as String?,
      smallImageUrl: json['smallImageUrl'] as String?,
      mediumImageUrl: json['mediumImageUrl'] as String?,
      largeImageUrl: json['largeImageUrl'] as String?,
      similarArtists: _extractArtists(json['similarArtist']),
    );
  }

  Future<AlbumInfo> getAlbumInfo2(String id, {CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getAlbumInfo2.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    return AlbumInfo.fromJson(_asMap(root['albumInfo2']));
  }

  Future<List<Genre>> getGenres({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getGenres.view',
      cancelToken: cancelToken,
    );
    final rawGenres = _asMapList(_asMap(root['genres'])['genre']);
    final genres = <Genre>[];
    for (final rawGenre in rawGenres) {
      final rawName = rawGenre['name'];
      if (rawName is! String) {
        continue;
      }
      final name = rawName.trim();
      if (name.isEmpty) {
        continue;
      }
      genres.add(
        Genre(
          name: name,
          songCount: _toInt(rawGenre['songCount']),
          albumCount: _toInt(rawGenre['albumCount']),
        ),
      );
    }
    return genres;
  }

  Future<List<Album>> getAlbumList2({
    required String type,
    int size = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getAlbumList2.view',
      query: {
        'type': type,
        'size': size,
        'offset': offset,
      },
      cancelToken: cancelToken,
    );
    return _asMapList(
      _asMap(root['albumList2'])['album'],
    ).map(Album.fromJson).toList(growable: false);
  }

  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    CancelToken? cancelToken,
  }) async {
    final query = <String, dynamic>{
      if (ifModifiedSince != null)
        'ifModifiedSince': ifModifiedSince.toUtc().millisecondsSinceEpoch,
    };
    final root = await _readRoot(
      '/rest/getIndexes.view',
      query: query.isEmpty ? null : query,
      cancelToken: cancelToken,
    );
    final indexesRoot = _asMap(root['indexes']);
    final normalized = <String, dynamic>{
      ...indexesRoot,
      'index': _asMapList(indexesRoot['index']),
      'shortcut': _asMapList(indexesRoot['shortcut']),
      'child': _asMapList(indexesRoot['child']),
    };
    return Indexes.fromJson(normalized);
  }

  Future<List<Song>> getRandomSongs({
    int size = 20,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getRandomSongs.view',
      query: {'size': size},
      cancelToken: cancelToken,
    );
    return _asMapList(
      _asMap(root['randomSongs'])['song'],
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<List<Song>> getSongsByGenre({
    required String genre,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getSongsByGenre.view',
      query: {'genre': genre},
      cancelToken: cancelToken,
    );
    return _asMapList(
      _asMap(root['songsByGenre'])['song'],
    ).map(Song.fromJson).toList(growable: false);
  }

  Future<StarredContent> getStarred2({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getStarred2.view',
      cancelToken: cancelToken,
    );
    final starred = _asMap(root['starred2']);
    return StarredContent(
      albums: _asMapList(
        starred['album'],
      ).map(Album.fromJson).toList(growable: false),
      artists: _asMapList(
        starred['artist'],
      ).map(Artist.fromJson).toList(growable: false),
      songs: _asMapList(
        starred['song'],
      ).map(Song.fromJson).toList(growable: false),
    );
  }

  Future<List<Song>> getNowPlaying({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getNowPlaying.view',
      cancelToken: cancelToken,
    );
    return _asMapList(
      _asMap(root['nowPlaying'])['entry'],
    ).map(Song.fromJson).toList(growable: false);
  }

  /// Returns songs similar to [seedSongId] using `getSimilarSongs2`.
  ///
  /// Falls back to `getInstantMix` when the primary endpoint returns a
  /// [SubsonicNotFoundException] (code 70 — not supported by the server).
  Future<List<Song>> getSimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    Future<List<Song>> fetch(String endpoint) async {
      final root = await _readRoot(
        endpoint,
        query: {'id': seedSongId, 'count': count},
        cancelToken: cancelToken,
      );
      return _asMapList(
        _asMap(root['similarSongs2'])['song'],
      ).map(Song.fromJson).toList(growable: false);
    }

    try {
      return await fetch('/rest/getSimilarSongs2.view');
    } on SubsonicNotFoundException {
      // Server doesn't support getSimilarSongs2 — try getInstantMix.
      final root = await _readRoot(
        '/rest/getInstantMix.view',
        query: {'id': seedSongId, 'count': count},
        cancelToken: cancelToken,
      );
      return _asMapList(
        _asMap(root['instantMix'])['song'],
      ).map(Song.fromJson).toList(growable: false);
    }
  }

  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/search3.view',
      query: {
        'query': query,
        'artistCount': artistCount,
        'albumCount': albumCount,
        'songCount': songCount,
        'artistOffset': artistOffset,
        'albumOffset': albumOffset,
        'songOffset': songOffset,
      },
      cancelToken: cancelToken,
    );

    final result = _asMap(root['searchResult3']);
    return SearchResult3(
      artists: _asMapList(
        result['artist'],
      ).map(Artist.fromJson).toList(growable: false),
      albums: _asMapList(
        result['album'],
      ).map(Album.fromJson).toList(growable: false),
      songs: _asMapList(
        result['song'],
      ).map(Song.fromJson).toList(growable: false),
    );
  }

  Future<List<Playlist>> getPlaylists({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getPlaylists.view',
      cancelToken: cancelToken,
    );
    return _asMapList(
      _asMap(root['playlists'])['playlist'],
    ).map(Playlist.fromJson).toList(growable: false);
  }

  Future<Playlist> getPlaylist(String id, {CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getPlaylist.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    final playlist = _asMap(root['playlist']);
    return Playlist.fromJson(<String, dynamic>{
      ...playlist,
      'entries': _asMapList(playlist['entry']),
    });
  }

  Future<Playlist> createPlaylist(
    String name, {
    List<String> songIds = const <String>[],
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/createPlaylist.view',
      query: {
        'name': name,
        if (songIds.isNotEmpty) 'songId': songIds,
      },
      cancelToken: cancelToken,
    );

    final playlist = _asMap(root['playlist']);
    if (playlist.isNotEmpty) {
      return Playlist.fromJson(<String, dynamic>{
        ...playlist,
        'entries': _asMapList(playlist['entry']),
      });
    }

    return Playlist(id: 'created', name: name, entries: const <Song>[]);
  }

  Future<Playlist> updatePlaylist({
    required String id,
    String? name,
    String? comment,
    bool? isPublic,
    List<String> songIdsToAdd = const <String>[],
    List<int> songIndexesToRemove = const <int>[],
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/updatePlaylist.view',
      query: {
        'playlistId': id,
        'name': ?name,
        'comment': ?comment,
        'public': ?isPublic,
        if (songIdsToAdd.isNotEmpty) 'songIdToAdd': songIdsToAdd,
        if (songIndexesToRemove.isNotEmpty)
          'songIndexToRemove': songIndexesToRemove,
      },
      cancelToken: cancelToken,
    );

    final playlist = _asMap(root['playlist']);
    if (playlist.isNotEmpty) {
      return Playlist.fromJson(<String, dynamic>{
        ...playlist,
        'entries': _asMapList(playlist['entry']),
      });
    }

    return Playlist(id: id, name: name ?? 'playlist', entries: const <Song>[]);
  }

  /// Atomically replace all songs in an existing playlist via
  /// `createPlaylist.view?playlistId=…&songId=…`.
  ///
  /// Unlike the two-step remove-all + re-add through `updatePlaylist`,
  /// this is a single API call, so the playlist is never left empty on
  /// the server if the network drops.
  Future<void> replacePlaylistSongs({
    required String playlistId,
    required List<String> songIds,
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/createPlaylist.view',
      query: {
        'playlistId': playlistId,
        if (songIds.isNotEmpty) 'songId': songIds,
      },
      cancelToken: cancelToken,
    );
  }

  Future<void> deletePlaylist(String id, {CancelToken? cancelToken}) async {
    await _readRoot(
      '/rest/deletePlaylist.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
  }

  Uri streamUrl({required String id, int? maxBitRate, String? format}) {
    final query = _buildMediaAuthQuery()
      ..['id'] = id
      ..addAll({
        if (maxBitRate != null) 'maxBitRate': '$maxBitRate',
        'format': ?format,
      });
    return _buildMediaUri('/rest/stream.view', query);
  }

  Uri downloadUrl({required String id}) {
    final query = _buildMediaAuthQuery()..['id'] = id;
    return _buildMediaUri('/rest/download.view', query);
  }

  Uri getCoverArtUrl({required String id, int? size}) {
    final query = _buildMediaAuthQuery()
      ..['id'] = id
      ..addAll({if (size != null) 'size': '$size'});
    return _buildMediaUri('/rest/getCoverArt.view', query);
  }

  Future<LyricsList> getLyricsBySongId(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getLyricsBySongId.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
    return LyricsList.fromJson(_asMap(root['lyricsList']));
  }

  Future<LyricsList> getLyrics({
    String? artist,
    String? title,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getLyrics.view',
      query: {
        'artist': ?artist,
        'title': ?title,
      },
      cancelToken: cancelToken,
    );

    final lyricsRoot = _asMap(root['lyrics']);
    if (lyricsRoot.isNotEmpty) {
      return LyricsList(
        value: lyricsRoot['value'] as String?,
        structuredLyrics: const <StructuredLyrics>[],
      );
    }

    return LyricsList.fromJson(_asMap(root['lyricsList']));
  }

  Future<void> star(String id, {CancelToken? cancelToken}) async {
    await _readRoot(
      '/rest/star.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
  }

  Future<void> unstar(String id, {CancelToken? cancelToken}) async {
    await _readRoot(
      '/rest/unstar.view',
      query: {'id': id},
      cancelToken: cancelToken,
    );
  }

  /// Creates a public URL for sharing a media item.
  ///
  /// Returns the share info including the public URL, or `null` if the
  /// server does not support sharing.
  ///
  /// See: https://opensubsonic.netlify.app/docs/endpoints/createshare/
  Future<ShareInfo?> createShare(
    String id, {
    String? description,
    CancelToken? cancelToken,
  }) async {
    try {
      final root = await _readRoot(
        '/rest/createShare.view',
        query: <String, dynamic>{
          'id': id,
          if (description != null) 'description': description,
        },
        cancelToken: cancelToken,
      );
      final shares = _asMapList(_asMap(root['shares'])['share']);
      if (shares.isEmpty) return null;
      return ShareInfo.fromJson(shares.first);
    } on SubsonicException {
      // Server returned a Subsonic-level error for sharing — not supported.
      return null;
    } on DioException {
      // HTTP-level error (e.g. 501 Not Implemented) — server doesn't support sharing.
      return null;
    }
  }

  Future<void> setRating(
    String id,
    int rating, {
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/setRating.view',
      query: {
        'id': id,
        'rating': rating,
      },
      cancelToken: cancelToken,
    );
  }

  Future<void> scrobble(
    String id, {
    bool submission = false,
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/scrobble.view',
      query: {
        'id': id,
        'submission': submission,
      },
      cancelToken: cancelToken,
    );
  }

  Future<List<InternetRadioStation>> getInternetRadioStations({
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getInternetRadioStations.view',
      cancelToken: cancelToken,
    );
    return _asMapList(
          _asMap(root['internetRadioStations'])['internetRadioStation'],
        )
        .map((json) {
          final id = (json['id'] as String?)?.trim();
          final name = (json['name'] as String?)?.trim();
          final streamUrl =
              (json['streamUrl'] as String?)?.trim() ??
              (json['url'] as String?)?.trim();
          if (id == null ||
              id.isEmpty ||
              name == null ||
              name.isEmpty ||
              streamUrl == null ||
              streamUrl.isEmpty) {
            return null;
          }
          return InternetRadioStation(
            id: id,
            name: name,
            streamUrl: streamUrl,
            homePageUrl: (json['homePageUrl'] as String?)?.trim(),
          );
        })
        .whereType<InternetRadioStation>()
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _readRoot(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: query,
        cancelToken: cancelToken,
      );
      final payload = _asMap(response.data);
      return _extractRoot(payload);
    } on DioException catch (err) {
      throw _mapDioException(err);
    }
  }

  Map<String, dynamic> _extractRoot(Map<String, dynamic> payload) {
    final root = _asMap(payload['subsonic-response']);
    final status = root['status'] as String?;

    if (status == 'failed') {
      final error = _asMap(root['error']);
      throw mapSubsonicApiError(
        code: (error['code'] as num?)?.toInt(),
        message: error['message'] as String?,
      );
    }

    if (status != 'ok') {
      throw const SubsonicGenericException(
        message: 'Subsonic response did not include a valid status.',
      );
    }

    return root;
  }

  SubsonicException _mapDioException(DioException err) {
    final statusCode = err.response?.statusCode;
    if (statusCode == HttpStatus.notFound) {
      return const SubsonicNotFoundException(
        message: 'Requested Subsonic endpoint was not found on this server.',
      );
    }

    final error = err.error;
    if (error is TimeoutException || error is SocketException) {
      return const SubsonicConnectionException(
        'Could not reach server. Check your connection and server URL.',
      );
    }

    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError) {
      return const SubsonicConnectionException(
        'Connection to server timed out.',
      );
    }

    final data = err.response?.data;
    if (data is Map<String, dynamic>) {
      final root = _asMap(data['subsonic-response']);
      if (root['status'] == 'failed') {
        final apiError = _asMap(root['error']);
        return mapSubsonicApiError(
          code: (apiError['code'] as num?)?.toInt(),
          message: apiError['message'] as String?,
        );
      }
    }

    if (statusCode != null) {
      final statusMessage = err.response?.statusMessage;
      final message = statusMessage == null || statusMessage.isEmpty
          ? 'Subsonic server returned HTTP $statusCode.'
          : 'Subsonic server returned HTTP $statusCode: $statusMessage';
      return SubsonicGenericException(code: statusCode, message: message);
    }

    return SubsonicConnectionException(
      err.message ??
          'Unexpected network error while talking to Subsonic server.',
    );
  }

  Uri _buildMediaUri(String path, Map<String, String> query) {
    final base = Uri.parse(_dio.options.baseUrl);
    return base.replace(
      path: '${base.path}$path'.replaceAll('//', '/'),
      queryParameters: query,
    );
  }

  Map<String, String> _buildMediaAuthQuery() {
    final query = <String, String>{
      'u': authConfig.username,
      'v': authConfig.apiVersion,
      'c': authConfig.client,
      'f': 'json',
    };

    switch (authConfig.authType) {
      case SubsonicAuthType.token:
        final salt = _uuid.v4().replaceAll('-', '').substring(0, 12);
        query['s'] = salt;
        query['t'] = md5
            .convert(utf8.encode('${authConfig.password}$salt'))
            .toString();
      case SubsonicAuthType.legacyPassword:
        final bytes = utf8.encode(authConfig.password);
        final hex = bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        query['p'] = 'enc:$hex';
    }

    return query;
  }

  List<Artist> _extractArtists(Object? raw) {
    if (raw == null) {
      return const <Artist>[];
    }

    if (raw is List) {
      return _dedupeArtists(
        _asMapList(raw).map(Artist.fromJson),
      );
    }

    if (raw is Map<String, dynamic>) {
      final nested = _asMapList(raw['artist']);
      if (nested.isNotEmpty) {
        return _dedupeArtists(
          nested.map(Artist.fromJson),
        );
      }
      return _dedupeArtists(<Artist>[Artist.fromJson(raw)]);
    }

    return const <Artist>[];
  }

  List<Artist> _dedupeArtists(Iterable<Artist> artists) {
    final seenIds = <String>{};
    final deduped = <Artist>[];
    for (final artist in artists) {
      final idKey = artist.id.trim().toLowerCase();
      if (idKey.isEmpty || !seenIds.add(idKey)) {
        continue;
      }
      deduped.add(artist);
    }
    return deduped;
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }

    if (value is Map) {
      return value.map(
        (key, dynamic mapValue) => MapEntry(key.toString(), mapValue),
      );
    }

    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is List) {
      return value.map(_asMap).where((element) => element.isNotEmpty).toList();
    }

    final map = _asMap(value);
    if (map.isNotEmpty) {
      return <Map<String, dynamic>>[map];
    }

    return const <Map<String, dynamic>>[];
  }

  int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final direct = int.tryParse(value);
      if (direct != null) {
        return direct;
      }
      final decimal = double.tryParse(value);
      return decimal?.toInt();
    }
    return null;
  }
}
