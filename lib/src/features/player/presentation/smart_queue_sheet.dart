import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

Future<void> activatePreferredMixMode(
  WidgetRef ref, {
  required String seedSongId,
}) {
  return _activatePreferredMixMode(
    mode: ref.read(preferredMixModeProvider),
    instantMix: ref.read(instantMixProvider.notifier),
    sameVibes: ref.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> activatePreferredMixModeFromContainer(
  ProviderContainer container, {
  required String seedSongId,
}) {
  return _activatePreferredMixMode(
    mode: container.read(preferredMixModeProvider),
    instantMix: container.read(instantMixProvider.notifier),
    sameVibes: container.read(sameVibesProvider.notifier),
    seedSongId: seedSongId,
  );
}

Future<void> togglePreferredMixMode(
  WidgetRef ref, {
  required String seedSongId,
}) {
  return _togglePreferredMixMode(
    mode: ref.read(preferredMixModeProvider),
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
}) {
  return _togglePreferredMixMode(
    mode: container.read(preferredMixModeProvider),
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
void showMixModeSheet(
  BuildContext context, {
  required String seedSongId,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  unawaited(
    togglePreferredMixModeFromContainer(
      container,
      seedSongId: seedSongId,
    ),
  );
}

/// Backwards-compatible wrapper for older call sites.
void showSmartQueueSheet(
  BuildContext context,
  WidgetRef ref, {
  required String seedSongId,
}) {
  unawaited(togglePreferredMixMode(ref, seedSongId: seedSongId));
}
