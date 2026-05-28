import 'dart:async';
import 'dart:math' as math;

import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/app_logger.dart';

enum ScrobbleProvider {
  subsonic('subsonic'),
  lastFm('lastfm'),
  listenBrainz('listenbrainz')
  ;

  const ScrobbleProvider(this.id);

  final String id;

  static ScrobbleProvider? fromId(String id) {
    for (final provider in values) {
      if (provider.id == id) {
        return provider;
      }
    }
    return null;
  }
}

class ScrobbleTrackPayload {
  const ScrobbleTrackPayload({
    required this.songId,
    this.title,
    this.artist,
    this.album,
    this.duration,
  });

  final String songId;
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;
}

class LastFmScrobbleCredentials {
  const LastFmScrobbleCredentials({
    required this.apiKey,
    required this.sharedSecret,
    required this.sessionKey,
  });

  final String apiKey;
  final String sharedSecret;
  final String sessionKey;
}

class ListenBrainzScrobbleCredentials {
  const ListenBrainzScrobbleCredentials({required this.userToken});

  final String userToken;
}

abstract class ScrobbleService {
  void start();

  Future<void> enqueueNowPlaying({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  });

  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  });

  Future<void> flushDue();

  Future<void> dispose();
}

class DriftScrobbleService implements ScrobbleService {
  DriftScrobbleService({
    required ScrobbleDao dao,
    required SubsonicApiClient? Function() readApiClient,
    required bool Function() readScrobbleEnabled,
    Future<LastFmScrobbleCredentials?> Function()? readLastFmCredentials,
    Future<ListenBrainzScrobbleCredentials?> Function()?
    readListenBrainzCredentials,
    void Function()? onLastFmInvalidSession,
    void Function()? onListenBrainzInvalidToken,
    required bool Function() readReachable,
    DateTime Function()? now,
    this.nowPlayingRetention = const Duration(hours: 2),
    this.submissionRetention = const Duration(days: 7),
    this.baseRetryDelay = const Duration(seconds: 15),
    this.maxRetryDelay = const Duration(minutes: 30),
    this.dispatchInterval = const Duration(seconds: 30),
  }) : _dao = dao,
       _readApiClient = readApiClient,
       _readScrobbleEnabled = readScrobbleEnabled,
       _readLastFmCredentials = readLastFmCredentials ?? (() async => null),
       _readListenBrainzCredentials =
           readListenBrainzCredentials ?? (() async => null),
       _onLastFmInvalidSession = onLastFmInvalidSession,
       _onListenBrainzInvalidToken = onListenBrainzInvalidToken,
       _readReachable = readReachable,
       _now = now ?? DateTime.now;

  final ScrobbleDao _dao;
  final SubsonicApiClient? Function() _readApiClient;
  final bool Function() _readScrobbleEnabled;
  final Future<LastFmScrobbleCredentials?> Function() _readLastFmCredentials;
  final Future<ListenBrainzScrobbleCredentials?> Function()
  _readListenBrainzCredentials;
  final void Function()? _onLastFmInvalidSession;
  final void Function()? _onListenBrainzInvalidToken;
  final bool Function() _readReachable;
  final DateTime Function() _now;

  final Duration nowPlayingRetention;
  final Duration submissionRetention;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;
  final Duration dispatchInterval;

  Timer? _dispatchTimer;
  Timer? _dispatchRetryTimer;
  bool _isDispatching = false;
  bool _started = false;

  @override
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    AppLogger.info('Scrobble service started');
    unawaited(_syncDispatchTimer());
  }

  @override
  Future<void> enqueueNowPlaying({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  }) {
    return _enqueueForProviders(
      songId: songId,
      submission: false,
      sessionKey: sessionKey,
      track: track,
      retention: nowPlayingRetention,
    );
  }

  @override
  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  }) {
    return _enqueueForProviders(
      songId: songId,
      submission: true,
      sessionKey: sessionKey,
      track: track,
      retention: submissionRetention,
    );
  }

  Future<void> _enqueueForProviders({
    required String songId,
    required bool submission,
    required String sessionKey,
    required ScrobbleTrackPayload? track,
    required Duration retention,
  }) async {
    final providers = await _activeProviders();
    if (providers.isEmpty) {
      return;
    }
    final now = _now();
    for (final provider in providers) {
      await _dao.enqueue(
        songId: songId,
        provider: provider.id,
        submission: submission,
        sessionKey: sessionKey,
        trackTitle: _clean(track?.title),
        artistName: _clean(track?.artist),
        albumName: _clean(track?.album),
        durationSeconds: track?.duration?.inSeconds,
        createdAt: now,
        nextAttemptAt: now,
        expiresAt: now.add(retention),
      );
    }
    _ensureDispatchTimer();
  }

  Future<List<ScrobbleProvider>> _activeProviders() async {
    final providers = <ScrobbleProvider>[];
    if (_readScrobbleEnabled()) {
      providers.add(ScrobbleProvider.subsonic);
    }
    if (await _readLastFmCredentials() != null) {
      providers.add(ScrobbleProvider.lastFm);
    }
    if (await _readListenBrainzCredentials() != null) {
      providers.add(ScrobbleProvider.listenBrainz);
    }
    return providers;
  }

  @override
  Future<void> flushDue() async {
    if (_isDispatching) {
      return;
    }
    _isDispatching = true;
    try {
      final hasAnyProvider =
          _readScrobbleEnabled() ||
          await _readLastFmCredentials() != null ||
          await _readListenBrainzCredentials() != null;
      if (!hasAnyProvider) {
        await _dao.clearAll();
        _stopDispatchTimer();
        return;
      }

      if (!_readReachable()) {
        return;
      }

      final api = _readApiClient();

      final now = _now();
      await _dao.pruneExpired(now);
      final events = await _dao.getDueEntries(now);

      if (events.isNotEmpty) {
        AppLogger.debug('Scrobble flush: ${events.length} due event(s)');
      }

      for (final event in events) {
        try {
          if (await _dispatchEvent(event, api)) {
            await _dao.markDelivered(event.id);
          }
        } on LastFmInvalidSessionException catch (_) {
          _onLastFmInvalidSession?.call();
          await _dao.markDelivered(event.id);
        } on ListenBrainzInvalidTokenException catch (_) {
          _onListenBrainzInvalidToken?.call();
          await _dao.markDelivered(event.id);
        } on _MalformedScrobbleMetadataException catch (_) {
          AppLogger.warning(
            'Dropping ${event.provider} scrobble with incomplete metadata.',
          );
          await _dao.markDelivered(event.id);
        } on Object catch (error) {
          final attempts = event.attempts + 1;
          final nextAttemptAt = now.add(_retryDelay(attempts));
          if (!event.expiresAt.isAfter(nextAttemptAt)) {
            await _dao.markDelivered(event.id);
            continue;
          }
          await _dao.reschedule(
            id: event.id,
            attempts: attempts,
            nextAttemptAt: nextAttemptAt,
            lastError: _redactedError(error),
          );
        }
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Scrobble dispatch failed: $error\n$stackTrace');
    } finally {
      _isDispatching = false;
      await _syncDispatchTimer();
    }
  }

  Future<bool> _dispatchEvent(
    ScrobbleQueueTableData event,
    SubsonicApiClient? api,
  ) async {
    final provider =
        ScrobbleProvider.fromId(event.provider) ?? ScrobbleProvider.subsonic;
    switch (provider) {
      case ScrobbleProvider.subsonic:
        if (!_readScrobbleEnabled() || api == null) {
          return false;
        }
        await api.scrobble(
          event.songId,
          submission: event.submission,
          time: event.createdAt,
        );
        return true;

      case ScrobbleProvider.lastFm:
        final credentials = await _readLastFmCredentials();
        if (credentials == null) {
          return true;
        }
        final track = _validatedExternalTrack(
          title: event.trackTitle,
          artist: event.artistName,
        );
        final client = LastFmApiClient(apiKey: credentials.apiKey);
        if (event.submission) {
          await client.scrobble(
            artist: track.artist,
            track: track.title,
            timestamp: event.createdAt,
            sessionKey: credentials.sessionKey,
            sharedSecret: credentials.sharedSecret,
            album: _clean(event.albumName),
            duration: event.durationSeconds,
          );
        } else {
          await client.updateNowPlaying(
            artist: track.artist,
            track: track.title,
            sessionKey: credentials.sessionKey,
            sharedSecret: credentials.sharedSecret,
            album: _clean(event.albumName),
            duration: event.durationSeconds,
          );
        }
        return true;

      case ScrobbleProvider.listenBrainz:
        final credentials = await _readListenBrainzCredentials();
        if (credentials == null) {
          return true;
        }
        final track = _validatedExternalTrack(
          title: event.trackTitle,
          artist: event.artistName,
        );
        final client = ListenBrainzApiClient();
        if (event.submission) {
          await client.submitSingleListen(
            userToken: credentials.userToken,
            artist: track.artist,
            track: track.title,
            listenedAt: event.createdAt,
            album: _clean(event.albumName),
            duration: event.durationSeconds,
          );
        } else {
          await client.sendPlayingNow(
            userToken: credentials.userToken,
            artist: track.artist,
            track: track.title,
            album: _clean(event.albumName),
            duration: event.durationSeconds,
          );
        }
        return true;
    }
  }

  Duration _retryDelay(int attempts) {
    final exponent = math.max(0, attempts - 1);
    final base = baseRetryDelay.inSeconds * math.pow(2, exponent);
    final capped = math.min(base.toInt(), maxRetryDelay.inSeconds);
    return Duration(seconds: capped);
  }

  ({String title, String artist}) _validatedExternalTrack({
    required String? title,
    required String? artist,
  }) {
    final normalizedTitle = _clean(title);
    final normalizedArtist = _clean(artist);
    if (normalizedTitle == null || normalizedArtist == null) {
      throw const _MalformedScrobbleMetadataException();
    }
    return (title: normalizedTitle, artist: normalizedArtist);
  }

  String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String _redactedError(Object error) => error.runtimeType.toString();

  @override
  Future<void> dispose() async {
    _stopDispatchTimer();
    _dispatchRetryTimer?.cancel();
    _dispatchRetryTimer = null;
  }

  void _ensureDispatchTimer() {
    _dispatchTimer ??= Timer.periodic(dispatchInterval, (_) {
      unawaited(flushDue());
    });
  }

  void _stopDispatchTimer() {
    _dispatchTimer?.cancel();
    _dispatchTimer = null;
  }

  Future<void> _syncDispatchTimer() async {
    if (!_started) {
      return;
    }

    try {
      final count = await _dao.countEntries();
      if (count > 0) {
        _dispatchRetryTimer?.cancel();
        _dispatchRetryTimer = null;
        _ensureDispatchTimer();
      } else {
        _stopDispatchTimer();
      }
    } on Object catch (error) {
      if (!_isDatabaseLocked(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Scrobble timer sync deferred: database is locked during startup.',
      );
      _dispatchRetryTimer?.cancel();
      _dispatchRetryTimer = Timer(const Duration(seconds: 2), () {
        _dispatchRetryTimer = null;
        unawaited(_syncDispatchTimer());
      });
    }
  }

  bool _isDatabaseLocked(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database is locked');
  }
}

class _MalformedScrobbleMetadataException implements Exception {
  const _MalformedScrobbleMetadataException();
}
