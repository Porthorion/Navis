import 'package:dio/dio.dart';

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

class LrclibClient {
  /// Production code passes a [dio] from `externalDioFactoryProvider`, built
  /// with [baseOptions], so the integration guard applies.
  new({Dio? dio}) : _dio = dio ?? Dio(baseOptions);

  static final baseOptions = BaseOptions(
    baseUrl: 'https://lrclib.net',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: const {'User-Agent': 'Navis/0.5'},
  );

  final Dio _dio;

  Future<LrclibLyrics?> getLyrics({
    required String artist,
    required String title,
    String? album,
    int? duration,
  }) async {
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
  }) async {
    final response = await _dio.get<List<dynamic>>(
      '/api/search',
      queryParameters: {'artist_name': artist, 'track_name': title},
    );
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
