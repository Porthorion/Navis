import 'package:dio/dio.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/utils/app_logger.dart';

/// HTTP client for communicating with the AudioMuse AI server.
///
/// The AudioMuse API provides AI-powered music recommendations including
/// similar artists, similar albums, song recommendations, and AI mix
/// generation.
///
/// All endpoints return Subsonic entity IDs that map to the user's local
/// library, ensuring recommendations are always playable.
class AudioMuseApiClient {
  AudioMuseApiClient({
    required String baseUrl,
    String? apiKey,
    Dio? dio,
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 15);
    _dio.options.sendTimeout = const Duration(seconds: 10);

    if (apiKey != null && apiKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    }
  }

  final String _baseUrl;
  final Dio _dio;

  /// Health check — verifies the AudioMuse server is reachable.
  Future<AudioMuseHealth> health() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/api/v1/health',
      );
      return AudioMuseHealth.fromJson(response.data ?? {});
    } on DioException catch (e) {
      AppLogger.warning('AudioMuse health check failed: ${e.message}');
      return const AudioMuseHealth(healthy: false);
    }
  }

  /// Returns artists similar to the given artist.
  Future<List<AudioMuseRecommendation>> getSimilarArtists(
    String artistId, {
    int count = 10,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/api/v1/similar/artists',
      queryParameters: <String, dynamic>{
        'id': artistId,
        'count': count,
      },
    );
    return _parseRecommendations(response.data);
  }

  /// Returns albums similar to the given album.
  Future<List<AudioMuseRecommendation>> getSimilarAlbums(
    String albumId, {
    int count = 10,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/api/v1/similar/albums',
      queryParameters: <String, dynamic>{
        'id': albumId,
        'count': count,
      },
    );
    return _parseRecommendations(response.data);
  }

  /// Returns recommended songs based on a seed song, recent history, or
  /// general listening patterns.
  Future<List<AudioMuseRecommendation>> getRecommendations({
    String? seedSongId,
    List<String>? recentSongIds,
    int count = 20,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/api/v1/recommendations',
      queryParameters: <String, dynamic>{
        if (seedSongId != null) 'seedId': seedSongId,
        if (recentSongIds != null && recentSongIds.isNotEmpty)
          'recentIds': recentSongIds.join(','),
        'count': count,
      },
    );
    return _parseRecommendations(response.data);
  }

  /// Generates an AI mix from a seed (artist, album, genre, or mood keyword).
  Future<AudioMuseMix> generateMix({
    required String seedType,
    required String seedId,
    int count = 50,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/api/v1/mix',
      queryParameters: <String, dynamic>{
        'seedType': seedType,
        'seedId': seedId,
        'count': count,
      },
    );
    return AudioMuseMix.fromJson(response.data ?? {});
  }

  /// Returns album recommendations for the home screen ("You might also
  /// like").
  Future<List<AudioMuseRecommendation>> getHomeRecommendations({
    int count = 10,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '$_baseUrl/api/v1/recommendations/home',
      queryParameters: <String, dynamic>{'count': count},
    );
    return _parseRecommendations(response.data);
  }

  List<AudioMuseRecommendation> _parseRecommendations(
    Map<String, dynamic>? data,
  ) {
    if (data == null) return const [];
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(AudioMuseRecommendation.fromJson)
        .toList(growable: false);
  }
}
