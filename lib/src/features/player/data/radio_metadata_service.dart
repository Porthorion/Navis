import 'dart:async';

import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Manages live metadata for radio streams.
///
/// Supports two metadata sources:
/// 1. **Azuracast API polling** — Polls `/api/nowplaying/{station_short_name}`
///    at a regular interval to get current track title, artist, and album art.
/// 2. **ICY metadata** — Falls back to `IcyMetadata` provided by `just_audio`
///    for generic Icecast/Shoutcast streams.
class RadioMetadataService {
  RadioMetadataService({
    required NavisPlaybackHandler handler,
    required AudioPlayer player,
    Dio? dio,
  }) : _handler = handler,
       _player = player,
       _dio = dio ?? Dio();

  final NavisPlaybackHandler _handler;
  final AudioPlayer _player;
  final Dio _dio;

  Timer? _pollingTimer;
  StreamSubscription<IcyMetadata?>? _icySubscription;
  String? _activeStationId;
  String? _azuracastBaseUrl;

  /// The polling interval for Azuracast API requests.
  static const Duration pollingInterval = Duration(seconds: 15);

  /// Start listening for metadata for the given radio station.
  ///
  /// If [azuracastApiUrl] is provided (e.g. `https://radio.example.com`),
  /// the service will poll `/api/nowplaying/{stationShortName}` for metadata.
  /// Otherwise, it falls back to ICY metadata from the stream.
  void startListening({
    required String stationId,
    String? azuracastApiUrl,
    String? stationShortName,
  }) {
    stop();
    _activeStationId = stationId;

    // Try Azuracast polling first.
    if (azuracastApiUrl != null &&
        azuracastApiUrl.isNotEmpty &&
        stationShortName != null &&
        stationShortName.isNotEmpty) {
      _azuracastBaseUrl = azuracastApiUrl.endsWith('/')
          ? azuracastApiUrl.substring(0, azuracastApiUrl.length - 1)
          : azuracastApiUrl;
      _startAzuracastPolling(stationShortName);
    }

    // Always listen for ICY metadata as a fallback / supplement.
    _startIcyListening();
  }

  /// Stop all metadata listeners.
  void stop() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _icySubscription?.cancel();
    _icySubscription = null;
    _activeStationId = null;
    _azuracastBaseUrl = null;
  }

  void _startAzuracastPolling(String stationShortName) {
    // Initial fetch immediately.
    unawaited(_fetchAzuracastMetadata(stationShortName));

    _pollingTimer = Timer.periodic(pollingInterval, (_) {
      unawaited(_fetchAzuracastMetadata(stationShortName));
    });
  }

  Future<void> _fetchAzuracastMetadata(String stationShortName) async {
    final baseUrl = _azuracastBaseUrl;
    if (baseUrl == null || _activeStationId == null) {
      return;
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/api/nowplaying/$stationShortName',
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode != 200 || response.data == null) {
        AppLogger.debug(
          'Azuracast metadata fetch returned ${response.statusCode} '
          'for $stationShortName',
        );
        return;
      }

      final json = response.data!;
      final nowPlaying = json['now_playing'] as Map<String, dynamic>?;
      if (nowPlaying == null) return;

      final song = nowPlaying['song'] as Map<String, dynamic>?;
      if (song == null) return;

      final title = song['title'] as String?;
      final artist = song['artist'] as String?;
      final art = song['art'] as String?;

      if (_activeStationId != null) {
        _handler.updateRadioMetadata(
          title: title,
          artist: artist,
          artUrl: art,
        );
      }
    } on DioException catch (error) {
      AppLogger.debug(
        'Azuracast metadata fetch failed: ${error.message}',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'Azuracast metadata fetch failed: $error\n$stackTrace',
      );
    }
  }

  void _startIcyListening() {
    _icySubscription = _player.icyMetadataStream.listen((metadata) {
      if (_activeStationId == null) return;
      // Only use ICY if we don't have Azuracast polling active.
      if (_pollingTimer != null) return;

      final info = metadata?.info;
      if (info == null) return;

      final title = info.title;
      if (title == null || title.isEmpty) return;

      // ICY title is often formatted as "Artist - Title".
      String? parsedArtist;
      String? parsedTitle;
      final dashIndex = title.indexOf(' - ');
      if (dashIndex > 0) {
        parsedArtist = title.substring(0, dashIndex).trim();
        parsedTitle = title.substring(dashIndex + 3).trim();
      } else {
        parsedTitle = title;
      }

      _handler.updateRadioMetadata(
        title: parsedTitle,
        artist: parsedArtist,
      );
    });
  }

  /// Dispose resources. Call when the handler is being disposed.
  void dispose() {
    stop();
    _dio.close();
  }
}
