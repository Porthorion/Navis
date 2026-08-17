import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/utils/connectivity.dart';

/// Runtime overrides used by the Linux sync diagnostics API (clone mode only).
@immutable
class SyncDiagnosticsOverrides {
  const SyncDiagnosticsOverrides({
    this.networkType,
    this.nativeMetered,
    this.backgroundSyncUnmeteredOnly,
    this.automaticSyncAllowed,
    this.interactiveHydrationAllowed,
    this.meteredBudgetBytes,
    this.requestReporting = false,
    this.cachedListenBrainzPresentation = false,
    this.forceSearchRemoteFailure = false,
    this.radioPresentationFixture = false,
    this.artistTopTracksPresentationFixture = false,
  });

  final NetworkType? networkType;
  final bool? nativeMetered;
  final bool? backgroundSyncUnmeteredOnly;
  final bool? automaticSyncAllowed;
  final bool? interactiveHydrationAllowed;
  final int? meteredBudgetBytes;
  final bool requestReporting;
  final bool cachedListenBrainzPresentation;
  final bool forceSearchRemoteFailure;
  final bool radioPresentationFixture;
  final bool artistTopTracksPresentationFixture;

  SyncDiagnosticsOverrides copyWith({
    NetworkType? networkType,
    bool? nativeMetered,
    bool? backgroundSyncUnmeteredOnly,
    bool? automaticSyncAllowed,
    bool? interactiveHydrationAllowed,
    int? meteredBudgetBytes,
    bool? requestReporting,
    bool? cachedListenBrainzPresentation,
    bool? forceSearchRemoteFailure,
    bool? radioPresentationFixture,
    bool? artistTopTracksPresentationFixture,
    bool clearNetworkType = false,
    bool clearNativeMetered = false,
    bool clearBackgroundSyncUnmeteredOnly = false,
    bool clearAutomaticSyncAllowed = false,
    bool clearInteractiveHydrationAllowed = false,
    bool clearMeteredBudgetBytes = false,
  }) {
    return SyncDiagnosticsOverrides(
      networkType: clearNetworkType ? null : networkType ?? this.networkType,
      nativeMetered: clearNativeMetered
          ? null
          : nativeMetered ?? this.nativeMetered,
      backgroundSyncUnmeteredOnly: clearBackgroundSyncUnmeteredOnly
          ? null
          : backgroundSyncUnmeteredOnly ?? this.backgroundSyncUnmeteredOnly,
      automaticSyncAllowed: clearAutomaticSyncAllowed
          ? null
          : automaticSyncAllowed ?? this.automaticSyncAllowed,
      interactiveHydrationAllowed: clearInteractiveHydrationAllowed
          ? null
          : interactiveHydrationAllowed ?? this.interactiveHydrationAllowed,
      meteredBudgetBytes: clearMeteredBudgetBytes
          ? null
          : meteredBudgetBytes ?? this.meteredBudgetBytes,
      requestReporting: requestReporting ?? this.requestReporting,
      cachedListenBrainzPresentation:
          cachedListenBrainzPresentation ?? this.cachedListenBrainzPresentation,
      forceSearchRemoteFailure:
          forceSearchRemoteFailure ?? this.forceSearchRemoteFailure,
      radioPresentationFixture:
          radioPresentationFixture ?? this.radioPresentationFixture,
      artistTopTracksPresentationFixture:
          artistTopTracksPresentationFixture ??
          this.artistTopTracksPresentationFixture,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'networkType': networkType?.name,
    'nativeMetered': nativeMetered,
    'backgroundSyncUnmeteredOnly': backgroundSyncUnmeteredOnly,
    'automaticSyncAllowed': automaticSyncAllowed,
    'interactiveHydrationAllowed': interactiveHydrationAllowed,
    'meteredBudgetBytes': meteredBudgetBytes,
    'requestReporting': requestReporting,
    'cachedListenBrainzPresentation': cachedListenBrainzPresentation,
    'forceSearchRemoteFailure': forceSearchRemoteFailure,
    'radioPresentationFixture': radioPresentationFixture,
    'artistTopTracksPresentationFixture': artistTopTracksPresentationFixture,
  };

  static SyncDiagnosticsOverrides fromJson(Map<String, Object?> json) {
    NetworkType? networkType;
    final rawNetworkType = json['networkType'];
    if (rawNetworkType is String) {
      for (final type in NetworkType.values) {
        if (type.name == rawNetworkType) {
          networkType = type;
          break;
        }
      }
    }
    return SyncDiagnosticsOverrides(
      networkType: networkType,
      nativeMetered: json['nativeMetered'] as bool?,
      backgroundSyncUnmeteredOnly: json['backgroundSyncUnmeteredOnly'] as bool?,
      automaticSyncAllowed: json['automaticSyncAllowed'] as bool?,
      interactiveHydrationAllowed: json['interactiveHydrationAllowed'] as bool?,
      meteredBudgetBytes: json['meteredBudgetBytes'] as int?,
      requestReporting: json['requestReporting'] as bool? ?? false,
      cachedListenBrainzPresentation:
          json['cachedListenBrainzPresentation'] as bool? ?? false,
      forceSearchRemoteFailure:
          json['forceSearchRemoteFailure'] as bool? ?? false,
      radioPresentationFixture:
          json['radioPresentationFixture'] as bool? ?? false,
      artistTopTracksPresentationFixture:
          json['artistTopTracksPresentationFixture'] as bool? ?? false,
    );
  }
}

class SyncDiagnosticsOverridesController
    extends Notifier<SyncDiagnosticsOverrides> {
  @override
  SyncDiagnosticsOverrides build() => const SyncDiagnosticsOverrides();

  void apply(SyncDiagnosticsOverrides overrides) {
    state = overrides;
  }

  void patch(Map<String, Object?> json) {
    final merged = <String, Object?>{
      ...state.toJson(),
      ...json,
    };
    if (json.containsKey('networkType') && json['networkType'] == null) {
      merged.remove('networkType');
    }
    if (json.containsKey('nativeMetered') && json['nativeMetered'] == null) {
      merged.remove('nativeMetered');
    }
    if (json.containsKey('backgroundSyncUnmeteredOnly') &&
        json['backgroundSyncUnmeteredOnly'] == null) {
      merged.remove('backgroundSyncUnmeteredOnly');
    }
    if (json.containsKey('automaticSyncAllowed') &&
        json['automaticSyncAllowed'] == null) {
      merged.remove('automaticSyncAllowed');
    }
    if (json.containsKey('interactiveHydrationAllowed') &&
        json['interactiveHydrationAllowed'] == null) {
      merged.remove('interactiveHydrationAllowed');
    }
    if (json.containsKey('meteredBudgetBytes') &&
        json['meteredBudgetBytes'] == null) {
      merged.remove('meteredBudgetBytes');
    }
    state = SyncDiagnosticsOverrides.fromJson(merged);
  }

  void reset() {
    state = const SyncDiagnosticsOverrides();
  }
}

final syncDiagnosticsOverridesProvider =
    NotifierProvider<
      SyncDiagnosticsOverridesController,
      SyncDiagnosticsOverrides
    >(
      SyncDiagnosticsOverridesController.new,
    );

/// Clone-diagnostics-only override for the desktop Now Playing surface.
///
/// Desktop intentionally presents the player as a lyrics overlay rather than
/// the phone/tablet expanded sheet. The diagnostics API uses this narrow
/// override so its `nowPlaying` control captures the same surface a desktop
/// user opens from the player bar, without changing production interaction.
class DesktopNowPlayingDiagnosticsController extends Notifier<bool?> {
  @override
  bool? build() => null;

  void setVisible(bool visible) => state = visible;

  void clear() => state = null;
}

final desktopNowPlayingDiagnosticsProvider =
    NotifierProvider<DesktopNowPlayingDiagnosticsController, bool?>(
      DesktopNowPlayingDiagnosticsController.new,
    );
