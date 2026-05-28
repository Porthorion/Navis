import 'package:dio/dio.dart';

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
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/validate-token',
        options: _authOptions(userToken),
      );
      return response.data?['valid'] == true;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        return false;
      }
      rethrow;
    }
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
