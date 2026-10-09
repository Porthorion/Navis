import 'package:dio/dio.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';

class ListenBrainzInvalidTokenException implements Exception {
  const new();
}

class ListenBrainzApiClient {
  /// Production code passes a [dio] from `externalDioFactoryProvider`, built
  /// with [baseOptions], so the integration guard applies.
  new({Dio? dio}) : _dio = dio ?? Dio(baseOptions);

  static final baseOptions = BaseOptions(
    baseUrl: 'https://api.listenbrainz.org/1',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': AppConstants.userAgent},
  );

  final Dio _dio;

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
      final options = _authOptions(userToken);
      final response = await _dio.get<Map<String, dynamic>>(
        '/validate-token',
        cancelToken: cancelToken,
        options: userInitiated ? userInitiatedOptions(options) : options,
      );
      final data = response.data ?? const <String, dynamic>{};
      return ListenBrainzTokenDetails(
        valid: data['valid'] == true,
        userName: data['user_name']?.toString(),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        return const ListenBrainzTokenDetails(valid: false);
      }
      rethrow;
    }
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
    try {
      await _dio.post<void>(
        '/submit-listens',
        data: payload,
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

  Options _authOptions(String userToken) {
    return Options(
      headers: <String, String>{'Authorization': 'Token $userToken'},
    );
  }
}
