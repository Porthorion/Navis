import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';

class ListenBrainzInvalidTokenException implements Exception {
  const new();
}

/// Dispatch must wait until ListenBrainz replenishes its request budget.
class ListenBrainzRateLimitedException implements Exception {
  const new(this.retryAt);
  final DateTime retryAt;
}

/// The documented endpoint is unavailable; this does not reject a token.
class ListenBrainzUnavailableException implements Exception {
  const new([this.statusCode]);
  final int? statusCode;
  @override
  String toString() => 'ListenBrainzUnavailableException (HTTP $statusCode)';
}

class ListenBrainzApiClient {
  /// Production code passes a [dio] from `externalDioFactoryProvider`, built
  /// with [baseOptions], so the integration guard applies.
  new({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? Dio(baseOptions),
      _now = now ?? DateTime.now;

  static final baseOptions = BaseOptions(
    baseUrl: 'https://api.listenbrainz.org/1',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': AppConstants.userAgent},
  );

  final Dio _dio;
  final DateTime Function() _now;
  DateTime? _rateLimitedUntil;

  DateTime? get rateLimitedUntil => _rateLimitedUntil;
  bool get isRateLimited =>
      _rateLimitedUntil != null && _now().isBefore(_rateLimitedUntil!);

  void _recordRateLimit(Headers? headers) {
    if (int.tryParse(
          headers?['x-ratelimit-remaining']?.singleOrNull?.trim() ?? '',
        ) !=
        0) {
      return;
    }
    final seconds = int.tryParse(
      headers?['x-ratelimit-reset-in']?.singleOrNull?.trim() ?? '',
    );
    if (seconds == null || seconds < 0) return;
    final deadline = _now().add(Duration(seconds: seconds.clamp(0, 300)));
    if (_rateLimitedUntil == null || deadline.isAfter(_rateLimitedUntil!)) {
      _rateLimitedUntil = deadline;
    }
  }

  /// Checks [userToken] with ListenBrainz.
  ///
  /// Pass [userInitiated] when the person asked for the check, such as the
  /// validate action in Settings or onboarding; only then does the request
  /// bypass a switched-off ListenBrainz service. Automatic revalidation leaves
  /// it false.
  Future<ListenBrainzTokenDetails> validateTokenDetails(
    String userToken, {
    bool userInitiated = false,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _connectionRequest(
        '/validate-token',
        userToken,
        userInitiated: userInitiated,
        cancelToken: cancelToken,
      );
      final data = _jsonObject(response);
      if (data['valid'] is! bool) {
        throw ListenBrainzUnavailableException(response.statusCode);
      }
      return ListenBrainzTokenDetails(
        valid: data['valid'] == true,
        userName: data['user_name']?.toString(),
      );
    } on ListenBrainzInvalidTokenException {
      return const ListenBrainzTokenDetails(valid: false);
    }
  }

  Map<String, dynamic> _jsonObject(Response<Object?> response) {
    var data = response.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        throw ListenBrainzUnavailableException(response.statusCode);
      }
    }
    if (data is! Map<String, dynamic>) {
      throw ListenBrainzUnavailableException(response.statusCode);
    }
    return data;
  }

  /// Follow same-origin redirects explicitly: Dart's native automatic redirect
  /// handling does not replay POST bodies on 307/308. Never forward a token to
  /// a different origin or downgrade HTTPS.
  Future<Response<Object?>> _connectionRequest(
    String path,
    String token, {
    String method = 'GET',
    Object? data,
    bool userInitiated = false,
    CancelToken? cancelToken,
  }) async {
    if (isRateLimited) {
      throw ListenBrainzRateLimitedException(_rateLimitedUntil!);
    }
    var target = path;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final options = _authOptions(token).copyWith(
        method: method,
        followRedirects: false,
        maxRedirects: 5,
        validateStatus: (status) =>
            status != null &&
            (status >= 200 && status < 300 ||
                (method == 'GET' && (status == 301 || status == 302)) ||
                status == 307 ||
                status == 308),
      );
      try {
        final response = await _dio.request<Object?>(
          target,
          data: data,
          cancelToken: cancelToken,
          options: userInitiated ? userInitiatedOptions(options) : options,
        );
        _recordRateLimit(response.headers);
        final status = response.statusCode;
        if (status != null && status >= 300 && status < 400) {
          final location = response.headers.value('location');
          if (location == null || redirects == 5) {
            throw ListenBrainzUnavailableException(status);
          }
          final previous = response.requestOptions.uri;
          final next = previous.resolve(location);
          if (next.scheme != previous.scheme ||
              next.host != previous.host ||
              next.port != previous.port) {
            throw ListenBrainzUnavailableException(status);
          }
          target = next.toString();
          continue;
        }
        // HTML responses sometimes arrive with a successful status as well.
        if (response.data is String &&
            (response.data! as String).trimLeft().startsWith('<')) {
          throw ListenBrainzUnavailableException(status);
        }
        return response;
      } on DioException catch (error) {
        if (error.error is IntegrationBlockedException ||
            CancelToken.isCancel(error)) {
          rethrow;
        }
        _recordRateLimit(error.response?.headers);
        final status = error.response?.statusCode;
        if (status == 401 || status == 403) {
          throw const ListenBrainzInvalidTokenException();
        }
        if (status == 429) {
          final seconds =
              int.tryParse(
                error.response?.headers.value('retry-after') ?? '',
              ) ??
              60;
          final fallback = _now().add(Duration(seconds: seconds.clamp(1, 300)));
          if (_rateLimitedUntil == null ||
              !_rateLimitedUntil!.isAfter(_now())) {
            _rateLimitedUntil = fallback;
          }
          throw ListenBrainzRateLimitedException(_rateLimitedUntil!);
        }
        throw ListenBrainzUnavailableException(status);
      }
    }
    throw const ListenBrainzUnavailableException();
  }

  Future<List<ListenBrainzPlaylist>> getRecommendationPlaylists({
    required String userName,
    String? userToken,
    CancelToken? cancelToken,
  }) async {
    final encodedUserName = Uri.encodeComponent(userName);
    final response = await _dio.get<Map<String, dynamic>>(
      '/user/$encodedUserName/playlists/recommendations',
      cancelToken: cancelToken,
      options: userToken == null || userToken.trim().isEmpty
          ? null
          : _authOptions(userToken),
    );
    return parseListenBrainzPlaylistList(
      response.data ?? const <String, dynamic>{},
    );
  }

  Future<ListenBrainzPlaylist> getPlaylist(
    String playlistMbid, {
    bool fetchMetadata = true,
    String? userToken,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/playlist/$playlistMbid',
      queryParameters: <String, Object?>{'fetch_metadata': fetchMetadata},
      cancelToken: cancelToken,
      options: userToken == null || userToken.trim().isEmpty
          ? null
          : _authOptions(userToken),
    );
    return ListenBrainzPlaylist.fromJson(
      response.data ?? const <String, dynamic>{},
    );
  }

  Future<void> sendPlayingNow({
    required String userToken,
    required String artist,
    required String track,
    String? album,
    int? duration,
  }) {
    return _submit(
      userToken: userToken,
      listenType: 'playing_now',
      artist: artist,
      track: track,
      album: album,
      duration: duration,
    );
  }

  Future<void> submitSingleListen({
    required String userToken,
    required String artist,
    required String track,
    required DateTime listenedAt,
    String? album,
    int? duration,
  }) {
    return _submit(
      userToken: userToken,
      listenType: 'single',
      artist: artist,
      track: track,
      album: album,
      duration: duration,
      listenedAt: listenedAt,
    );
  }

  Future<void> submitRecordingFeedback({
    required String userToken,
    String? recordingMbid,
    String? recordingMsid,
    required int score,
  }) async {
    final mbid = recordingMbid?.trim();
    final msid = recordingMsid?.trim();
    if ((mbid == null || mbid.isEmpty) && (msid == null || msid.isEmpty)) {
      throw ArgumentError('recordingMbid or recordingMsid is required');
    }
    try {
      await _dio.post<void>(
        '/feedback/recording-feedback',
        data: <String, dynamic>{
          if (mbid != null && mbid.isNotEmpty) 'recording_mbid': mbid,
          if (msid != null && msid.isNotEmpty) 'recording_msid': msid,
          'score': score,
        },
        options: _authOptions(userToken),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const ListenBrainzInvalidTokenException();
      }
      rethrow;
    }
  }

  Future<String?> lookupRecordingMbid({
    required String userToken,
    required String title,
    required String artist,
    String? album,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/metadata/lookup',
      queryParameters: <String, Object?>{
        'recording_name': title,
        'artist_name': artist,
        if (album != null && album.trim().isNotEmpty)
          'release_name': album.trim(),
      },
      options: _authOptions(userToken),
    );
    return parseListenBrainzRecordingMbid(
      response.data ?? const <String, dynamic>{},
    );
  }

  Future<void> _submit({
    required String userToken,
    required String listenType,
    required String artist,
    required String track,
    String? album,
    int? duration,
    DateTime? listenedAt,
  }) async {
    if (isRateLimited) {
      throw ListenBrainzRateLimitedException(_rateLimitedUntil!);
    }
    final metadata = <String, dynamic>{
      'artist_name': artist,
      'track_name': track,
      if (album != null && album.trim().isNotEmpty)
        'release_name': album.trim(),
      if (duration != null && duration > 0) 'duration': duration,
    };
    final payload = <String, dynamic>{
      'listen_type': listenType,
      'payload': [
        <String, dynamic>{
          if (listenedAt != null)
            'listened_at': listenedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
          'track_metadata': metadata,
        },
      ],
    };
    final response = await _connectionRequest(
      '/submit-listens',
      userToken,
      method: 'POST',
      data: payload,
    );
    if (response.data != null) {
      final body = _jsonObject(response);
      if (body['valid'] == false) {
        throw const ListenBrainzInvalidTokenException();
      }
    }
  }

  Options _authOptions(String userToken) {
    return Options(
      headers: <String, String>{'Authorization': 'Token $userToken'},
    );
  }
}
