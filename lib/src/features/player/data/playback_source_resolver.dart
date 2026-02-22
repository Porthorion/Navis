import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;

@immutable
class ResolvedPlaybackSource {
  const ResolvedPlaybackSource.file({
    required this.songId,
    required this.uri,
    this.cachedFilePath,
  }) : kind = PlaybackSourceKind.file,
       lockCachingAudioSource = null;

  const ResolvedPlaybackSource.lockCachedStream({
    required this.songId,
    required this.lockCachingAudioSource,
    required this.cachedFilePath,
  }) : kind = PlaybackSourceKind.lockCachedStream,
       uri = null;

  const ResolvedPlaybackSource.directStream({
    required this.songId,
    required this.uri,
  }) : kind = PlaybackSourceKind.directStream,
       cachedFilePath = null,
       lockCachingAudioSource = null;

  final PlaybackSourceKind kind;
  final String songId;
  final Uri? uri;
  final String? cachedFilePath;
  // ignore: experimental_member_use, reason: LockCachingAudioSource is intentionally surfaced so the audio handler can subscribe to cache completion.
  final LockCachingAudioSource? lockCachingAudioSource;

  bool get isLocal => kind == PlaybackSourceKind.file;

  IndexedAudioSource asAudioSource({dynamic tag}) {
    return switch (kind) {
      PlaybackSourceKind.file => AudioSource.uri(uri!, tag: tag),
      PlaybackSourceKind.directStream => AudioSource.uri(uri!, tag: tag),
      PlaybackSourceKind.lockCachedStream => lockCachingAudioSource!,
    };
  }
}

enum PlaybackSourceKind {
  file,
  directStream,
  lockCachedStream,
}

class PlaybackSourceUnavailableException implements Exception {
  const PlaybackSourceUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PlaybackSourceResolver {
  const PlaybackSourceResolver({
    required CacheDao cacheDao,
    required RollingCacheManager rollingCacheManager,
    required SubsonicApiClient? Function() readApiClient,
    required StreamingQuality Function() readStreamingQuality,
    required Future<Directory> Function() readRollingCacheDirectory,
  }) : _cacheDao = cacheDao,
       _rollingCacheManager = rollingCacheManager,
       _readApiClient = readApiClient,
       _readStreamingQuality = readStreamingQuality,
       _readRollingCacheDirectory = readRollingCacheDirectory;

  final CacheDao _cacheDao;
  final RollingCacheManager _rollingCacheManager;
  final SubsonicApiClient? Function() _readApiClient;
  final StreamingQuality Function() _readStreamingQuality;
  final Future<Directory> Function() _readRollingCacheDirectory;

  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
  }) async {
    final quality = _readStreamingQuality();
    final cachedTrack = await _cacheDao.getCachedTrack(song.id);
    if (cachedTrack != null && _shouldUseCachedTrack(cachedTrack, quality)) {
      final file = File(cachedTrack.filePath);
      if (file.existsSync()) {
        AppLogger.debug(
          'Playback source resolved: song=${song.id} '
          'kind=${PlaybackSourceKind.file.name} path=${cachedTrack.filePath} '
          'qualityLabel=${quality.label} '
          'maxBitRate=${quality.maxBitRate?.toString() ?? 'original'} '
          'format=${quality.format ?? 'original'}',
        );
        await _rollingCacheManager.touchTrack(song.id);
        return ResolvedPlaybackSource.file(
          songId: song.id,
          uri: file.uri,
          cachedFilePath: cachedTrack.filePath,
        );
      }
    }

    if (cachedTrack != null && !_shouldUseCachedTrack(cachedTrack, quality)) {
      AppLogger.debug(
        'Skipping cached source for song=${song.id} due to active '
        'streaming quality profile. cacheType=${cachedTrack.cacheType.name} '
        'cacheFormat=${cachedTrack.format} requestedFormat=${quality.format} '
        'requestedBitRate=${quality.maxBitRate}',
      );
    }

    final api = _readApiClient();
    if (api == null) {
      throw const PlaybackSourceUnavailableException(
        'No authenticated Subsonic session available.',
      );
    }

    final streamUri = _buildStreamUri(
      api: api,
      songId: song.id,
      quality: quality,
    );
    if (!preferLockCaching) {
      AppLogger.debug(
        'Playback source resolved: song=${song.id} '
        'kind=${PlaybackSourceKind.directStream.name} '
        'fallback=prefer_lock_disabled '
        'qualityLabel=${quality.label} '
        'maxBitRate=${quality.maxBitRate?.toString() ?? 'original'} '
        'format=${quality.format ?? 'original'}',
      );
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: streamUri,
      );
    }

    final cacheFile = await _resolveRollingCacheFile(
      song: song,
      quality: quality,
    );
    try {
      // ignore: experimental_member_use, reason: just_audio exposes rolling stream caching through this experimental source type.
      final lockCachingSource = LockCachingAudioSource(
        streamUri,
        cacheFile: cacheFile,
      );

      AppLogger.debug(
        'Playback source resolved: song=${song.id} '
        'kind=${PlaybackSourceKind.lockCachedStream.name} '
        'cache=${cacheFile.path} '
        'qualityLabel=${quality.label} '
        'maxBitRate=${quality.maxBitRate?.toString() ?? 'original'} '
        'format=${quality.format ?? 'original'}',
      );
      return ResolvedPlaybackSource.lockCachedStream(
        songId: song.id,
        lockCachingAudioSource: lockCachingSource,
        cachedFilePath: cacheFile.path,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Playback source fallback: song=${song.id} '
        'from=${PlaybackSourceKind.lockCachedStream.name} '
        'to=${PlaybackSourceKind.directStream.name} '
        'reason=${error.runtimeType}. '
        '$error\n$stackTrace',
      );
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: streamUri,
      );
    }
  }

  Uri? resolveArtUri(SongsTableData song) {
    final coverArt = song.coverArt;
    if (coverArt == null || coverArt.trim().isEmpty) {
      return null;
    }

    final api = _readApiClient();
    if (api == null) {
      return null;
    }
    return api.getCoverArtUrl(id: coverArt, size: 512);
  }

  Future<File> _resolveRollingCacheFile({
    required SongsTableData song,
    required StreamingQuality quality,
  }) async {
    final rootDir = await _readRollingCacheDirectory();
    final rollingDir = Directory(p.join(rootDir.path, 'audio', 'rolling'));
    if (!rollingDir.existsSync()) {
      rollingDir.createSync(recursive: true);
    }

    final qualitySignature = '${quality.label}-${quality.maxBitRate ?? 0}';
    final digest = sha1
        .convert(utf8.encode('${song.id}::$qualitySignature'))
        .toString();
    final extension = _songFileExtension(song, quality);

    return File(p.join(rollingDir.path, '${song.id}_$digest.$extension'));
  }

  Uri _buildStreamUri({
    required SubsonicApiClient api,
    required String songId,
    required StreamingQuality quality,
  }) {
    return api.streamUrl(
      id: songId,
      maxBitRate: quality.maxBitRate,
      format: quality.format,
    );
  }

  String _songFileExtension(SongsTableData song, StreamingQuality quality) {
    final requestedFormat = quality.format?.trim();
    if (requestedFormat != null && requestedFormat.isNotEmpty) {
      return requestedFormat;
    }

    final suffix = song.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) {
      return suffix;
    }

    final contentType = song.contentType?.trim() ?? '';
    if (contentType.contains('/')) {
      final inferred = contentType.split('/').last.trim();
      if (inferred.isNotEmpty) {
        return inferred;
      }
    }

    return 'bin';
  }

  bool _shouldUseCachedTrack(
    CachedTracksTableData cachedTrack,
    StreamingQuality quality,
  ) {
    final requestedFormat = quality.format?.trim().toLowerCase();
    final hasRequestedFormat =
        requestedFormat != null && requestedFormat.isNotEmpty;
    final requestedBitRate = quality.maxBitRate;
    final hasRequestedBitRate = requestedBitRate != null;
    final wantsTranscoding = hasRequestedFormat || hasRequestedBitRate;
    final cachedFormat = cachedTrack.format.trim().toLowerCase();
    final cachedBitRate = cachedTrack.bitRate;

    if (!wantsTranscoding) {
      return true;
    }

    if (cachedTrack.cacheType == CacheType.permanent) {
      return true;
    }

    if (hasRequestedFormat && cachedFormat != requestedFormat) {
      return _isLosslessFormat(cachedFormat) &&
          !_isLosslessFormat(requestedFormat);
    }

    if (hasRequestedBitRate && cachedBitRate != null) {
      if (cachedBitRate >= requestedBitRate) {
        return true;
      }
    }

    if (hasRequestedFormat) {
      return cachedFormat == requestedFormat;
    }

    return false;
  }

  bool _isLosslessFormat(String? format) {
    if (format == null || format.trim().isEmpty) {
      return false;
    }
    return switch (format.trim().toLowerCase()) {
      'flac' || 'alac' || 'wav' || 'aiff' || 'ape' || 'dsf' || 'dff' => true,
      _ => false,
    };
  }
}
