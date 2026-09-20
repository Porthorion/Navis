import 'package:flutter/foundation.dart';

/// Possible error conditions surfaced by `InstantMixNotifier`.
enum InstantMixError {
  /// The connected server supports neither standard Subsonic similarity
  /// endpoint nor Navidrome's compatibility fallback.
  unsupported,

  /// A network or unexpected error occurred during a refill fetch.
  networkError,
}

/// Immutable state for the Instant Mix background auto-refill service.
@immutable
class InstantMixState {
  const InstantMixState({
    this.active = false,
    this.seedSongId,
    this.refilling = false,
    this.error,
    this.pendingSnackbar,
  });

  const InstantMixState.inactive()
    : active = false,
      seedSongId = null,
      refilling = false,
      error = null,
      pendingSnackbar = null;

  /// Whether the Instant Mix auto-refill mode is currently active.
  final bool active;

  /// Song ID used as the seed for the current session.
  ///
  /// Updated each refill cycle to keep recommendations fresh.
  final String? seedSongId;

  /// `true` while an API call to fetch more similar songs is in progress.
  final bool refilling;

  /// Non-null when an error should be surfaced to the UI (one-shot).
  final InstantMixError? error;

  /// A one-shot message to show in a snackbar — consumed and cleared by the UI.
  final String? pendingSnackbar;

  InstantMixState copyWith({
    bool? active,
    String? seedSongId,
    bool? refilling,
    InstantMixError? error,
    Object? clearError = _sentinel,
    String? pendingSnackbar,
    Object? clearSnackbar = _sentinel,
  }) {
    return InstantMixState(
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
      other is InstantMixState &&
          runtimeType == other.runtimeType &&
          active == other.active &&
          seedSongId == other.seedSongId &&
          refilling == other.refilling &&
          error == other.error &&
          pendingSnackbar == other.pendingSnackbar;

  @override
  int get hashCode => Object.hash(
    active,
    seedSongId,
    refilling,
    error,
    pendingSnackbar,
  );
}

/// Sentinel used to distinguish "don't change this field" from "clear it".
const Object _sentinel = Object();
