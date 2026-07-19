import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
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
  /// Local boolean guard that prevents overlapping refills even if the
  /// Riverpod state update has not yet been observed by a concurrent listener
  /// invocation.
  bool _isRefilling = false;

  /// Exclusive end index of the active mix segment in the playback queue.
  ///
  /// Refill is based on tracks within this segment, not the pre-mix queue tail.
  int? _mixSegmentEndIndex;
  DateTime? _nextRefillAllowedAt;
  bool _activationInProgress = false;
  bool _suppressActivationSeedSnapshot = false;

  @override
  InstantMixState build() {
    ref.listen<PlaybackSnapshot>(
      playerStateProvider,
      _onSnapshotChanged,
    );
    ref.listen<int>(regularQueueReplacementEpochProvider, (prev, next) {
      if (state.active) {
        deactivate();
      }
    });
    return const InstantMixState.inactive();
  }

  Future<void> activate(String seedSongId) async {
    final normalizedSeedSongId = seedSongId.trim();
    if (normalizedSeedSongId.isEmpty) {
      return;
    }
    _mixSegmentEndIndex = null;
    _nextRefillAllowedAt = null;
    _activationInProgress = true;
    _suppressActivationSeedSnapshot = true;
    state = InstantMixState(
      active: true,
      seedSongId: normalizedSeedSongId,
    );
    try {
      await ref
          .read(queueProvider.notifier)
          .retainCurrentAsQueue(normalizedSeedSongId);
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'InstantMix seed queue reset failed: $error\n$stackTrace',
      );
      _activationInProgress = false;
      _suppressActivationSeedSnapshot = false;
      state = const InstantMixState(error: InstantMixError.networkError);
      return;
    }
    _activationInProgress = false;
    if (!state.active) {
      return;
    }
    await _refill(normalizedSeedSongId, isInitial: true);
  }

  void deactivate() {
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
      if (nextAllowed != null && DateTime.now().isBefore(nextAllowed)) {
        return;
      }
      final seedSongId = next.currentSongId ?? state.seedSongId;
      if (seedSongId != null) {
        // ignore: discarded_futures
        _refill(seedSongId);
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

  Future<void> _refill(String seedSongId, {bool isInitial = false}) async {
    if (_isRefilling || state.refilling) return;
    _isRefilling = true;
    state = state.copyWith(refilling: true, seedSongId: seedSongId);

    try {
      await _doRefill(seedSongId, isInitial: isInitial).timeout(
        _kRefillTimeout,
        onTimeout: () {
          AppLogger.debug(
            'InstantMix: refill timed out after ${_kRefillTimeout.inSeconds}s '
            '— resetting',
          );
          state = state.copyWith(refilling: false);
        },
      );
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'InstantMix refill failed: $error\n$stackTrace',
      );
      if (isInitial) {
        state = const InstantMixState(error: InstantMixError.networkError);
        return;
      }
      if (state.active) {
        state = state.copyWith(
          refilling: false,
          error: InstantMixError.networkError,
        );
      }
    } finally {
      _isRefilling = false;
      if (state.active && state.refilling) {
        state = state.copyWith(refilling: false);
      }
    }
  }

  Future<void> _doRefill(String seedSongId, {bool isInitial = false}) async {
    try {
      final legacyMode =
          ref.read(preferredMixModeProvider) ==
          PreferredMixMode.legacyInstantMix;

      if (!legacyMode) {
        final audioMuseRepo = ref.read(audioMuseRepositoryProvider);
        if (audioMuseRepo != null) {
          try {
            final recs = await audioMuseRepo.getRecommendations(
              seedSongId: seedSongId,
            );
            if (recs.isNotEmpty && state.active) {
              final songs = _songsFromAudioMuse(recs);
              final queuedCount = await _queueMixSongs(songs);
              if (queuedCount <= 0) {
                state = isInitial
                    ? const InstantMixState(error: InstantMixError.networkError)
                    : state.copyWith(
                        refilling: false,
                        error: InstantMixError.networkError,
                      );
                return;
              }
              AppLogger.debug(
                'InstantMix: queued $queuedCount tracks via AudioMuse',
              );
              state = state.copyWith(
                refilling: false,
                pendingSnackbar: isInitial ? '$queuedCount' : null,
              );
              return;
            }
          } on Object catch (e) {
            AppLogger.debug('AudioMuse refill failed, falling back: $e');
          }
        }
      }

      if (!state.active) {
        state = state.copyWith(refilling: false);
        return;
      }

      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        state = state.copyWith(refilling: false);
        return;
      }

      late final List<Song> songs;
      if (legacyMode) {
        try {
          songs = await api.getInstantMix(seedSongId, count: 50);
        } on SubsonicNotFoundException {
          songs = await api.getSimilarSongs(seedSongId, count: 50);
        }
      } else {
        songs = await api.getSimilarSongs(seedSongId, count: 50);
      }
      if (!state.active) {
        state = state.copyWith(refilling: false);
        return;
      }

      final queuedCount = await _queueMixSongs(songs);
      if (queuedCount <= 0) {
        state = isInitial
            ? const InstantMixState(error: InstantMixError.networkError)
            : state.copyWith(
                refilling: false,
                error: InstantMixError.networkError,
              );
        return;
      }
      state = state.copyWith(
        refilling: false,
        pendingSnackbar: isInitial ? '$queuedCount' : null,
      );
    } on SubsonicNotFoundException {
      state = const InstantMixState(
        error: InstantMixError.unsupported,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.debug('InstantMix _doRefill error: $error\n$stackTrace');
      if (isInitial) {
        state = const InstantMixState(error: InstantMixError.networkError);
        return;
      }
      if (state.active) {
        state = state.copyWith(
          refilling: false,
          error: InstantMixError.networkError,
        );
      }
    }
  }

  List<Song> _songsFromAudioMuse(List<AudioMuseRecommendation> recs) {
    return recs
        .map(
          (rec) => Song(
            id: rec.id,
            title: rec.title,
            artist: rec.artist,
            album: rec.album,
            coverArt: rec.coverArtId,
          ),
        )
        .toList(growable: false);
  }

  Future<int> _queueMixSongs(List<Song> songs) async {
    if (songs.isEmpty) {
      return 0;
    }
    final queueLengthBeforeAppend = ref
        .read(playerStateProvider)
        .queueSongIds
        .length;
    try {
      final queuedCount = await ref
          .read(queueProvider.notifier)
          .appendMixTracks(
            songs,
            expandMatchFlows: false,
          );
      if (queuedCount > 0) {
        _mixSegmentEndIndex = queueLengthBeforeAppend + queuedCount;
        _nextRefillAllowedAt = DateTime.now().add(_kMinimumRefillInterval);
      }
      return queuedCount;
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'InstantMix queue failed: $error\n$stackTrace',
      );
      rethrow;
    }
  }
}

final instantMixProvider =
    NotifierProvider<InstantMixNotifier, InstantMixState>(
      InstantMixNotifier.new,
    );
