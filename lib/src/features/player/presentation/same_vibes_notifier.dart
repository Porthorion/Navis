import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart'
    show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart'
    show libraryAlbumTitlesReader;
import 'package:navis/src/features/player/data/same_vibes_deezer_pool.dart';
import 'package:navis/src/features/player/domain/same_vibes_ranking.dart';
import 'package:navis/src/features/player/domain/scrobble_threshold.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
import 'package:navis/src/features/player/domain/artist_spacing.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Target number of tracks to queue per background refill.
const _kTargetQueueBatchSize = 10;

/// Last.fm recommendation request limit per refill.
const _kLastFmRecommendationLimit = 20;

/// The server fill asks for more than a batch so the artist spacing has a
/// choice.
const _kServerFillLimit = 20;

/// Candidates by one artist that may reach the library search; the rest of a
/// run by one artist cannot all be queued anyway.
const _kMaxSearchedPerArtist = 3;

/// The whole Deezer leg (artist lookup and radio) must answer within this, or
/// the server fills the refill instead.
const _kDeezerLegTimeout = Duration(seconds: 6);

/// A background refill's Deezer leg waits for the pool top-up first, so it
/// gets longer.
const _kDeezerRefillLegTimeout = Duration(seconds: 20);

/// How long a refill waits for the pool top-up before ranking with what the
/// pool holds (the top-up keeps running).
const _kVibesTopUpWait = Duration(seconds: 12);

/// The largest position step that counts as listening (a seek, a stale tick
/// of the previous song or a backwards jump only moves the baseline).
const _kListenedTickMax = Duration(seconds: 3);

/// Deezer was over its quota or too slow; the server fills, nothing retries.
const _kDeezerSkippedReason = 'deezer_skipped';

/// Miss budget for mapping Last.fm recommendations with `search3` (only
/// misses count; it matches the fetch limit, so every fetched one may be tried).
const _kMaxSearchAttempts = 20;

/// Number of song candidates to inspect per `search3` query.
const _kSearchSongCount = 8;

/// Guard against rapid repeated refill attempts from playback ticks.
const _kMinimumRefillInterval = Duration(milliseconds: 1200);

/// Retry window base/cap for transient failures.
const _kRetryBackoffBase = Duration(seconds: 3);

const _kRetryBackoffMax = Duration(seconds: 45);
const _kRetryJitterMaxMs = 600;

/// Bounded concurrent `search3` fan-out for Last.fm mapping.
const _kMappingParallelism = 5;

/// Minimum confidence required to map Last.fm recommendation -> Subsonic song.
const _kMinimumMappingScore = 0.62;

/// Auto-refill notifier for Last.fm-backed Same Vibes mode.
class SameVibesNotifier extends Notifier<SameVibesState> {
  /// [now] lets tests step the refill backoff without waiting.
  new({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  final math.Random _random = math.Random();
  Timer? _retryTimer;

  /// Re-checks a refill the post-refill block dropped (#747).
  Timer? _blockRecheckTimer;
  bool _inBlockRecheck = false;

  /// Listened-time feed, open while a mix is active (#747). A container-level
  /// listener, not `ref.listen`: Riverpod 3 deactivates the notifier's own
  /// subscriptions when nothing listens to the notifier, and an unlistened
  /// position stream is paused, so played-through would stop counting.
  ProviderSubscription<AsyncValue<Duration>>? _positionSub;

  /// `deezer` or `lastFm`: the source the latest recommendation fetch used.
  String _recommendationSource = 'lastFm';
  DateTime? _nextRefillAllowedAt;
  int _consecutiveTransientFailures = 0;

  /// The seed a refill found nothing new for (or failed five times in a row
  /// on). Refills on that song return at once; the next current song re-arms
  /// the mix.
  String? _parkedSeedSongId;

  /// Songs this mix appended. Refill counts only these after the current
  /// song, so queue edits and songs added later do not skew it.
  Set<String>? _mixSongIds;

  /// Version keys of every song the mix queued or played as a seed. Together
  /// with [_mixSongIds] it is the session memory: a song queued once is not
  /// queued again, even after it played and left the queue.
  Set<String>? _mixSongKeys;

  /// The activation seed, whatever its kind (#743). Deezer refills rank from
  /// it for the whole mix; the song playing when a refill fires is only the
  /// trigger (park key, retry key).
  String? _anchorId;

  /// The anchor's resolved metadata, stored by the initial refill.
  _SeedMetadata? _anchorSeed;

  /// Mix songs the player left after the scrobble threshold, oldest first
  /// (#743). The snapshot's position is not refreshed on every tick, so the
  /// listened time of the playing song is accumulated from the position
  /// stream: only ticks that advance by a normal step count, so a seek or a
  /// stale tick of the previous song never credits a skipped song.
  final List<String> _playedThrough = <String>[];

  /// Artist names of the songs the mix queued, for the played-through radios.
  final Map<String, String> _mixArtists = <String, String>{};
  String? _playingSongId;
  Duration _playingDuration = Duration.zero;
  Duration _listened = Duration.zero;
  Duration _lastTick = Duration.zero;

  /// The mix's Deezer lists, created by its first Deezer leg and set after
  /// `session.start()` (#743). Every refill reads it into a local first.
  SameVibesDeezerPool? _vibesPool;

  /// Track ids of the last ranking's top 24: the top-up fetches their
  /// features for the next refill.
  List<int> _lastFeatureIds = const <int>[];

  /// While the foreground first-batch leg runs: its timeout cancels the
  /// requests the pool starts meanwhile.
  CancelToken? _deezerLegToken;

  SameVibesRefillRecord? _lastRefill;

  /// What the last refill did, for the diagnostics (never credentials).
  SameVibesRefillRecord? get lastRefill => _lastRefill;
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
      _blockRecheckTimer?.cancel();
      _blockRecheckTimer = null;
      _positionSub?.close();
      _positionSub = null;
    });
    return const SameVibesState.inactive();
  }

  Future<void> activate(String seedSongId) async {
    final normalizedSeedSongId = seedSongId.trim();
    if (normalizedSeedSongId.isEmpty) {
      return;
    }
    _mixSongIds = null;
    _mixSongKeys = null;
    _resetPlayedThrough();
    _parkedSeedSongId = null;
    _lastRefill = null;
    _consecutiveTransientFailures = 0;
    final session = ref
        .read(recommendationSessionProvider.notifier)
        .start(RecommendationMode.sameVibes, seedId: normalizedSeedSongId);
    _session = session;
    // After `start`: a superseded mix's listener runs deactivate() inside it,
    // which clears the anchor.
    _anchorId = normalizedSeedSongId;
    _anchorSeed = null;
    _vibesPool = null;
    _lastFeatureIds = const <int>[];
    _activationInProgress = true;
    _suppressActivationSeedSnapshot = true;
    // A fresh state also clears the refilling flag of a refill still running
    // for a superseded mix, so this mix's first refill starts at once.
    state = SameVibesState(active: true, seedSongId: normalizedSeedSongId);
    _positionSub?.close();
    _positionSub = ref.container.listen<AsyncValue<Duration>>(
      playbackPositionProvider,
      (_, next) {
        final position = next.asData?.value;
        if (position == null || !state.active) return;
        final delta = position - _lastTick;
        _lastTick = position;
        if (delta > Duration.zero && delta <= _kListenedTickMax) {
          _listened += delta;
        }
      },
    );
    try {
      await _refill(isInitial: true);
    } finally {
      // A newer activation owns the flag now.
      if (identical(_session, session)) {
        _activationInProgress = false;
        // A failed first refill ends the mix without deactivate().
        if (!state.active) {
          _positionSub?.close();
          _positionSub = null;
        } else if (ref.mounted) {
          // Snapshots were ignored while the run streamed: the user may have
          // skipped onto the last appended songs meanwhile.
          final playing = ref.read(playerStateProvider);
          if (playing.currentSongId?.trim() != normalizedSeedSongId) {
            _onSnapshotChanged(null, playing);
          }
        }
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
    _blockRecheckTimer?.cancel();
    _blockRecheckTimer = null;
    _positionSub?.close();
    _positionSub = null;
    _nextRefillAllowedAt = null;
    _consecutiveTransientFailures = 0;
    _parkedSeedSongId = null;
    _anchorId = null;
    _anchorSeed = null;
    _vibesPool = null;
    _lastFeatureIds = const <int>[];
    _mixSongIds = null;
    _mixSongKeys = null;
    _resetPlayedThrough();
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

  void _resetPlayedThrough() {
    _playedThrough.clear();
    _mixArtists.clear();
    _playingSongId = null;
    _playingDuration = Duration.zero;
    _listened = Duration.zero;
    _lastTick = Duration.zero;
  }

  /// Notes a mix song the player just left after the scrobble threshold.
  /// Runs before every early return of [_onSnapshotChanged]: a refill in
  /// flight must not lose it. Skips (below the threshold) never count.
  void _trackPlayedThrough(PlaybackSnapshot next) {
    final id = next.isRadioMode ? null : next.currentSongId;
    if (id == _playingSongId) {
      if (next.duration > Duration.zero) _playingDuration = next.duration;
      return;
    }
    final left = _playingSongId;
    if (left != null &&
        left != _anchorId &&
        (_mixSongIds?.contains(left) ?? false) &&
        reachedScrobbleThreshold(
          duration: _playingDuration,
          position: _listened,
        )) {
      _playedThrough
        ..remove(left)
        ..add(left);
    }
    _playingSongId = id;
    _playingDuration = next.duration;
    _listened = Duration.zero;
    _lastTick = Duration.zero;
  }

  void _onSnapshotChanged(PlaybackSnapshot? prev, PlaybackSnapshot next) {
    if (!state.active) return;
    _trackPlayedThrough(next);
    if (_activationInProgress) return;
    if (_consumeActivationSeedSnapshot(next)) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error != null) {
      return;
    }

    if (next.queueSongIds.isEmpty) {
      deactivate();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final remaining = mixSongsAfterCurrent(next, currentIndex, _mixSongIds);
    if (remaining <= kRecommendationRefillLowWater) {
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
    final now = _now();
    final nextAllowed = _nextRefillAllowedAt;
    if (!isInitial && nextAllowed != null && now.isBefore(nextAllowed)) {
      AppLogger.debug(
        'SameVibes diagnostics: refill skipped (backoff active '
        'until=${nextAllowed.toIso8601String()})',
      );
      // Steady playback sends no further snapshot (#747): look again when
      // the block ends, unless a retry timer will refill by itself or this
      // is already that look (an injected clock that stands still must not
      // loop).
      if (!isInitial &&
          !(_retryTimer?.isActive ?? false) &&
          _blockRecheckTimer == null &&
          !_inBlockRecheck) {
        _blockRecheckTimer = Timer(
          nextAllowed.difference(now) + const Duration(milliseconds: 50),
          () {
            _blockRecheckTimer = null;
            if (!ref.mounted || !state.active) return;
            _inBlockRecheck = true;
            try {
              _onSnapshotChanged(null, ref.read(playerStateProvider));
            } finally {
              _inBlockRecheck = false;
            }
          },
        );
      }
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
    // Read now: a refill of a superseded mix must not pick up the new mix's.
    final anchorId = _anchorId;
    final anchorSeed = _anchorSeed;
    final vibesPool = _vibesPool;
    final deezerReport = _DeezerLegReport();
    if (session == null ||
        !ref.read(recommendationSessionProvider.notifier).owns(session)) {
      return;
    }
    if (!isInitial && _parkedSeedSongId != null) {
      if (_parkedSeedSongId == normalizedSeedSongId) {
        // The last song found nothing new and nothing can extend the queue.
        if (_mixCannotExtend(snapshot)) deactivate();
        return;
      }
      _parkedSeedSongId = null;
      _consecutiveTransientFailures = 0;
      AppLogger.debug('SameVibes diagnostics: seed changed, refill re-armed');
    }
    _nextRefillAllowedAt = now.add(_kMinimumRefillInterval);
    _retryTimer?.cancel();
    _retryTimer = null;
    _blockRecheckTimer?.cancel();
    _blockRecheckTimer = null;

    state = state.copyWith(refilling: true, clearError: true);
    const targetBatch = _kTargetQueueBatchSize;
    const searchAttemptLimit = _kMaxSearchAttempts;
    var initialQueueChangeAttempted = false;
    // Songs are appended chunk by chunk while they map (#759): the counters
    // live out here so a failure after the first append ends the run as a
    // partial success instead of rolling the live mix back.
    var totalQueued = 0;
    var chunks = 0;
    var seedRetained = false;
    var seedUnloadable = false;
    final started = Stopwatch()..start();
    int? firstAppendMs;
    final orderSpacing = ArtistSpacing();
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
      // The anchor's own metadata, never the trigger's: a refill whose anchor
      // lookup failed earlier asks again, and the Deezer leg waits for it.
      var anchorMeta = isInitial ? seed : anchorSeed;
      if (anchorMeta == null && anchorId != null) {
        anchorMeta = normalizedSeedSongId == anchorId
            ? seed
            : await _resolveSeedMetadata(api: api, seedSongId: anchorId);
        if (!_isCurrent(session)) return;
      }
      if (anchorMeta != null && _anchorSeed == null && _isCurrent(session)) {
        _anchorSeed = anchorMeta;
      }
      // The library copy of a remote seed is the same recording; never queue
      // it right behind its remote twin.
      final libraryCopyId = seed?.libraryCopyId;
      if (libraryCopyId != null) {
        queuedIds.add(libraryCopyId);
      }
      // Session memory: what this mix queued or played stays blocked after it
      // left the queue. The seed itself played, so it counts too.
      queuedIds.addAll(_mixSongIds ?? const <String>{});
      queuedSongKeys.addAll(_mixSongKeys ?? const <String>{});
      final seedKey = seed == null
          ? null
          : sameVibesCanonicalSongKey(seed.artist, seed.title);
      if (seedKey != null) {
        queuedSongKeys.add(seedKey);
        (_mixSongKeys ??= <String>{}).add(seedKey);
      }
      final mappedSongs = <Song>[];
      bool alive() => ref.mounted && _isCurrent(session) && state.active;
      void failUnloadableSeed() {
        _retryTimer?.cancel();
        _retryTimer = null;
        _nextRefillAllowedAt = _now().add(_kRetryBackoffBase);
        state = const SameVibesState(error: SameVibesError.networkError);
        _reportFailed(session, SameVibesError.networkError);
      }

      /// Queues one chunk. False ends the run: superseded, switched off, the
      /// queue cleared, or a seed the handler cannot load. An append that
      /// inserts nothing is not a stop.
      Future<bool> flush(List<Song> chunk) async {
        if (!alive()) return false;
        var songs = chunk;
        // The first chunk of an initial run sees the old queue, which the
        // retain below replaces; every other chunk sees the live one.
        if (!isInitial || seedRetained) {
          final live =
              ref.read(audioHandlerProvider)?.snapshot.queueSongIds ??
              ref.read(playerStateProvider).queueSongIds;
          if (live.isEmpty) {
            deactivate();
            return false;
          }
          final liveIds = live.map((id) => id.trim()).toSet();
          songs = songs.where((s) => !liveIds.contains(s.id.trim())).toList();
        }
        if (songs.isEmpty) return true;
        final ordered = spaceByArtist<Song>(
          songs,
          artistOf: _artistKey,
          count: songs.length,
          spacing: orderSpacing,
        );
        final queue = ref.read(queueProvider.notifier);
        if (isInitial && !seedRetained) {
          // The handler loads the seed from the database when it is neither
          // playing nor queued; a seed it cannot load would clear the queue.
          final loadable = await queue.ensureSeedLoadable(
            snapshot,
            normalizedSeedSongId,
            () async => seed?.song,
          );
          // The store awaited; a newer mix must not be retained over or failed.
          if (!_isCurrent(session)) return false;
          if (!loadable) {
            seedUnloadable = true;
            return false;
          }
          initialQueueChangeAttempted = true;
          await queue.retainCurrentAsQueue(normalizedSeedSongId);
          seedRetained = true;
          if (!_isCurrent(session)) return false;
        }
        final result = await queue.appendRecommendationTracks(
          ordered,
          expandMatchFlows: false,
          isCurrent: () =>
              ref.mounted &&
              ref.read(recommendationSessionProvider.notifier).owns(session),
        );
        // A superseded or stopped mix owns no state any more.
        if (!_isCurrent(session)) return false;
        if (result.count == 0) return true;
        chunks += 1;
        firstAppendMs ??= started.elapsedMilliseconds;
        totalQueued += result.count;
        final insertedIds = result.insertedIds.toSet();
        (_mixSongIds ??= <String>{}).addAll(insertedIds);
        final keys = _mixSongKeys ??= <String>{};
        for (final song in ordered) {
          if (!insertedIds.contains(song.id)) continue;
          final artist = song.artist;
          if (artist != null) _mixArtists[song.id] = artist;
          final key = sameVibesCanonicalSongKey(artist ?? '', song.title);
          if (key != null) keys.add(key);
        }
        AppLogger.debug(
          'SameVibes diagnostics: chunk n=$chunks inserted=${result.count} '
          'total=$totalQueued elapsedMs=${started.elapsedMilliseconds}',
        );
        ref
            .read(recommendationSessionProvider.notifier)
            .report(
              session,
              stage: 'active',
              insertedCount: totalQueued,
              source: mappedSongs.isEmpty ? 'server' : _recommendationSource,
            );
        return true;
      }

      final candidatePreferences = _CandidatePreferenceContext(
        allowJunkVersions: seed != null && isJunkSongVersion(seed.title),
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
      _recommendationSource = 'lastFm';
      var lastFmResult = const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.noResults,
        tracks: <LastFmTrackRecommendation>[],
      );
      var mappedSongCount = 0;
      if (seed != null) {
        lastFmResult = await _fetchRecommendations(
          seed: seed,
          anchorSeed: anchorMeta,
          anchorId: anchorId,
          session: session,
          pool: vibesPool,
          report: deezerReport,
          limit: _kLastFmRecommendationLimit,
          background: !isInitial,
        );
        AppLogger.debug(
          'SameVibes diagnostics: seed resolved artist="${seed.artist}" '
          'title="${seed.title}"',
        );
        if (lastFmResult.outcome == LastFmFetchOutcome.success &&
            lastFmResult.tracks.isNotEmpty) {
          try {
            mappedSongCount = await _mapLastFmRecommendationsIncremental(
              api: api,
              recommendations: lastFmResult.tracks,
              blockedIds: queuedIds,
              blockedSongKeys: queuedSongKeys,
              preferences: candidatePreferences,
              targetCount: targetBatch,
              maxSearchAttempts: searchAttemptLimit,
              alive: alive,
              onChunk: (chunk) {
                mappedSongs.addAll(chunk);
                for (final song in chunk) {
                  final id = song.id.trim();
                  if (id.isNotEmpty) {
                    queuedIds.add(id);
                  }
                  final key = sameVibesCanonicalSongKey(
                    song.artist ?? '',
                    song.title,
                  );
                  if (key != null) {
                    queuedSongKeys.add(key);
                  }
                }
                AppLogger.debug(
                  'SameVibes diagnostics: mapped incremental chunk=${chunk.length}',
                );
                return flush(chunk);
              },
            );
          } on Object catch (error) {
            // Songs are already queued: end the run as a success below.
            if (totalQueued == 0) rethrow;
            mappedSongCount = mappedSongs.length;
            AppLogger.debug('SameVibes mapping stopped after queuing: $error');
          }
        }
      } else {
        AppLogger.debug(
          'SameVibes diagnostics: seed metadata unavailable '
          '(lastfm mapping skipped)',
        );
      }
      final mappedBeforeFallback = mappedSongCount;
      if (!_isCurrent(session)) return;
      if (seedUnloadable) {
        failUnloadableSeed();
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

      // Server fill order: the mix's anchor first, then the song that fired
      // the refill (a dry or missing anchor must not end the mix, #743).
      final anchorFillId = anchorId == null
          ? null
          : _resolveFallbackSeedSongId(
              preferredSeedSongId: anchorId,
              libraryCopyId: anchorMeta?.libraryCopyId,
            );
      final triggerFillId = _resolveFallbackSeedSongId(
        preferredSeedSongId: normalizedSeedSongId,
        libraryCopyId: seed?.libraryCopyId,
      );
      if (shouldAttemptFallback) {
        fallbackSeedEligible = anchorFillId != null || triggerFillId != null;
        if (!fallbackSeedEligible) {
          fallbackDecision = 'skip';
          fallbackReason = 'seed_not_server_addressable';
        } else {
          fallbackDecision = 'attempt';
          fallbackReason = switch (lastFmResult.outcome) {
            LastFmFetchOutcome.notConfigured => 'lastfm_not_configured',
            LastFmFetchOutcome.noResults =>
              lastFmResult.message == _kDeezerSkippedReason
                  ? _kDeezerSkippedReason
                  : 'lastfm_no_results',
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

      // Either fill erred (transport/api): with nothing queued, a retry.
      var fillErrored = false;
      var fillUnsupported = false;
      final legReason = fallbackReason;

      /// Asks the server for [serverSeedId]'s similar songs; true when it
      /// added songs. A failure only sets the reason; never throws.
      Future<bool> fillFrom(String serverSeedId, String? seedTitle) async {
        AppLogger.debug(
          'SameVibes diagnostics: fallback engaged '
          'reason="$fallbackReason" '
          'mapped=$mappedSongCount seed=$serverSeedId',
        );
        try {
          final fallback = await api.getSimilarSongs(
            serverSeedId,
            count: _kServerFillLimit,
          );
          AppLogger.debug(
            'SameVibes diagnostics: fallback candidates=${fallback.length}',
          );
          fallbackSongs = _mergeUniqueSongs(
            fallback: fallback,
            excludedIds: queuedIds,
            excludedSongKeys: queuedSongKeys,
            targetCount: targetBatch - mappedSongCount,
            chosen: mappedSongs,
            seedTitle: seedTitle,
            allowJunk: candidatePreferences.allowJunkVersions,
          );
          for (final song in fallbackSongs) {
            final id = song.id.trim();
            if (id.isNotEmpty) {
              queuedIds.add(id);
            }
            final key = sameVibesCanonicalSongKey(
              song.artist ?? '',
              song.title,
            );
            if (key != null) {
              queuedSongKeys.add(key);
            }
          }
          fallbackQueued = fallbackSongs.length;
          AppLogger.debug(
            'SameVibes diagnostics: mergedAfterFallback='
            '${mappedSongCount + fallbackQueued}',
          );
          if (fallbackQueued > 0) fallbackReason = legReason;
          return fallbackQueued > 0;
        } on SubsonicNotFoundException catch (error) {
          final endpointUnsupported = _isEndpointUnsupportedMessage(
            error.message,
          );
          AppLogger.debug(
            'SameVibes diagnostics: fallback notfound '
            'code=${error.code} message="${error.message}" '
            'endpointUnsupported=$endpointUnsupported',
          );
          // The user's own rejected Last.fm key outranks "server unsupported":
          // fall through to the terminal invalid-key check below (#717).
          final userKeyRejected =
              (lastFmResult.apiErrorCode == 10 ||
                  lastFmResult.apiErrorCode == 26) &&
              !ref.read(lastFmBundledKeyProvider);
          if (endpointUnsupported &&
              mappedSongs.isEmpty &&
              totalQueued == 0 &&
              !userKeyRejected) {
            fillUnsupported = true;
          }
          fallbackReason = _subsonicFailureReason(error);
        } on SubsonicApiException catch (error) {
          AppLogger.debug(
            'SameVibes diagnostics: fallback api_error '
            'code=${error.code} message="${error.message}"',
          );
          fallbackReason = _subsonicFailureReason(error);
          fillErrored = true;
        } on SubsonicException catch (error) {
          AppLogger.debug(
            'SameVibes diagnostics: fallback transport_error '
            'message="${error.message}"',
          );
          fallbackReason = _subsonicFailureReason(error);
          fillErrored = true;
        }
        return false;
      }

      try {
        if (shouldAttemptFallback && fallbackSeedEligible) {
          var filled =
              anchorFillId != null &&
              await fillFrom(anchorFillId, anchorMeta?.title);
          if (!filled &&
              !fillUnsupported &&
              triggerFillId != null &&
              triggerFillId != anchorFillId) {
            if (!_isCurrent(session)) return;
            filled = await fillFrom(triggerFillId, seed?.title);
          }
          if (fillUnsupported) {
            if (!_isCurrent(session)) return;
            state = const SameVibesState(error: SameVibesError.unsupported);
            _reportFailed(session, SameVibesError.unsupported);
            return;
          }
        }

        if (mappedSongCount < targetBatch && !shouldAttemptFallback) {
          AppLogger.debug(
            'SameVibes diagnostics: fallback skipped '
            'reason=$fallbackReason mapped=$mappedSongCount',
          );
        }

        // The fallback fetch awaited; a newer mix may own the queue now, and
        // `state` is its state. A superseded refill must not retain its seed
        // (that would collapse the new mix's queue) or append anything.
        if (!_isCurrent(session)) return;

        if (!state.active) {
          AppLogger.debug(
            'SameVibes diagnostics: refill canceled (state inactive post-fallback)',
          );
          state = state.copyWith(refilling: false);
          return;
        }

        await flush(fallbackSongs);
      } on Object catch (error) {
        // Songs are already queued: end the run as a success below.
        if (totalQueued == 0) rethrow;
        AppLogger.debug('SameVibes fill stopped after queuing: $error');
      }
      if (!_isCurrent(session)) return;
      if (seedUnloadable) {
        failUnloadableSeed();
        return;
      }
      var parked = false;
      if (!_isCurrent(session)) return;
      if (totalQueued <= 0) {
        if (isInitial && initialQueueChangeAttempted) {
          await _restorePreviousQueue(snapshot, session);
        }
        final terminalError =
            // A rejected bundled key is not the user's to fix: stay silent and
            // fall through (silent self-healing, #694).
            (lastFmResult.apiErrorCode == 10 ||
                    lastFmResult.apiErrorCode == 26) &&
                !ref.read(lastFmBundledKeyProvider)
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
          _nextRefillAllowedAt = _now().add(_kRetryBackoffBase);
          state = const SameVibesState(error: SameVibesError.networkError);
          _reportFailed(session, SameVibesError.networkError);
          return;
        }
        // Only a real failure is worth a retry on this seed; "nothing new"
        // waits for the next song instead.
        final failed =
            switch (lastFmResult.outcome) {
              LastFmFetchOutcome.networkError ||
              LastFmFetchOutcome.parseError => true,
              LastFmFetchOutcome.apiError => !lastFmResult.hasNoSimilarTracks,
              _ => false,
            } ||
            fillErrored;
        if (failed) {
          _scheduleTransientRetry(
            reason: fallbackReason,
            seedSongId: normalizedSeedSongId,
          );
        } else {
          parked = true;
          _parkedSeedSongId = normalizedSeedSongId;
          _consecutiveTransientFailures = 0;
          // The park is not a backoff: a skip right after it gets its refill.
          _nextRefillAllowedAt = null;
          AppLogger.debug(
            'SameVibes diagnostics: seed spent, waiting for the next song '
            'seed=$normalizedSeedSongId',
          );
        }
      } else {
        AppLogger.debug('SameVibes diagnostics: queuedTracks=$totalQueued');
        _consecutiveTransientFailures = 0;
        _nextRefillAllowedAt = _now().add(_kMinimumRefillInterval);
      }

      state = state.copyWith(
        refilling: false,
        pendingSnackbar: isInitial ? '$totalQueued' : null,
      );
      // Where the songs came from, by the source this refill asked.
      final mixSource = mappedSongs.isEmpty ? 'server' : _recommendationSource;
      _lastRefill = SameVibesRefillRecord(
        mixSource: mixSource,
        at: _now().toUtc(),
        seedId: anchorId ?? normalizedSeedSongId,
        triggerId: normalizedSeedSongId,
        isInitial: isInitial,
        lastFmOutcome: deezerReport.lastFmSkipped
            ? null
            : lastFmResult.outcome.name,
        lastFmSource: deezerReport.lastFmSkipped
            ? null
            : lastFmResult.source.name,
        deezer: deezerReport.record,
        mapped: mappedSongCount,
        fallbackReason: fallbackReason,
        inserted: totalQueued,
        parkedSeedId: parked ? normalizedSeedSongId : null,
        chunks: chunks,
        firstAppendMs: firstAppendMs,
      );
      // The first Deezer batch shipped what had arrived; fetch the rest (and
      // the features) in the background for the next refill.
      final topUpPool = deezerReport.pool;
      if (deezerReport.firstBatch && topUpPool != null && _isCurrent(session)) {
        unawaited(topUpPool.topUp(_lastFeatureIds));
      }
      ref
          .read(recommendationSessionProvider.notifier)
          .report(
            session,
            // A failed refill keeps the stage its retry reported (pending or
            // exhausted); a refill that queued songs, or parked, is 'active'.
            stage: totalQueued > 0 || parked ? 'active' : null,
            retryCount: totalQueued > 0 || parked ? 0 : null,
            source: mixSource,
            candidateCount: mappedSongs.length + fallbackSongs.length,
            insertedCount: totalQueued,
          );
      // Parked on the last song with repeat off: nothing can extend the
      // queue, so end the mix now instead of leaving the button lit.
      // The playing song must still be the parked seed: after a skip onto
      // the last item, that song has not been tried yet (re-checked below).
      final playing = ref.read(playerStateProvider);
      if (parked &&
          playing.currentSongId?.trim() == normalizedSeedSongId &&
          _mixCannotExtend(playing)) {
        deactivate();
        return;
      }
      // The user may have skipped while this refill ran (snapshots are
      // ignored meanwhile), and steady playback sends no further one.
      // A streamed refill that queued songs looks again when the song moved on
      // meanwhile (an unmoved song would chain refills on low-yield libraries).
      final movedOn = ref.read(playerStateProvider).currentSongId;
      if (parked
          ? movedOn?.trim() != normalizedSeedSongId
          : !isInitial &&
                totalQueued > 0 &&
                movedOn != snapshot.currentSongId) {
        scheduleMicrotask(() {
          if (ref.mounted) {
            _onSnapshotChanged(null, ref.read(playerStateProvider));
          }
        });
      }
    } on Exception catch (error) {
      if (totalQueued > 0) {
        _endPartialRefill(session, error);
        return;
      }
      if (isInitial && initialQueueChangeAttempted) {
        await _restorePreviousQueue(snapshot, session);
      }
      AppLogger.debug('SameVibes refill error: $error');
      if (!_isCurrent(session)) return;
      if (isInitial) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _nextRefillAllowedAt = _now().add(_kRetryBackoffBase);
        state = const SameVibesState(error: SameVibesError.networkError);
        _reportFailed(session, SameVibesError.networkError);
        return;
      }
      _scheduleTransientRetry(
        reason: 'unexpected_exception',
        seedSongId: normalizedSeedSongId,
      );
      state = state.copyWith(
        refilling: false,
        error: SameVibesError.networkError,
      );
    } on Object catch (error, stackTrace) {
      if (totalQueued > 0) {
        _endPartialRefill(session, error);
        return;
      }
      if (isInitial && initialQueueChangeAttempted) {
        await _restorePreviousQueue(snapshot, session);
      }
      AppLogger.debug('SameVibes refill error: $error\n$stackTrace');
      if (!_isCurrent(session)) return;
      if (isInitial) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _nextRefillAllowedAt = _now().add(_kRetryBackoffBase);
        state = const SameVibesState(error: SameVibesError.networkError);
        _reportFailed(session, SameVibesError.networkError);
        return;
      }
      _scheduleTransientRetry(
        reason: 'unexpected_exception',
        seedSongId: normalizedSeedSongId,
      );
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

  /// A failure after songs were queued ends the run as a success: a live mix
  /// is never rolled back, shows no error and needs no retry (#759).
  void _endPartialRefill(RecommendationSession session, Object error) {
    AppLogger.debug('SameVibes refill error after queuing: $error');
    if (!_isCurrent(session)) return;
    _nextRefillAllowedAt = _now().add(_kMinimumRefillInterval);
    state = state.copyWith(refilling: false);
    ref
        .read(recommendationSessionProvider.notifier)
        .report(session, stage: 'active');
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
            // A shuffled queue stays shuffled; the queue ids are its play order.
            originalOrder: snapshot.shuffleMode == AudioServiceShuffleMode.all
                ? snapshot.queueSongIds
                : null,
            notifyMixSessionReset: false,
          );
    } on Object {
      // Keep the original recommendation failure as the reported result.
    }
  }

  Future<_SeedMetadata?> _resolveSeedMetadata({
    required SubsonicApiClient api,
    required String seedSongId,
    bool rethrowNotFound = false,
  }) async {
    final mediaItem = ref.read(currentMediaItemProvider).asData?.value;
    final mediaTitle = mediaItem?.title.trim() ?? '';
    final mediaArtist = mediaItem?.artist?.trim() ?? '';
    final fromMediaItem =
        mediaItem?.id == seedSongId &&
            mediaTitle.isNotEmpty &&
            mediaArtist.isNotEmpty
        ? _SeedMetadata(
            title: mediaTitle,
            artist: mediaArtist,
            artistId: (mediaItem?.extras?['artistId'] as String?)?.trim(),
          )
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
          artistId: fromMediaItem.artistId ?? song.artistId?.trim(),
          song: song,
        );
      }
      if (title.isEmpty || artist.isEmpty) {
        return null;
      }
      return _SeedMetadata(
        title: title,
        artist: artist,
        libraryCopyId: libraryCopyId,
        artistId: song.artistId?.trim(),
        song: song,
      );
    } on SubsonicNotFoundException {
      if (rethrowNotFound) rethrow;
      return fromMediaItem;
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
    required bool Function() alive,
    required Future<bool> Function(List<Song> chunk) onChunk,
  }) async {
    if (recommendations.isEmpty) {
      return 0;
    }

    // Songs already queued need no search, and a search that resolves to one
    // is "already have", not a miss: overlapping Last.fm lists (#377) would
    // otherwise fill the whole budget with queued songs and park every seed.
    // Walks the full requested list; only misses spend `maxSearchAttempts`.
    // Also dropped before any search: junk versions, a second version of a
    // song already in the list, and a long run by one artist, so the miss
    // budget goes to songs that can be used.
    final sorted = [...recommendations]
      ..sort((a, b) => (b.match ?? 0).compareTo(a.match ?? 0));
    final seenKeys = <String>{...blockedSongKeys};
    final searchedPerArtist = <String, int>{};
    final attemptsLimit = <LastFmTrackRecommendation>[];
    for (final rec in sorted) {
      final key = sameVibesCanonicalSongKey(rec.artist, rec.title);
      final artist = looseArtistKey(rec.artist);
      if ((key != null && seenKeys.contains(key)) ||
          (!preferences.allowJunkVersions && isJunkSongVersion(rec.title)) ||
          (searchedPerArtist[artist] ?? 0) >= _kMaxSearchedPerArtist) {
        continue;
      }
      if (key != null) seenKeys.add(key);
      searchedPerArtist[artist] = (searchedPerArtist[artist] ?? 0) + 1;
      attemptsLimit.add(rec);
    }
    // Two per artist while the list lasts; the rest wait in [deferred] and
    // fill a short batch (three, then any number per artist).
    final spacing = ArtistSpacing();
    final deferred = <Song>[];
    final deferredKeys = <String>{};
    var attempts = 0;
    var misses = 0;
    var mappedCount = 0;
    final pendingChunk = <Song>[];
    var stopped = false;

    for (
      var batchStart = 0;
      batchStart < attemptsLimit.length;
      batchStart += _kMappingParallelism
    ) {
      if (!alive() ||
          mappedCount >= targetCount ||
          misses >= maxSearchAttempts) {
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
        if (!alive() || mappedCount >= targetCount) {
          break;
        }
        attempts += 1;
        if (best == null) {
          misses += 1;
          continue;
        }
        final id = best.id.trim();
        if (id.isEmpty) {
          misses += 1;
          continue;
        }
        final key = sameVibesCanonicalSongKey(best.artist ?? '', best.title);
        if (blockedIds.contains(id) ||
            (key != null && blockedSongKeys.contains(key)) ||
            (!preferences.allowJunkVersions && isJunkSongVersion(best.title))) {
          continue;
        }
        if (!spacing.allows(_artistKey(best), cap: 2, backToBack: true)) {
          // One waiting version per song, by id or key.
          if (key == null
              ? !deferred.any((song) => song.id.trim() == id)
              : deferredKeys.add(key)) {
            deferred.add(best);
          }
          continue;
        }
        spacing.add(_artistKey(best));
        pendingChunk.add(best);
        blockedIds.add(id);
        if (key != null) {
          blockedSongKeys.add(key);
        }
        mappedCount += 1;
      }
      // One append per group: a group resolves together, so nothing could be
      // queued sooner. An append that inserted nothing is not a reason to stop.
      if (pendingChunk.isNotEmpty) {
        final keepGoing = await onChunk(List<Song>.from(pendingChunk));
        pendingChunk.clear();
        if (!keepGoing) {
          stopped = true;
          break;
        }
      }
    }

    if (!stopped && alive() && mappedCount < targetCount) {
      // A waiting song whose key was queued since (a later candidate placed
      // another version) stays out.
      final waiting = deferred.where((song) {
        final key = sameVibesCanonicalSongKey(song.artist ?? '', song.title);
        return key == null || !blockedSongKeys.contains(key);
      }).toList();
      for (final song in spaceByArtist<Song>(
        waiting,
        artistOf: _artistKey,
        count: targetCount - mappedCount,
        spacing: spacing,
      )) {
        pendingChunk.add(song);
        blockedIds.add(song.id.trim());
        final key = sameVibesCanonicalSongKey(song.artist ?? '', song.title);
        if (key != null) blockedSongKeys.add(key);
        mappedCount += 1;
      }
    }
    if (!stopped && alive() && pendingChunk.isNotEmpty) {
      await onChunk(List<Song>.from(pendingChunk));
    }
    AppLogger.debug(
      'SameVibes diagnostics: mappingSummary '
      'mapped=$mappedCount attempts=$attempts misses=$misses '
      'excluded=${blockedIds.length}',
    );

    return mappedCount;
  }

  /// Similar-song candidates from the source Instant Mix is set to. Deezer
  /// mode never calls Last.fm, so only that source's errors can end a mix.
  Future<LastFmTrackFetchResult> _fetchRecommendations({
    required _SeedMetadata seed,
    required _SeedMetadata? anchorSeed,
    required String? anchorId,
    required RecommendationSession session,
    required SameVibesDeezerPool? pool,
    required _DeezerLegReport report,
    required int limit,
    required bool background,
  }) async {
    switch (ref.read(preferredMixModeProvider)) {
      case PreferredMixMode.sameVibesDeezer:
        _recommendationSource = 'deezer';
        report.lastFmSkipped = true;
        return _fetchDeezerRadio(
          seed: anchorSeed,
          anchorId: anchorId,
          session: session,
          pool: pool,
          report: report,
          background: background,
        );
      case PreferredMixMode.legacyInstantMix:
        // The user switched to Server Mix after this mix started.
        return const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.notConfigured,
          tracks: <LastFmTrackRecommendation>[],
        );
      case PreferredMixMode.sameVibesLastFm:
        break;
    }
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

    _recommendationSource = 'lastFm';
    final result = await client.getSimilarTracksResult(
      artist: seed.artist,
      track: seed.title,
      limit: limit,
    );
    // Last.fm rejected the key: the user chose a source they cannot use, so
    // Deezer carries this fetch. Without songs from Deezer, the Last.fm
    // answer stands and its one-time notice can show.
    if ((result.apiErrorCode == 10 || result.apiErrorCode == 26) &&
        ref
            .read(integrationPolicyProvider)
            .allows(IntegrationFeature.deezerSameVibes)) {
      final deezer = await _fetchDeezerRadio(
        seed: anchorSeed,
        anchorId: anchorId,
        session: session,
        pool: pool,
        report: report,
        background: background,
      );
      if (deezer.tracks.isNotEmpty) {
        _recommendationSource = 'deezer';
        return deezer;
      }
    }
    AppLogger.debug(
      'SameVibes diagnostics: lastfm recommendations=${result.tracks.length} '
      'artist="${seed.artist}" track="${seed.title}" '
      'outcome=${result.outcome.name} source=${result.source.name} '
      'status=${result.statusCode} apiCode=${result.apiErrorCode}',
    );
    return result;
  }

  /// The Deezer leg: the anchor's pool ranked into recommendations, within
  /// [_kDeezerLegTimeout] (the first batch) or [_kDeezerRefillLegTimeout] (a
  /// refill, which waits for the pool top-up). Quota or a timeout reads as
  /// "skipped" (no retry); codes stay null so Last.fm's terminal errors cannot
  /// come from here.
  ///
  /// ponytail: an empty radio has no `/top` fallback; the server fills.
  Future<LastFmTrackFetchResult> _fetchDeezerRadio({
    required _SeedMetadata? seed,
    required String? anchorId,
    required RecommendationSession session,
    required SameVibesDeezerPool? pool,
    required _DeezerLegReport report,
    required bool background,
  }) async {
    const skipped = LastFmTrackFetchResult(
      outcome: LastFmFetchOutcome.noResults,
      tracks: <LastFmTrackRecommendation>[],
      message: _kDeezerSkippedReason,
    );
    if (seed == null) {
      // The anchor's metadata is still unknown: never rank from the trigger.
      // The server fills; the next refill asks for the anchor again.
      report.record = _deezerRecord(
        null,
        0,
        skipped: true,
        firstBatch: false,
        likedSignals: 0,
      );
      return skipped;
    }
    final stopwatch = Stopwatch()..start();
    final legToken = CancelToken();
    _deezerLegToken = legToken;
    LastFmTrackFetchResult result;
    try {
      result =
          await _deezerRadioLeg(
            seed: seed,
            anchorId: anchorId,
            session: session,
            pool: pool,
            report: report,
            legToken: legToken,
          ).timeout(
            background ? _kDeezerRefillLegTimeout : _kDeezerLegTimeout,
            onTimeout: () {
              legToken.cancel();
              return skipped;
            },
          );
    } on DeezerApiException catch (error) {
      AppLogger.debug('SameVibes diagnostics: deezer leg $error');
      result = error.isQuotaExceeded
          ? skipped
          : const LastFmTrackFetchResult(
              outcome: LastFmFetchOutcome.networkError,
              tracks: <LastFmTrackRecommendation>[],
            );
    } on DioException catch (error) {
      AppLogger.debug('SameVibes diagnostics: deezer leg ${error.type.name}');
      result = CancelToken.isCancel(error)
          ? skipped
          : const LastFmTrackFetchResult(
              outcome: LastFmFetchOutcome.networkError,
              tracks: <LastFmTrackRecommendation>[],
            );
    } finally {
      if (identical(_deezerLegToken, legToken)) _deezerLegToken = null;
    }
    report.record = _deezerRecord(
      report.pool,
      stopwatch.elapsedMilliseconds,
      skipped: result.message == _kDeezerSkippedReason,
      firstBatch: report.firstBatch,
      likedSignals: report.likedSignals,
      poolSize: report.poolSize,
      featuresUsed: report.featuresUsed,
    );
    return result;
  }

  Map<String, Object?> _deezerRecord(
    SameVibesDeezerPool? pool,
    int msTotal, {
    required bool skipped,
    required bool firstBatch,
    required int likedSignals,
    int poolSize = 0,
    int featuresUsed = 0,
  }) {
    final stats = pool?.stats;
    return <String, Object?>{
      'poolSize': poolSize,
      'relatedCount': stats?.relatedCount ?? 0,
      'listsUsed': stats?.listsUsed ?? 0,
      'featuresUsed': featuresUsed,
      'likedSignals': likedSignals,
      // Only the refill that ran the first batch has these.
      'deadlineHit': firstBatch ? stats?.deadlineHit : null,
      'msLists': firstBatch ? stats?.msLists : null,
      'msTotal': msTotal,
      'skipped': skipped,
    };
  }

  /// A request of the pool, under the mix's cancel token. Stopping the mix
  /// stops the pool: a cancelled session starts no further request.
  SameVibesPoolRunner _poolRunner(RecommendationSession session) =>
      <T>(request, {leg = false}) => session.withCancelToken((token) {
        if (token.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: 'Same Vibes stopped',
          );
        }
        final legToken = leg ? _deezerLegToken : null;
        if (legToken != null) {
          unawaited(legToken.whenCancel.then((_) => token.cancel()));
        }
        return request(token);
      });

  Future<LastFmTrackFetchResult> _deezerRadioLeg({
    required _SeedMetadata seed,
    required String? anchorId,
    required RecommendationSession session,
    required SameVibesDeezerPool? pool,
    required _DeezerLegReport report,
    required CancelToken legToken,
  }) async {
    var vibesPool = pool;
    const empty = LastFmTrackFetchResult(
      outcome: LastFmFetchOutcome.noResults,
      tracks: <LastFmTrackRecommendation>[],
    );
    var firstBatch = false;
    if (vibesPool == null) {
      // The mix's first Deezer leg (also after a switch from Last.fm).
      if (!_isCurrent(session)) return empty;
      final libraryArtistId = seed.artistId;
      // Read the providers directly: an unlistened provider is paused.
      vibesPool = _vibesPool = SameVibesDeezerPool(
        client: ref.read(deezerApiClientProvider),
        catalog: ref.read(deezerCatalogProvider),
        resolver: ref.read(deezerArtistResolverProvider),
        readLibraryAlbumTitles:
            libraryArtistId == null ||
                libraryArtistId.isEmpty ||
                libraryArtistId.startsWith('ext-')
            ? null
            : libraryAlbumTitlesReader(
                ref.read(navisDatabaseProvider).libraryDao,
                libraryArtistId,
              ),
        runner: _poolRunner(session),
      );
      firstBatch = true;
    }
    report
      ..pool = vibesPool
      ..firstBatch = firstBatch;
    final SameVibesRanking ranking;
    if (firstBatch) {
      final batch = await vibesPool.firstBatch(
        SameVibesPoolSeed(
          songId: anchorId ?? '',
          artistId: seed.artistId,
          artist: seed.artist,
          title: seed.title,
        ),
      );
      if (batch == null) return empty;
      ranking = rankSameVibesPool(
        seedArtistId: batch.seedArtistId,
        relatedArtistIds: batch.relatedArtistIds,
        seedRadio: batch.seedRadio,
        relatedLists: batch.relatedLists,
        seedFeatures: vibesPool.seedTrack,
        featuresOf: vibesPool.featuresOf,
      );
    } else {
      // Repair what the pool lacks first; the top-up keeps running if it is
      // slow, and the ranking uses what has arrived.
      await vibesPool
          .topUp(_lastFeatureIds)
          .timeout(_kVibesTopUpWait, onTimeout: () {});
      // Errors propagate (the Deezer-leg failure path); null is a clean empty.
      // The last two played-through songs by the seed's neighbourhood.
      final likedIds = <int>[];
      for (final songId in _playedThrough.reversed) {
        final artist = _mixArtists[songId];
        final deezerId = artist == null
            ? null
            : vibesPool.deezerArtistIdFor(artist);
        if (deezerId != null && !likedIds.contains(deezerId)) {
          likedIds.add(deezerId);
          if (likedIds.length == 2) break;
        }
      }
      final lists = await vibesPool.refillLists(likedIds);
      final seedArtistId = vibesPool.seedArtistId;
      if (lists == null || seedArtistId == null) return empty;
      report.likedSignals = lists.likedRadios.length;
      ranking = rankSameVibesPool(
        seedArtistId: seedArtistId,
        relatedArtistIds: vibesPool.relatedArtistIds,
        seedRadio: lists.seedRadio,
        relatedLists: vibesPool.relatedLists,
        likedRadios: lists.likedRadios,
        seedFeatures: vibesPool.seedTrack,
        featuresOf: vibesPool.featuresOf,
      );
    }
    // A leg that timed out (its token is cancelled) must not overwrite what a
    // newer refill ranked.
    if (_isCurrent(session) && !legToken.isCancelled) {
      _lastFeatureIds = ranking.featureIds;
    }
    report.poolSize = ranking.ordered.length;
    final pooled = vibesPool;
    report.featuresUsed = pooled.seedTrack == null
        ? 0
        : ranking.featureIds
              .where((id) => pooled.featuresOf(id) != null)
              .length;
    // The mapper sorts by match, so the ranked order needs strictly
    // decreasing values; the seed itself is never recommended.
    final seedKey = sameVibesCanonicalSongKey(seed.artist, seed.title);
    final usable = <DeezerTrack>[
      for (final track in ranking.ordered)
        if (track.artist.name.trim().isNotEmpty &&
            track.title.trim().isNotEmpty &&
            sameVibesCanonicalSongKey(track.artist.name, track.title) !=
                seedKey)
          track,
    ];
    final tracks = <LastFmTrackRecommendation>[
      for (var i = 0; i < usable.length; i++)
        LastFmTrackRecommendation(
          artist: usable[i].artist.name,
          title: usable[i].title,
          match: 1 - i / usable.length,
        ),
    ];
    return LastFmTrackFetchResult(
      outcome: tracks.isEmpty
          ? LastFmFetchOutcome.noResults
          : LastFmFetchOutcome.success,
      tracks: tracks,
    );
  }

  /// The server id whose similar songs back the fallback: the seed itself, or
  /// a remote seed's library copy. A remote seed without a library copy has no
  /// fallback, and never borrows the similar songs of an unrelated queue
  /// neighbour.
  String? _resolveFallbackSeedSongId({
    required String preferredSeedSongId,
    String? libraryCopyId,
  }) {
    if (_isServerAddressableSeedId(preferredSeedSongId)) {
      return preferredSeedSongId;
    }
    return libraryCopyId;
  }

  /// How a failed similar-songs ask is told apart: a missing seed is final,
  /// the rest is retried.
  String _subsonicFailureReason(SubsonicException error) => switch (error) {
    SubsonicNotFoundException() => 'fallback_seed_not_found',
    SubsonicApiException() => 'fallback_api_error',
    _ => 'fallback_transport_error',
  };

  bool _isServerAddressableSeedId(String id) => isServerAddressableSongId(id);

  bool _isEndpointUnsupportedMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('endpoint') ||
        normalized.contains('not found on this server') ||
        normalized.contains('not support') ||
        normalized.contains('unsupported');
  }

  /// Whether nothing can extend the queue past the current song: it is the
  /// last one and repeat is off.
  bool _mixCannotExtend(PlaybackSnapshot snapshot) =>
      snapshot.repeatMode == AudioServiceRepeatMode.none &&
      snapshot.currentIndex == snapshot.queueSongIds.length - 1;

  void _scheduleTransientRetry({
    required String reason,
    required String seedSongId,
  }) {
    if (!state.active) {
      return;
    }
    _consecutiveTransientFailures += 1;
    if (_consecutiveTransientFailures >= 5) {
      _parkedSeedSongId = seedSongId;
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
    final nextAt = _now().add(delay);
    _nextRefillAllowedAt = nextAt;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!state.active || state.refilling) {
        return;
      }
      // The timer firing is the backoff elapsing; the wall clock can read a
      // hair early, which would make `_refill` skip and never retry.
      _nextRefillAllowedAt = null;
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
      if (score < _kMinimumMappingScore) continue;
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

  /// The server's similar songs that are new to the mix, up to
  /// [targetCount], one version per song and spread over artists (counting
  /// the [chosen] songs of this batch already). A seed that is itself a
  /// variant (live, remix) prefers variants; the rest prefer the studio cut.
  List<Song> _mergeUniqueSongs({
    required List<Song> fallback,
    required Set<String> excludedIds,
    required Set<String> excludedSongKeys,
    required int targetCount,
    required Iterable<Song> chosen,
    required String? seedTitle,
    required bool allowJunk,
  }) {
    bool isVariant(String title) =>
        normalizeMetadataKeepingEdition(title) != songVersionTitleKey(title);
    final seedIsVariant = seedTitle != null && isVariant(seedTitle);
    final ordered = [
      ...fallback.where((song) => isVariant(song.title) == seedIsVariant),
      ...fallback.where((song) => isVariant(song.title) != seedIsVariant),
    ];
    final seen = <String>{...excludedIds};
    final seenSongKeys = <String>{...excludedSongKeys};
    final unique = <Song>[];
    for (final song in ordered) {
      final id = song.id.trim();
      final key = sameVibesCanonicalSongKey(song.artist ?? '', song.title);
      if (id.isEmpty ||
          seen.contains(id) ||
          (key != null && seenSongKeys.contains(key)) ||
          (!allowJunk && isJunkSongVersion(song.title))) {
        continue;
      }
      unique.add(song);
      seen.add(id);
      if (key != null) seenSongKeys.add(key);
    }
    final spacing = ArtistSpacing();
    for (final song in chosen) {
      spacing.add(_artistKey(song));
    }
    return spaceByArtist<Song>(
      unique,
      artistOf: _artistKey,
      count: targetCount,
      spacing: spacing,
    );
  }

  /// The artist identity the spacing compares: spellings and "The"/"&"
  /// variants of one artist are one.
  static String _artistKey(Song song) => looseArtistKey(song.artist ?? '');
}

class _SeedMetadata {
  const new({
    required this.artist,
    required this.title,
    this.libraryCopyId,
    this.artistId,
    this.song,
  });

  final String artist;
  final String title;

  /// What `getSong` answered for the seed, kept to store an unsaved seed.
  final Song? song;

  /// The server's artist id, when known; it keys the Deezer artist lookup.
  final String? artistId;

  /// The server's library copy of a remote seed, when it has one.
  final String? libraryCopyId;
}

class _CandidatePreferenceContext {
  const new({
    required this.downloadedSongIds,
    required this.cachedSongIds,
    this.allowJunkVersions = false,
  });

  final Set<String> downloadedSongIds;
  final Set<String> cachedSongIds;

  /// The seed is itself a sped-up, slowed, nightcore... version, so the mix
  /// keeps those.
  final bool allowJunkVersions;
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
      final key = sameVibesCanonicalSongKey(song.artistName ?? '', song.title);
      if (key != null) keys.add(key);
    }
    return keys;
  };
});

final sameVibesProvider = NotifierProvider<SameVibesNotifier, SameVibesState>(
  SameVibesNotifier.new,
);

/// What one refill's Deezer leg tells the refill: the pool it used, whether
/// that was the mix's first batch, and the record for the diagnostics.
class _DeezerLegReport {
  SameVibesDeezerPool? pool;
  bool firstBatch = false;
  int poolSize = 0;
  int featuresUsed = 0;

  /// Liked-song radios this refill asked for (played-through signals).
  int likedSignals = 0;

  /// Deezer mode never asks Last.fm, so its outcome fields stay null.
  bool lastFmSkipped = false;
  Map<String, Object?>? record;
}

/// The last refill of a mix, for the diagnostics. Holds song ids and enum
/// names only: no server address, user name or token.
class SameVibesRefillRecord {
  const new({
    required this.at,
    required this.mixSource,
    required this.seedId,
    required this.triggerId,
    required this.isInitial,
    required this.lastFmOutcome,
    required this.lastFmSource,
    this.deezer,
    required this.mapped,
    required this.fallbackReason,
    required this.inserted,
    required this.parkedSeedId,
    this.chunks = 0,
    this.firstAppendMs,
  });

  final DateTime at;

  /// Where the queued songs came from: `deezer`, `lastFm` or `server`. The
  /// `lastFm*` fields below keep their names for readers of the diagnostics.
  final String mixSource;

  /// The mix's anchor (activation seed), and the song that fired the refill.
  final String seedId;
  final String triggerId;
  final bool isInitial;

  /// Null when Last.fm was not asked (Deezer mode).
  final String? lastFmOutcome;
  final String? lastFmSource;

  /// The Deezer leg: pool counts, `msTotal` and `skipped`; null when the
  /// refill never ran a Deezer leg.
  final Map<String, Object?>? deezer;
  final int mapped;
  final String fallbackReason;
  final int inserted;
  final String? parkedSeedId;

  /// How many appends queued songs, and how long after the refill started
  /// the first one did (null when none did).
  final int chunks;
  final int? firstAppendMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'mixSource': mixSource,
    'seedId': seedId,
    'triggerId': triggerId,
    'isInitial': isInitial,
    'lastFmOutcome': lastFmOutcome,
    'lastFmSource': lastFmSource,
    'deezer': deezer,
    'mapped': mapped,
    'fallbackReason': fallbackReason,
    'inserted': inserted,
    'parkedSeedId': parkedSeedId,
    'chunks': chunks,
    'firstAppendMs': firstAppendMs,
  };
}
