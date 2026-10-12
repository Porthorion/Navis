import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';

class PersonalRadioState {
  const new({
    this.active = false,
    this.busy = false,
    this.issue = RecommendationIssue.none,
    this.source,
    this.insertedCount = 0,
    this.retryCount = 0,
  });

  final bool active;
  final bool busy;
  final RecommendationIssue issue;
  final RecommendationSource? source;
  final int insertedCount;
  final int retryCount;
}

class RadioStartResult {
  const new({required this.insertedCount, required this.issue});

  final int insertedCount;
  final RecommendationIssue issue;

  bool get succeeded => insertedCount > 0;
}

class PersonalRadioNotifier extends Notifier<PersonalRadioState> {
  RecommendationSession? _session;
  RadioFilters _filters = const RadioFilters();
  final List<String> _recentGenerated = <String>[];
  bool _starting = false;
  bool _refilling = false;
  ({int index, String songId})? _pendingSkip;
  DateTime? _nextRetryAt;
  int _failures = 0;
  Timer? _retryTimer;

  @override
  PersonalRadioState build() {
    ref.listen<PlaybackSnapshot>(playerStateProvider, _onSnapshot);
    ref.listen<int>(regularQueueReplacementEpochProvider, (previous, next) {
      stop();
    });
    ref.listen<RecommendationSessionStatus>(recommendationSessionProvider, (
      previous,
      next,
    ) {
      final session = _session;
      if (session != null && next.generation != session.generation) {
        _clearLocalSession();
      }
    });
    ref.onDispose(() => _retryTimer?.cancel());
    return const PersonalRadioState();
  }

  Future<RadioStartResult> start({
    RadioFilters filters = const RadioFilters(),
    bool autoPlay = true,
  }) async {
    if (_starting) {
      return const RadioStartResult(
        insertedCount: 0,
        issue: RecommendationIssue.empty,
      );
    }
    stop();
    final coordinator = ref.read(recommendationSessionProvider.notifier);
    final session = coordinator.start(RecommendationMode.personalRadio);
    _session = session;
    _filters = filters;
    _starting = true;
    state = const PersonalRadioState(busy: true);
    final previousQueue = ref.read(playerStateProvider);
    var queueChangeAttempted = false;
    try {
      final snapshot = previousQueue;
      final excluded = <String>{...snapshot.queueSongIds, ..._recentGenerated};
      final batch = await session.withCancelToken(
        (cancelToken) => ref
            .read(recommendationServiceProvider)
            .personalRadio(
              filters,
              excludedIds: excluded,
              cancelToken: cancelToken,
            ),
      );
      if (!coordinator.owns(session)) {
        return const RadioStartResult(
          insertedCount: 0,
          issue: RecommendationIssue.empty,
        );
      }
      coordinator.report(
        session,
        stage: 'prepared',
        source: batch.source.name,
        candidateCount: batch.songs.length,
      );
      if (batch.songs.isEmpty) {
        state = PersonalRadioState(issue: batch.issue);
        coordinator.report(
          session,
          stage: 'failed',
          errorCategory: batch.issue.name,
        );
        return RadioStartResult(insertedCount: 0, issue: batch.issue);
      }
      queueChangeAttempted = true;
      await ref
          .read(queueProvider.notifier)
          .replaceWithSongs(
            batch.songs,
            autoPlay: autoPlay,
            expandMatchFlows: false,
            notifyMixSessionReset: false,
          );
      if (!coordinator.owns(session)) {
        return const RadioStartResult(
          insertedCount: 0,
          issue: RecommendationIssue.empty,
        );
      }
      final actualIds =
          ref.read(audioHandlerProvider)?.snapshot.queueSongIds ??
          ref.read(playerStateProvider).queueSongIds;
      final inserted = actualIds
          .where((id) => batch.songs.any((song) => song.id == id))
          .length;
      if (inserted == 0) {
        await _restorePreviousQueue(previousQueue, session);
        state = const PersonalRadioState(issue: RecommendationIssue.empty);
        coordinator.report(
          session,
          stage: 'failed',
          errorCategory: 'zeroInsertion',
        );
        return const RadioStartResult(
          insertedCount: 0,
          issue: RecommendationIssue.empty,
        );
      }
      _remember(actualIds);
      state = PersonalRadioState(
        active: true,
        source: batch.source,
        insertedCount: inserted,
      );
      coordinator.report(session, stage: 'active', insertedCount: inserted);
      return RadioStartResult(
        insertedCount: inserted,
        issue: RecommendationIssue.none,
      );
    } on Object {
      if (coordinator.owns(session)) {
        if (queueChangeAttempted) {
          await _restorePreviousQueue(previousQueue, session);
        }
        state = const PersonalRadioState(
          issue: RecommendationIssue.networkFailure,
        );
        coordinator.report(
          session,
          stage: 'failed',
          errorCategory: RecommendationIssue.networkFailure.name,
        );
      }
      return const RadioStartResult(
        insertedCount: 0,
        issue: RecommendationIssue.networkFailure,
      );
    } finally {
      // A newer start (after stop) owns the flag now.
      if (identical(_session, session)) _starting = false;
    }
  }

  Future<RadioStartResult> retry() => start(filters: _filters);

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
      // Keep the original start failure as the reported outcome.
    }
  }

  /// Drops a held Next because a newer transport command replaced it.
  void cancelSkipAfterRefill() => _pendingSkip = null;

  /// Remembers an unavailable Next at the queue tail until songs are appended.
  void requestSkipAfterRefill(int index, String songId) {
    final session = _session;
    if (!state.active || _starting || session == null || _failures >= 5) return;
    if (!ref.read(recommendationSessionProvider.notifier).owns(session)) return;
    final snapshot =
        ref.read(audioHandlerProvider)?.snapshot ??
        ref.read<PlaybackSnapshot>(playerStateProvider);
    if (index != snapshot.queueSongIds.length - 1 ||
        index < 0 ||
        snapshot.queueSongIds[index] != songId) {
      return;
    }
    _pendingSkip = (index: index, songId: songId);
    final retryAt = _nextRetryAt;
    if (!_refilling && (retryAt == null || !DateTime.now().isBefore(retryAt))) {
      unawaited(_refill());
    }
  }

  void stop() {
    final session = _session;
    if (session != null) {
      ref.read(recommendationSessionProvider.notifier).stop(session);
    }
    _clearLocalSession();
  }

  void _clearLocalSession() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _session = null;
    _starting = false;
    _refilling = false;
    _pendingSkip = null;
    _failures = 0;
    _nextRetryAt = null;
    state = const PersonalRadioState();
  }

  void _onSnapshot(PlaybackSnapshot? previous, PlaybackSnapshot next) {
    final pendingSkip = _pendingSkip;
    if (pendingSkip != null &&
        (next.pendingQueueIndex ?? next.currentIndex) != pendingSkip.index) {
      _pendingSkip = null;
    }
    if (!state.active || _starting || _refilling) return;
    if (next.queueSongIds.isEmpty || next.isRadioMode) {
      stop();
      return;
    }
    final currentIndex = next.currentIndex ?? 0;
    final remaining = next.queueSongIds.length - currentIndex - 1;
    if (remaining > kRecommendationRefillLowWater || _failures >= 5) return;
    final retryAt = _nextRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
    unawaited(_refill());
  }

  Future<void> _refill() async {
    if (_refilling) return;
    final session = _session;
    if (session == null) return;
    final coordinator = ref.read(recommendationSessionProvider.notifier);
    if (!ref.mounted || !coordinator.owns(session)) return;
    _refilling = true;
    state = PersonalRadioState(
      active: true,
      busy: true,
      source: state.source,
      insertedCount: state.insertedCount,
      retryCount: _failures,
    );
    try {
      final snapshot = ref.read(playerStateProvider);
      final excluded = <String>{...snapshot.queueSongIds, ..._recentGenerated};
      final batch = await session
          .withCancelToken(
            (cancelToken) => ref
                .read(recommendationServiceProvider)
                .personalRadio(
                  _filters,
                  excludedIds: excluded,
                  cancelToken: cancelToken,
                ),
          )
          .timeout(const Duration(seconds: 30));
      if (!ref.mounted || !coordinator.owns(session)) return;
      coordinator.report(
        session,
        stage: 'refilling',
        source: batch.source.name,
        candidateCount: batch.songs.length,
      );
      if (batch.songs.isEmpty) {
        if (batch.issue == RecommendationIssue.empty) {
          stop();
        } else {
          _scheduleRetry(session, batch.issue);
        }
        return;
      }
      final beforeAppend =
          ref.read(audioHandlerProvider)?.snapshot ??
          ref.read<PlaybackSnapshot>(playerStateProvider);
      final result = await ref
          .read(queueProvider.notifier)
          .appendRecommendationTracks(
            batch.songs,
            isCurrent: () => ref.mounted && coordinator.owns(session),
          );
      if (!ref.mounted || !coordinator.owns(session)) return;
      if (result.count == 0) {
        _scheduleRetry(session, RecommendationIssue.empty);
        return;
      }
      _remember(result.insertedIds);
      _failures = 0;
      _nextRetryAt = null;
      state = PersonalRadioState(
        active: true,
        source: batch.source,
        insertedCount: result.count,
      );
      coordinator.report(session, stage: 'active', insertedCount: result.count);
      final pendingSkip = _pendingSkip;
      _pendingSkip = null;
      final afterAppend =
          ref.read(audioHandlerProvider)?.snapshot ??
          ref.read<PlaybackSnapshot>(playerStateProvider);
      final firstInsertedIndex = beforeAppend.queueSongIds.length;
      if (pendingSkip != null &&
          coordinator.owns(session) &&
          pendingSkip.index == firstInsertedIndex - 1 &&
          beforeAppend.queueSongIds.last == pendingSkip.songId &&
          afterAppend.currentIndex == pendingSkip.index &&
          (afterAppend.pendingQueueIndex == null ||
              afterAppend.pendingQueueIndex == pendingSkip.index) &&
          afterAppend.currentSongId == pendingSkip.songId &&
          afterAppend.queueSongIds.length > firstInsertedIndex &&
          afterAppend.queueSongIds[firstInsertedIndex] ==
              result.insertedIds.first) {
        await ref.read(audioHandlerProvider)?.skipToNext();
      }
    } on Object {
      if (ref.mounted && coordinator.owns(session)) {
        _scheduleRetry(session, RecommendationIssue.networkFailure);
      }
    } finally {
      // A refill of a newer session owns the flag now.
      if (identical(_session, session)) _refilling = false;
    }
  }

  void _scheduleRetry(
    RecommendationSession session,
    RecommendationIssue issue,
  ) {
    _failures++;
    final exhausted = _failures >= 5;
    final delay = Duration(seconds: 3 * (1 << (_failures - 1).clamp(0, 4)));
    _nextRetryAt = DateTime.now().add(delay);
    state = PersonalRadioState(
      active: true,
      issue: issue,
      source: state.source,
      retryCount: _failures,
    );
    ref
        .read(recommendationSessionProvider.notifier)
        .report(
          session,
          stage: exhausted ? 'retryExhausted' : 'retryPending',
          errorCategory: issue.name,
          retryCount: _failures,
        );
    if (!exhausted) {
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        if (ref.read(recommendationSessionProvider.notifier).owns(session)) {
          unawaited(_refill());
        }
      });
    }
  }

  void _remember(Iterable<String> ids) {
    _recentGenerated.addAll(ids);
    if (_recentGenerated.length > 200) {
      _recentGenerated.removeRange(0, _recentGenerated.length - 200);
    }
  }
}

final personalRadioProvider =
    NotifierProvider<PersonalRadioNotifier, PersonalRadioState>(
      PersonalRadioNotifier.new,
    );
