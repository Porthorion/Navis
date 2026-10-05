import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Number of remaining tracks (after the current one) that triggers refill.
const _kRefillThreshold = 3;

/// Target number of tracks to queue per background refill.
const _kTargetQueueBatchSize = 5;

/// Last.fm recommendation request limit per refill.
const _kLastFmRecommendationLimit = 20;

/// Maximum Last.fm recommendations to map with `search3`.
const _kMaxSearchAttempts = 10;

/// Number of song candidates to inspect per `search3` query.
const _kSearchSongCount = 8;

/// Guard against rapid repeated refill attempts from playback ticks.
const _kMinimumRefillInterval = Duration(milliseconds: 1200);

/// Retry window base/cap for transient failures.
const _kRetryBackoffBase = Duration(seconds: 3);
const _kRetryBackoffMax = Duration(seconds: 45);
const _kRetryJitterMaxMs = 600;

/// Collect incremental mapped results in this chunk size.
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
  int? _mixSegmentEndIndex;
  bool _activationInProgress = false;
  bool _suppressActivationSeedSnapshot = false;
  RecommendationSession? _session;

  @override
  SameVibesState build() {
    ref.listen<PlaybackSnapshot>(playerStateProvider, _onSnapshotChanged);
    ref.listen<int>(regularQueueReplacementEpochProvider, (prev, next) {
      if (state.active) {
        deactivate();
      }
    });
    ref.listen<RecommendationSessionStatus>(recommendationSessionProvider, (
      previous,
      next,
    ) {
      final session = _session;
      if (session != null && next.generation != session.generation) {
        deactivate();
      }
    });
    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
    });
    return const SameVibesState.inactive();
  }

  Future<void> activate(String seedSongId) async {
    final normalizedSeedSongId = seedSongId.trim();
    if (normalizedSeedSongId.isEmpty) {
      return;
    }
    _mixSegmentEndIndex = null;
    final session = ref
        .read(recommendationSessionProvider.notifier)
        .start(RecommendationMode.sameVibes, seedId: normalizedSeedSongId);
    _session = session;
    _activationInProgress = true;
    _suppressActivationSeedSnapshot = true;
    // A fresh state also clears the refilling flag of a refill still running
    // for a superseded mix, so this mix's first refill starts at once.
    state = SameVibesState(active: true, seedSongId: normalizedSeedSongId);
    try {
      await _refill(isInitial: true);
    } finally {
      // A newer activation owns the flag now.
      if (identical(_session, session)) {
        _activationInProgress = false;
      }
    }
  }

  /// Whether [session] is still the active mix. A refill of a superseded
  /// session (the user started another mix) must not touch state or queue.
  bool _isCurrent(RecommendationSession session) =>
      identical(_session, session) &&
      ref.read(recommendationSessionProvider.notifier).owns(session);

  void deactivate() {
    final session = _session;
    if (session != null) {
      ref.read(recommendationSessionProvider.notifier).stop(session);
    }
    _session = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRefillAllowedAt = null;
    _consecutiveTransientFailures = 0;
    _mixSegmentEndIndex = null;
    _activationInProgress = false;
    _suppressActivationSeedSnapshot = false;
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
    if (_activationInProgress) return;
    if (_consumeActivationSeedSnapshot(next)) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error != null) {
      return;
    }

    if (next.queueSongIds.isEmpty) {
      _mixSegmentEndIndex = null;
      state = const SameVibesState.inactive();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final mixEnd = _mixSegmentEndIndex;
    final remaining = mixEnd != null
        ? mixEnd - currentIndex - 1
        : next.queueSongIds.length - currentIndex - 1;
    if (remaining <= _kRefillThreshold) {
      unawaited(_refill());
    }
  }

  bool _consumeActivationSeedSnapshot(PlaybackSnapshot snapshot) {
    if (!_suppressActivationSeedSnapshot) {
      return false;
    }
    final seedSongId = state.seedSongId;
    final isRetainedSeedQueue =
        seedSongId != null &&
        snapshot.queueSongIds.length == 1 &&
        snapshot.queueSongIds.first == seedSongId &&
        (snapshot.currentSongId == null ||
            snapshot.currentSongId == seedSongId) &&
        (snapshot.currentIndex == null || snapshot.currentIndex == 0);
    if (!isRetainedSeedQueue) {
      return false;
    }
    _suppressActivationSeedSnapshot = false;
    return true;
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
    // The first refill serves the song the caller chose, which need not be
    // the one playing (Android Auto starts mixes from browsed songs). Later
    // refills follow the current song.
    final seedSongId = isInitial
        ? state.seedSongId
        : snapshot.currentSongId ?? state.seedSongId;
    if (seedSongId == null || seedSongId.trim().isEmpty) {
      AppLogger.debug('SameVibes diagnostics: refill skipped (missing seed)');
      return;
    }
    final normalizedSeedSongId = seedSongId.trim();
    final session = _session;
    if (session == null ||
        !ref.read(recommendationSessionProvider.notifier).owns(session)) {
      return;
    }
    _nextRefillAllowedAt = now.add(_kMinimumRefillInterval);
    _retryTimer?.cancel();
    _retryTimer = null;

    state = state.copyWith(
      refilling: true,
      seedSongId: normalizedSeedSongId,
      clearError: true,
    );
    const targetBatch = _kTargetQueueBatchSize;
    const searchAttemptLimit = _kMaxSearchAttempts;
    var initialQueueChangeAttempted = false;
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

      // The first refill keeps only the seed in the queue (it retains the
      // seed before appending), so only the seed counts as already queued.
      // Blocking the whole old queue made starting over from a song whose
      // previous mix was still queued insert nothing.
      final queueSongIds = isInitial
          ? <String>[normalizedSeedSongId]
          : snapshot.queueSongIds;
      final queuedIds = queueSongIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final queuedSongKeys = <String>{
        ...await _readQueueCanonicalSongKeys(queueSongIds),
      };

      final seed = await _resolveSeedMetadata(
        api: api,
        seedSongId: normalizedSeedSongId,
      );
      if (!ref.read(recommendationSessionProvider.notifier).owns(session)) {
        return;
      }
      // The library copy of a remote seed is the same recording; never queue
      // it right behind its remote twin.
      final libraryCopyId = seed?.libraryCopyId;
      if (libraryCopyId != null) {
        queuedIds.add(libraryCopyId);
      }
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
      var lastFmResult = const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.noResults,
        tracks: <LastFmTrackRecommendation>[],
      );
      var mappedSongCount = 0;
      final mappedSongs = <Song>[];
      if (seed != null) {
        lastFmResult = await _fetchLastFmRecommendations(
          expectedArtist: seed.artist,
          expectedTitle: seed.title,
          limit: _kLastFmRecommendationLimit,
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
            targetCount: targetBatch,
            maxSearchAttempts: searchAttemptLimit,
            onChunk: (chunk) async {
              if (chunk.isEmpty || !state.active) {
                return 0;
              }
              mappedSongs.addAll(chunk);
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
                'SameVibes diagnostics: mapped incremental chunk=${chunk.length}',
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
      if (!ref.read(recommendationSessionProvider.notifier).owns(session)) {
        return;
      }
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
      var fallbackSongs = const <Song>[];
      var fallbackDecision = 'skip';
      var fallbackReason = 'not_needed';
      var fallbackSeedEligible = false;
      final shouldAttemptFallback = switch (lastFmResult.outcome) {
        LastFmFetchOutcome.success => mappedSongCount < targetBatch,
        LastFmFetchOutcome.noResults ||
        LastFmFetchOutcome.apiError ||
        LastFmFetchOutcome.networkError ||
        LastFmFetchOutcome.parseError ||
        LastFmFetchOutcome.notConfigured => mappedSongCount < targetBatch,
      };

      if (shouldAttemptFallback) {
        final fallbackSeedSongId = _resolveFallbackSeedSongId(
          snapshot: snapshot,
          preferredSeedSongId: normalizedSeedSongId,
          libraryCopyId: seed?.libraryCopyId,
        );
        fallbackSeedEligible = fallbackSeedSongId != null;
        if (fallbackSeedSongId == null) {
          fallbackDecision = 'skip';
          fallbackReason = 'seed_not_server_addressable';
        } else {
          fallbackDecision = 'attempt';
          fallbackReason = switch (lastFmResult.outcome) {
            LastFmFetchOutcome.notConfigured => 'lastfm_not_configured',
            LastFmFetchOutcome.noResults => 'lastfm_no_results',
            LastFmFetchOutcome.networkError => 'lastfm_network_error',
            LastFmFetchOutcome.parseError => 'lastfm_parse_error',
            LastFmFetchOutcome.apiError => 'lastfm_api_error',
            LastFmFetchOutcome.success => 'mapped_below_target',
          };
        }
      } else {
        fallbackReason = mappedSongCount >= targetBatch
            ? 'mapping_sufficient'
            : 'seed_not_server_addressable';
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
          libraryCopyId: seed?.libraryCopyId,
        );
        if (fallbackSeedSongId != null) {
          AppLogger.debug(
            'SameVibes diagnostics: fallback engaged '
            'reason="$fallbackReason" '
            'mapped=$mappedSongCount seed=$fallbackSeedSongId',
          );
          try {
            final fallback = await api.getSimilarSongs(
              fallbackSeedSongId,
              count: targetBatch,
            );
            AppLogger.debug(
              'SameVibes diagnostics: fallback candidates=${fallback.length}',
            );
            fallbackSongs = _mergeUniqueSongs(
              primary: const <Song>[],
              fallback: fallback,
              excludedIds: queuedIds,
              excludedSongKeys: queuedSongKeys,
              targetCount: targetBatch - mappedSongCount,
            );
            if (fallbackSongs.isNotEmpty) {
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
            if (endpointUnsupported && mappedSongs.isEmpty) {
              if (!_isCurrent(session)) return;
              state = const SameVibesState(error: SameVibesError.unsupported);
              _reportFailed(session, SameVibesError.unsupported);
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

      if (mappedSongCount < targetBatch && !shouldAttemptFallback) {
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

      final songsToQueue = <Song>[...mappedSongs, ...fallbackSongs];
      var totalQueued = 0;
      if (songsToQueue.isNotEmpty) {
        if (isInitial) {
          initialQueueChangeAttempted = true;
          await ref
              .read(queueProvider.notifier)
              .retainCurrentAsQueue(normalizedSeedSongId);
        }
        if (!ref.read(recommendationSessionProvider.notifier).owns(session)) {
          return;
        }
        final queueLengthBeforeAppend = ref
            .read(playerStateProvider)
            .queueSongIds
            .length;
        final result = await ref
            .read(queueProvider.notifier)
            .appendRecommendationTracks(
              songsToQueue,
              expandMatchFlows: false,
              isCurrent: () =>
                  ref.mounted &&
                  ref
                      .read(recommendationSessionProvider.notifier)
                      .owns(session),
            );
        totalQueued = result.count;
        if (totalQueued > 0) {
          _mixSegmentEndIndex = queueLengthBeforeAppend + totalQueued;
        }
      }

      // A superseded refill's songs were not queued (the append checks the
      // session); its outcome belongs to no one now.
      if (!_isCurrent(session)) return;
      if (totalQueued <= 0) {
        if (isInitial && initialQueueChangeAttempted) {
          await _restorePreviousQueue(snapshot, session);
        }
        final terminalError =
            lastFmResult.apiErrorCode == 10 || lastFmResult.apiErrorCode == 26
            ? SameVibesError.invalidKey
            : lastFmResult.statusCode == 429 || lastFmResult.apiErrorCode == 29
            ? SameVibesError.rateLimited
            : null;
        if (terminalError != null) {
          _retryTimer?.cancel();
          _retryTimer = null;
          state = SameVibesState(error: terminalError);
          ref
              .read(recommendationSessionProvider.notifier)
              .report(
                session,
                stage: 'failed',
                errorCategory: terminalError.name,
              );
          return;
        }
        AppLogger.debug(
          'SameVibes diagnostics: no tracks queued (empty result after fallback)',
        );
        if (isInitial) {
          _retryTimer?.cancel();
          _retryTimer = null;
          _nextRefillAllowedAt = DateTime.now().add(_kRetryBackoffBase);
          state = const SameVibesState(error: SameVibesError.networkError);
          _reportFailed(session, SameVibesError.networkError);
          return;
        }
        _scheduleTransientRetry(reason: fallbackReason);
      } else {
        AppLogger.debug('SameVibes diagnostics: queuedTracks=$totalQueued');
        _consecutiveTransientFailures = 0;
        _nextRefillAllowedAt = DateTime.now().add(_kMinimumRefillInterval);
      }

      state = state.copyWith(
        refilling: false,
        pendingSnackbar: isInitial ? '$totalQueued' : null,
      );
      ref
          .read(recommendationSessionProvider.notifier)
          .report(
            session,
            stage: totalQueued > 0 ? 'active' : 'failed',
            source: mappedSongs.isNotEmpty ? 'lastFm' : 'server',
            candidateCount: songsToQueue.length,
            insertedCount: totalQueued,
          );
    } on Exception catch (error) {
      if (isInitial && initialQueueChangeAttempted) {
        await _restorePreviousQueue(snapshot, session);
      }
      AppLogger.debug('SameVibes refill error: $error');
      if (!_isCurrent(session)) return;
      if (isInitial) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _nextRefillAllowedAt = DateTime.now().add(_kRetryBackoffBase);
        state = const SameVibesState(error: SameVibesError.networkError);
        _reportFailed(session, SameVibesError.networkError);
        return;
      }
      _scheduleTransientRetry(reason: 'unexpected_exception');
      state = state.copyWith(
        refilling: false,
        error: SameVibesError.networkError,
      );
    } on Object catch (error, stackTrace) {
      if (isInitial && initialQueueChangeAttempted) {
        await _restorePreviousQueue(snapshot, session);
      }
      AppLogger.debug('SameVibes refill error: $error\n$stackTrace');
      if (!_isCurrent(session)) return;
      if (isInitial) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _nextRefillAllowedAt = DateTime.now().add(_kRetryBackoffBase);
        state = const SameVibesState(error: SameVibesError.networkError);
        _reportFailed(session, SameVibesError.networkError);
        return;
      }
      _scheduleTransientRetry(reason: 'unexpected_exception');
      if (state.active) {
        state = state.copyWith(
          refilling: false,
          error: SameVibesError.networkError,
        );
      }
    } finally {
      if (_isCurrent(session) && state.active && state.refilling) {
        state = state.copyWith(refilling: false);
      }
    }
  }

  /// Ends [session] as failed; without this the session would keep reading
  /// "preparing" after the mix gave up.
  void _reportFailed(RecommendationSession session, SameVibesError error) {
    ref
        .read(recommendationSessionProvider.notifier)
        .report(session, stage: 'failed', errorCategory: error.name);
  }

  Future<void> _restorePreviousQueue(
    PlaybackSnapshot snapshot,
    RecommendationSession session,
  ) async {
    if (!ref.read(recommendationSessionProvider.notifier).owns(session)) return;
    try {
      await ref
          .read(queueProvider.notifier)
          .replace(
            snapshot.queueSongIds,
            startIndex: snapshot.currentIndex ?? 0,
            autoPlay: snapshot.playing,
            expandMatchFlows: false,
            notifyMixSessionReset: false,
          );
    } on Object {
      // Keep the original recommendation failure as the reported result.
    }
  }

  Future<_SeedMetadata?> _resolveSeedMetadata({
    required SubsonicApiClient api,
    required String seedSongId,
  }) async {
    final mediaItem = ref.read(currentMediaItemProvider).asData?.value;
    final mediaTitle = mediaItem?.title.trim() ?? '';
    final mediaArtist = mediaItem?.artist?.trim() ?? '';
    final fromMediaItem =
        mediaItem?.id == seedSongId &&
            mediaTitle.isNotEmpty &&
            mediaArtist.isNotEmpty
        ? _SeedMetadata(title: mediaTitle, artist: mediaArtist)
        : null;
    // A server-addressable seed needs nothing more than its title and
    // artist. A remote seed also needs getSong even while it plays: a server
    // with a remote catalogue answers with its library copy when it has one,
    // and only that id works for similar songs.
    if (fromMediaItem != null && _isServerAddressableSeedId(seedSongId)) {
      return fromMediaItem;
    }

    try {
      final song = await api.getSong(seedSongId);
      final title = song.title.trim();
      final artist = (song.artist ?? '').trim();
      final copyId = song.id.trim();
      final libraryCopyId =
          copyId != seedSongId && _isServerAddressableSeedId(copyId)
          ? copyId
          : null;
      if (fromMediaItem != null) {
        return _SeedMetadata(
          title: fromMediaItem.title,
          artist: fromMediaItem.artist,
          libraryCopyId: libraryCopyId,
        );
      }
      if (title.isEmpty || artist.isEmpty) {
        return null;
      }
      return _SeedMetadata(
        title: title,
        artist: artist,
        libraryCopyId: libraryCopyId,
      );
    } on Exception {
      return fromMediaItem;
    }
  }

  Future<int> _mapLastFmRecommendationsIncremental({
    required SubsonicApiClient api,
    required List<LastFmTrackRecommendation> recommendations,
    required Set<String> blockedIds,
    required Set<String> blockedSongKeys,
    required _CandidatePreferenceContext preferences,
    required int targetCount,
    required int maxSearchAttempts,
    required Future<int> Function(List<Song> chunk) onChunk,
  }) async {
    if (recommendations.isEmpty) {
      return 0;
    }

    final sortedRecs = [...recommendations]
      ..sort((a, b) => (b.match ?? 0).compareTo(a.match ?? 0));

    final attemptsLimit = sortedRecs
        .take(maxSearchAttempts)
        .toList(growable: false);
    var attempts = 0;
    var misses = 0;
    var mappedCount = 0;
    final pendingChunk = <Song>[];

    for (
      var batchStart = 0;
      batchStart < attemptsLimit.length;
      batchStart += _kMappingParallelism
    ) {
      if (!state.active || mappedCount >= targetCount) {
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
        if (!state.active || mappedCount >= targetCount) {
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
    required int limit,
  }) async {
    if (!ref
        .read(integrationPolicyProvider)
        .allows(IntegrationFeature.lastFmSameVibes)) {
      AppLogger.debug('SameVibes diagnostics: lastfm unavailable (turned off)');
      return const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.notConfigured,
        tracks: <LastFmTrackRecommendation>[],
      );
    }
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
      limit: limit,
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
    String? libraryCopyId,
  }) {
    if (_isServerAddressableSeedId(preferredSeedSongId)) {
      return preferredSeedSongId;
    }
    if (libraryCopyId != null) {
      return libraryCopyId;
    }

    final queue = snapshot.queueSongIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    // Neighbours stand in for the seed only while the seed is among them; a
    // seed chosen from outside the queue replaces it.
    if (queue.isEmpty || !queue.contains(preferredSeedSongId)) {
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

  bool _isServerAddressableSeedId(String id) => isServerAddressableSongId(id);

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
    if (_consecutiveTransientFailures >= 5) {
      _retryTimer?.cancel();
      _retryTimer = null;
      final session = _session;
      if (session != null) {
        ref
            .read(recommendationSessionProvider.notifier)
            .report(
              session,
              stage: 'retryExhausted',
              errorCategory: reason,
              retryCount: _consecutiveTransientFailures,
            );
      }
      return;
    }
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
    final session = _session;
    if (session != null) {
      ref
          .read(recommendationSessionProvider.notifier)
          .report(
            session,
            stage: 'retryPending',
            errorCategory: reason,
            retryCount: _consecutiveTransientFailures,
          );
    }
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
    final queries = _mappingQueriesFor(recommendation);
    if (queries.isEmpty) {
      return null;
    }
    for (final query in queries) {
      try {
        final search = await api.search3(
          query: query,
          artistCount: 0,
          albumCount: 0,
          songCount: _kSearchSongCount,
        );
        final albumSongCounts = await _readAlbumSongCounts(search.songs);
        final candidate = _pickBestCandidate(
          recommendation: recommendation,
          songs: search.songs,
          blockedIds: const <String>{},
          preferences: preferences,
          albumSongCounts: albumSongCounts,
        );
        if (candidate != null) {
          return candidate;
        }
      } on Exception catch (error) {
        AppLogger.debug(
          'SameVibes diagnostics: mapping search failed '
          'query="$query" error=$error',
        );
      }
    }
    return null;
  }

  List<String> _mappingQueriesFor(LastFmTrackRecommendation recommendation) {
    final artist = recommendation.artist.trim();
    final title = recommendation.title.trim();
    final queries = <String>[
      '$artist $title'.trim(),
      '$title $artist'.trim(),
      title,
      artist,
    ];
    final seen = <String>{};
    return queries
        .where((query) => query.isNotEmpty && seen.add(query.toLowerCase()))
        .toList(growable: false);
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
    var bestSameEdition = false;
    final expectedEdition = normalizeMetadataKeepingEdition(
      recommendation.title,
    );

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
      final sameEdition =
          normalizeMetadataKeepingEdition(candidate.title) == expectedEdition;
      final nearTie = (score - bestScore).abs() <= _kAvailabilityTieWindow;
      // Among equally good matches the recommended version ("Wonder
      // (Japanese Version)" rather than "Wonder") wins first.
      final shouldReplace = nearTie && sameEdition != bestSameEdition
          ? sameEdition
          : score > bestScore ||
                (nearTie &&
                    (albumRank > bestAlbumRank ||
                        (albumRank == bestAlbumRank &&
                            availabilityRank > bestAvailabilityRank)));
      if (shouldReplace) {
        best = candidate;
        bestScore = score;
        bestAlbumRank = albumRank;
        bestAvailabilityRank = availabilityRank;
        bestSameEdition = sameEdition;
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
  const new({required this.artist, required this.title, this.libraryCopyId});

  final String artist;
  final String title;

  /// The server's library copy of a remote seed, when it has one.
  final String? libraryCopyId;
}

class _CandidatePreferenceContext {
  const new({required this.downloadedSongIds, required this.cachedSongIds});

  final Set<String> downloadedSongIds;
  final Set<String> cachedSongIds;
}

/// Only apply availability preference when textual match quality is close.
const _kAvailabilityTieWindow = 0.03;

typedef _AlbumSongCountLookup = Future<Map<String, int?>> Function(
  Set<String> albumIds,
);

typedef _QueueSongKeyLookup = Future<Set<String>> Function(
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
    return await dao.getAlbumSongCountsByIds(albumIds);
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
