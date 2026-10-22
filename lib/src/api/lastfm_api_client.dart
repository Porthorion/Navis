import 'dart:convert';
import 'dart:math' as math;

import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
import 'package:dio/dio.dart';
import 'package:navis/src/utils/constants.dart';
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

/// Where a similar-track result came from.
enum LastFmSimilarSource {
  /// `track.getSimilar` for the seed (or its title without qualifiers).
  track,

  /// The top tracks of the seed artist's similar artists: Last.fm has no
  /// similar tracks for most songs released since about 2015.
  artistSimilar,
}

class LastFmTrackFetchResult {
  const new({
    required this.outcome,
    required this.tracks,
    this.statusCode,
    this.apiErrorCode,
    this.message,
    this.source = LastFmSimilarSource.track,
  });

  final LastFmFetchOutcome outcome;
  final LastFmSimilarSource source;
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
  new({required String apiKey, Dio? dio, this._cache})
    : _apiKey = apiKey.trim(),
      _dio = dio ?? Dio(baseOptions);

  static final baseOptions = BaseOptions(
    baseUrl: 'https://ws.audioscrobbler.com/2.0',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': AppConstants.userAgent},
  );

  final Dio _dio;
  final String _apiKey;
  final IntegrationJsonCache? _cache;
  static const similarTracksNamespace = 'lastfm.similar-tracks';
  static const similarTracksTtl = Duration(hours: 24);

  /// An empty answer is kept briefly: Last.fm's index changes, and a later
  /// mix should ask again soon rather than stay empty for a day.
  static const emptySimilarTracksTtl = Duration(minutes: 10);

  /// Artist-level fallback: similar artists asked for, and how many of them
  /// get a top-tracks request of [_fallbackTracksPerArtist] tracks each.
  static const _similarArtistLimit = 10;
  static const _fallbackArtistCount = 5;
  static const _fallbackTracksPerArtist = 3;

  /// Each later track of one artist counts for this much of the one before.
  static const _fallbackRankDecay = 0.6;

  Future<void> _storeSimilarTracks(
    String key,
    LastFmTrackFetchResult result,
    int limit,
  ) async {
    // "Track not found" is as final an answer as an empty list.
    final empty = _hasNoSimilarTracks(result);
    if (result.outcome != LastFmFetchOutcome.success && !empty) return;
    await _cache?.write(similarTracksNamespace, key, <String, Object?>{
      'limit': limit,
      'source': result.source.name,
      'tracks': [
        for (final track in result.tracks)
          <String, Object?>{
            'artist': track.artist,
            'title': track.title,
            'match': track.match,
          },
      ],
    }, ttl: empty ? emptySimilarTracksTtl : similarTracksTtl);
  }

  Future<LastFmTrackFetchResult?> _readSimilarTracks(
    String key,
    int limit,
  ) async {
    final cached = (await _cache?.read(similarTracksNamespace, key))?.value;
    if (cached is! Map<String, dynamic> ||
        cached['limit'] is! int ||
        (cached['limit'] as int) < limit ||
        cached['tracks'] is! List) {
      return null;
    }
    final tracks = [
      for (final entry in _asMapList(cached['tracks']))
        LastFmTrackRecommendation(
          artist: entry['artist'] as String? ?? '',
          title: entry['title'] as String? ?? '',
          match: (entry['match'] as num?)?.toDouble(),
        ),
    ].where((rec) => rec.isUsable).take(limit).toList(growable: false);
    return LastFmTrackFetchResult(
      outcome: tracks.isEmpty
          ? LastFmFetchOutcome.noResults
          : LastFmFetchOutcome.success,
      tracks: tracks,
      statusCode: 200,
      source: cached['source'] == LastFmSimilarSource.artistSimilar.name
          ? LastFmSimilarSource.artistSimilar
          : LastFmSimilarSource.track,
    );
  }

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

  // ponytail: concurrent seeds each run their own fan-out (no single-flight),
  // and a fetch in the middle of the fallback cannot be cancelled; add a
  // shared in-flight map and a CancelToken parameter if either shows up.
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

    final key = jsonEncode([
      normalizedArtist.toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
      normalizedTrack.toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
    ]);
    final cached = await _readSimilarTracks(key, limit);
    if (cached != null) return cached;

    var result = await _fetchTrackSimilar(
      normalizedArtist,
      normalizedTrack,
      limit,
    );
    // Last.fm answers "no similar tracks" or "Track not found" for most songs
    // released since about 2015 and for titles with a qualifier; neither says
    // the artist is unknown. Try the plain title, then the artist's neighbours.
    if (_hasNoSimilarTracks(result)) {
      final plainTitle = stripTitleQualifiers(normalizedTrack);
      if (plainTitle.toLowerCase() != normalizedTrack.toLowerCase()) {
        final retry = await _fetchTrackSimilar(
          normalizedArtist,
          plainTitle,
          limit,
        );
        if (retry.outcome == LastFmFetchOutcome.success) result = retry;
      }
    }
    if (_hasNoSimilarTracks(result)) {
      final viaArtists = await _similarArtistTracks(normalizedArtist, limit);
      if (viaArtists.isNotEmpty) {
        AppLogger.debug(
          'LastFm diagnostics: artist-level fallback tracks='
          '${viaArtists.length} artist="$normalizedArtist"',
        );
        result = LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: viaArtists,
          statusCode: 200,
          source: LastFmSimilarSource.artistSimilar,
        );
      }
    }
    await _storeSimilarTracks(key, result, limit);
    return result;
  }

  static bool _hasNoSimilarTracks(LastFmTrackFetchResult result) =>
      result.outcome == LastFmFetchOutcome.noResults ||
      (result.outcome == LastFmFetchOutcome.apiError &&
          result.apiErrorCode == _trackNotFoundErrorCode);

  /// Last.fm's "Track not found".
  static const _trackNotFoundErrorCode = 6;

  /// One `track.getSimilar` request, with no cache or fallback.
  Future<LastFmTrackFetchResult> _fetchTrackSimilar(
    String normalizedArtist,
    String normalizedTrack,
    int limit,
  ) async {
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
        tracks: recommendations.take(limit).toList(growable: false),
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

  /// Top tracks of [artist]'s similar artists, one track per artist at a time
  /// (the best of each, then the second best of each) so no artist floods the
  /// mix. Costs one `artist.getSimilar` and up to [_fallbackArtistCount]
  /// `artist.getTopTracks` requests; empty when Last.fm knows no neighbours.
  Future<List<LastFmTrackRecommendation>> _similarArtistTracks(
    String artist,
    int limit,
  ) async {
    final neighbours = (await _similarArtists(artist))
        .take(_fallbackArtistCount)
        .toList(growable: false);
    final charts = await Future.wait([
      for (final neighbour in neighbours)
        getArtistTopTracks(
          artist: neighbour.name,
          limit: _fallbackTracksPerArtist,
        ),
    ]);
    final recommendations = <LastFmTrackRecommendation>[];
    for (var rank = 0; rank < _fallbackTracksPerArtist; rank++) {
      for (var i = 0; i < neighbours.length; i++) {
        if (rank >= charts[i].length) continue;
        final track = charts[i][rank];
        recommendations.add(
          LastFmTrackRecommendation(
            artist: track.artist,
            title: track.title,
            match: neighbours[i].match * math.pow(_fallbackRankDecay, rank),
          ),
        );
      }
    }
    return recommendations.take(limit).toList(growable: false);
  }

  Future<List<({String name, double match})>> _similarArtists(
    String artist,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '',
        queryParameters: <String, dynamic>{
          'method': 'artist.getsimilar',
          'artist': artist,
          'api_key': _apiKey,
          'format': 'json',
          'autocorrect': 1,
          'limit': _similarArtistLimit,
        },
      );
      final data = response.data;
      if (data == null || data['error'] != null) return const [];
      // Last.fm sometimes lists the artist itself among its neighbours.
      final seed = normalizeMetadata(artist);
      bool isSeed(String name) =>
          seed.isNotEmpty && normalizeMetadata(name) == seed;
      return [
        for (final entry in _asMapList(
          _asMap(data['similarartists'])['artist'],
        ))
          if (((entry['name'] as String?)?.trim() ?? '').isNotEmpty &&
              !isSeed(entry['name'] as String))
            (
              name: (entry['name'] as String).trim(),
              match: switch (entry['match']) {
                final num value => value.toDouble(),
                final String value => double.tryParse(value) ?? 0.5,
                _ => 0.5,
              },
            ),
      ]..sort((a, b) => b.match.compareTo(a.match));
    } on DioException {
      return const [];
    } on FormatException {
      return const [];
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
    final a = normalizeMetadata(requested);
    final b = normalizeMetadata(resolved);
    if (a.isEmpty || b.isEmpty) {
      return requested.trim().toLowerCase() == resolved.trim().toLowerCase();
    }
    return a == b || a.contains(b) || b.contains(a);
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
