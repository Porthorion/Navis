import 'dart:async';

import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/utils/app_logger.dart';

enum RadioMetadataSource { azuracast, icy, none }

/// Manages live metadata for radio streams.
///
/// Supports two metadata sources:
/// 1. **Azuracast API polling** — Polls `/api/nowplaying/{station_short_name}`
///    at a regular interval to get current track title, artist, and album art.
/// 2. **ICY metadata** — Falls back to `IcyMetadata` provided by `just_audio`
///    for generic Icecast/Shoutcast streams.
class RadioMetadataService {
  /// [isAllowed] is the integration policy for radio now-playing lookups. It
  /// is read before every poll, so switching the integration off stops
  /// Azuracast polling mid-station; ICY metadata comes from the audio stream
  /// itself and is not affected. Production code passes a guarded [dio] from
  /// `externalDioFactoryProvider`.
  new({
    required this._handler,
    required this._player,
    Dio? dio,
    bool Function()? isAllowed,
  }) : _dio = dio ?? Dio(),
       _isAllowed = isAllowed ?? (() => true);

  final NavisPlaybackHandler _handler;
  final AudioPlayer _player;
  final Dio _dio;
  final bool Function() _isAllowed;

  Timer? _pollingTimer;
  StreamSubscription<IcyMetadata?>? _icySubscription;
  String? _activeStationId;
  String? _azuracastBaseUrl;
  String? _stationShortName;
  bool _candidateRejected = false;
  int _generation = 0;

  /// Generation whose Azuracast poll is in flight, so polls never stack.
  int? _pollGeneration;
  int _initialFailureCount = 0;
  bool _hasAzuracastSuccess = false;
  IcyMetadata? _latestIcyMetadata;
  RadioMetadataSource _metadataSource = RadioMetadataSource.none;

  RadioMetadataSource get metadataSource => _metadataSource;

  // ── Dead-stream detection state ─────────────────────────────────────────
  String? _lastMetadataTitle;
  int _unchangedCycleCount = 0;
  bool _isReducedPolling = false;

  /// The polling interval for Azuracast API requests.
  static const Duration pollingInterval = Duration(seconds: 5);

  /// Reduced polling interval after dead-stream is detected.
  static const Duration reducedPollingInterval = Duration(seconds: 30);

  /// Number of unchanged polling cycles before switching to reduced polling.
  static const int deadStreamThreshold = 5;

  /// Start listening for metadata for the given radio station.
  ///
  /// If [azuracastApiUrl] is provided (e.g. `https://radio.example.com`),
  /// the service will poll `/api/nowplaying/{stationShortName}` for metadata.
  /// Otherwise, it falls back to ICY metadata from the stream.
  /// [initialMetadataSource] preserves the displayed metadata's source when
  /// rebinding the same station to a replacement player.
  void startListening({
    required String stationId,
    RadioMetadataSource initialMetadataSource = RadioMetadataSource.none,
    String? azuracastApiUrl,
    String? stationShortName,
  }) {
    stop();
    _activeStationId = stationId;
    _metadataSource = initialMetadataSource;

    // Try Azuracast polling first.
    if (azuracastApiUrl != null &&
        azuracastApiUrl.isNotEmpty &&
        stationShortName != null &&
        stationShortName.isNotEmpty) {
      _azuracastBaseUrl = azuracastApiUrl.endsWith('/')
          ? azuracastApiUrl.substring(0, azuracastApiUrl.length - 1)
          : azuracastApiUrl;
      _stationShortName = stationShortName;
      refreshPolicy();
    }

    // Always listen for ICY metadata as a fallback / supplement.
    _startIcyListening();
  }

  /// Stop all metadata listeners.
  void stop() {
    _generation++;
    _metadataSource = RadioMetadataSource.none;
    _initialFailureCount = 0;
    _candidateRejected = false;
    _stationShortName = null;
    _hasAzuracastSuccess = false;
    _latestIcyMetadata = null;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    unawaited(_icySubscription?.cancel());
    _icySubscription = null;
    _activeStationId = null;
    _azuracastBaseUrl = null;
    _lastMetadataTitle = null;
    _unchangedCycleCount = 0;
    _isReducedPolling = false;
  }

  /// Apply the current integration policy without forgetting this station.
  void refreshPolicy() {
    if (_activeStationId == null) return;
    if (!_isAllowed()) {
      final needsFallback =
          _pollingTimer != null ||
          _metadataSource == RadioMetadataSource.azuracast;
      _generation++;
      _pollingTimer?.cancel();
      _pollingTimer = null;
      if (needsFallback) {
        _applyIcyMetadata(_latestIcyMetadata ?? _player.icyMetadata);
      }
      return;
    }
    final shortName = _stationShortName;
    if (_pollingTimer == null &&
        !_candidateRejected &&
        _azuracastBaseUrl != null &&
        shortName != null) {
      _initialFailureCount = 0;
      _isReducedPolling = false;
      _unchangedCycleCount = 0;
      _startAzuracastPolling(shortName);
    }
  }

  void _startAzuracastPolling(String stationShortName) {
    // Initial fetch immediately.
    unawaited(_fetchAzuracastMetadata(stationShortName));

    _pollingTimer = Timer.periodic(pollingInterval, (_) {
      unawaited(_fetchAzuracastMetadata(stationShortName));
    });
  }

  Future<void> _fetchAzuracastMetadata(String stationShortName) async {
    final generation = _generation;
    final baseUrl = _azuracastBaseUrl;
    if (baseUrl == null || _activeStationId == null) {
      return;
    }
    if (!_isAllowed()) {
      refreshPolicy();
      return;
    }
    // One poll per station at a time: a slow response must not stack later
    // ticks. A generation bump (station switch, stop, policy) polls at once.
    if (_pollGeneration == generation) return;
    _pollGeneration = generation;

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/api/nowplaying/$stationShortName',
        options: Options(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 5),
        ),
      );

      if (generation != _generation || !_isAllowed()) return;
      if (response.statusCode != 200 || response.data == null) {
        AppLogger.debug(
          'Azuracast metadata fetch returned ${response.statusCode} '
          'for $stationShortName',
        );
        _recordInitialFailure();
        return;
      }

      final json = response.data!;
      final nowPlaying = json['now_playing'] as Map<String, dynamic>?;
      if (nowPlaying == null) {
        _recordInitialFailure();
        return;
      }

      final song = nowPlaying['song'] as Map<String, dynamic>?;
      if (song == null) {
        _recordInitialFailure();
        return;
      }

      final title = song['title'] as String?;
      final artist = song['artist'] as String?;
      final art = song['art'] as String?;

      _metadataSource = RadioMetadataSource.azuracast;
      _hasAzuracastSuccess = true;
      _initialFailureCount = 0;

      // Dead-stream detection: track whether the title has changed.
      _updateDeadStreamCounter(title, stationShortName);

      if (_activeStationId != null) {
        _handler.updateRadioMetadata(title: title, artist: artist, artUrl: art);
      }
    } on DioException catch (error) {
      AppLogger.debug('Azuracast metadata fetch failed: ${error.message}');
      if (generation == _generation && _isAllowed()) {
        _recordInitialFailure();
      }
    } on Object catch (error, stackTrace) {
      AppLogger.debug('Azuracast metadata fetch failed: $error\n$stackTrace');
      if (generation == _generation && _isAllowed()) {
        _recordInitialFailure();
      }
    } finally {
      if (_pollGeneration == generation) _pollGeneration = null;
    }
  }

  void _recordInitialFailure() {
    if (_hasAzuracastSuccess || ++_initialFailureCount < 2) return;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _candidateRejected = true;
    _generation++;
    // The stream may not emit again until its title changes.
    _applyIcyMetadata(_latestIcyMetadata ?? _player.icyMetadata);
  }

  /// Track whether the metadata title has changed across polling cycles.
  /// After [deadStreamThreshold] unchanged cycles, switch to reduced polling.
  void _updateDeadStreamCounter(String? title, String stationShortName) {
    if (title == _lastMetadataTitle) {
      _unchangedCycleCount++;
      if (_unchangedCycleCount >= deadStreamThreshold && !_isReducedPolling) {
        _isReducedPolling = true;
        AppLogger.debug(
          'RadioMetadataService: Dead stream detected for '
          '$stationShortName — reducing polling to '
          '${reducedPollingInterval.inSeconds}s.',
        );
        // Restart the timer at a lower frequency.
        _pollingTimer?.cancel();
        _pollingTimer = Timer.periodic(reducedPollingInterval, (_) {
          unawaited(_fetchAzuracastMetadata(stationShortName));
        });
      }
    } else {
      // Metadata actually changed — reset counters.
      _lastMetadataTitle = title;
      _unchangedCycleCount = 0;
      if (_isReducedPolling) {
        _isReducedPolling = false;
        AppLogger.debug(
          'RadioMetadataService: Stream for $stationShortName '
          'is live again — restoring normal polling.',
        );
        _pollingTimer?.cancel();
        _pollingTimer = Timer.periodic(pollingInterval, (_) {
          unawaited(_fetchAzuracastMetadata(stationShortName));
        });
      }
    }
  }

  void _startIcyListening() {
    _icySubscription = _player.icyMetadataStream.listen((metadata) {
      if (_activeStationId == null) return;
      _latestIcyMetadata = metadata;
      // Only use ICY if we don't have Azuracast polling active.
      if (_pollingTimer != null) return;

      _applyIcyMetadata(metadata);
    });

    // Also check if ICY metadata is already available (e.g. reconnecting to an
    // ongoing stream) — the stream above only fires on *changes*.
    if (_pollingTimer == null) {
      final existing = _player.icyMetadata;
      if (existing != null) {
        _applyIcyMetadata(existing);
      }
    }
  }

  void _applyIcyMetadata(IcyMetadata? metadata) {
    final title = metadata?.info?.title?.trim();
    if (title == null || title.isEmpty) {
      _metadataSource = RadioMetadataSource.none;
      _handler.updateRadioMetadata(replaceMetadata: true);
      return;
    }

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

    _metadataSource = RadioMetadataSource.icy;
    _handler.updateRadioMetadata(
      title: parsedTitle,
      artist: parsedArtist,
      replaceMetadata: true,
    );
  }

  /// Dispose resources. Call when the handler is being disposed.
  void dispose() {
    stop();
    _dio.close();
  }
}
