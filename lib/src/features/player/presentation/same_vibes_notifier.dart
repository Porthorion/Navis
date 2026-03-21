import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Number of remaining tracks (after the current one) that triggers refill.
const _kRefillThreshold = 3;

/// Target number of tracks to queue per refill.
const _kTargetQueueBatchSize = 5;

/// Last.fm recommendation request limit per refill.
const _kLastFmRecommendationLimit = 20;

/// Maximum Last.fm recommendations to map with `search3`.
const _kMaxSearchAttempts = 10;

/// Number of song candidates to inspect per `search3` query.
const _kSearchSongCount = 8;

/// Use Subsonic similar fallback when Last.fm mapping yields fewer than this.
const _kMinimumMappedTracksBeforeFallback = 2;

/// Guard against rapid repeated refill attempts from playback ticks.
const _kMinimumRefillInterval = Duration(milliseconds: 1200);

/// Retry window base/cap for transient failures.
const _kRetryBackoffBase = Duration(seconds: 3);
const _kRetryBackoffMax = Duration(seconds: 45);
const _kRetryJitterMaxMs = 600;

/// Flush incremental mapped results to queue in this chunk size.
const _kIncrementalQueueFlushChunkSize = 3;

/// Bounded concurrent `search3` fan-out for Last.fm mapping.
const _kMappingParallelism = 5;

/// Minimum confidence required to map Last.fm recommendation -> Subsonic song.
const _kMinimumMappingScore = 0.62;

/// Auto-refill notifier for Last.fm-backed Same Vibes mode.
class SameVibesNotifier extends Notifier<SameVibesState> {
  final math.Random _random = math.Random();
  Timer? _retryTimer;
  DateTime? _nextRefillAllowedAt;
  int _consecutiveTransientFailures = 0;

  @override
  SameVibesState build() {
    ref.listen<PlaybackSnapshot>(playerStateProvider, _onSnapshotChanged);
    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
    });
    return const SameVibesState.inactive();
  }

  Future<void> activate(String seedSongId) async {
    state = SameVibesState(
      active: true,
      seedSongId: seedSongId,
    );
    await _refill(isInitial: true);
  }

  void deactivate() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRefillAllowedAt = null;
    _consecutiveTransientFailures = 0;
    state = const SameVibesState.inactive();
  }

  Future<void> toggle(String? currentSongId) async {
    if (state.active) {
      deactivate();
    } else if (currentSongId != null && currentSongId.trim().isNotEmpty) {
      await activate(currentSongId.trim());
    }
  }

  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  void clearSnackbar() {
    if (state.pendingSnackbar != null) {
      state = state.copyWith(clearSnackbar: true);
    }
  }

  void _onSnapshotChanged(PlaybackSnapshot? prev, PlaybackSnapshot next) {
    if (!state.active) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error == SameVibesError.unsupported) {
      return;
    }

    if (next.queueSongIds.isEmpty) {
      state = const SameVibesState.inactive();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final remaining = next.queueSongIds.length - currentIndex - 1;
    if (remaining <= _kRefillThreshold) {
      unawaited(_refill());
    }
  }

  Future<void> _refill({bool isInitial = false}) async {
    if (state.refilling) return;
    final now = DateTime.now();
    final nextAllowed = _nextRefillAllowedAt;
    if (!isInitial && nextAllowed != null && now.isBefore(nextAllowed)) {
      AppLogger.debug(
        'SameVibes diagnostics: refill skipped (backoff active '
        'until=${nextAllowed.toIso8601String()})',
      );
      return;
    }

    final snapshot = ref.read(playerStateProvider);
    final seedSongId = snapshot.currentSongId ?? state.seedSongId;
    if (seedSongId == null || seedSongId.trim().isEmpty) {
      AppLogger.debug('SameVibes diagnostics: refill skipped (missing seed)');
      return;
    }
    final normalizedSeedSongId = seedSongId.trim();
    _nextRefillAllowedAt = now.add(_kMinimumRefillInterval);
    _retryTimer?.cancel();
    _retryTimer = null;

    state = state.copyWith(
      refilling: true,
      seedSongId: normalizedSeedSongId,
      clearError: true,
    );
    AppLogger.debug(
      'SameVibes diagnostics: refill start '
      'seedSongId=$normalizedSeedSongId '
      'queueSize=${snapshot.queueSongIds.length} '
      'currentIndex=${snapshot.currentIndex} '
      'isInitial=$isInitial',
    );

    try {
      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        AppLogger.debug(
          'SameVibes diagnostics: refill aborted (subsonic api unavailable)',
        );
        state = state.copyWith(refilling: false);
        return;
      }

      final queuedIds = snapshot.queueSongIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final queuedSongKeys = <String>{
        ...await _readQueueCanonicalSongKeys(snapshot.queueSongIds),
      };

      final seed = await _resolveSeedMetadata(
        api: api,
        seedSongId: normalizedSeedSongId,
      );
      final candidatePreferences = _CandidatePreferenceContext(
        downloadedSongIds: await _readPreferenceSongIds(
          downloadedSongIdsProvider,
        ),
        cachedSongIds: await _readPreferenceSongIds(cachedSongIdsProvider),
      );
      AppLogger.debug(
        'SameVibes diagnostics: preferencePool '
        'downloaded=${candidatePreferences.downloadedSongIds.length} '
        'cached=${candidatePreferences.cachedSongIds.length}',
      );
      LastFmTrackFetchResult lastFmResult = const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.noResults,
        tracks: <LastFmTrackRecommendation>[],
      );
      var mappedSongCount = 0;
      if (seed != null) {
        lastFmResult = await _fetchLastFmRecommendations(
          expectedArtist: seed.artist,
          expectedTitle: seed.title,
        );
        AppLogger.debug(
          'SameVibes diagnostics: seed resolved artist="${seed.artist}" '
          'title="${seed.title}"',
        );
        if (lastFmResult.outcome == LastFmFetchOutcome.success &&
            lastFmResult.tracks.isNotEmpty) {
          mappedSongCount = await _mapLastFmRecommendationsIncremental(
            api: api,
            recommendations: lastFmResult.tracks,
            blockedIds: queuedIds,
            blockedSongKeys: queuedSongKeys,
            preferences: candidatePreferences,
            onChunk: (chunk) async {
              if (chunk.isEmpty || !state.active) {
                return 0;
              }
              await ref.read(queueProvider.notifier).addWithSongs(chunk);
              for (final song in chunk) {
                final id = song.id.trim();
                if (id.isNotEmpty) {
                  queuedIds.add(id);
                }
                final key = _canonicalSongKey(song.artist ?? '', song.title);
                if (key != null) {
                  queuedSongKeys.add(key);
                }
              }
              AppLogger.debug(
                'SameVibes diagnostics: queued incremental chunk=${chunk.length}',
              );
              return chunk.length;
            },
          );
        }
      } else {
        AppLogger.debug(
          'SameVibes diagnostics: seed metadata unavailable '
          '(lastfm mapping skipped)',
        );
      }
      final mappedBeforeFallback = mappedSongCount;
      AppLogger.debug(
        'SameVibes diagnostics: mappedBeforeFallback=$mappedBeforeFallback',
      );

      if (!state.active) {
        AppLogger.debug(
          'SameVibes diagnostics: refill canceled (state inactive after mapping)',
        );
        state = state.copyWith(refilling: false);
        return;
      }

      var fallbackQueued = 0;
      var fallbackDecision = 'skip';
      var fallbackReason = 'not_needed';
      var fallbackSeedEligible = false;
      final shouldAttemptFallback = switch (lastFmResult.outcome) {
        LastFmFetchOutcome.success =>
          mappedSongCount < _kMinimumMappedTracksBeforeFallback,
        LastFmFetchOutcome.noResults || LastFmFetchOutcome.apiError =>
          mappedSongCount < _kMinimumMappedTracksBeforeFallback,
        LastFmFetchOutcome.networkError ||
        LastFmFetchOutcome.parseError => false,
        LastFmFetchOutcome.notConfigured => false,
      };

      if (lastFmResult.outcome == LastFmFetchOutcome.notConfigured) {
        AppLogger.debug(
          'SameVibes diagnostics: refill decision '
          'lastfmOutcome=${lastFmResult.outcome.name} mapped=$mappedSongCount '
          'fallbackDecision=skip fallbackReason=lastfm_not_configured '
          'seedEligible=false',
        );
        state = const SameVibesState(error: SameVibesError.unsupported);
        return;
      }

      if (shouldAttemptFallback) {
        final fallbackSeedSongId = _resolveFallbackSeedSongId(
          snapshot: snapshot,
          preferredSeedSongId: normalizedSeedSongId,
        );
        fallbackSeedEligible = fallbackSeedSongId != null;
        if (fallbackSeedSongId == null) {
          fallbackDecision = 'skip';
          fallbackReason = 'seed_not_server_addressable';
        } else {
          fallbackDecision = 'attempt';
          fallbackReason = 'mapped_below_threshold';
        }
      } else if (lastFmResult.outcome == LastFmFetchOutcome.networkError) {
        fallbackReason = 'lastfm_network_error';
      } else if (lastFmResult.outcome == LastFmFetchOutcome.parseError) {
        fallbackReason = 'lastfm_parse_error';
      } else {
        fallbackReason = 'mapping_sufficient';
      }

      AppLogger.debug(
        'SameVibes diagnostics: refill decision '
        'lastfmOutcome=${lastFmResult.outcome.name} mapped=$mappedSongCount '
        'fallbackDecision=$fallbackDecision fallbackReason=$fallbackReason '
        'seedEligible=$fallbackSeedEligible',
      );

      if (shouldAttemptFallback && fallbackSeedEligible) {
        final fallbackSeedSongId = _resolveFallbackSeedSongId(
          snapshot: snapshot,
          preferredSeedSongId: normalizedSeedSongId,
        );
        if (fallbackSeedSongId != null) {
          AppLogger.debug(
            'SameVibes diagnostics: fallback engaged '
            'reason="mapped<$_kMinimumMappedTracksBeforeFallback" '
            'mapped=$mappedSongCount seed=$fallbackSeedSongId',
          );
          try {
            final fallback = await api.getSimilarSongs(
              fallbackSeedSongId,
              count: _kTargetQueueBatchSize,
            );
            AppLogger.debug(
              'SameVibes diagnostics: fallback candidates=${fallback.length}',
            );
            final fallbackSongs = _mergeUniqueSongs(
              primary: const <Song>[],
              fallback: fallback,
              excludedIds: queuedIds,
              excludedSongKeys: queuedSongKeys,
              targetCount: _kTargetQueueBatchSize - mappedSongCount,
            );
            if (fallbackSongs.isNotEmpty) {
              await ref
                  .read(queueProvider.notifier)
                  .addWithSongs(fallbackSongs);
              for (final song in fallbackSongs) {
                final id = song.id.trim();
                if (id.isNotEmpty) {
                  queuedIds.add(id);
                }
                final key = _canonicalSongKey(song.artist ?? '', song.title);
                if (key != null) {
                  queuedSongKeys.add(key);
                }
              }
              fallbackQueued = fallbackSongs.length;
            }
            AppLogger.debug(
              'SameVibes diagnostics: mergedAfterFallback='
              '${mappedSongCount + fallbackQueued}',
            );
          } on SubsonicNotFoundException catch (error) {
            final endpointUnsupported = _isEndpointUnsupportedMessage(
              error.message,
            );
            AppLogger.debug(
              'SameVibes diagnostics: fallback notfound '
              'code=${error.code} message="${error.message}" '
              'endpointUnsupported=$endpointUnsupported',
            );
            if (endpointUnsupported) {
              state = const SameVibesState(error: SameVibesError.unsupported);
              return;
            }
            fallbackReason = 'fallback_seed_not_found';
          } on SubsonicApiException catch (error) {
            AppLogger.debug(
              'SameVibes diagnostics: fallback api_error '
              'code=${error.code} message="${error.message}"',
            );
            fallbackReason = 'fallback_api_error';
          } on SubsonicException catch (error) {
            AppLogger.debug(
              'SameVibes diagnostics: fallback transport_error '
              'message="${error.message}"',
            );
            fallbackReason = 'fallback_transport_error';
          }
        }
      }

      if (mappedSongCount < _kMinimumMappedTracksBeforeFallback &&
          !shouldAttemptFallback) {
        AppLogger.debug(
          'SameVibes diagnostics: fallback skipped '
          'reason=$fallbackReason mapped=$mappedSongCount',
        );
      }

      if (!state.active) {
        AppLogger.debug(
          'SameVibes diagnostics: refill canceled (state inactive post-fallback)',
        );
        state = state.copyWith(refilling: false);
        return;
      }

      final totalQueued = mappedSongCount + fallbackQueued;
      if (totalQueued <= 0) {
        AppLogger.debug(
          'SameVibes diagnostics: no tracks queued (empty result after fallback)',
        );
        _scheduleTransientRetry(reason: fallbackReason);
      } else {
        AppLogger.debug(
          'SameVibes diagnostics: queuedTracks=$totalQueued',
        );
        _consecutiveTransientFailures = 0;
        _nextRefillAllowedAt = DateTime.now().add(_kMinimumRefillInterval);
      }

      state = state.copyWith(
        refilling: false,
        pendingSnackbar: isInitial ? '$totalQueued' : null,
      );
    } on Exception catch (error) {
      AppLogger.debug('SameVibes refill error: $error');
      _scheduleTransientRetry(reason: 'unexpected_exception');
      state = state.copyWith(
        refilling: false,
        error: SameVibesError.networkError,
      );
    }
  }

  Future<_SeedMetadata?> _resolveSeedMetadata({
    required SubsonicApiClient api,
    required String seedSongId,
  }) async {
    final mediaItem = ref.read(currentMediaItemProvider).asData?.value;
    final mediaTitle = mediaItem?.title.trim() ?? '';
    final mediaArtist = mediaItem?.artist?.trim() ?? '';
    if (mediaTitle.isNotEmpty && mediaArtist.isNotEmpty) {
      return _SeedMetadata(title: mediaTitle, artist: mediaArtist);
    }

    try {
      final song = await api.getSong(seedSongId);
      final title = song.title.trim();
      final artist = (song.artist ?? '').trim();
      if (title.isEmpty || artist.isEmpty) {
        return null;
      }
      return _SeedMetadata(title: title, artist: artist);
    } on Exception {
      return null;
    }
  }

  Future<int> _mapLastFmRecommendationsIncremental({
    required SubsonicApiClient api,
    required List<LastFmTrackRecommendation> recommendations,
    required Set<String> blockedIds,
    required Set<String> blockedSongKeys,
    required _CandidatePreferenceContext preferences,
    required Future<int> Function(List<Song> chunk) onChunk,
  }) async {
    if (recommendations.isEmpty) {
      return 0;
    }

    final sortedRecs = [...recommendations]
      ..sort((a, b) => (b.match ?? 0).compareTo(a.match ?? 0));

    final attemptsLimit = sortedRecs
        .take(_kMaxSearchAttempts)
        .toList(
          growable: false,
        );
    var attempts = 0;
    var misses = 0;
    var mappedCount = 0;
    final pendingChunk = <Song>[];

    for (
      var batchStart = 0;
      batchStart < attemptsLimit.length;
      batchStart += _kMappingParallelism
    ) {
      if (!state.active || mappedCount >= _kTargetQueueBatchSize) {
        break;
      }
      final batchEnd = math.min(
        attemptsLimit.length,
        batchStart + _kMappingParallelism,
      );
      final batch = attemptsLimit.sublist(batchStart, batchEnd);
      final resolutions = await Future.wait(
        batch.map(
          (rec) => _resolveBestCandidate(
            api: api,
            recommendation: rec,
            preferences: preferences,
          ),
        ),
      );

      for (final best in resolutions) {
        if (!state.active || mappedCount >= _kTargetQueueBatchSize) {
          break;
        }
        attempts += 1;
        if (best == null) {
          misses += 1;
          continue;
        }
        final id = best.id.trim();
        if (id.isEmpty || blockedIds.contains(id)) {
          misses += 1;
          continue;
        }
        final key = _canonicalSongKey(best.artist ?? '', best.title);
        if (key != null && blockedSongKeys.contains(key)) {
          misses += 1;
          continue;
        }
        pendingChunk.add(best);
        blockedIds.add(id);
        if (key != null) {
          blockedSongKeys.add(key);
        }
        mappedCount += 1;

        if (pendingChunk.length >= _kIncrementalQueueFlushChunkSize) {
          final flushed = await onChunk(List<Song>.from(pendingChunk));
          if (flushed <= 0 || !state.active) {
            pendingChunk.clear();
            break;
          }
          pendingChunk.clear();
        }
      }
    }

    if (state.active && pendingChunk.isNotEmpty) {
      final flushed = await onChunk(List<Song>.from(pendingChunk));
      if (flushed > 0) {
        pendingChunk.clear();
      }
    }
    AppLogger.debug(
      'SameVibes diagnostics: mappingSummary '
      'mapped=$mappedCount attempts=$attempts misses=$misses '
      'excluded=${blockedIds.length}',
    );

    return mappedCount;
  }

  Future<LastFmTrackFetchResult> _fetchLastFmRecommendations({
    required String expectedArtist,
    required String expectedTitle,
  }) async {
    final client = ref.read(lastFmApiClientProvider);
    if (client == null) {
      AppLogger.debug(
        'SameVibes diagnostics: lastfm unavailable (client not configured)',
      );
      return const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.notConfigured,
        tracks: <LastFmTrackRecommendation>[],
      );
    }

    final result = await client.getSimilarTracksResult(
      artist: expectedArtist,
      track: expectedTitle,
      limit: _kLastFmRecommendationLimit,
    );
    AppLogger.debug(
      'SameVibes diagnostics: lastfm recommendations=${result.tracks.length} '
      'artist="$expectedArtist" track="$expectedTitle" '
      'outcome=${result.outcome.name} '
      'status=${result.statusCode} apiCode=${result.apiErrorCode}',
    );
    return result;
  }

  String? _resolveFallbackSeedSongId({
    required PlaybackSnapshot snapshot,
    required String preferredSeedSongId,
  }) {
    if (_isServerAddressableSeedId(preferredSeedSongId)) {
      return preferredSeedSongId;
    }

    final queue = snapshot.queueSongIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (queue.isEmpty) {
      return null;
    }

    final currentIndex = (snapshot.currentIndex ?? 0).clamp(
      0,
      queue.length - 1,
    );
    for (var distance = 0; distance < queue.length; distance++) {
      final left = currentIndex - distance;
      if (left >= 0) {
        final id = queue[left];
        if (_isServerAddressableSeedId(id)) {
          return id;
        }
      }
      if (distance == 0) {
        continue;
      }
      final right = currentIndex + distance;
      if (right < queue.length) {
        final id = queue[right];
        if (_isServerAddressableSeedId(id)) {
          return id;
        }
      }
    }

    return null;
  }

  bool _isServerAddressableSeedId(String id) {
    final normalized = id.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    if (normalized.startsWith('ext-') || normalized.startsWith('remote-')) {
      return false;
    }
    return true;
  }

  bool _isEndpointUnsupportedMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('endpoint') ||
        normalized.contains('not found on this server') ||
        normalized.contains('not support') ||
        normalized.contains('unsupported');
  }

  void _scheduleTransientRetry({required String reason}) {
    if (!state.active) {
      return;
    }
    _consecutiveTransientFailures += 1;
    final delay = _computeRetryDelay();
    final nextAt = DateTime.now().add(delay);
    _nextRefillAllowedAt = nextAt;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!state.active || state.refilling) {
        return;
      }
      unawaited(_refill());
    });
    AppLogger.debug(
      'SameVibes diagnostics: retry scheduled '
      'reason=$reason failures=$_consecutiveTransientFailures '
      'delayMs=${delay.inMilliseconds}',
    );
  }

  Duration _computeRetryDelay() {
    final exponent = (_consecutiveTransientFailures - 1).clamp(0, 6);
    final multiplier = 1 << exponent;
    final baseMs = _kRetryBackoffBase.inMilliseconds * multiplier;
    final cappedMs = math.min(baseMs, _kRetryBackoffMax.inMilliseconds);
    final jitterMs = _random.nextInt(_kRetryJitterMaxMs + 1);
    return Duration(milliseconds: cappedMs + jitterMs);
  }

  Future<Song?> _resolveBestCandidate({
    required SubsonicApiClient api,
    required LastFmTrackRecommendation recommendation,
    required _CandidatePreferenceContext preferences,
  }) async {
    final query = '${recommendation.artist} ${recommendation.title}'.trim();
    if (query.isEmpty) {
      return null;
    }
    final search = await api.search3(
      query: query,
      artistCount: 0,
      albumCount: 0,
      songCount: _kSearchSongCount,
    );
    final albumSongCounts = await _readAlbumSongCounts(search.songs);
    return _pickBestCandidate(
      recommendation: recommendation,
      songs: search.songs,
      blockedIds: const <String>{},
      preferences: preferences,
      albumSongCounts: albumSongCounts,
    );
  }

  Song? _pickBestCandidate({
    required LastFmTrackRecommendation recommendation,
    required List<Song> songs,
    required Set<String> blockedIds,
    required _CandidatePreferenceContext preferences,
    required Map<String, int?> albumSongCounts,
  }) {
    Song? best;
    var bestScore = 0.0;
    var bestAlbumRank = -1;
    var bestAvailabilityRank = -1;

    for (final candidate in songs) {
      final id = candidate.id.trim();
      if (id.isEmpty || blockedIds.contains(id)) {
        continue;
      }
      final score = _scoreSongCandidate(
        recommendation: recommendation,
        candidate: candidate,
      );
      final availabilityRank = _availabilityRank(
        songId: id,
        preferences: preferences,
      );
      final albumRank = _albumBackedRank(
        candidate: candidate,
        albumSongCounts: albumSongCounts,
      );
      final nearTie = (score - bestScore).abs() <= _kAvailabilityTieWindow;
      final shouldReplace =
          score > bestScore ||
          (nearTie &&
              (albumRank > bestAlbumRank ||
                  (albumRank == bestAlbumRank &&
                      availabilityRank > bestAvailabilityRank)));
      if (shouldReplace) {
        best = candidate;
        bestScore = score;
        bestAlbumRank = albumRank;
        bestAvailabilityRank = availabilityRank;
      }
    }

    if (best == null || bestScore < _kMinimumMappingScore) {
      return null;
    }
    return best;
  }

  double _scoreSongCandidate({
    required LastFmTrackRecommendation recommendation,
    required Song candidate,
  }) {
    final expectedTitle = normalizeMetadata(recommendation.title);
    final expectedArtist = normalizeMetadata(recommendation.artist);
    final candidateTitle = normalizeMetadata(candidate.title);
    final candidateArtist = normalizeMetadata(candidate.artist ?? '');

    if (expectedTitle.isEmpty ||
        expectedArtist.isEmpty ||
        candidateTitle.isEmpty ||
        candidateArtist.isEmpty) {
      return 0;
    }

    final titleScore = _fieldScore(
      expected: expectedTitle,
      actual: candidateTitle,
      exactWeight: 0.58,
      partialWeight: 0.42,
      tokenWeight: 0.42,
    );
    final artistScore = _fieldScore(
      expected: expectedArtist,
      actual: candidateArtist,
      exactWeight: 0.42,
      partialWeight: 0.30,
      tokenWeight: 0.30,
    );

    return math.max(0, math.min(1, titleScore + artistScore));
  }

  double _fieldScore({
    required String expected,
    required String actual,
    required double exactWeight,
    required double partialWeight,
    required double tokenWeight,
  }) {
    if (expected == actual) {
      return exactWeight;
    }
    if (expected.contains(actual) || actual.contains(expected)) {
      return partialWeight;
    }
    return _tokenOverlap(expected, actual) * tokenWeight;
  }

  double _tokenOverlap(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((token) => token.isNotEmpty).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) {
      return 0;
    }
    final overlap = aTokens.intersection(bTokens).length;
    return overlap / math.max(aTokens.length, bTokens.length);
  }

  Future<Set<String>> _readPreferenceSongIds(
    StreamProvider<Set<String>> provider,
  ) async {
    final current = ref.read(provider);
    if (current.hasValue) {
      return Set<String>.from(current.requireValue);
    }
    try {
      final resolved = await ref
          .read(provider.future)
          .timeout(const Duration(milliseconds: 150));
      return Set<String>.from(resolved);
    } on Exception {
      return const <String>{};
    }
  }

  int _availabilityRank({
    required String songId,
    required _CandidatePreferenceContext preferences,
  }) {
    if (preferences.downloadedSongIds.contains(songId)) {
      return 2;
    }
    if (preferences.cachedSongIds.contains(songId)) {
      return 1;
    }
    return 0;
  }

  int _albumBackedRank({
    required Song candidate,
    required Map<String, int?> albumSongCounts,
  }) {
    final albumId = (candidate.albumId ?? '').trim();
    if (albumId.isEmpty) {
      return 0;
    }

    final knownSongCount = albumSongCounts[albumId];
    if (knownSongCount != null) {
      return knownSongCount > 1 ? 3 : 1;
    }

    final normalizedAlbum = normalizeMetadata(candidate.album ?? '');
    final normalizedTitle = normalizeMetadata(candidate.title);
    if (normalizedAlbum.isNotEmpty && normalizedAlbum != normalizedTitle) {
      return 2;
    }
    return 1;
  }

  Future<Map<String, int?>> _readAlbumSongCounts(List<Song> songs) async {
    final albumIds = songs
        .map((song) => (song.albumId ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (albumIds.isEmpty) {
      return const <String, int?>{};
    }
    try {
      final lookup = ref.read(sameVibesAlbumSongCountLookupProvider);
      return await lookup(albumIds);
    } on Object {
      return const <String, int?>{};
    }
  }

  Future<Set<String>> _readQueueCanonicalSongKeys(
    Iterable<String> queueSongIds,
  ) async {
    try {
      final lookup = ref.read(sameVibesQueueSongKeyLookupProvider);
      return await lookup(queueSongIds);
    } on Object {
      return const <String>{};
    }
  }

  String? _canonicalSongKey(String artist, String title) {
    final normalizedArtist = normalizeMetadata(artist);
    final normalizedTitle = normalizeMetadata(title);
    if (normalizedArtist.isEmpty || normalizedTitle.isEmpty) {
      return null;
    }
    return '$normalizedArtist|$normalizedTitle';
  }

  List<Song> _mergeUniqueSongs({
    required List<Song> primary,
    required List<Song> fallback,
    required Set<String> excludedIds,
    required Set<String> excludedSongKeys,
    required int targetCount,
  }) {
    final merged = <Song>[];
    final seen = <String>{...excludedIds};
    final seenSongKeys = <String>{...excludedSongKeys};

    void push(Song song) {
      if (merged.length >= targetCount) {
        return;
      }
      final id = song.id.trim();
      if (id.isEmpty || seen.contains(id)) {
        return;
      }
      final key = _canonicalSongKey(song.artist ?? '', song.title);
      if (key != null && seenSongKeys.contains(key)) {
        return;
      }
      merged.add(song);
      seen.add(id);
      if (key != null) {
        seenSongKeys.add(key);
      }
    }

    primary.forEach(push);
    fallback.forEach(push);
    return merged;
  }
}

class _SeedMetadata {
  const _SeedMetadata({
    required this.artist,
    required this.title,
  });

  final String artist;
  final String title;
}

class _CandidatePreferenceContext {
  const _CandidatePreferenceContext({
    required this.downloadedSongIds,
    required this.cachedSongIds,
  });

  final Set<String> downloadedSongIds;
  final Set<String> cachedSongIds;
}

/// Only apply availability preference when textual match quality is close.
const _kAvailabilityTieWindow = 0.03;

typedef _AlbumSongCountLookup =
    Future<Map<String, int?>> Function(
      Set<String> albumIds,
    );

typedef _QueueSongKeyLookup =
    Future<Set<String>> Function(
      Iterable<String> songIds,
    );

final sameVibesAlbumSongCountLookupProvider = Provider<_AlbumSongCountLookup>((
  ref,
) {
  return (albumIds) async {
    if (albumIds.isEmpty) {
      return const <String, int?>{};
    }
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    return dao.getAlbumSongCountsByIds(albumIds);
  };
});

final sameVibesQueueSongKeyLookupProvider = Provider<_QueueSongKeyLookup>((
  ref,
) {
  return (songIds) async {
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    final songs = await dao.getSongsByIds(songIds);
    final keys = <String>{};
    for (final song in songs) {
      final normalizedArtist = normalizeMetadata(song.artistName ?? '');
      final normalizedTitle = normalizeMetadata(song.title);
      if (normalizedArtist.isEmpty || normalizedTitle.isEmpty) {
        continue;
      }
      keys.add('$normalizedArtist|$normalizedTitle');
    }
    return keys;
  };
});

final sameVibesProvider = NotifierProvider<SameVibesNotifier, SameVibesState>(
  SameVibesNotifier.new,
);
