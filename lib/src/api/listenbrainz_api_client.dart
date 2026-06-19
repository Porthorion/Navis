import 'package:dio/dio.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';

class ListenBrainzInvalidTokenException implements Exception {
  const ListenBrainzInvalidTokenException();
}

class ListenBrainzApiClient {
  ListenBrainzApiClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.listenbrainz.org/1',
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 10),
              headers: const {'User-Agent': 'Navis/1.0'},
            ),
          );

  final Dio _dio;

  Future<bool> validateToken(String userToken) async {
    return (await validateTokenDetails(userToken)).valid;
  }

  Future<ListenBrainzTokenDetails> validateTokenDetails(
    String userToken,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/validate-token',
        options: _authOptions(userToken),
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
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/user/$userName/playlists/recommendations',
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
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/playlist/$playlistMbid',
      queryParameters: <String, Object?>{'fetch_metadata': fetchMetadata},
      options: userToken == null || userToken.trim().isEmpty
          ? null
          : _authOptions(userToken),
    );
    return ListenBrainzPlaylist.fromJson(
      response.data ?? const <String, dynamic>{},
    );
  }

  Future<Map<String, dynamic>> getPlaylistStatus() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/status/get-dump-info',
    );
    return response.data ?? const <String, dynamic>{};
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
