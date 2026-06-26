import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Number of remaining tracks (after the current one) that triggers
/// an automatic refill fetch.
const _kRefillThreshold = 3;

/// Maximum duration a single refill fetch is allowed to run before it is
/// cancelled and the refilling flag is reset.
const _kRefillTimeout = Duration(seconds: 30);

/// Global notifier that manages the Instant Mix auto-refill mode.
///
/// When `active`, this notifier watches the playback queue and automatically
/// appends similar tracks whenever fewer than `_kRefillThreshold` tracks remain
/// after the current position.  The seed song is updated each cycle to the
/// currently-playing track, keeping the recommendations fresh.
///
/// The provider is intentionally **not** `autoDispose` — the Instant Mix
/// session should persist across navigation until explicitly deactivated or
/// the queue is cleared by the user.
class InstantMixNotifier extends Notifier<InstantMixState> {
  /// Local boolean guard that prevents overlapping refills even if the
  /// Riverpod state update has not yet been observed by a concurrent listener
  /// invocation.
  bool _isRefilling = false;

  @override
  InstantMixState build() {
    // Whenever the playback snapshot changes, check if a refill is needed.
    ref.listen<PlaybackSnapshot>(
      playerStateProvider,
      _onSnapshotChanged,
    );
    return const InstantMixState.inactive();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Activates Instant Mix and immediately queues similar tracks.
  ///
  /// If Instant Mix is already active this replaces the current seed, cancels
  /// any pending error, and starts a fresh refill from [seedSongId].
  Future<void> activate(String seedSongId) async {
    state = InstantMixState(
      active: true,
      seedSongId: seedSongId,
    );
    await _refill(seedSongId, isInitial: true);
  }

  /// Deactivates Instant Mix and stops all future auto-refills.
  void deactivate() {
    state = const InstantMixState.inactive();
  }

  /// Toggles the Instant Mix mode.
  ///
  /// [currentSongId] is used as the seed when activating.  If [currentSongId]
  /// is null and Instant Mix is not currently active, the call is a no-op.
  Future<void> toggle(String? currentSongId) async {
    if (state.active) {
      deactivate();
    } else if (currentSongId != null) {
      await activate(currentSongId);
    }
  }

  /// Clears a pending one-shot error so it is not shown again.
  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// Clears the pending snackbar message so it is not shown again.
  void clearSnackbar() {
    if (state.pendingSnackbar != null) {
      state = state.copyWith(clearSnackbar: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _onSnapshotChanged(PlaybackSnapshot? prev, PlaybackSnapshot next) {
    if (!state.active) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error == InstantMixError.unsupported) return;

    // Deactivate automatically when the user clears / replaces the queue,
    // so the toggle does not silently refill a brand-new queue.
    if (next.queueSongIds.isEmpty) {
      state = const InstantMixState.inactive();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final remaining = next.queueSongIds.length - currentIndex - 1;

    if (remaining <= _kRefillThreshold) {
      // Use the currently-playing track as seed for fresh variety.
      final seedSongId = next.currentSongId ?? state.seedSongId;
      if (seedSongId != null) {
        // _refill is async but we intentionally fire-and-forget here.
        // ignore: discarded_futures
        _refill(seedSongId);
      }
    }
  }

  /// Fetches similar songs and inserts them after the current queue item.
  ///
  /// When AudioMuse is available the AI-powered recommendations are tried
  /// first.  If AudioMuse returns no results (or is not configured) the
  /// method falls back to the standard Subsonic getSimilarSongs endpoint.
  ///
  /// [isInitial] distinguishes the first activation fill (which may show
  /// a snackbar) from background auto-refills (which are silent).
  Future<void> _refill(String seedSongId, {bool isInitial = false}) async {
    // Guard 1: local boolean prevents overlapping refills even if the state
    // update has not yet been observed by a concurrent listener invocation.
    if (_isRefilling || state.refilling) return;
    _isRefilling = true;
    // Record the seed we are refilling from.
    state = state.copyWith(refilling: true, seedSongId: seedSongId);

    try {
      // Guard 2: wrap the actual fetch work in a timeout so a slow or hung API
      // call cannot leave the notifier stuck in `refilling: true` indefinitely.
      await _doRefill(seedSongId, isInitial: isInitial).timeout(
        _kRefillTimeout,
        onTimeout: () {
          AppLogger.debug(
            'InstantMix: refill timed out after ${_kRefillTimeout.inSeconds}s — resetting',
          );
          state = state.copyWith(refilling: false);
        },
      );
    } finally {
      _isRefilling = false;
    }
  }

  /// Internal implementation of the refill fetch, called inside [_refill].
  Future<void> _doRefill(String seedSongId, {bool isInitial = false}) async {
    try {
      final legacyMode =
          ref.read(preferredMixModeProvider) ==
          PreferredMixMode.legacyInstantMix;

      // ── 1. Try AudioMuse AI recommendations first (non-legacy only) ──
      if (!legacyMode) {
        final audioMuseRepo = ref.read(audioMuseRepositoryProvider);
        if (audioMuseRepo != null) {
          try {
            final recs = await audioMuseRepo.getRecommendations(
              seedSongId: seedSongId,
            );
            // Guard 3: user may have deactivated Instant Mix while the fetch ran.
            if (recs.isNotEmpty && state.active) {
              final ids = recs.map((r) => r.id).toList(growable: false);
              final handler = ref.read(audioHandlerProvider);
              await handler?.playNext(ids, expandMatchFlows: false);
              AppLogger.debug(
                'InstantMix: queued ${ids.length} tracks via AudioMuse',
              );
              state = state.copyWith(
                refilling: false,
                pendingSnackbar: isInitial ? '${recs.length}' : null,
              );
              return;
            }
          } on Object catch (e) {
            AppLogger.debug('AudioMuse refill failed, falling back: $e');
          }
        }
      }

      // Guard 3: check again after AudioMuse path (covers fallback too).
      if (!state.active) {
        state = state.copyWith(refilling: false);
        return;
      }

      // ── 2. Subsonic recommendations ──
      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        state = state.copyWith(refilling: false);
        return;
      }

      late final List<Song> songs;
      if (legacyMode) {
        try {
          songs = await api.getInstantMix(seedSongId);
        } on SubsonicNotFoundException {
          songs = await api.getSimilarSongs(seedSongId);
        }
      } else {
        songs = await api.getSimilarSongs(seedSongId);
      }
      // Guard 3: deactivated while fetching — discard results.
      if (!state.active) {
        state = state.copyWith(refilling: false);
        return;
      }

      final ids = songs.map((s) => s.id).toList(growable: false);
      final handler = ref.read(audioHandlerProvider);
      await handler?.playNext(ids, expandMatchFlows: false);

      state = state.copyWith(
        refilling: false,
        // Surface a snackbar on initial activation only.
        pendingSnackbar: isInitial ? '${songs.length}' : null,
      );
    } on SubsonicNotFoundException {
      state = InstantMixState(
        // Keep active=false so the toggle returns to its off state.
        error: InstantMixError.unsupported,
      );
    } on Exception {
      // Network/parse error — deactivate and surface error once.
      state = InstantMixState(
        error: InstantMixError.networkError,
      );
    }
  }
}

/// Global provider for the Instant Mix auto-refill service.
///
/// Not autoDispose — must persist across routing to keep the session alive.
final instantMixProvider =
    NotifierProvider<InstantMixNotifier, InstantMixState>(
      InstantMixNotifier.new,
    );
