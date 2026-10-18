import 'package:dio/dio.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/utils/app_logger.dart';

const int normalLyricsCacheTtlSeconds = 86400;
const int permanentLyricsCacheTtlSeconds = 31536000;

bool hasRecentLyricsFailure(ExternalLyricsCacheTableData? cache) =>
    cache != null &&
    cache.failureCount > 0 &&
    cache.lastFailedAt != null &&
    DateTime.now().difference(cache.lastFailedAt!) < const Duration(days: 7);

typedef LyricsLookupMetadata = ({
  String artist,
  String title,
  String? album,
  int? durationSeconds,
});

typedef _LyricsLookupResult = ({LyricsResolution? resolution, bool failed});

class LyricsResolver {
  const new({
    required this._libraryDao,
    required this._lrclibClient,
    required this._apiClient,
    this.background = false,
    this.cancelToken,
  });

  final bool background;
  final CancelToken? cancelToken;
  final LibraryDao _libraryDao;
  final LrclibClient _lrclibClient;
  final SubsonicApiClient? _apiClient;

  Future<LyricsResolution> resolve({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required bool useLrclib,
    int lyricsCacheTtlSeconds = normalLyricsCacheTtlSeconds,
    bool cacheServerLyrics = false,
    bool forceSyncedUpgrade = false,
  }) async {
    final cached = await _libraryDao.getExternalLyricsCache(songId);
    final cachedResolution = cached == null
        ? null
        : lyricsResolutionFromExternalCache(cached);
    final cachedSyncedResolution = cachedResolution?.source.isSynced == true
        ? cachedResolution
        : null;

    if (useLrclib) {
      if (cachedSyncedResolution != null) {
        return cachedSyncedResolution;
      }

      final upgradeBackoff =
          !forceSyncedUpgrade && hasRecentLyricsFailure(cached);
      final server = await _resolveWithServer(
        songId: songId,
        metadata: metadata,
        cacheServerLyrics: cacheServerLyrics && !upgradeBackoff,
        lyricsCacheTtlSeconds: lyricsCacheTtlSeconds,
      );
      if (server.resolution case final resolution?) {
        if (resolution.source.isSynced ||
            upgradeBackoff ||
            cached?.instrumental == true) {
          if (cacheServerLyrics && upgradeBackoff) {
            // Keep plain lyrics durable without clearing the upgrade backoff.
            await _cacheServerLyrics(
              songId: songId,
              source: resolution.source,
              lyrics: resolution.lyrics,
              ttlSeconds: lyricsCacheTtlSeconds,
              failureCount: resolution.source.isSynced
                  ? 0
                  : cached!.failureCount,
              lastFailedAt: resolution.source.isSynced
                  ? null
                  : cached!.lastFailedAt,
            );
          }
          return resolution;
        }
      }

      if (cached?.instrumental == true) {
        return cachedResolution!;
      }

      final lrclibResult = await _resolveWithLrclib(
        songId: songId,
        metadata: metadata,
        lyricsCacheTtlSeconds: lyricsCacheTtlSeconds,
      );
      if (lrclibResult.resolution?.source.isSynced == true) {
        return lrclibResult.resolution!;
      }

      final preferred =
          server.resolution ??
          (lrclibResult.resolution?.instrumental == false
              ? lrclibResult.resolution
              : null) ??
          cachedResolution ??
          lrclibResult.resolution;
      if (preferred != null) {
        // LRCLIB may have cached plain lyrics while trying the synced upgrade.
        // Keep the selected server plain result for downloaded songs instead.
        if (cacheServerLyrics &&
            server.resolution != null &&
            lrclibResult.resolution?.instrumental != true) {
          await _cacheServerLyrics(
            songId: songId,
            source: preferred.source,
            lyrics: preferred.lyrics,
            ttlSeconds: lyricsCacheTtlSeconds,
          );
        }
        return LyricsResolution(
          lyrics: preferred.lyrics,
          source: preferred.source,
          instrumental: preferred.instrumental,
          syncedUpgradeMiss:
              metadata != null &&
              !lrclibResult.failed &&
              lrclibResult.resolution?.instrumental != true &&
              !preferred.instrumental,
        );
      }

      return LyricsResolution(
        lyrics: const LyricsList(),
        source: LyricsSource.lrclibPlain,
        confirmedMiss:
            _apiClient != null && !lrclibResult.failed && !server.failed,
      );
    }

    final cachedServerResolution = cachedResolution?.source.isServer == true
        ? cachedResolution
        : null;
    if (cachedServerResolution != null) {
      return cachedServerResolution;
    }

    final server = await _resolveWithServer(
      songId: songId,
      metadata: metadata,
      cacheServerLyrics: cacheServerLyrics,
      lyricsCacheTtlSeconds: lyricsCacheTtlSeconds,
    );
    if (server.resolution case final resolution?) {
      return resolution;
    }

    if (cachedResolution != null) {
      return cachedResolution;
    }

    return LyricsResolution(
      lyrics: const LyricsList(),
      source: LyricsSource.serverPlain,
      confirmedMiss: _apiClient != null && !server.failed,
    );
  }

  Future<_LyricsLookupResult> _resolveWithLrclib({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required int lyricsCacheTtlSeconds,
  }) async {
    if (_lrclibClient.isRateLimited) {
      return (resolution: null, failed: true);
    }
    if (metadata == null) {
      return (resolution: null, failed: false);
    }

    try {
      final best = await _findBestLrclibMatch(metadata);
      if (best == null) {
        return (resolution: null, failed: false);
      }

      final parsedSynced = tryParseLrc(best.syncedLyrics);
      if (best.instrumental && parsedSynced == null && !best.hasPlain) {
        await _libraryDao.upsertExternalLyricsCache(
          songId: songId,
          source: LyricsSource.lrclibPlain.name,
          instrumental: true,
          ttlSeconds: lyricsCacheTtlSeconds,
        );
        return (
          resolution: const LyricsResolution(
            lyrics: LyricsList(),
            source: LyricsSource.lrclibPlain,
            instrumental: true,
          ),
          failed: false,
        );
      }
      if (parsedSynced == null && !best.hasPlain) {
        return (resolution: null, failed: false);
      }
      final source = parsedSynced != null
          ? LyricsSource.lrclibSynced
          : LyricsSource.lrclibPlain;
      final resolvedLyrics =
          parsedSynced ?? LyricsList(value: best.plainLyrics);

      await _libraryDao.upsertExternalLyricsCache(
        songId: songId,
        source: source.name,
        syncedLyrics: best.syncedLyrics,
        plainLyrics: best.plainLyrics,
        ttlSeconds: lyricsCacheTtlSeconds,
        failureCount: 0,
        lastFailedAt: null,
      );
      AppLogger.info('Lyrics source resolved: ${source.name} for song=$songId');
      return (
        resolution: LyricsResolution(lyrics: resolvedLyrics, source: source),
        failed: false,
      );
    } on LrclibRateLimitedException {
      return (resolution: null, failed: true);
    } on DioException catch (error) {
      AppLogger.warning(
        'Lyrics: LRCLIB lookup failed for $songId: ${error.message}',
      );
      return (resolution: null, failed: true);
    } on Object catch (error) {
      AppLogger.warning('Lyrics: LRCLIB lookup failed for $songId: $error');
      return (resolution: null, failed: true);
    }
  }

  Future<LrclibLyrics?> _findBestLrclibMatch(
    LyricsLookupMetadata metadata,
  ) async {
    final expected = LrclibMatchCandidate(
      artist: metadata.artist,
      title: metadata.title,
      album: metadata.album,
      durationSeconds: metadata.durationSeconds,
    );

    LrclibLyrics? best;
    var bestScore = 0.0;
    var bestSameEdition = false;

    final candidates = await _lrclibClient.searchLyrics(
      artist: metadata.artist,
      title: metadata.title,
      background: background,
      cancelToken: cancelToken,
    );
    for (final candidate in candidates) {
      final score = _scoreLrclibResult(expected, candidate);
      if (score.value < 0.7) continue;
      // A different version of the song (another language, acoustic, ...)
      // has other lyrics, so it is only used when no same-version result
      // passes.
      final better = score.sameEdition == bestSameEdition
          ? score.value > bestScore ||
                (score.value == bestScore &&
                    best?.instrumental == true &&
                    (candidate.hasSynced || candidate.hasPlain))
          : score.sameEdition;
      if (better) {
        best = candidate;
        bestScore = score.value;
        bestSameEdition = score.sameEdition;
      }
    }
    if (best != null) {
      return best;
    }

    final direct = await _lrclibClient.getLyrics(
      artist: metadata.artist,
      title: metadata.title,
      album: metadata.album,
      duration: metadata.durationSeconds,
      background: background,
      cancelToken: cancelToken,
    );
    if (direct == null) {
      return null;
    }
    final score = _scoreLrclibResult(expected, direct);
    return score.value >= 0.7 ? direct : null;
  }

  LrclibMatchScore _scoreLrclibResult(
    LrclibMatchCandidate expected,
    LrclibLyrics lyrics,
  ) {
    return scoreCandidate(
      expected: expected,
      candidate: LrclibMatchCandidate(
        artist: lyrics.artistName,
        title: lyrics.trackName,
        album: lyrics.albumName,
        durationSeconds: lyrics.duration,
      ),
    );
  }

  Future<_LyricsLookupResult> _resolveWithServer({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required bool cacheServerLyrics,
    required int lyricsCacheTtlSeconds,
  }) async {
    final api = _apiClient;
    if (api == null) {
      return (resolution: null, failed: false);
    }

    var failed = false;
    try {
      final serverLyrics = await api.getLyricsBySongId(songId);
      final source = resolveServerLyricsSource(serverLyrics);
      if (source != null) {
        if (cacheServerLyrics) {
          await _cacheServerLyrics(
            songId: songId,
            source: source,
            lyrics: serverLyrics,
            ttlSeconds: lyricsCacheTtlSeconds,
          );
        }
        return (
          resolution: LyricsResolution(lyrics: serverLyrics, source: source),
          failed: false,
        );
      }
    } on SubsonicException {
      failed = true;
    }

    if (metadata == null) {
      return (resolution: null, failed: failed);
    }

    try {
      final legacy = await api.getLyrics(
        artist: metadata.artist,
        title: metadata.title,
      );
      if (hasAnyLyrics(legacy)) {
        if (cacheServerLyrics) {
          await _cacheServerLyrics(
            songId: songId,
            source: LyricsSource.serverPlain,
            lyrics: legacy,
            ttlSeconds: lyricsCacheTtlSeconds,
          );
        }
        return (
          resolution: LyricsResolution(
            lyrics: legacy,
            source: LyricsSource.serverPlain,
          ),
          failed: false,
        );
      }
    } on SubsonicException {
      failed = true;
    }

    return (resolution: null, failed: failed);
  }

  Future<void> _cacheServerLyrics({
    required String songId,
    required LyricsSource source,
    required LyricsList lyrics,
    required int ttlSeconds,
    int failureCount = 0,
    DateTime? lastFailedAt,
  }) async {
    if (source == LyricsSource.serverSynced) {
      final synced = lyrics.structuredLyrics
          .where((entry) => entry.line.any((line) => line.start != null))
          .firstOrNull;
      if (synced != null) {
        await _libraryDao.upsertExternalLyricsCache(
          songId: songId,
          source: source.name,
          syncedLyrics: structuredLyricsToLrc(synced.line),
          ttlSeconds: ttlSeconds,
        );
        return;
      }
    }

    final plain = plainLyricsText(lyrics);
    if (plain.trim().isEmpty) {
      return;
    }
    final cached = await _libraryDao.getExternalLyricsCache(songId);
    // Refreshing known plain lyrics must not reopen an instrumental upgrade.
    if (cached?.instrumental == true &&
        cached?.plainLyrics?.trim().isNotEmpty == true) {
      return;
    }
    await _libraryDao.upsertExternalLyricsCache(
      songId: songId,
      source: LyricsSource.serverPlain.name,
      plainLyrics: plain,
      ttlSeconds: ttlSeconds,
      failureCount: failureCount,
      lastFailedAt: lastFailedAt,
    );
  }
}

extension on LyricsSource {
  bool get isSynced {
    return this == LyricsSource.serverSynced ||
        this == LyricsSource.lrclibSynced;
  }

  bool get isServer {
    return this == LyricsSource.serverSynced ||
        this == LyricsSource.serverPlain;
  }
}

LyricsSource? resolveServerLyricsSource(LyricsList lyrics) {
  if (lyrics.structuredLyrics.isNotEmpty) {
    final first = lyrics.structuredLyrics.first;
    final hasSynced = first.line.any((line) => line.start != null);
    if (hasSynced) {
      return LyricsSource.serverSynced;
    }
    final hasUnsyncedLine = first.line.any(
      (line) => (line.value ?? '').trim().isNotEmpty,
    );
    if (hasUnsyncedLine) {
      return LyricsSource.serverPlain;
    }
  }
  if ((lyrics.value ?? '').trim().isNotEmpty) {
    return LyricsSource.serverPlain;
  }
  return null;
}

/// Plain text of [lyrics]: `value`, else the non-empty structured lines. The
/// server sends unsynced lyrics as structured lines without a start time.
String plainLyricsText(LyricsList lyrics) {
  if (lyrics.value?.trim().isNotEmpty == true) return lyrics.value!;
  return lyrics.structuredLyrics
      .expand((entry) => entry.line)
      .map((line) => line.value ?? '')
      .where((line) => line.trim().isNotEmpty)
      .join('\n');
}

bool hasAnyLyrics(LyricsList lyrics) {
  return resolveServerLyricsSource(lyrics) != null;
}

String? preferNonEmpty(String? primary, String? fallback) {
  final trimmedPrimary = primary?.trim();
  if (trimmedPrimary != null && trimmedPrimary.isNotEmpty) {
    return trimmedPrimary;
  }
  final trimmedFallback = fallback?.trim();
  if (trimmedFallback != null && trimmedFallback.isNotEmpty) {
    return trimmedFallback;
  }
  return null;
}

LyricsResolution? lyricsResolutionFromExternalCache(
  ExternalLyricsCacheTableData cache,
) {
  final source = switch (cache.source) {
    'lrclibSynced' || 'lrclib_synced' => LyricsSource.lrclibSynced,
    'lrclibPlain' || 'lrclib_plain' => LyricsSource.lrclibPlain,
    'serverSynced' => LyricsSource.serverSynced,
    'serverPlain' => LyricsSource.serverPlain,
    _ => null,
  };
  if (source == null) {
    return null;
  }

  if (source == LyricsSource.serverSynced ||
      source == LyricsSource.lrclibSynced) {
    final synced = tryParseLrc(cache.syncedLyrics);
    if (synced != null) {
      return LyricsResolution(lyrics: synced, source: source);
    }
  }

  final plain = cache.plainLyrics;
  if (plain != null && plain.trim().isNotEmpty) {
    return LyricsResolution(
      lyrics: LyricsList(value: plain),
      source:
          source == LyricsSource.serverSynced ||
              source == LyricsSource.serverPlain
          ? LyricsSource.serverPlain
          : LyricsSource.lrclibPlain,
    );
  }
  if (cache.instrumental) {
    return LyricsResolution(
      lyrics: const LyricsList(),
      source: source,
      instrumental: true,
    );
  }
  return null;
}

LyricsList? tryParseLrc(String? lrc) {
  if (lrc == null || lrc.trim().isEmpty) {
    return null;
  }
  final regex = RegExp(r'^\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\](.*)$');
  final parsed = <LyricLine>[];

  for (final raw in lrc.split('\n')) {
    final line = raw.trim();
    final match = regex.firstMatch(line);
    if (match == null) {
      continue;
    }

    final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
    final fractionText = match.group(3);
    final fraction = int.tryParse(fractionText ?? '') ?? 0;
    final millis = fractionText == null
        ? 0
        : fractionText.length == 3
        ? fraction
        : fraction * 10;
    final start = minutes * 60000 + seconds * 1000 + millis;
    parsed.add(LyricLine(start: start, value: (match.group(4) ?? '').trim()));
  }

  if (parsed.isEmpty) {
    return null;
  }

  parsed.sort((a, b) => (a.start ?? 0).compareTo(b.start ?? 0));
  final lines = <LyricLine>[];
  for (var i = 0; i < parsed.length; i++) {
    final current = parsed[i];
    final nextStart = i + 1 < parsed.length ? parsed[i + 1].start : null;
    final duration = (current.start != null && nextStart != null)
        ? (nextStart - current.start!).clamp(0, 60000)
        : null;
    lines.add(
      LyricLine(start: current.start, duration: duration, value: current.value),
    );
  }

  return LyricsList(
    structuredLyrics: <StructuredLyrics>[
      StructuredLyrics(synced: true, line: lines),
    ],
  );
}

String structuredLyricsToLrc(List<LyricLine> lines) {
  final buffer = StringBuffer();
  for (final line in lines) {
    final milliseconds = line.start ?? 0;
    final minutes = milliseconds ~/ 60000;
    final seconds = (milliseconds % 60000) ~/ 1000;
    final centiseconds = (milliseconds % 1000) ~/ 10;
    final timestamp =
        '${minutes.toString().padLeft(2, '0')}'
        ':${seconds.toString().padLeft(2, '0')}'
        '.${centiseconds.toString().padLeft(2, '0')}';
    buffer.writeln('[$timestamp]${line.value ?? ''}');
  }
  return buffer.toString().trimRight();
}
