import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/utils/semver.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Current setup highlight release, or null while metadata loads or none apply.
final setupWhatsNewReleaseProvider = Provider<String?>((ref) {
  final info = ref.watch(packageInfoProvider);
  if (info.isLoading) return null;
  final version = info.asData?.value.version;
  return version == null ? null : setupWhatsNewRelease(version);
});

bool _atLeast(String? recorded, String release) {
  final parts = parseSemver(recorded);
  return parts != null && compareSemver(parts, parseSemver(release)!) >= 0;
}

/// Unacknowledged options for an updated user. First-run and loading are empty.
final pendingSetupHighlightsProvider = Provider<Set<SetupHighlight>>((ref) {
  final settings = ref.watch(appSettingsProvider);
  final release = ref.watch(setupWhatsNewReleaseProvider);
  if (settings.isLoading ||
      settings.asData == null ||
      release == null ||
      ref.watch(onboardingRequiredProvider) != false ||
      _atLeast(settings.asData!.value.setupHighlightsSeenRelease, release)) {
    return const <SetupHighlight>{};
  }
  final seen = settings.asData!.value.setupHighlightsSeen;
  return Set.unmodifiable(
    setupHighlightsFor(release).where((h) => !seen.contains(h.storageKey)),
  );
});

/// Whether Settings home should mark Appearance and Quick Customization as
/// having new options.
///
/// Use OLED When Dark only exists in Auto mode, so while it is hidden it does
/// not count: the tag must lead to something the user can actually see.
final settingsHasNewOptionsProvider = Provider<bool>((ref) {
  final pending = ref.watch(pendingSetupHighlightsProvider);
  final autoMode = ref.watch(themeModeProvider) == 'system';
  return pending.any(
    (highlight) => autoMode || highlight != SetupHighlight.oledForAuto,
  );
});

/// Whether Home should invite the updated user to review setup for this release.
///
/// Dismissing the card leaves [pendingSetupHighlightsProvider] unchanged.
final setupHighlightsCardVisibleProvider = Provider<bool>((ref) {
  if (ref.watch(pendingSetupHighlightsProvider).isEmpty) return false;
  final release = ref.watch(setupWhatsNewReleaseProvider)!;
  final dismissed = ref
      .watch(appSettingsProvider)
      .asData!
      .value
      .setupCardDismissedRelease;
  return !_atLeast(dismissed, release);
});

/// Targeted setup acknowledgement and Home invitation dismissal operations.
class SetupHighlightsService {
  const new(this._markSeen, this._dismissCard, this._markOptionSeen);

  final Future<void> Function() _markSeen;
  final Future<void> Function() _dismissCard;
  final Future<void> Function(SetupHighlight) _markOptionSeen;

  /// Clears one option after it has been visible; repeated calls are harmless.
  Future<void> markOptionSeen(SetupHighlight option) => _markOptionSeen(option);

  /// Acknowledges the current highlight release after Finish or first-run Skip.
  ///
  /// Waits for package metadata so completing setup during loading cannot miss it.
  Future<void> markSeen() => _markSeen();

  /// Hides the invitation for this release without clearing its setup tags.
  Future<void> dismissCard() => _dismissCard();
}

/// Uses package metadata and the existing settings repository targeted writers.
final setupHighlightsServiceProvider = Provider<SetupHighlightsService>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  Future<void> writeRelease({required bool seen}) async {
    final info = await ref.read(packageInfoProvider.future);
    final release = setupWhatsNewRelease(info.version);
    if (release == null) return;
    if (seen) {
      await repository.updateSetupHighlightsSeenRelease(release);
    } else {
      await repository.updateSetupCardDismissedRelease(release);
    }
  }

  return SetupHighlightsService(
    () => writeRelease(seen: true),
    () => writeRelease(seen: false),
    (option) async {
      final info = await ref.read(packageInfoProvider.future);
      final release = setupWhatsNewRelease(info.version);
      if (release == null || !setupHighlightsFor(release).contains(option)) {
        return;
      }
      await repository.markSetupHighlightSeen(option.storageKey);
    },
  );
});
