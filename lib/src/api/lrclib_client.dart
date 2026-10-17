import 'package:dio/dio.dart';
import 'package:navis/src/api/request_limiter.dart';
import 'package:navis/src/api/retry_after.dart';
import 'package:navis/src/utils/constants.dart';

class LrclibLyrics {
  const new({
    required this.artistName,
    required this.trackName,
    this.albumName,
    this.duration,
    this.syncedLyrics,
    this.plainLyrics,
  });

  factory fromJson(Map<String, dynamic> json) {
    return LrclibLyrics(
      artistName: (json['artistName'] as String? ?? '').trim(),
      trackName: (json['trackName'] as String? ?? '').trim(),
      albumName: (json['albumName'] as String?)?.trim(),
      duration: (json['duration'] as num?)?.toInt(),
      syncedLyrics: (json['syncedLyrics'] as String?)?.trim(),
      plainLyrics: (json['plainLyrics'] as String?)?.trim(),
    );
  }

  final String artistName;
  final String trackName;
  final String? albumName;
  final int? duration;
  final String? syncedLyrics;
  final String? plainLyrics;

  bool get hasSynced => syncedLyrics != null && syncedLyrics!.trim().isNotEmpty;
  bool get hasPlain => plainLyrics != null && plainLyrics!.trim().isNotEmpty;
}

/// LRCLIB is temporarily unavailable until its shared cooldown expires.
class LrclibRateLimitedException implements Exception {
  const new();
}

class LrclibClient {
  /// Production code passes a [dio] from `externalDioFactoryProvider`, built
  /// with [baseOptions], so the integration guard applies.
  new({Dio? dio, DateTime Function()? now, RequestLimiter? limiter})
    : _dio = dio ?? Dio(baseOptions),
      _now = now ?? DateTime.now,
      // Reserve one of two starts per second for interactive lyrics lookups.
      _limiter =
          limiter ??
          RequestLimiter(
            maxPerWindow: 2,
            maxBackgroundPerWindow: 1,
            maxInFlight: 2,
          );

  static final baseOptions = BaseOptions(
    baseUrl: 'https://lrclib.net',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': AppConstants.userAgent},
  );

  final Dio _dio;
  final DateTime Function() _now;
  final RequestLimiter _limiter;
  DateTime? _blockedUntil;
  int _consecutiveCooldowns = 0;
  int _cooldownGeneration = 0;
  static const _maxCooldown = Duration(minutes: 10);

  /// Deadline of the last cooldown, including one that has just expired.
  DateTime? get retryAt => _blockedUntil;

  /// Remaining cooldown on the same clock used to interpret Retry-After.
  Duration get cooldownRemaining {
    final remaining = _blockedUntil?.difference(_now()) ?? Duration.zero;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isRateLimited =>
      _blockedUntil != null && _now().isBefore(_blockedUntil!);

  void _checkRateLimit() {
    if (isRateLimited) throw const LrclibRateLimitedException();
  }

  void _recordRateLimit(Response<dynamic>? response) {
    if (response?.statusCode != 429 && response?.statusCode != 503) return;
    final now = _now();
    if (!isRateLimited) {
      _consecutiveCooldowns++;
      _cooldownGeneration++;
    }
    final fallback = Duration(
      seconds: 60 * (1 << (_consecutiveCooldowns - 1).clamp(0, 4)),
    );
    final parsed = parseRetryAfter(
      response?.headers.value('retry-after'),
      now: _now,
    );
    final delay = parsed?.difference(now) ?? fallback;
    final bounded = delay > _maxCooldown ? _maxCooldown : delay;
    // An immediate retry must still leave the interrupted song eligible.
    final deadline = now.add(
      bounded <= Duration.zero ? const Duration(seconds: 1) : bounded,
    );
    if (_blockedUntil == null || deadline.isAfter(_blockedUntil!)) {
      _blockedUntil = deadline;
    }
    throw const LrclibRateLimitedException();
  }

  Future<Response<T>> _get<T>(
    String path,
    Map<String, dynamic> parameters, {
    required bool background,
    CancelToken? cancelToken,
  }) {
    _checkRateLimit();
    return _limiter.run(
      () async {
        // A queued request must observe a cooldown reported while it waited.
        _checkRateLimit();
        final generation = _cooldownGeneration;
        try {
          final response = await _dio.get<T>(
            path,
            queryParameters: parameters,
            cancelToken: cancelToken,
          );
          _recordRateLimit(response);
          if (generation == _cooldownGeneration) _consecutiveCooldowns = 0;
          return response;
        } on DioException catch (error) {
          _recordRateLimit(error.response);
          if (error.response?.statusCode == 404 &&
              generation == _cooldownGeneration) {
            _consecutiveCooldowns = 0;
          }
          rethrow;
        }
      },
      background: background,
      cancelToken: cancelToken,
    );
  }

  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
    bool background = false,
    CancelToken? cancelToken,
  }) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _get<Map<String, dynamic>>(
        '/api/get',
        {
          'artist_name': artist,
          'track_name': title,
          if (album != null && album.trim().isNotEmpty) 'album_name': album,
          if (duration != null && duration > 0) 'duration': duration,
        },
        background: background,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
    final data = response.data;
    if (data == null || data.isEmpty) {
      return null;
    }
    return LrclibLyrics.fromJson(data);
  }

  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
    bool background = false,
    CancelToken? cancelToken,
  }) async {
    final Response<List<dynamic>> response;
    try {
      response = await _get<List<dynamic>>(
        '/api/search',
        {'artist_name': artist, 'track_name': title},
        background: background,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return const <LrclibLyrics>[];
      rethrow;
    }
    final data = response.data;
    if (data == null) {
      return const <LrclibLyrics>[];
    }

    return data
        .whereType<Map<String, dynamic>>()
        .map(LrclibLyrics.fromJson)
        .toList(growable: false);
  }
}
