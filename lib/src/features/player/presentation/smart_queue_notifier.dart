import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// How many tracks may remain before triggering a refill.
const _kRefillThreshold = 3;

/// Maximum artist-deduplication set size (to keep memory bounded).
const _kMaxArtistSetSize = 200;

/// The notifier driving the Smart Queue feature.
///
/// Smart Queues rely on the AudioMuse Navidrome plugin which enhances
/// the standard `getSimilarSongs2` Subsonic endpoint with AI-powered
/// sonic analysis.  Different [SmartQueueProfile]s vary the re-seeding
/// and filtering strategy while calling the same underlying API.
class SmartQueueNotifier extends Notifier<SmartQueueState> {
  @override
  SmartQueueState build() {
    ref.listen<PlaybackSnapshot>(
      playerStateProvider,
      _onSnapshotChanged,
    );
    return const SmartQueueState.inactive();
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Start a Smart Queue session with [profile] seeded from [seedSongId].
  Future<void> activate(
    SmartQueueProfile profile,
    String seedSongId,
  ) async {
    state = SmartQueueState(
      active: true,
      profile: profile,
      seedSongId: seedSongId,
    );
    await _refill(seedSongId, isInitial: true);
  }

  /// Stop the Smart Queue session.
  void deactivate() {
    state = const SmartQueueState.inactive();
  }

  /// Dismiss a one-shot error notification.
  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// Dismiss a one-shot snackbar notification.
  void clearSnackbar() {
    if (state.pendingSnackbar != null) {
      state = state.copyWith(clearSnackbar: true);
    }
  }

  // ── Playback listener ──────────────────────────────────────────────────

  void _onSnapshotChanged(PlaybackSnapshot? prev, PlaybackSnapshot next) {
    if (!state.active) return;
    if (next.isRadioMode) return;
    if (state.refilling || state.error == SmartQueueError.unsupported) {
      return;
    }

    if (next.queueSongIds.isEmpty) {
      state = const SmartQueueState.inactive();
      return;
    }

    final currentIndex = next.currentIndex ?? 0;
    final remaining = next.queueSongIds.length - currentIndex - 1;

    if (remaining <= _kRefillThreshold) {
      final profile = state.profile ?? SmartQueueProfile.steadyVibes;
      // Determine the seed for this refill based on profile strategy.
      final seed = _chooseSeed(profile, next);
      if (seed != null) {
        _refill(seed);
      }
    }
  }

  // ── Core refill logic ──────────────────────────────────────────────────

  Future<void> _refill(String seedSongId, {bool isInitial = false}) async {
    if (state.refilling) return;
    state = state.copyWith(refilling: true, seedSongId: seedSongId);

    final profile = state.profile ?? SmartQueueProfile.steadyVibes;

    try {
      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        state = state.copyWith(refilling: false);
        return;
      }

      // Fetch a generous batch so we have room to filter.
      final songs = await api.getSimilarSongs(seedSongId, count: 50);

      if (!state.active) {
        state = state.copyWith(refilling: false);
        return;
      }

      // Apply profile-specific filtering.
      final filtered = _applyProfile(profile, songs);
      if (filtered.isEmpty) {
        // If filtering removed everything, fall back to unfiltered.
        await _enqueue(songs, isInitial: isInitial);
      } else {
        await _enqueue(filtered, isInitial: isInitial);
      }
    } on SubsonicNotFoundException {
      state = SmartQueueState(error: SmartQueueError.unsupported);
    } on Exception catch (e) {
      AppLogger.debug('SmartQueue refill error: $e');
      state = SmartQueueState(error: SmartQueueError.networkError);
    }
  }

  Future<void> _enqueue(
    List<Song> songs, {
    bool isInitial = false,
  }) async {
    final ids = songs.map((s) => s.id).toList(growable: false);
    final handler = ref.read(audioHandlerProvider);
    await handler?.addToQueue(ids);

    // Track artists for deduplication (used by discovery profile).
    final artists = Set<String>.from(state.queuedArtists);
    for (final s in songs) {
      if (s.artist != null) artists.add(s.artist!);
    }
    // Bound the set to prevent unbounded growth.
    final trimmed = artists.length > _kMaxArtistSetSize
        ? (artists.toList()..shuffle(Random())).take(_kMaxArtistSetSize).toSet()
        : artists;

    AppLogger.debug(
      'SmartQueue [${state.profile?.name}]: queued ${ids.length} tracks',
    );

    state = state.copyWith(
      refilling: false,
      queuedArtists: trimmed,
      pendingSnackbar: isInitial ? '${ids.length}' : null,
    );
  }

  // ── Profile strategies ─────────────────────────────────────────────────

  /// Pick the seed song ID for the next refill.
  String? _chooseSeed(SmartQueueProfile profile, PlaybackSnapshot snap) {
    switch (profile) {
      case SmartQueueProfile.steadyVibes:
        // Always re-seed from the original seed to keep things consistent.
        return state.seedSongId;
      case SmartQueueProfile.discoveryMix:
      case SmartQueueProfile.energyFlow:
        // Chain-seed from the last track in the queue.
        if (snap.queueSongIds.isNotEmpty) {
          return snap.queueSongIds.last;
        }
        return state.seedSongId;
      case SmartQueueProfile.deepDive:
        // Re-seed from the currently-playing track to stay close.
        return snap.currentSongId ?? state.seedSongId;
    }
  }

  /// Filter / reorder results based on the active profile.
  List<Song> _applyProfile(SmartQueueProfile profile, List<Song> songs) {
    switch (profile) {
      case SmartQueueProfile.steadyVibes:
        // No filtering — trust the similarity ordering from AudioMuse.
        return songs;

      case SmartQueueProfile.discoveryMix:
        // Remove tracks whose artist is already in the queue.
        final known = state.queuedArtists;
        final unique = songs
            .where((s) => s.artist == null || !known.contains(s.artist))
            .toList();
        // Shuffle to maximise variety.
        unique.shuffle(Random());
        return unique;

      case SmartQueueProfile.deepDive:
        // Prefer tracks from the seed's artist.  The very first result set
        // won't know the artist yet, so treat missing artists as valid.
        final snapshot = ref.read(playerStateProvider);
        final currentId = snapshot.currentSongId;
        String? seedArtist;
        if (currentId != null) {
          // Try to grab the artist from the song table.
          try {
            final songData = ref
                .read(songByIdProvider(currentId))
                .asData
                ?.value;
            seedArtist = songData?.artistName;
          } on Object {
            // Ignore — we just won't filter.
          }
        }
        if (seedArtist == null || seedArtist.isEmpty) return songs;
        final sameArtist = songs.where((s) => s.artist == seedArtist).toList();
        // If very few matches, append others after to avoid tiny queues.
        if (sameArtist.length >= 5) return sameArtist;
        final rest = songs.where((s) => s.artist != seedArtist).toList();
        return [...sameArtist, ...rest];

      case SmartQueueProfile.energyFlow:
        // Shuffle slightly so the chain doesn't repeat the same ordering
        // on successive refills.
        final shuffled = List<Song>.from(songs)..shuffle(Random());
        return shuffled;
    }
  }
}

/// Global provider for the Smart Queue service.
///
/// Not autoDispose — must persist across routing to keep the session alive.
final smartQueueProvider =
    NotifierProvider<SmartQueueNotifier, SmartQueueState>(
      SmartQueueNotifier.new,
    );
