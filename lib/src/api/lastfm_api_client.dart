import 'package:dio/dio.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
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
  const new({
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
  const new({required this.artist, required this.title, this.match});

  final String artist;
  final String title;
  final double? match;

  bool get isUsable => artist.trim().isNotEmpty && title.trim().isNotEmpty;
}

/// A single entry in an artist's top-tracks chart from Last.fm.
class LastFmArtistTopTrack {
  const new({
    required this.rank,
    required this.title,
    required this.artist,
    this.listeners,
  });

  /// 1-based chart position as returned by Last.fm.
  final int rank;
  final String title;
  final String artist;

  /// Total unique listener count (may be absent).
  final int? listeners;

  bool get isUsable =>
      rank > 0 && title.trim().isNotEmpty && artist.trim().isNotEmpty;
}

class LastFmApiKeyValidationResult {
  const new({
    required this.valid,
    this.message,
    this.apiErrorCode,
    this.statusCode,
  });

  final bool valid;
  final String? message;
  final int? apiErrorCode;
  final int? statusCode;
}

class LastFmApiClient {
  /// Production code passes a [dio] from `externalDioFactoryProvider`, built
  /// with [baseOptions], so the integration guard applies.
  new({required String apiKey, Dio? dio})
    : _apiKey = apiKey.trim(),
      _dio = dio ?? Dio(baseOptions);

  static final baseOptions = BaseOptions(
    baseUrl: 'https://ws.audioscrobbler.com/2.0',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
    headers: const {'User-Agent': 'Navis/0.8'},
  );

  final Dio _dio;
  final String _apiKey;

  bool get isConfigured => _apiKey.isNotEmpty;

  Future<LastFmApiKeyValidationResult> validateApiKey() async {
    if (_apiKey.isEmpty) {
      return const LastFmApiKeyValidationResult(
        valid: false,
        message: 'Enter a Last.fm API key.',
      );
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '',
        queryParameters: <String, dynamic>{
          'method': 'chart.getTopArtists',
          'api_key': _apiKey,
          'format': 'json',
          'limit': 1,
        },
        // Entering a key is the user asking for this check.
        options: userInitiatedOptions(),
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        return LastFmApiKeyValidationResult(
          valid: false,
          message: 'Last.fm returned an empty response.',
          statusCode: response.statusCode,
        );
      }
      if (data['error'] != null) {
        final code = switch (data['error']) {
          final int value => value,
          final num value => value.toInt(),
          final String value => int.tryParse(value),
          _ => null,
        };
        return LastFmApiKeyValidationResult(
          valid: false,
          message: data['message']?.toString() ?? 'Last.fm rejected this key.',
          apiErrorCode: code,
          statusCode: response.statusCode,
        );
      }
      return LastFmApiKeyValidationResult(
        valid: true,
        statusCode: response.statusCode,
      );
    } on DioException catch (error) {
      return LastFmApiKeyValidationResult(
        valid: false,
        message: error.response?.statusCode == 429
            ? 'Last.fm is rate limiting validation. Try again later.'
            : 'Last.fm is unavailable. Check your connection and try again.',
        statusCode: error.response?.statusCode,
      );
    } on FormatException {
      return const LastFmApiKeyValidationResult(
        valid: false,
        message: 'Last.fm returned an unreadable response.',
      );
    }
  }

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
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return const <String, dynamic>{};
  }

  /// Returns `true` when [requested] and [resolved] refer to the same artist.
  ///
  /// Comparison is case-insensitive with punctuation normalised to spaces so
  /// that minor typographical differences (e.g. "AC/DC" vs "AC DC") do not
  /// produce false negatives. Accepts when either string is a substring of
  /// the other to handle "The Beatles" vs "Beatles" style differences.
  static bool _artistNamesMatch(String requested, String resolved) {
    final a = _normalizeArtistName(requested);
    final b = _normalizeArtistName(resolved);
    if (a.isEmpty || b.isEmpty) return true; // can't validate — assume OK
    return a == b || a.contains(b) || b.contains(a);
  }

  /// Lowercases [name] and replaces non-alphanumeric characters with spaces,
  /// collapsing consecutive spaces, for artist-name comparison purposes.
  static String _normalizeArtistName(String name) {
    return name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), ' ').trim();
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (entry) => entry.map((key, val) => MapEntry(key.toString(), val)),
          )
          .toList(growable: false);
    }
    if (value is Map) {
      return <Map<String, dynamic>>[
        value.map((key, val) => MapEntry(key.toString(), val)),
      ];
    }
    return const <Map<String, dynamic>>[];
  }

  /// Fetches the top tracks for [artist] from Last.fm.
  ///
  /// Returns an empty list when the API key is absent, the artist is empty,
  /// or any network / parse error occurs.  Results are sorted ascending by
  /// rank (position 1 first).
  Future<List<LastFmArtistTopTrack>> getArtistTopTracks({
    required String artist,
    int limit = 10,
    CancelToken? cancelToken,
  }) async {
    final normalizedArtist = artist.trim();
    if (_apiKey.isEmpty || normalizedArtist.isEmpty || limit <= 0) {
      return const [];
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '',
        cancelToken: cancelToken,
        queryParameters: <String, dynamic>{
          'method': 'artist.getTopTracks',
          'artist': normalizedArtist,
          'api_key': _apiKey,
          'format': 'json',
          'autocorrect': 0,
          'limit': limit,
        },
      );
      final data = response.data;
      if (data == null || data['error'] != null) {
        AppLogger.debug(
          'LastFm getArtistTopTracks: api error or empty payload '
          'for artist="$normalizedArtist"',
        );
        return const [];
      }

      final topTracksRoot = _asMap(data['toptracks']);

      // Validate the artist Last.fm actually resolved to. If it differs
      // significantly from the requested artist, the API returned results
      // for the wrong person — discard them rather than show misleading data.
      final attrArtist =
          (_asMap(topTracksRoot['@attr'])['artist'] as String?)?.trim() ?? '';
      if (attrArtist.isNotEmpty &&
          !_artistNamesMatch(normalizedArtist, attrArtist)) {
        AppLogger.debug(
          'LastFm getArtistTopTracks: resolved artist mismatch — '
          'requested="$normalizedArtist" resolved="$attrArtist" — discarding',
        );
        return const [];
      }

      final tracks = _asMapList(topTracksRoot['track']);
      if (tracks.isEmpty) return const [];

      final result = <LastFmArtistTopTrack>[];
      for (final track in tracks) {
        final title = (track['name'] as String?)?.trim() ?? '';
        final artistMap = _asMap(track['artist']);
        final trackArtist =
            ((artistMap['name'] as String?)?.trim() ?? '').isNotEmpty
            ? (artistMap['name'] as String).trim()
            : normalizedArtist;
        final attrMap = _asMap(track['@attr']);
        final rankRaw = attrMap['rank'];
        final rank = switch (rankRaw) {
          final int r => r,
          final String s => int.tryParse(s) ?? 0,
          _ => 0,
        };
        final listenersRaw = track['listeners'];
        final listeners = switch (listenersRaw) {
          final int l => l,
          final String s => int.tryParse(s),
          _ => null,
        };
        if (title.isEmpty || rank <= 0) continue;

        // Skip tracks whose per-track artist doesn't match the requested
        // artist.  Last.fm can return collaboration or compilation tracks
        // attributed to a different artist within an otherwise valid response.
        if (!_artistNamesMatch(normalizedArtist, trackArtist)) {
          AppLogger.debug(
            'LastFm getArtistTopTracks: skipping track "$title" — '
            'track artist="$trackArtist" does not match '
            'requested="$normalizedArtist"',
          );
          continue;
        }

        result.add(
          LastFmArtistTopTrack(
            rank: rank,
            title: title,
            artist: trackArtist,
            listeners: listeners,
          ),
        );
      }

      // Re-number ranks sequentially so no gaps appear in the UI after
      // filtering out mismatched tracks.
      for (var i = 0; i < result.length; i++) {
        result[i] = LastFmArtistTopTrack(
          rank: i + 1,
          title: result[i].title,
          artist: result[i].artist,
          listeners: result[i].listeners,
        );
      }
      AppLogger.debug(
        'LastFm getArtistTopTracks: fetched ${result.length} tracks '
        'for artist="$normalizedArtist"',
      );
      return List.unmodifiable(result);
    } on DioException catch (e) {
      AppLogger.debug(
        'LastFm getArtistTopTracks: network error for '
        'artist="$normalizedArtist": ${e.message}',
      );
      return const [];
    } on FormatException catch (e) {
      AppLogger.debug(
        'LastFm getArtistTopTracks: parse error for '
        'artist="$normalizedArtist": $e',
      );
      return const [];
    }
  }
}
