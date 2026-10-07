import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

Future<PreferredMixMode> _readPreferredMixMode(WidgetRef ref) async {
  return await _resolvePreferredMixMode(
    readLastFmVerified: () => ref.read(hasLastFmApiKeyProvider),
    loadSettings: () => ref.read(settingsRepositoryProvider).getSettings(),
  );
}

Future<PreferredMixMode> _readPreferredMixModeFromContainer(
  ProviderContainer container,
) async {
  return await _resolvePreferredMixMode(
    readLastFmVerified: () => container.read(hasLastFmApiKeyProvider),
    loadSettings: () =>
        container.read(settingsRepositoryProvider).getSettings(),
  );
}

Future<PreferredMixMode> _resolvePreferredMixMode({
  required bool Function() readLastFmVerified,
  required Future<AppSettingsModel> Function() loadSettings,
}) async {
  // Settings are read from storage rather than the policy provider, which
  // denies everything until the settings stream has emitted.
  final settings = await loadSettings();
  final policy = integrationPolicyFromSettings(
    settings,
    lastFmVerified: readLastFmVerified(),
  );
  return policy.allows(IntegrationFeature.lastFmSameVibes)
      ? PreferredMixMode.sameVibes
      : PreferredMixMode.legacyInstantMix;
}

Future<void> activatePreferredMixMode(
  WidgetRef ref, {
  required String seedSongId,
}) async {
  final mode = await _readPreferredMixMode(ref);
  return await _activatePreferredMixMode(
    mode: mode,
    instantMix: ref.read(instantMixProvider.notifier),
    sameVibes: ref.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> activatePreferredMixModeFromContainer(
  ProviderContainer container, {
  required String seedSongId,
}) async {
  final mode = await _readPreferredMixModeFromContainer(container);
  return await _activatePreferredMixMode(
    mode: mode,
    instantMix: container.read(instantMixProvider.notifier),
    sameVibes: container.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> togglePreferredMixMode(
  WidgetRef ref, {
  required String seedSongId,
}) async {
  final mode = await _readPreferredMixMode(ref);
  return await _togglePreferredMixMode(
    mode: mode,
    instantMixState: ref.read(instantMixProvider),
    sameVibesState: ref.read(sameVibesProvider),
    instantMix: ref.read(instantMixProvider.notifier),
    sameVibes: ref.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> togglePreferredMixModeFromContainer(
  ProviderContainer container, {
  required String seedSongId,
}) async {
  final mode = await _readPreferredMixModeFromContainer(container);
  return await _togglePreferredMixMode(
    mode: mode,
    instantMixState: container.read(instantMixProvider),
    sameVibesState: container.read(sameVibesProvider),
    instantMix: container.read(instantMixProvider.notifier),
    sameVibes: container.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> _activatePreferredMixMode({
  required PreferredMixMode mode,
  required InstantMixNotifier instantMix,
  required SameVibesNotifier sameVibes,
  required String seedSongId,
}) async {
  if (mode == PreferredMixMode.legacyInstantMix) {
    sameVibes.deactivate();
    await instantMix.activate(seedSongId);
  } else {
    instantMix.deactivate();
    await sameVibes.activate(seedSongId);
  }
}

Future<void> _togglePreferredMixMode({
  required PreferredMixMode mode,
  required InstantMixState instantMixState,
  required SameVibesState sameVibesState,
  required InstantMixNotifier instantMix,
  required SameVibesNotifier sameVibes,
  required String seedSongId,
}) async {
  if (mode == PreferredMixMode.legacyInstantMix) {
    sameVibes.deactivate();
    if (instantMixState.active) {
      instantMix.deactivate();
      return;
    }
    await instantMix.activate(seedSongId);
    return;
  }

  instantMix.deactivate();
  if (sameVibesState.active) {
    sameVibes.deactivate();
    return;
  }
  await sameVibes.activate(seedSongId);
}

/// Backwards-compatible entrypoint: now directly toggles the preferred mode.
void showMixModeSheet(BuildContext context, {required String seedSongId}) {
  final container = ProviderScope.containerOf(context, listen: false);
  unawaited(
    togglePreferredMixModeFromContainer(container, seedSongId: seedSongId),
  );
}
