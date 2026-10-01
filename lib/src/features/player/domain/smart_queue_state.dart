import 'package:material_ui/material_ui.dart';

/// The different smart queue mood profiles available.
///
/// Each profile uses `getSimilarSongs2` (powered by the AudioMuse Navidrome
/// plugin) but varies the track-selection and re-seeding strategy to produce
/// distinct listening experiences.
enum SmartQueueProfile {
  /// Consistent mood — re-seeds from the **original** seed track every refill,
  /// producing a cohesive listening session with minimal sonic drift.
  steadyVibes(icon: Icons.spa_outlined, color: Color(0xFF7C4DFF)),

  /// Maximum diversity — re-seeds from the **last queued** track and skips
  /// tracks whose artist is already in the queue, broadening discovery.
  discoveryMix(icon: Icons.explore_outlined, color: Color(0xFF00BFA5)),

  /// Same-artist focus — keeps results that share an artist with the seed
  /// or recent queue, deepening the listener's immersion in a style.
  deepDive(icon: Icons.scuba_diving, color: Color(0xFF2979FF)),

  /// Chain-seeding — every refill uses the most-recently-queued track as the
  /// new seed, letting the mood gradually evolve over time.
  energyFlow(icon: Icons.electric_bolt_outlined, color: Color(0xFFFF6D00));

  new({required this.icon, required this.color});

  /// Default Material icon for this profile.
  final IconData icon;

  /// Brand colour used for the profile card in the selection sheet.
  final Color color;
}

/// Errors that can occur when starting / running a smart queue.
enum SmartQueueError {
  /// The server does not support `getSimilarSongs2` — plugin not installed.
  unsupported,

  /// Network / server error while fetching similar tracks.
  networkError,
}

/// Immutable state for the Smart Queue notifier.
@immutable
class SmartQueueState {
  const new({
    this.active = false,
    this.profile,
    this.seedSongId,
    this.refilling = false,
    this.error,
    this.pendingSnackbar,
    this.queuedArtists = const <String>{},
  });

  const new inactive()
    : active = false,
      profile = null,
      seedSongId = null,
      refilling = false,
      error = null,
      pendingSnackbar = null,
      queuedArtists = const <String>{};

  /// Whether a smart queue session is active.
  final bool active;

  /// The currently selected mood profile.
  final SmartQueueProfile? profile;

  /// Track ID used as the seed for the current/next refill.
  final String? seedSongId;

  /// `true` while a refill request is in-flight.
  final bool refilling;

  /// Non-null when an error should be surfaced once.
  final SmartQueueError? error;

  /// Non-null when a snackbar should be shown once (contains count string).
  final String? pendingSnackbar;

  /// Set of artist names already queued — used by [SmartQueueProfile.discoveryMix]
  /// to skip duplicates.
  final Set<String> queuedArtists;

  SmartQueueState copyWith({
    bool? active,
    SmartQueueProfile? profile,
    String? seedSongId,
    bool? refilling,
    SmartQueueError? error,
    Object? clearError,
    String? pendingSnackbar,
    Object? clearSnackbar,
    Set<String>? queuedArtists,
  }) {
    return SmartQueueState(
      active: active ?? this.active,
      profile: profile ?? this.profile,
      seedSongId: seedSongId ?? this.seedSongId,
      refilling: refilling ?? this.refilling,
      error: clearError != null ? null : (error ?? this.error),
      pendingSnackbar: clearSnackbar != null
          ? null
          : (pendingSnackbar ?? this.pendingSnackbar),
      queuedArtists: queuedArtists ?? this.queuedArtists,
    );
  }
}
