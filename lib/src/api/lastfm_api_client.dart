import 'package:dio/dio.dart';
import 'package:navis/src/utils/app_logger.dart';

enum LastFmFetchOutcome {
  success,
  noResults,
  apiError,
  networkError,
  parseError,
  notConfigured,
}

class LastFmTrackFetchResult {
  const LastFmTrackFetchResult({
    required this.outcome,
    required this.tracks,
    this.statusCode,
    this.apiErrorCode,
    this.message,
  });

  final LastFmFetchOutcome outcome;
  final List<LastFmTrackRecommendation> tracks;
  final int? statusCode;
  final int? apiErrorCode;
  final String? message;
}

class LastFmTrackRecommendation {
  const LastFmTrackRecommendation({
    required this.artist,
    required this.title,
    this.match,
  });

  final String artist;
  final String title;
  final double? match;

  bool get isUsable => artist.trim().isNotEmpty && title.trim().isNotEmpty;
}

class LastFmApiClient {
  LastFmApiClient({
    required String apiKey,
    Dio? dio,
  }) : _apiKey = apiKey.trim(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://ws.audioscrobbler.com/2.0',
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 15),
               sendTimeout: const Duration(seconds: 10),
               headers: const {'User-Agent': 'Navis/0.8'},
             ),
           );

  final Dio _dio;
  final String _apiKey;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<List<LastFmTrackRecommendation>> getSimilarTracks({
    required String artist,
    required String track,
    int limit = 50,
  }) async {
    final result = await getSimilarTracksResult(
      artist: artist,
      track: track,
      limit: limit,
    );
    return result.tracks;
  }

  Future<LastFmTrackFetchResult> getSimilarTracksResult({
    required String artist,
    required String track,
    int limit = 50,
  }) async {
    final normalizedArtist = artist.trim();
    final normalizedTrack = track.trim();
    if (_apiKey.isEmpty ||
        normalizedArtist.isEmpty ||
        normalizedTrack.isEmpty ||
        limit <= 0) {
      AppLogger.debug(
        'LastFm diagnostics: request skipped '
        'configured=${_apiKey.isNotEmpty} '
        'artistEmpty=${normalizedArtist.isEmpty} '
        'trackEmpty=${normalizedTrack.isEmpty} '
        'limit=$limit',
      );
      return const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.notConfigured,
        tracks: <LastFmTrackRecommendation>[],
      );
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '',
        queryParameters: <String, dynamic>{
          'method': 'track.getsimilar',
          'artist': normalizedArtist,
          'track': normalizedTrack,
          'api_key': _apiKey,
          'format': 'json',
          'autocorrect': 1,
          'limit': limit,
        },
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        AppLogger.debug(
          'LastFm diagnostics: empty payload artist="$normalizedArtist" '
          'track="$normalizedTrack"',
        );
        return LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.parseError,
          tracks: const <LastFmTrackRecommendation>[],
          statusCode: response.statusCode,
          message: 'empty payload',
        );
      }

      // Last.fm error payloads are soft-fail for recommendation flows.
      if (data['error'] != null) {
        final apiErrorCode = switch (data['error']) {
          final int code => code,
          final num code => code.toInt(),
          _ => null,
        };
        final message = data['message']?.toString();
        AppLogger.debug(
          'LastFm diagnostics: api error code=$apiErrorCode '
          'message=$message artist="$normalizedArtist" '
          'track="$normalizedTrack"',
        );
        return LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.apiError,
          tracks: const <LastFmTrackRecommendation>[],
          statusCode: response.statusCode,
          apiErrorCode: apiErrorCode,
          message: message,
        );
      }

      final similarRoot = _asMap(data['similartracks']);
      final tracks = _asMapList(similarRoot['track']);
      if (tracks.isEmpty) {
        AppLogger.debug(
          'LastFm diagnostics: no similar tracks artist="$normalizedArtist" '
          'track="$normalizedTrack"',
        );
        return LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.noResults,
          tracks: const <LastFmTrackRecommendation>[],
          statusCode: response.statusCode,
        );
      }

      final recommendations = tracks
          .map(_parseRecommendation)
          .whereType<LastFmTrackRecommendation>()
          .where((rec) => rec.isUsable)
          .toList(growable: false);
      AppLogger.debug(
        'LastFm diagnostics: recommendations=${recommendations.length} '
        'artist="$normalizedArtist" track="$normalizedTrack"',
      );
      return LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.success,
        tracks: recommendations,
        statusCode: response.statusCode,
      );
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      AppLogger.debug(
        'LastFm diagnostics: network error type=${error.type.name} '
        'status=$statusCode artist="$normalizedArtist" '
        'track="$normalizedTrack"',
      );
      return LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.networkError,
        tracks: const <LastFmTrackRecommendation>[],
        statusCode: statusCode,
        message: error.message,
      );
    } on FormatException {
      AppLogger.debug(
        'LastFm diagnostics: parse error artist="$normalizedArtist" '
        'track="$normalizedTrack"',
      );
      return const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.parseError,
        tracks: <LastFmTrackRecommendation>[],
      );
    }
  }

  LastFmTrackRecommendation? _parseRecommendation(Map<String, dynamic> json) {
    final title = (json['name'] as String?)?.trim() ?? '';
    final artistMap = _asMap(json['artist']);
    final artist = (artistMap['name'] as String?)?.trim() ?? '';
    if (title.isEmpty || artist.isEmpty) {
      return null;
    }

    final rawMatch = json['match'];
    double? match;
    if (rawMatch is num) {
      match = rawMatch.toDouble();
    } else if (rawMatch is String) {
      match = double.tryParse(rawMatch);
    }

    return LastFmTrackRecommendation(
      artist: artist,
      title: title,
      match: match,
    );
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, val) => MapEntry(
          key.toString(),
          val,
        ),
      );
    }
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (entry) => entry.map(
              (key, val) => MapEntry(
                key.toString(),
                val,
              ),
            ),
          )
          .toList(growable: false);
    }
    if (value is Map) {
      return <Map<String, dynamic>>[
        value.map(
          (key, val) => MapEntry(
            key.toString(),
            val,
          ),
        ),
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
