import 'package:dio/dio.dart';
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
  new({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? Dio(baseOptions),
      _now = now ?? DateTime.now;

  static final baseOptions = BaseOptions(
    baseUrl: 'https://lrclib.net',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': AppConstants.userAgent},
  );

  final Dio _dio;
  final DateTime Function() _now;
  DateTime? _blockedUntil;

  bool get isRateLimited =>
      _blockedUntil != null && _now().isBefore(_blockedUntil!);

  void _checkRateLimit() {
    if (isRateLimited) throw const LrclibRateLimitedException();
  }

  void _recordRateLimit(Response<dynamic>? response) {
    if (response?.statusCode != 429 && response?.statusCode != 503) return;
    final deadline =
        parseRetryAfter(response?.headers.value('retry-after'), now: _now) ??
        _now().add(const Duration(seconds: 60));
    if (_blockedUntil == null || deadline.isAfter(_blockedUntil!)) {
      _blockedUntil = deadline;
    }
    throw const LrclibRateLimitedException();
  }

  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
  }) async {
    _checkRateLimit();
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        '/api/get',
        queryParameters: {
          'artist_name': artist,
          'track_name': title,
          if (album != null && album.trim().isNotEmpty) 'album_name': album,
          if (duration != null && duration > 0) 'duration': duration,
        },
      );
    } on DioException catch (error) {
      _recordRateLimit(error.response);
      if (error.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
    _recordRateLimit(response);
    final data = response.data;
    if (data == null || data.isEmpty) {
      return null;
    }
    return LrclibLyrics.fromJson(data);
  }

  Future<List<LrclibLyrics>> searchLyrics({
    required String artist,
    required String title,
  }) async {
    _checkRateLimit();
    final Response<List<dynamic>> response;
    try {
      response = await _dio.get<List<dynamic>>(
        '/api/search',
        queryParameters: {'artist_name': artist, 'track_name': title},
      );
    } on DioException catch (error) {
      _recordRateLimit(error.response);
      if (error.response?.statusCode == 404) return const <LrclibLyrics>[];
      rethrow;
    }
    _recordRateLimit(response);
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
