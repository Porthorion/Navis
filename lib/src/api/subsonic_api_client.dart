import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:dio/io.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/api/subsonic_logging_interceptor.dart';
import 'package:navis/src/api/subsonic_retry_interceptor.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/credential_redaction.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:uuid/uuid.dart';

/// Typed Subsonic/OpenSubsonic API wrapper.
class SubsonicApiClient {
  new({
    required String baseUrl,
    required this.authConfig,
    Dio? dio,
    this.enableLogging = true,
    this.maxConnectionsPerHost,
    this._reportNetworkUsage,
  }) : connectionIdentity = sha256
           .convert(
             utf8.encode(
               jsonEncode(<String>[
                 _normalizeBaseUrl(baseUrl),
                 authConfig.username,
                 authConfig.password,
                 authConfig.authType.name,
               ]),
             ),
           )
           .toString(),
       _uuid = const Uuid(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: _normalizeBaseUrl(baseUrl),
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 15),
               headers: <String, Object>{'User-Agent': AppConstants.userAgent},
             ),
           ) {
    _configureTransport();
    _dio.options.headers['User-Agent'] = AppConstants.userAgent;
    _dio.interceptors.add(SubsonicAuthInterceptor(config: authConfig));
    if (enableLogging) {
      _dio.interceptors.add(SubsonicLoggingInterceptor());
    }
    _dio.interceptors.add(SubsonicRetryInterceptor(dio: _dio));
  }

  final Dio _dio;
  final Uuid _uuid;
  final SubsonicAuthConfig authConfig;

  /// Internal session key for comparing transports across connectivity-only
  /// rebuilds. Never expose it in logs or diagnostics.
  final Object? connectionIdentity;
  final bool enableLogging;
  final int? maxConnectionsPerHost;
  final NetworkUsageReporter? _reportNetworkUsage;

  void close({bool force = true}) {
    _dio.close(force: force);
  }

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

    final extensionsRoot = root['openSubsonicExtensions'];
    final rawExtensions = extensionsRoot is List
        ? extensionsRoot
        : _asMap(extensionsRoot)['openSubsonicExtension'];
    final extensions = _asMapList(rawExtensions)
        .map((raw) {
          final versions = raw['versions'];
          return OpenSubsonicExtension.fromJson({
            ...raw,
            'versions': versions is List
                ? versions.map((version) => version.toString()).toList()
                : <String>[],
          });
        })
        .toList(growable: false);

    return ServerCapabilities(extensions: extensions);
  }

  Future<List<Artist>> getArtists({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getArtists.view',
      cancelToken: cancelToken,
    );
    final artistsNode = _snapshotNode(root, 'artists');
    final indexEntries = _snapshotList(artistsNode['index']);

    final artists = <Artist>[];
    for (final indexEntry in indexEntries) {
      artists.addAll(_snapshotList(indexEntry['artist']).map(Artist.fromJson));
    }

    if (artists.isEmpty) {
      artists.addAll(_snapshotList(artistsNode['artist']).map(Artist.fromJson));
    }

    return artists;
  }

  Future<Artist> getArtist(
    String id, {
    CancelToken? cancelToken,
    int? maxResponseBytes,
  }) async {
    final root = await _readRoot(
      '/rest/getArtist.view',
      query: {'id': id},
      cancelToken: cancelToken,
      maxResponseBytes: maxResponseBytes,
    );
    final artist = _snapshotNode(root, 'artist');
    // Standard Subsonic payloads use `album`, while Navis's model follows the
    // plural Dart field name. Normalizing here preserves artist-detail albums
    // for incremental discovery and hydration.
    return Artist.fromJson(<String, dynamic>{
      ...artist,
      'albums': _snapshotList(artist['album']),
    });
  }

  Future<Album> getAlbum(
    String id, {
    CancelToken? cancelToken,
    int? maxResponseBytes,
  }) async {
    final root = await _readRoot(
      '/rest/getAlbum.view',
      query: {'id': id},
      cancelToken: cancelToken,
      maxResponseBytes: maxResponseBytes,
    );
    final album = _snapshotNode(root, 'album');
    _requireDetailEntries(album, 'song', 'songCount');
    return Album.fromJson(<String, dynamic>{
      ...album,
      // Subsonic uses `song` for album track payloads. Normalize it so
      // Album.fromJson always receives the expected `songs` list key.
      'songs': _snapshotList(album['song']),
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

  Future<List<Album>> getAlbumList2({
    required String type,
    int size = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getAlbumList2.view',
      query: {'type': type, 'size': size, 'offset': offset},
      cancelToken: cancelToken,
    );
    return _snapshotList(_snapshotNode(root, 'albumList2')['album'])
        .map(Album.fromJson)
        .toList(growable: false);
  }

  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    CancelToken? cancelToken,
    bool disableRetry = false,
  }) async {
    final query = <String, dynamic>{
      if (ifModifiedSince != null)
        'ifModifiedSince': ifModifiedSince.toUtc().millisecondsSinceEpoch,
    };
    final root = await _readRoot(
      '/rest/getIndexes.view',
      query: query.isEmpty ? null : query,
      cancelToken: cancelToken,
      disableRetry: disableRetry,
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
    return _asMapList(_asMap(root['randomSongs'])['song'])
        .map(Song.fromJson)
        .toList(growable: false);
  }

  Future<StarredContent> getStarred2({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getStarred2.view',
      cancelToken: cancelToken,
    );
    final starred = _snapshotNode(root, 'starred2');
    return StarredContent(
      albums: _snapshotList(starred['album'])
          .map(Album.fromJson)
          .toList(growable: false),
      artists: _snapshotList(starred['artist'])
          .map(Artist.fromJson)
          .toList(growable: false),
      songs: _snapshotList(starred['song'])
          .map(Song.fromJson)
          .toList(growable: false),
    );
  }

  /// OpenSubsonic scan status. Servers without the endpoint report it through
  /// the typed [SubsonicApiException] path, so callers can treat unsupported
  /// scan status as a capability result rather than a sync failure.
  Future<ScanStatus> getScanStatus({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getScanStatus.view',
      cancelToken: cancelToken,
    );
    final node = _asMap(root['scanStatus']);
    return ScanStatus.fromJson(node);
  }

  Future<List<Song>> getNowPlaying({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getNowPlaying.view',
      cancelToken: cancelToken,
    );
    return _asMapList(_asMap(root['nowPlaying'])['entry'])
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// Returns songs from Navidrome's optional `getInstantMix` endpoint.
  Future<List<Song>> getInstantMix(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getInstantMix.view',
      query: {'id': seedSongId, 'count': count},
      cancelToken: cancelToken,
    );
    return _asMapList(_asMap(root['instantMix'])['song'])
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// Generic server similarity without endpoint fallback. A caller can
  /// distinguish an unsupported endpoint from an empty or unindexed seed.
  Future<List<Song>> getSimilarSongs2(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getSimilarSongs2.view',
      query: {'id': seedSongId, 'count': count},
      cancelToken: cancelToken,
    );
    return _asMapList(_asMap(root['similarSongs2'])['song'])
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// The original Subsonic similarity endpoint. Some compatible servers
  /// implement this endpoint but do not implement `getSimilarSongs2`.
  Future<List<Song>> getLegacySimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/getSimilarSongs.view',
      query: {'id': seedSongId, 'count': count},
      cancelToken: cancelToken,
    );
    return _asMapList(_asMap(root['similarSongs'])['song'])
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// Returns songs similar to [seedSongId] using `getSimilarSongs2`.
  ///
  /// Falls back to the original standard endpoint before Navidrome's
  /// `getInstantMix` when an endpoint is unsupported.
  Future<List<Song>> getSimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    try {
      return await getSimilarSongs2(
        seedSongId,
        count: count,
        cancelToken: cancelToken,
      );
    } on SubsonicNotFoundException {
      try {
        return await getLegacySimilarSongs(
          seedSongId,
          count: count,
          cancelToken: cancelToken,
        );
      } on SubsonicNotFoundException {
        return await getInstantMix(
          seedSongId,
          count: count,
          cancelToken: cancelToken,
        );
      }
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
      artists: _asMapList(result['artist'])
          .map(Artist.fromJson)
          .toList(growable: false),
      albums: _asMapList(result['album'])
          .map(Album.fromJson)
          .toList(growable: false),
      songs: _asMapList(result['song'])
          .map(Song.fromJson)
          .toList(growable: false),
    );
  }

  Future<List<Playlist>> getPlaylists({CancelToken? cancelToken}) async {
    final root = await _readRoot(
      '/rest/getPlaylists.view',
      cancelToken: cancelToken,
    );
    return _snapshotList(_snapshotNode(root, 'playlists')['playlist'])
        .map(Playlist.fromJson)
        .toList(growable: false);
  }

  Future<Playlist> getPlaylist(
    String id, {
    CancelToken? cancelToken,
    int? maxResponseBytes,
  }) async {
    final root = await _readRoot(
      '/rest/getPlaylist.view',
      query: {'id': id},
      cancelToken: cancelToken,
      maxResponseBytes: maxResponseBytes,
    );
    final playlist = _snapshotNode(root, 'playlist');
    _requireDetailEntries(playlist, 'entry', 'songCount');
    return Playlist.fromJson(<String, dynamic>{
      ...playlist,
      'entries': _snapshotList(playlist['entry']),
    });
  }

  Future<Playlist> createPlaylist(
    String name, {
    List<String> songIds = const <String>[],
    CancelToken? cancelToken,
  }) async {
    final root = await _readRoot(
      '/rest/createPlaylist.view',
      query: {'name': name, if (songIds.isNotEmpty) 'songId': songIds},
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

  /// [estimateContentLength] asks the server to send a Content-Length for a
  /// transcoded stream, so a download can report progress.
  Uri streamUrl({
    required String id,
    int? maxBitRate,
    String? format,
    bool estimateContentLength = false,
  }) {
    final query = _buildMediaAuthQuery()
      ..['id'] = id
      ..addAll({
        if (maxBitRate != null) 'maxBitRate': '$maxBitRate',
        'format': ?format,
        if (estimateContentLength) 'estimateContentLength': 'true',
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

  /// Signs only this client's cover endpoint with the current credentials.
  Uri authenticateCoverArtUri(Uri uri) {
    final id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return uri;
    final signed = getCoverArtUrl(
      id: id,
      size: int.tryParse(uri.queryParameters['size'] ?? ''),
    );
    if (uri.origin != signed.origin || uri.path != signed.path) return uri;
    return signed.replace(
      queryParameters: {
        ...credentialFreeUri(uri).queryParametersAll,
        ...signed.queryParametersAll,
      },
    );
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
      query: {'artist': ?artist, 'title': ?title},
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

  static String _starIdParameter(String itemType) => switch (itemType) {
    'song' => 'id',
    'album' => 'albumId',
    'artist' => 'artistId',
    _ => throw ArgumentError.value(itemType, 'itemType'),
  };

  Future<void> star(
    String id, {
    String itemType = 'song',
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/star.view',
      query: {_starIdParameter(itemType): id},
      cancelToken: cancelToken,
    );
  }

  Future<void> unstar(
    String id, {
    String itemType = 'song',
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/unstar.view',
      query: {_starIdParameter(itemType): id},
      cancelToken: cancelToken,
    );
  }

  /// Creates a public URL for sharing a media item.
  ///
  Future<void> setRating(
    String id,
    int rating, {
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/setRating.view',
      query: {'id': id, 'rating': rating},
      cancelToken: cancelToken,
    );
  }

  Future<void> scrobble(
    String id, {
    bool submission = false,
    DateTime? time,
    CancelToken? cancelToken,
  }) async {
    await _readRoot(
      '/rest/scrobble.view',
      query: {
        'id': id,
        'submission': submission,
        if (time != null) 'time': time.millisecondsSinceEpoch,
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
    bool disableRetry = false,
    int? maxResponseBytes,
  }) async {
    final scope = SyncRequestScope.current;
    final endpoint = syncEndpointForPath(path, query);
    var attempt = scope?.beginTransport(endpoint);
    // Decoded bytes as they arrive. Navidrome gzips JSON without a
    // Content-Length, and re-encoding the parsed body to count it cost two
    // full JSON encodes of every large page on the UI isolate.
    var receivedBytes = 0;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          extra: <String, Object?>{
            if (disableRetry) 'navisDisableRetry': true,
            if (scope != null)
              'navisBeforeSyncRetry': (int previousBytes) {
                attempt?.observe(previousBytes);
                attempt?.finish(succeeded: false);
                attempt = scope.beginTransport(endpoint, retryOf: attempt);
              },
          },
        ),
        onReceiveProgress: (received, total) {
          receivedBytes = received;
          if (maxResponseBytes == null && scope == null) return;
          attempt?.observe(received);
          final knownTotal = total > 0 ? total : null;
          if (maxResponseBytes != null &&
              knownTotal != null &&
              knownTotal > maxResponseBytes) {
            cancelToken?.cancel(
              'Response exceeds sync byte budget ($maxResponseBytes).',
            );
            throw SubsonicResponseBudgetExceededException(
              maxBytes: maxResponseBytes,
              observedBytes: knownTotal,
            );
          }
          if (maxResponseBytes != null && received > maxResponseBytes) {
            cancelToken?.cancel(
              'Response exceeds sync byte budget ($maxResponseBytes).',
            );
            throw SubsonicResponseBudgetExceededException(
              maxBytes: maxResponseBytes,
              observedBytes: received,
            );
          }
        },
      );
      final bytes = _responseBodyBytes(response, receivedBytes: receivedBytes);
      attempt?.observe(bytes);
      if (maxResponseBytes != null && bytes > maxResponseBytes) {
        throw SubsonicResponseBudgetExceededException(
          maxBytes: maxResponseBytes,
          observedBytes: bytes,
        );
      }
      _recordUsageForResponse(path, bytes);
      final payload = _asMap(response.data);
      final root = _extractRoot(payload);
      attempt?.finish(succeeded: true);
      return root;
    } on SubsonicResponseBudgetExceededException {
      rethrow;
    } on DioException catch (err) {
      final nested = err.error;
      final failedData = err.response?.data;
      if (failedData != null) {
        attempt?.observe(utf8.encode(jsonEncode(failedData)).length);
      }
      if (nested is SubsonicSyncLimitException) throw nested;
      if (scope?.stopped case final SubsonicSyncLimitException stopped) {
        throw stopped;
      }
      if (nested is SubsonicResponseBudgetExceededException) {
        throw nested;
      }
      if (err.type == DioExceptionType.cancel &&
          err.error is SubsonicResponseBudgetExceededException) {
        throw err.error! as SubsonicResponseBudgetExceededException;
      }
      throw _mapDioException(err);
    } finally {
      // Idempotent: a successful envelope or earlier retry is already closed.
      attempt?.finish(succeeded: false);
    }
  }

  void _recordUsageForResponse(String path, int bytes) {
    final reporter = _reportNetworkUsage;
    if (reporter == null) {
      return;
    }
    if (bytes <= 0) {
      return;
    }
    AppLogger.debug(
      'Subsonic API response bytes path=$path '
      'category=${networkUsageCategoryForSubsonicPath(path).key} '
      'estimatedDecodedBytes=$bytes',
    );
    reporter(
      category: networkUsageCategoryForSubsonicPath(path),
      bytes: bytes,
      operation: path,
    );
  }

  int _responseBodyBytes(
    Response<Map<String, dynamic>> response, {
    int receivedBytes = 0,
  }) {
    final contentLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (contentLength != null && contentLength > 0) {
      return contentLength;
    }
    if (receivedBytes > 0) {
      return receivedBytes;
    }
    final data = response.data;
    if (data == null) {
      return 0;
    }
    try {
      return utf8.encode(jsonEncode(data)).length;
    } on Object {
      return utf8.encode(data.toString()).length;
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
      return SubsonicGenericException(
        code: statusCode,
        message: message,
        retryAt: subsonicRetryAt(err.response?.headers.value('retry-after')),
      );
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
      return _dedupeArtists(_asMapList(raw).map(Artist.fromJson));
    }

    if (raw is Map<String, dynamic>) {
      final nested = _asMapList(raw['artist']);
      if (nested.isNotEmpty) {
        return _dedupeArtists(nested.map(Artist.fromJson));
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

  Map<String, dynamic> _snapshotNode(Map<String, dynamic> root, String key) {
    final value = root[key];
    if (value is! Map) {
      throw SubsonicIncompleteResponseException(
        'Missing or invalid $key snapshot.',
      );
    }
    return _asMap(value);
  }

  List<Map<String, dynamic>> _snapshotList(Object? value) {
    // Subsonic represents an empty collection by omitting its child field.
    if (value == null) return const [];
    final values = value is List ? value : [value];
    if (values.any((entry) => entry is! Map || entry.isEmpty)) {
      throw const SubsonicIncompleteResponseException(
        'Snapshot contains invalid entries.',
      );
    }
    return values.map(_asMap).toList(growable: false);
  }

  void _requireDetailEntries(
    Map<String, dynamic> detail,
    String key,
    String countKey,
  ) {
    if (detail[key] == null && _toInt(detail[countKey]) != 0) {
      throw SubsonicIncompleteResponseException(
        'Detail omitted $key entries without an explicit zero count.',
      );
    }
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
