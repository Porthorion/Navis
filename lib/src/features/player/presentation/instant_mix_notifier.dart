import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Number of remaining mix tracks (after the current one) that triggers refill.
const _kRefillThreshold = 3;

/// Maximum duration a single refill fetch is allowed to run before it is
/// cancelled and the refilling flag is reset.
const _kRefillTimeout = Duration(seconds: 30);

/// Guard against rapid repeated refill attempts from playback ticks.
const _kMinimumRefillInterval = Duration(milliseconds: 1200);

/// Global notifier that manages the Instant Mix auto-refill mode.
///
/// When `active`, this notifier watches the playback queue and automatically
/// appends similar tracks whenever fewer than [_kRefillThreshold] mix tracks
/// remain after the current position.  The seed song is updated each cycle to
/// the currently-playing track, keeping the recommendations fresh.
///
/// The provider is intentionally **not** `autoDispose` — the Instant Mix
/// session should persist across navigation until explicitly deactivated or
/// the queue is cleared by the user.
class InstantMixNotifier extends Notifier<InstantMixState> {
  /// [now] lets tests step the refill backoff without waiting.
  new({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// The session whose refill is running. It prevents overlapping refills of
  /// one session even before the Riverpod state update is observed, while a
  /// new activation (a new session) starts its own refill at once.
  RecommendationSession? _refillingSession;

  /// Exclusive end index of the active mix segment in the playback queue.
  ///
  /// Refill is based on tracks within this segment, not the pre-mix queue tail.
  int? _mixSegmentEndIndex;
  DateTime? _nextRefillAllowedAt;
  bool _activationInProgress = false;
  bool _suppressActivationSeedSnapshot = false;
  RecommendationSession? _session;
  Timer? _retryTimer;
  int _transientFailures = 0;

  /// Set after five consecutive failed refills: the mix stops refilling until
  /// the user starts it again.
  bool _retryExhausted = false;

  @override
  InstantMixState build() {
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
    ref.onDispose(() => _retryTimer?.cancel());
    return const InstantMixState.inactive();
  }

  Future<void> activate(String seedSongId) async {
    final normalizedSeedSongId = seedSongId.trim();
    if (normalizedSeedSongId.isEmpty) {
      return;
    }
    _mixSegmentEndIndex = null;
    _nextRefillAllowedAt = null;
    _transientFailures = 0;
    _retryExhausted = false;
    _retryTimer?.cancel();
    final coordinator = ref.read(recommendationSessionProvider.notifier);
    final session = coordinator.start(
      RecommendationMode.serverMix,
      seedId: normalizedSeedSongId,
    );
    _session = session;
    _activationInProgress = true;
    _suppressActivationSeedSnapshot = true;
    state = InstantMixState(active: true, seedSongId: normalizedSeedSongId);
    try {
      await _refill(normalizedSeedSongId, isInitial: true);
    } finally {
      // A newer activation owns the flag now.
      if (identical(_session, session)) {
        _activationInProgress = false;
      }
    }
  }

  void deactivate() {
    final session = _session;
    if (session != null) {
      ref.read(recommendationSessionProvider.notifier).stop(session);
    }
    _session = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _transientFailures = 0;
    _retryExhausted = false;
    _mixSegmentEndIndex = null;
    _nextRefillAllowedAt = null;
    _activationInProgress = false;
    _suppressActivationSeedSnapshot = false;
    state = const InstantMixState.inactive();
  }

  Future<void> toggle(String? currentSongId) async {
    if (state.active) {
      deactivate();
    } else if (currentSongId != null) {
      await activate(currentSongId);
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
    if (_retryExhausted) return;
    if (_consumeActivationSeedSnapshot(next)) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error != null) return;

    if (next.queueSongIds.isEmpty) {
      _mixSegmentEndIndex = null;
      state = const InstantMixState.inactive();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final remaining = _mixRemainingAfterCurrent(currentIndex, next);

    if (remaining <= _kRefillThreshold) {
      final nextAllowed = _nextRefillAllowedAt;
      if (nextAllowed != null && _now().isBefore(nextAllowed)) {
        return;
      }
      final seedSongId = next.currentSongId ?? state.seedSongId;
      if (seedSongId != null) {
        unawaited(_refill(seedSongId));
      }
    }
  }

  int _mixRemainingAfterCurrent(int currentIndex, PlaybackSnapshot snapshot) {
    final mixEnd = _mixSegmentEndIndex;
    if (mixEnd != null) {
      return mixEnd - currentIndex - 1;
    }
    return snapshot.queueSongIds.length - currentIndex - 1;
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

  /// Whether [session] is still the active mix. A refill of a superseded
  /// session (the user started another mix) must not touch state or queue.
  bool _isCurrent(RecommendationSession session) =>
      identical(_session, session) &&
      ref.read(recommendationSessionProvider.notifier).owns(session);

  Future<void> _refill(String seedSongId, {bool isInitial = false}) async {
    final refillSession = _session;
    if (refillSession == null) return;
    if (!isInitial && _retryExhausted) return;
    // Only a refill of this same session blocks. Starting a mix replaces the
    // session and cancels the old fetch, so its first refill runs at once
    // instead of waiting, "preparing", for the superseded one.
    if (identical(_refillingSession, refillSession) || state.refilling) return;
    _refillingSession = refillSession;
    state = state.copyWith(refilling: true, seedSongId: seedSongId);

    try {
      await _doRefill(seedSongId, refillSession, isInitial: isInitial).timeout(
        _kRefillTimeout,
        onTimeout: () {
          if (!ref.mounted || !_isCurrent(refillSession)) return;
          AppLogger.debug(
            'InstantMix: refill timed out after ${_kRefillTimeout.inSeconds}s '
            '— resetting',
          );
          ref.read(recommendationSessionProvider.notifier).stop(refillSession);
          state = const InstantMixState(error: InstantMixError.networkError);
        },
      );
    } on Object catch (error, stackTrace) {
      if (!ref.mounted || !_isCurrent(refillSession)) return;
      AppLogger.debug('InstantMix refill failed: $error\n$stackTrace');
      if (isInitial) {
        state = const InstantMixState(error: InstantMixError.networkError);
        _reportFailed(refillSession, InstantMixError.networkError);
        return;
      }
      if (state.active) {
        _scheduleTransientRetry(seedSongId, 'networkFailure');
      }
    } finally {
      if (identical(_refillingSession, refillSession)) {
        _refillingSession = null;
      }
      if (ref.mounted &&
          _isCurrent(refillSession) &&
          state.active &&
          state.refilling) {
        state = state.copyWith(refilling: false);
      }
    }
  }

  Future<void> _doRefill(
    String seedSongId,
    RecommendationSession session, {
    bool isInitial = false,
  }) async {
    final coordinator = ref.read(recommendationSessionProvider.notifier);
    final previousQueue = isInitial ? ref.read(playerStateProvider) : null;
    var queueChangeAttempted = false;
    try {
      final batch = await session.withCancelToken(
        (cancelToken) => ref
            .read(recommendationServiceProvider)
            .serverMix(seedSongId, count: 50, cancelToken: cancelToken),
      );
      if (!ref.mounted) return;
      if (!coordinator.owns(session)) return;
      coordinator.report(
        session,
        stage: 'prepared',
        source: batch.source.name,
        candidateCount: batch.songs.length,
      );
      if (batch.songs.isEmpty) {
        state = InstantMixState(
          error: batch.issue == RecommendationIssue.unsupported
              ? InstantMixError.unsupported
              : InstantMixError.networkError,
        );
        coordinator.report(
          session,
          stage: 'failed',
          errorCategory: batch.issue.name,
        );
        return;
      }
      if (isInitial) {
        queueChangeAttempted = true;
        await ref.read(queueProvider.notifier).retainCurrentAsQueue(seedSongId);
        if (!ref.mounted) return;
        if (!coordinator.owns(session)) return;
      }
      final queuedCount = await _queueMixSongs(batch.songs, session);
      if (!ref.mounted) return;
      if (!coordinator.owns(session)) return;
      if (queuedCount <= 0) {
        if (previousQueue != null) {
          await _restorePreviousQueue(previousQueue, session);
        }
        if (isInitial) {
          state = const InstantMixState(error: InstantMixError.networkError);
          _reportFailed(session, InstantMixError.networkError);
        } else {
          _scheduleTransientRetry(seedSongId, 'zeroInsertion');
        }
        return;
      }
      _transientFailures = 0;
      _retryTimer?.cancel();
      state = state.copyWith(
        refilling: false,
        pendingSnackbar: isInitial ? '$queuedCount' : null,
      );
      coordinator.report(session, stage: 'active', insertedCount: queuedCount);
    } on SubsonicNotFoundException {
      if (!ref.mounted || !_isCurrent(session)) return;
      state = const InstantMixState(error: InstantMixError.unsupported);
      _reportFailed(session, InstantMixError.unsupported);
    } on Object catch (error, stackTrace) {
      if (!ref.mounted) return;
      if (queueChangeAttempted && previousQueue != null) {
        await _restorePreviousQueue(previousQueue, session);
      }
      AppLogger.debug('InstantMix _doRefill error: $error\n$stackTrace');
      if (!_isCurrent(session)) return;
      if (isInitial) {
        state = const InstantMixState(error: InstantMixError.networkError);
        _reportFailed(session, InstantMixError.networkError);
        return;
      }
      if (state.active) {
        _scheduleTransientRetry(seedSongId, 'networkFailure');
      }
    }
  }

  /// Ends [session] as failed so it does not keep reading "preparing". A
  /// refill reports only its own session; a newer one is left alone.
  void _reportFailed(RecommendationSession session, InstantMixError error) {
    ref
        .read(recommendationSessionProvider.notifier)
        .report(session, stage: 'failed', errorCategory: error.name);
  }

  void _scheduleTransientRetry(String seedSongId, String reason) {
    final session = _session;
    if (session == null || !state.active) return;
    _transientFailures++;
    final exhausted = _transientFailures >= 5;
    if (exhausted) _retryExhausted = true;
    final delay = Duration(
      seconds: 3 * (1 << (_transientFailures - 1).clamp(0, 4)),
    );
    _nextRefillAllowedAt = _now().add(delay);
    state = exhausted
        ? state.copyWith(refilling: false, error: InstantMixError.networkError)
        : state.copyWith(refilling: false, clearError: true);
    ref
        .read(recommendationSessionProvider.notifier)
        .report(
          session,
          stage: exhausted ? 'retryExhausted' : 'retryPending',
          errorCategory: reason,
          retryCount: _transientFailures,
        );
    _retryTimer?.cancel();
    if (!exhausted) {
      _retryTimer = Timer(delay, () {
        if (ref.mounted &&
            ref.read(recommendationSessionProvider.notifier).owns(session)) {
          unawaited(_refill(seedSongId));
        }
      });
    }
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
      // The original insertion failure remains the surfaced result.
    }
  }

  Future<int> _queueMixSongs(
    List<Song> songs,
    RecommendationSession session,
  ) async {
    if (songs.isEmpty) {
      return 0;
    }
    final queueLengthBeforeAppend = ref
        .read(playerStateProvider)
        .queueSongIds
        .length;
    try {
      final result = await ref
          .read(queueProvider.notifier)
          .appendRecommendationTracks(
            songs,
            expandMatchFlows: false,
            isCurrent: () =>
                ref.mounted &&
                ref.read(recommendationSessionProvider.notifier).owns(session),
          );
      final queuedCount = result.count;
      if (queuedCount > 0) {
        _mixSegmentEndIndex = queueLengthBeforeAppend + queuedCount;
        _nextRefillAllowedAt = _now().add(_kMinimumRefillInterval);
      }
      return queuedCount;
    } on Object catch (error, stackTrace) {
      AppLogger.debug('InstantMix queue failed: $error\n$stackTrace');
      rethrow;
    }
  }
}

final instantMixProvider =
    NotifierProvider<InstantMixNotifier, InstantMixState>(
      InstantMixNotifier.new,
    );
