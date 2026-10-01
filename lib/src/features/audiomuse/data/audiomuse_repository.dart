import 'package:dio/dio.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_api_client.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Repository that wraps [AudioMuseApiClient] with error handling and
/// provides data to the UI layer.
///
/// All methods return `null` or empty lists on failure rather than throwing,
/// so the UI can gracefully degrade when AudioMuse is unavailable or errors
/// occur.
class AudioMuseRepository {
  new(this._client);

  final AudioMuseApiClient _client;

  /// Checks whether the AudioMuse server is healthy and reachable.
  Future<AudioMuseHealth> testConnection() async {
    try {
      return await _client.health();
    } on DioException catch (e) {
      AppLogger.warning('AudioMuse connection test failed: ${e.message}');
      return const AudioMuseHealth(healthy: false);
    } on Object catch (e) {
      AppLogger.warning('AudioMuse connection test failed: $e');
      return const AudioMuseHealth(healthy: false);
    }
  }

  /// Returns AI-powered similar artists, or an empty list on error.
  Future<List<AudioMuseRecommendation>> getSimilarArtists(
    String artistId, {
    int count = 10,
  }) async {
    try {
      return await _client.getSimilarArtists(artistId, count: count);
    } on DioException catch (e) {
      AppLogger.debug('AudioMuse getSimilarArtists failed: ${e.message}');
      return const [];
    } on Object catch (e) {
      AppLogger.debug('AudioMuse getSimilarArtists failed: $e');
      return const [];
    }
  }

  /// Returns AI-powered similar albums, or an empty list on error.
  Future<List<AudioMuseRecommendation>> getSimilarAlbums(
    String albumId, {
    int count = 10,
  }) async {
    try {
      return await _client.getSimilarAlbums(albumId, count: count);
    } on DioException catch (e) {
      AppLogger.debug('AudioMuse getSimilarAlbums failed: ${e.message}');
      return const [];
    } on Object catch (e) {
      AppLogger.debug('AudioMuse getSimilarAlbums failed: $e');
      return const [];
    }
  }

  /// Returns AI-recommended songs for auto-queue or discovery.
  Future<List<AudioMuseRecommendation>> getRecommendations({
    String? seedSongId,
    List<String>? recentSongIds,
    int count = 20,
  }) async {
    try {
      return await _client.getRecommendations(
        seedSongId: seedSongId,
        recentSongIds: recentSongIds,
        count: count,
      );
    } on DioException catch (e) {
      AppLogger.debug('AudioMuse getRecommendations failed: ${e.message}');
      return const [];
    } on Object catch (e) {
      AppLogger.debug('AudioMuse getRecommendations failed: $e');
      return const [];
    }
  }

  /// Generates an AI mix from a seed, or `null` on error.
  Future<AudioMuseMix?> generateMix({
    required String seedType,
    required String seedId,
    int count = 50,
  }) async {
    try {
      return await _client.generateMix(
        seedType: seedType,
        seedId: seedId,
        count: count,
      );
    } on DioException catch (e) {
      AppLogger.debug('AudioMuse generateMix failed: ${e.message}');
      return null;
    } on Object catch (e) {
      AppLogger.debug('AudioMuse generateMix failed: $e');
      return null;
    }
  }

  /// Returns home screen album recommendations, or an empty list on error.
  Future<List<AudioMuseRecommendation>> getHomeRecommendations({
    int count = 10,
  }) async {
    try {
      return await _client.getHomeRecommendations(count: count);
    } on DioException catch (e) {
      AppLogger.debug('AudioMuse getHomeRecommendations failed: ${e.message}');
      return const [];
    } on Object catch (e) {
      AppLogger.debug('AudioMuse getHomeRecommendations failed: $e');
      return const [];
    }
  }
}
