import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;

@immutable
class ResolvedPlaybackMetadata {
  const ResolvedPlaybackMetadata({
    this.format,
    this.bitRate,
    this.sampleRate,
    required this.isTranscoded,
  });

  final String? format;
  final int? bitRate;
  final int? sampleRate;
  final bool isTranscoded;
}

@immutable
class ResolvedPlaybackSource {
  const ResolvedPlaybackSource.file({
    required this.songId,
    required this.uri,
    required this.metadata,
    this.cachedFilePath,
  }) : kind = PlaybackSourceKind.file,
       lockCachingStreamUri = null,
       lockCachingAudioSource = null,
       sidecarCacheFilePath = null;

  const ResolvedPlaybackSource.lockCachedStream({
    required this.songId,
    required this.lockCachingStreamUri,
    required this.lockCachingAudioSource,
    required this.cachedFilePath,
    required this.metadata,
  }) : kind = PlaybackSourceKind.lockCachedStream,
       uri = null,
       sidecarCacheFilePath = null;

  const ResolvedPlaybackSource.directStream({
    required this.songId,
    required this.uri,
    required this.metadata,
    this.sidecarCacheFilePath,
  }) : kind = PlaybackSourceKind.directStream,
       lockCachingStreamUri = null,
       cachedFilePath = null,
       lockCachingAudioSource = null;

  final PlaybackSourceKind kind;
  final String songId;
  final Uri? uri;
  final Uri? lockCachingStreamUri;
  final ResolvedPlaybackMetadata metadata;
  final String? cachedFilePath;

  /// Desktop rolling-cache target filled by [RollingCacheSidecarDownloader]
  /// while playback uses [uri] directly (media_kit cannot seek lock-cache
  /// proxies reliably).
  final String? sidecarCacheFilePath;
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

  IndexedAudioSource asClonedAudioSource({dynamic tag}) {
    return switch (kind) {
      PlaybackSourceKind.file => AudioSource.uri(uri!, tag: tag),
      PlaybackSourceKind.directStream => AudioSource.uri(uri!, tag: tag),
      // A second LockCachingAudioSource cannot share the active deck's cache
      // path: both instances would race to rename the same `.part` file.
      PlaybackSourceKind.lockCachedStream => AudioSource.uri(
        lockCachingStreamUri!,
        tag: tag,
      ),
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
    LibraryDao? libraryDao,
    required RollingCacheManager rollingCacheManager,
    required SubsonicApiClient? Function() readApiClient,
    required StreamingQuality Function() readStreamingQuality,
    required Future<Directory> Function() readRollingCacheDirectory,
    bool Function()? readCachedPlaybackFirst,
    bool Function()? readPreferAnyCache,
    bool Function()? readCanStream,
    bool Function()? readSupportsLockCaching,
    bool Function()? readUsesSidecarRollingCache,
  }) : _cacheDao = cacheDao,
       _libraryDao = libraryDao,
       _rollingCacheManager = rollingCacheManager,
       _readApiClient = readApiClient,
       _readStreamingQuality = readStreamingQuality,
       _readRollingCacheDirectory = readRollingCacheDirectory,
       _readCachedPlaybackFirst = readCachedPlaybackFirst ?? _readFalse,
       _readPreferAnyCache = readPreferAnyCache ?? _readFalse,
       _readCanStream = readCanStream ?? _readTrue,
       _readSupportsLockCaching =
           readSupportsLockCaching ?? _defaultSupportsLockCaching,
       _readUsesSidecarRollingCache = readUsesSidecarRollingCache ?? _readFalse;

  final CacheDao _cacheDao;
  final LibraryDao? _libraryDao;
  final RollingCacheManager _rollingCacheManager;
  final SubsonicApiClient? Function() _readApiClient;
  final StreamingQuality Function() _readStreamingQuality;
  final Future<Directory> Function() _readRollingCacheDirectory;
  final bool Function() _readCachedPlaybackFirst;
  final bool Function() _readPreferAnyCache;
  final bool Function() _readCanStream;
  final bool Function() _readSupportsLockCaching;
  final bool Function() _readUsesSidecarRollingCache;

  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
  }) async {
    final quality = _readStreamingQuality();
    final streamingMetadata = _resolveStreamingMetadata(
      song: song,
      quality: quality,
    );
    var cachedTrack = await _cacheDao.getCachedTrack(song.id);
    // Startup maintenance reconciles the cache in bulk, but a file can still
    // disappear while Navis is running (manual cleanup, storage pressure, or
    // filesystem damage). Repair that single stale record immediately before
    // choosing a source so it cannot keep presenting as downloaded/cached.
    if (cachedTrack != null && !File(cachedTrack.filePath).existsSync()) {
      await _cacheDao.removeCachedTrack(song.id);
      AppLogger.info(
        'Removed missing ${cachedTrack.cacheType.name} cache entry for '
        'song=${song.id} during source resolution.',
      );
      cachedTrack = null;
    }
    if (song.serverDeletedAt != null) {
      if (cachedTrack != null &&
          cachedTrack.cacheType == CacheType.permanent &&
          cachedTrack.downloadStatus == DownloadStatus.complete) {
        final file = File(cachedTrack.filePath);
        if (file.existsSync()) {
          await _rollingCacheManager.touchTrack(song.id);
          return ResolvedPlaybackSource.file(
            songId: song.id,
            uri: file.uri,
            metadata: _resolveCachedTrackMetadata(
              song: song,
              cachedTrack: cachedTrack,
            ),
            cachedFilePath: cachedTrack.filePath,
          );
        }
      }
      await _cacheDao.removeCachedTrack(song.id);
      await _libraryDao?.deleteLocalOnlySong(song.id);
      throw const PlaybackSourceUnavailableException(
        'Downloaded file is no longer available.',
      );
    }

    final cachePolicy = PlaybackCachePolicy(
      cachedPlaybackFirst: _readCachedPlaybackFirst(),
      preferAnyCache: _readPreferAnyCache(),
      canStream: _readCanStream(),
    );
    if (cachedTrack != null &&
        _shouldUseCachedTrack(
          song: song,
          cachedTrack: cachedTrack,
          quality: quality,
          policy: cachePolicy,
        )) {
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
          metadata: _resolveCachedTrackMetadata(
            song: song,
            cachedTrack: cachedTrack,
          ),
          cachedFilePath: cachedTrack.filePath,
        );
      }
    }

    if (cachedTrack != null &&
        !_shouldUseCachedTrack(
          song: song,
          cachedTrack: cachedTrack,
          quality: quality,
          policy: cachePolicy,
        )) {
      AppLogger.debug(
        'Skipping cached source for song=${song.id} due to active '
        'streaming quality profile. cacheType=${cachedTrack.cacheType.name} '
        'cacheFormat=${cachedTrack.format} requestedFormat=${quality.format} '
        'requestedBitRate=${quality.maxBitRate}',
      );
    }

    if (!cachePolicy.canStream) {
      throw const PlaybackSourceUnavailableException(
        'No cached playback source available while offline.',
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
      song: song,
      quality: quality,
    );
    final canUseLockCaching = preferLockCaching && _readSupportsLockCaching();
    if (!canUseLockCaching) {
      final reason = !preferLockCaching
          ? 'prefer_lock_disabled'
          : 'runtime_lock_cache_unsupported';
      AppLogger.debug(
        'Playback source resolved: song=${song.id} '
        'kind=${PlaybackSourceKind.directStream.name} '
        'fallback=$reason '
        'qualityLabel=${quality.label} '
        'maxBitRate=${quality.maxBitRate?.toString() ?? 'original'} '
        'format=${quality.format ?? 'original'}',
      );
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: streamUri,
        metadata: streamingMetadata,
      );
    }

    final cacheFile = await _resolveRollingCacheFile(
      song: song,
      quality: quality,
    );

    // Desktop/media_kit cannot seek LockCachingAudioSource's local proxy.
    // Play via direct HTTPS (Range-seekable) and fill the rolling cache with a
    // sidecar download so seeks stay responsive while caching continues.
    if (_readUsesSidecarRollingCache()) {
      AppLogger.debug(
        'Playback source resolved: song=${song.id} '
        'kind=${PlaybackSourceKind.directStream.name} '
        'sidecarCache=${cacheFile.path} '
        'qualityLabel=${quality.label} '
        'maxBitRate=${quality.maxBitRate?.toString() ?? 'original'} '
        'format=${quality.format ?? 'original'}',
      );
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: streamUri,
        metadata: streamingMetadata,
        sidecarCacheFilePath: cacheFile.path,
      );
    }

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
        lockCachingStreamUri: streamUri,
        lockCachingAudioSource: lockCachingSource,
        cachedFilePath: cacheFile.path,
        metadata: streamingMetadata,
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
        metadata: streamingMetadata,
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

    final metadata = _resolveStreamingMetadata(song: song, quality: quality);
    final normalizedBitRate =
        metadata.isTranscoded && metadata.bitRate != song.bitRate
        ? metadata.bitRate?.toString() ?? 'original'
        : 'original';
    final normalizedFormat =
        _resolveRequestedStreamFormat(song: song, quality: quality) ??
        'original';
    final sourceFormat = _inferSourceFormat(song) ?? 'unknown';
    final qualitySignature =
        '$normalizedBitRate::$normalizedFormat::$sourceFormat';
    final digest = sha1
        .convert(utf8.encode('${song.id}::$qualitySignature'))
        .toString();
    final extension = _songFileExtension(
      song,
      metadata: metadata,
      quality: quality,
    );

    return File(p.join(rollingDir.path, '${song.id}_$digest.$extension'));
  }

  Uri _buildStreamUri({
    required SubsonicApiClient api,
    required SongsTableData song,
    required StreamingQuality quality,
  }) {
    final metadata = _resolveStreamingMetadata(song: song, quality: quality);

    return api.streamUrl(
      id: song.id,
      maxBitRate: metadata.isTranscoded && metadata.bitRate != song.bitRate
          ? metadata.bitRate
          : null,
      format: _resolveRequestedStreamFormat(song: song, quality: quality),
    );
  }

  String? _resolveRequestedStreamFormat({
    required SongsTableData song,
    required StreamingQuality quality,
  }) {
    final requestedFormat = _canonicalAudioFormat(quality.format);
    if (requestedFormat == null) {
      return null;
    }
    final sourceFormat = _inferSourceFormat(song);
    if (sourceFormat == requestedFormat) {
      return null;
    }
    return requestedFormat;
  }

  ResolvedPlaybackMetadata _resolveStreamingMetadata({
    required SongsTableData song,
    required StreamingQuality quality,
  }) {
    final sourceFormat = _inferSourceFormat(song);
    final requestedFormat = _canonicalAudioFormat(quality.format);
    final requestedBitRate = quality.maxBitRate;
    final sourceBitRate = song.bitRate;

    final shouldRequestFormat =
        requestedFormat != null &&
        (sourceFormat == null || sourceFormat != requestedFormat);
    final shouldRequestBitRate =
        requestedBitRate != null &&
        (sourceBitRate == null || sourceBitRate > requestedBitRate);
    final isTranscoded = shouldRequestFormat || shouldRequestBitRate;

    return ResolvedPlaybackMetadata(
      format: _resolveDisplayFormat(
        sourceFormat: sourceFormat,
        requestedFormat: requestedFormat,
        isTranscoded: isTranscoded,
      ),
      bitRate: shouldRequestBitRate ? requestedBitRate : sourceBitRate,
      sampleRate: song.sampleRate,
      isTranscoded: isTranscoded,
    );
  }

  ResolvedPlaybackMetadata _resolveCachedTrackMetadata({
    required SongsTableData song,
    required CachedTracksTableData cachedTrack,
  }) {
    final sourceFormat = _inferSourceFormat(song);
    final cachedFormat = _canonicalAudioFormat(cachedTrack.format);
    final resolvedFormat = cachedFormat == 'transcoded'
        ? null
        : cachedFormat ?? sourceFormat;
    final sourceBitRate = song.bitRate;
    final resolvedBitRate = cachedTrack.bitRate ?? sourceBitRate;
    final isTranscoded =
        cachedTrack.cacheType == CacheType.rolling &&
        ((cachedFormat == 'transcoded') ||
            (sourceFormat != null &&
                resolvedFormat != null &&
                sourceFormat != resolvedFormat) ||
            (sourceBitRate != null &&
                resolvedBitRate != null &&
                resolvedBitRate < sourceBitRate));
    return ResolvedPlaybackMetadata(
      format: resolvedFormat,
      bitRate: resolvedBitRate,
      sampleRate: song.sampleRate,
      isTranscoded: isTranscoded,
    );
  }

  String? _resolveDisplayFormat({
    required String? sourceFormat,
    required String? requestedFormat,
    required bool isTranscoded,
  }) {
    if (!isTranscoded) {
      return sourceFormat;
    }
    if (requestedFormat != null && requestedFormat.isNotEmpty) {
      return requestedFormat;
    }
    if (sourceFormat != null && _isLossyAudioFormat(sourceFormat)) {
      return sourceFormat;
    }
    return null;
  }

  bool _isLossyAudioFormat(String format) {
    return switch (format.toLowerCase()) {
      'mp3' || 'aac' || 'ogg' || 'opus' || 'm4a' || 'vorbis' => true,
      _ => false,
    };
  }

  String? _inferSourceFormat(SongsTableData song) {
    final suffixFormat = _canonicalAudioFormat(song.suffix);
    if (suffixFormat != null) {
      return suffixFormat;
    }

    final contentType = song.contentType?.trim() ?? '';
    if (!contentType.contains('/')) {
      return null;
    }
    final subtype = contentType.split('/').last;
    return _canonicalAudioFormat(subtype);
  }

  String? _canonicalAudioFormat(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    return switch (normalized) {
      'mpeg' || 'mpga' => 'mp3',
      'x-flac' => 'flac',
      'x-wav' || 'wave' => 'wav',
      'x-aac' || 'aacp' => 'aac',
      _ => normalized,
    };
  }

  String _songFileExtension(
    SongsTableData song, {
    required StreamingQuality quality,
    required ResolvedPlaybackMetadata metadata,
  }) {
    final requestedFormat = quality.format?.trim();
    if (requestedFormat != null && requestedFormat.isNotEmpty) {
      return requestedFormat;
    }
    if (metadata.isTranscoded) {
      return metadata.format ?? 'transcoded';
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

  bool _shouldUseCachedTrack({
    required SongsTableData song,
    required CachedTracksTableData cachedTrack,
    required StreamingQuality quality,
    required PlaybackCachePolicy policy,
  }) {
    if (cachedTrack.downloadStatus != DownloadStatus.complete) {
      return false;
    }
    if (policy.cachedPlaybackFirst ||
        policy.preferAnyCache ||
        !policy.canStream) {
      return true;
    }

    final cachedMetadata = _resolveCachedTrackMetadata(
      song: song,
      cachedTrack: cachedTrack,
    );
    final streamingMetadata = _resolveStreamingMetadata(
      song: song,
      quality: quality,
    );
    return _metadataMatchesActiveProfile(
      cachedMetadata: cachedMetadata,
      streamingMetadata: streamingMetadata,
    );
  }

  bool _metadataMatchesActiveProfile({
    required ResolvedPlaybackMetadata cachedMetadata,
    required ResolvedPlaybackMetadata streamingMetadata,
  }) {
    final cachedFormat = _canonicalAudioFormat(cachedMetadata.format);
    final streamingFormat = _canonicalAudioFormat(streamingMetadata.format);
    if (cachedFormat != streamingFormat) {
      return false;
    }

    return cachedMetadata.bitRate == streamingMetadata.bitRate;
  }
}

@immutable
class PlaybackCachePolicy {
  const PlaybackCachePolicy({
    required this.cachedPlaybackFirst,
    required this.preferAnyCache,
    required this.canStream,
  });

  final bool cachedPlaybackFirst;
  final bool preferAnyCache;
  final bool canStream;
}

bool _readFalse() => false;

bool _readTrue() => true;

bool _defaultSupportsLockCaching() => !kIsWeb;
