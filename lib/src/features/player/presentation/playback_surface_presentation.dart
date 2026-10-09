import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

/// What the Mix transport button shows: which engine the preferred mode
/// selects, and whether that engine is active or refilling.
@immutable
class PreferredMixView {
  const PreferredMixView({
    required this.legacyMode,
    required this.active,
    required this.loading,
  });

  /// True when the preferred mode is Server Mix (Instant Mix); false for Same
  /// Vibes.
  final bool legacyMode;
  final bool active;
  final bool loading;

  @override
  bool operator ==(Object other) =>
      other is PreferredMixView &&
      other.legacyMode == legacyMode &&
      other.active == active &&
      other.loading == loading;

  @override
  int get hashCode => Object.hash(legacyMode, active, loading);
}

/// The preferred mix engine's button state, shared by every transport surface.
final preferredMixViewProvider = Provider<PreferredMixView>((ref) {
  final legacyMode =
      ref.watch(preferredMixModeProvider) == PreferredMixMode.legacyInstantMix;
  final instantMix = ref.watch(instantMixProvider);
  final sameVibes = ref.watch(sameVibesProvider);
  final active = legacyMode ? instantMix.active : sameVibes.active;
  final refilling = legacyMode ? instantMix.refilling : sameVibes.refilling;
  return PreferredMixView(
    legacyMode: legacyMode,
    active: active,
    loading: refilling && active,
  );
});

/// Tooltip, icon and active flag of the repeat control for [mode].
@immutable
class RepeatPresentation {
  const RepeatPresentation({
    required this.tooltip,
    required this.icon,
    required this.active,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
}

RepeatPresentation repeatPresentation(
  AudioServiceRepeatMode mode,
  AppLocalizations l10n,
) => switch (mode) {
  AudioServiceRepeatMode.one => RepeatPresentation(
    tooltip: l10n.nowPlayingRepeatOne,
    icon: Icons.repeat_one,
    active: true,
  ),
  AudioServiceRepeatMode.all ||
  AudioServiceRepeatMode.group => RepeatPresentation(
    tooltip: l10n.nowPlayingRepeatAll,
    icon: Icons.repeat,
    active: true,
  ),
  AudioServiceRepeatMode.none => RepeatPresentation(
    tooltip: l10n.nowPlayingRepeatOff,
    icon: Icons.repeat,
    active: false,
  ),
};

/// The repeat mode a tap on the repeat control selects: off, all, one, off.
AudioServiceRepeatMode nextRepeatMode(AudioServiceRepeatMode mode) =>
    switch (mode) {
      AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
      AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
      AudioServiceRepeatMode.group => AudioServiceRepeatMode.none,
    };

/// Pauses when [isPlaying], otherwise plays. A missing handler is ignored.
Future<void> togglePlayPause(WidgetRef ref, {required bool isPlaying}) async {
  final handler = ref.read(audioHandlerProvider);
  if (handler == null) {
    return;
  }
  if (isPlaying) {
    await handler.pause();
  } else {
    await handler.play();
  }
}
