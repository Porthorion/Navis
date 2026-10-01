import 'package:flutter/foundation.dart';

/// Possible error conditions surfaced by `SameVibesNotifier`.
enum SameVibesError {
  /// The connected server does not support similar-song endpoints.
  unsupported,

  /// A network or unexpected error occurred during a refill fetch.
  networkError,

  /// Last.fm rejected the configured API key.
  invalidKey,

  /// Last.fm limited further requests.
  rateLimited,
}

/// Immutable state for the Same Vibes auto-refill mode.
@immutable
class SameVibesState {
  const new({
    this.active = false,
    this.seedSongId,
    this.refilling = false,
    this.error,
    this.pendingSnackbar,
  });

  const new inactive()
    : active = false,
      seedSongId = null,
      refilling = false,
      error = null,
      pendingSnackbar = null;

  /// Whether Same Vibes is currently active.
  final bool active;

  /// Last seed song id used for the current session.
  final String? seedSongId;

  /// `true` while recommendation refill is in flight.
  final bool refilling;

  /// One-shot error surfaced to the shell listener.
  final SameVibesError? error;

  /// One-shot count string surfaced to the shell listener.
  final String? pendingSnackbar;

  SameVibesState copyWith({
    bool? active,
    String? seedSongId,
    bool? refilling,
    SameVibesError? error,
    Object? clearError = _sentinel,
    String? pendingSnackbar,
    Object? clearSnackbar = _sentinel,
  }) {
    return SameVibesState(
      active: active ?? this.active,
      seedSongId: seedSongId ?? this.seedSongId,
      refilling: refilling ?? this.refilling,
      error: clearError == _sentinel ? (error ?? this.error) : null,
      pendingSnackbar: clearSnackbar == _sentinel
          ? (pendingSnackbar ?? this.pendingSnackbar)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SameVibesState &&
          runtimeType == other.runtimeType &&
          active == other.active &&
          seedSongId == other.seedSongId &&
          refilling == other.refilling &&
          error == other.error &&
          pendingSnackbar == other.pendingSnackbar;

  @override
  int get hashCode =>
      Object.hash(active, seedSongId, refilling, error, pendingSnackbar);
}

const Object _sentinel = Object();
