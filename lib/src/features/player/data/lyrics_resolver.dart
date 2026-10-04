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

typedef LyricsLookupMetadata = ({
  String artist,
  String title,
  String? album,
  int? durationSeconds,
});

class LyricsResolver {
  const new({
    required this._libraryDao,
    required this._lrclibClient,
    required this._apiClient,
  });

  final LibraryDao _libraryDao;
  final LrclibClient _lrclibClient;
  final SubsonicApiClient? _apiClient;

  Future<LyricsResolution> resolve({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required bool useLrclib,
    int lyricsCacheTtlSeconds = normalLyricsCacheTtlSeconds,
    bool cacheServerLyrics = false,
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

      final lrclibResult = await _resolveWithLrclib(
        songId: songId,
        metadata: metadata,
        lyricsCacheTtlSeconds: lyricsCacheTtlSeconds,
      );
      if (lrclibResult != null) {
        return lrclibResult;
      }

      final server = await _resolveWithServer(
        songId: songId,
        metadata: metadata,
        cacheServerLyrics: cacheServerLyrics,
        lyricsCacheTtlSeconds: lyricsCacheTtlSeconds,
      );
      if (server != null) {
        return server;
      }

      if (cachedResolution != null) {
        return cachedResolution;
      }
      return const LyricsResolution(
        lyrics: LyricsList(),
        source: LyricsSource.lrclibPlain,
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
    if (server != null) {
      return server;
    }

    if (cachedResolution != null) {
      return cachedResolution;
    }

    return const LyricsResolution(
      lyrics: LyricsList(),
      source: LyricsSource.serverPlain,
    );
  }

  Future<LyricsResolution?> _resolveWithLrclib({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required int lyricsCacheTtlSeconds,
  }) async {
    if (metadata == null) {
      return null;
    }

    try {
      final best = await _findBestLrclibMatch(metadata);
      if (best == null) {
        return null;
      }

      final parsedSynced = tryParseLrc(best.syncedLyrics);
      if (parsedSynced == null && !best.hasPlain) {
        return null;
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
      return LyricsResolution(lyrics: resolvedLyrics, source: source);
    } on DioException catch (error) {
      AppLogger.warning(
        'Lyrics: LRCLIB lookup failed for $songId: ${error.message}',
      );
      return null;
    } on Object catch (error) {
      AppLogger.warning('Lyrics: LRCLIB lookup failed for $songId: $error');
      return null;
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
    );
    for (final candidate in candidates) {
      final score = _scoreLrclibResult(expected, candidate);
      if (score.value < 0.7) continue;
      // A different version of the song (another language, acoustic, ...)
      // has other lyrics, so it is only used when no same-version result
      // passes.
      final better = score.sameEdition == bestSameEdition
          ? score.value > bestScore
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

  Future<LyricsResolution?> _resolveWithServer({
    required String songId,
    required LyricsLookupMetadata? metadata,
    required bool cacheServerLyrics,
    required int lyricsCacheTtlSeconds,
  }) async {
    final api = _apiClient;
    if (api == null) {
      return null;
    }

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
        return LyricsResolution(lyrics: serverLyrics, source: source);
      }
    } on SubsonicNotFoundException {
      // Continue fallback chain.
    } on SubsonicApiException {
      // Continue fallback chain.
    } on SubsonicConnectionException {
      // Continue fallback chain.
    }

    if (metadata == null) {
      return null;
    }

    try {
      final legacy = await api.getLyrics(
        artist: metadata.artist,
        title: metadata.title,
      );
      if (hasAnyLyrics(legacy)) {
        if (cacheServerLyrics) {
          await _libraryDao.upsertExternalLyricsCache(
            songId: songId,
            source: LyricsSource.serverPlain.name,
            plainLyrics: legacy.value,
            ttlSeconds: lyricsCacheTtlSeconds,
          );
        }
        return LyricsResolution(
          lyrics: legacy,
          source: LyricsSource.serverPlain,
        );
      }
    } on SubsonicException {
      // Continue fallback chain.
    }

    return null;
  }

  Future<void> _cacheServerLyrics({
    required String songId,
    required LyricsSource source,
    required LyricsList lyrics,
    required int ttlSeconds,
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

    final plain = lyrics.value?.trim().isNotEmpty == true
        ? lyrics.value!
        : lyrics.structuredLyrics
              .expand((entry) => entry.line)
              .map((line) => line.value ?? '')
              .where((line) => line.trim().isNotEmpty)
              .join('\n');
    if (plain.trim().isEmpty) {
      return;
    }
    await _libraryDao.upsertExternalLyricsCache(
      songId: songId,
      source: LyricsSource.serverPlain.name,
      plainLyrics: plain,
      ttlSeconds: ttlSeconds,
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
