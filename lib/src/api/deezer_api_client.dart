import 'package:dio/dio.dart';

import 'package:navis/src/api/deezer_request_limiter.dart';
import 'package:navis/src/api/models/deezer_models.dart';

export 'package:navis/src/api/models/deezer_models.dart';

/// An error Deezer reported in the response body.
///
/// Deezer answers errors with HTTP 200 and
/// `{"error": {"type", "message", "code"}}`. Code 800 ("no data") is not an
/// error for Navis and never surfaces as this exception; code 4 (quota) does
/// only after its retries.
class DeezerApiException implements Exception {
  const new({this.code, this.type, this.message});

  /// Deezer's error code; 4 is the quota limit.
  final int? code;
  final String? type;
  final String? message;

  bool get isQuotaExceeded => code == DeezerApiClient.quotaErrorCode;

  @override
  String toString() => 'DeezerApiException(code: $code, type: $type)';
}

/// Client for Deezer's public, keyless API (`api.deezer.com`).
///
/// Production code passes a `dio` from `externalDioFactoryProvider`, built
/// with [baseOptions], so the integration guard and call recorder apply.
/// Every request goes through one [DeezerRequestLimiter] (5 per second, 4 in
/// flight); a `background` request (Home's warm-up) waits while any
/// foreground one is waiting. Errors arrive in the body of an HTTP 200
/// response: code 4 (quota) pauses the shared limiter for [quotaRetryDelay],
/// so every Deezer request waits, and the request that hit it is then
/// retried, up to [foregroundQuotaRetries] times for a foreground request
/// and [backgroundQuotaRetries] for a background one, each retry after the
/// pause; code 800 ("no data") reads as an empty result; any other
/// code throws [DeezerApiException]. Transport failures, including a request
/// the integration guard refused, throw [DioException].
class DeezerApiClient {
  new({required this._dio, DeezerRequestLimiter? limiter})
    : _limiter = limiter ?? DeezerRequestLimiter();

  static final baseOptions = BaseOptions(
    baseUrl: 'https://api.deezer.com/',
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    sendTimeout: const Duration(seconds: 8),
    headers: const {'User-Agent': 'Navis/1.0'},
  );

  static const int quotaErrorCode = 4;
  static const int noDataErrorCode = 800;
  static const Duration quotaRetryDelay = Duration(seconds: 5);

  /// Retries after code 4: a foreground request (what the user opened)
  /// tries harder than Home's background warm-up.
  static const int foregroundQuotaRetries = 3;
  static const int backgroundQuotaRetries = 1;

  final Dio _dio;
  final DeezerRequestLimiter _limiter;

  /// The error Deezer reported in the decoded response [body], or null when
  /// it reported none. Code 800 ("no data") is returned like any other code.
  static DeezerApiException? bodyError(Object? body) {
    if (body is! Map) return null;
    final error = body['error'];
    if (error is! Map) return null;
    return DeezerApiException(
      code: switch (error['code']) {
        final num code => code.toInt(),
        final String code => int.tryParse(code),
        _ => null,
      },
      type: error['type']?.toString(),
      message: error['message']?.toString(),
    );
  }

  /// `/search/artist?q=<name>`: artists whose name matches [name], in
  /// Deezer's relevance order.
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    final query = name.trim();
    if (query.isEmpty) return const [];
    final data = await _getData(
      'search/artist',
      <String, Object>{'q': query, 'limit': limit},
      cancelToken: cancelToken,
      background: background,
    );
    return data.map(DeezerArtist.fromJson).where(_hasId).toList();
  }

  /// `/artist/{id}/top`: the artist's most popular tracks.
  ///
  /// In some regions this returns no tracks for every artist; callers fall
  /// back to [searchTracks].
  Future<List<DeezerTrack>> getArtistTopTracks(
    int artistId, {
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final data = await _getData('artist/$artistId/top', <String, Object>{
      'limit': limit,
    }, cancelToken: cancelToken);
    return data.map(DeezerTrack.fromJson).where(_hasTrackId).toList();
  }

  /// `/search/track?q=<query>`: tracks matching [query]. Results include
  /// covers and remixes by other artists.
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final data = await _getData('search/track', <String, Object>{
      'q': trimmed,
      'limit': limit,
    }, cancelToken: cancelToken);
    return data.map(DeezerTrack.fromJson).where(_hasTrackId).toList();
  }

  /// `/artist/{id}/albums`: the artist's releases, recent ones first (Deezer
  /// does not order them strictly by date).
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    final data = await _getData(
      'artist/$artistId/albums',
      <String, Object>{'limit': limit},
      cancelToken: cancelToken,
      background: background,
    );
    return data.map(DeezerAlbum.fromJson).where((a) => a.id > 0).toList();
  }

  /// `/artist/{id}`: the artist's photo and fan count, or null when Deezer
  /// has no such artist.
  Future<DeezerArtist?> getArtist(
    int artistId, {
    CancelToken? cancelToken,
  }) async {
    final body = await getJson(
      'artist/$artistId',
      const <String, Object>{},
      cancelToken: cancelToken,
    );
    if (body == null) return null;
    final artist = DeezerArtist.fromJson(body);
    return _hasId(artist) ? artist : null;
  }

  /// `/artist/{id}/related`: artists Deezer's listeners of this artist also
  /// listen to, most related first.
  Future<List<DeezerArtist>> getRelatedArtists(
    int artistId, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final data = await _getData('artist/$artistId/related', <String, Object>{
      'limit': limit,
    }, cancelToken: cancelToken);
    return data.map(DeezerArtist.fromJson).where(_hasId).toList();
  }

  /// `/chart/0/tracks`: the most played tracks on Deezer in the caller's
  /// country, most played first.
  Future<List<DeezerTrack>> getChartTracks({
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    final data = await _getData(
      'chart/0/tracks',
      <String, Object>{'limit': limit},
      cancelToken: cancelToken,
      background: background,
    );
    return data.map(DeezerTrack.fromJson).where(_hasTrackId).toList();
  }

  /// The `data` list of a list endpoint, empty for code 800.
  Future<List<Map<String, dynamic>>> _getData(
    String path,
    Map<String, Object> query, {
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    final body = await getJson(
      path,
      query,
      cancelToken: cancelToken,
      background: background,
    );
    final data = body?['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<Object?, Object?>>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }

  /// The decoded body of `GET path` (relative to [baseOptions]' base URL,
  /// without a leading slash), or null for code 800 ("no data").
  ///
  /// The building block for every endpoint, so a new endpoint inherits the
  /// limiter and the error handling. A [background] request yields the
  /// limiter to foreground ones.
  Future<Map<String, dynamic>?> getJson(
    String path,
    Map<String, Object> query, {
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final response = await _limiter.run(() async {
        final response = await _dio.get<Object?>(
          path,
          queryParameters: query,
          cancelToken: cancelToken,
        );
        // Paused before this request's slot is released, so no waiting
        // request starts into the quota in between.
        if (bodyError(response.data)?.isQuotaExceeded ?? false) {
          _limiter.pauseStarts(quotaRetryDelay);
        }
        return response;
      }, background: background);
      final body = response.data;
      if (body is! Map) {
        throw const DeezerApiException(
          type: 'FormatException',
          message: 'Response is not a JSON object',
        );
      }
      final json = Map<String, dynamic>.from(body);
      final exception = bodyError(json);
      if (exception == null) return json;
      if (exception.code == noDataErrorCode) return null;
      // The limiter is already paused (above), so every request waits out
      // the quota, each retry included; a request cancelled meanwhile fails
      // there with Dio's cancellation, without being sent.
      final quotaRetries = background
          ? backgroundQuotaRetries
          : foregroundQuotaRetries;
      if (exception.isQuotaExceeded && attempt < quotaRetries) continue;
      throw exception;
    }
  }

  static bool _hasId(DeezerArtist artist) => artist.id > 0;

  static bool _hasTrackId(DeezerTrack track) => track.id > 0;
}
