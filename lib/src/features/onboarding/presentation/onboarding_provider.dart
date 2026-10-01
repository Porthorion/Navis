import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

const int currentOnboardingVersion = 1;

/// Completes setup without coupling route/lifecycle callers to Drift.
///
/// The Onboarding screen uses this for both Finish and Skip; clone-only
/// diagnostics use the same operation to exercise the post-onboarding route.
class OnboardingCompletionService {
  const new(this._complete);

  final Future<void> Function() _complete;

  Future<void> complete() => _complete();
}

final onboardingCompletionServiceProvider =
    Provider<OnboardingCompletionService>(
      (ref) => OnboardingCompletionService(
        () => ref
            .read(navisDatabaseProvider)
            .appSettingsDao
            .completeOnboarding(currentOnboardingVersion),
      ),
    );

/// The only settings value that participates in router refreshes for setup.
/// Ordinary settings writes deliberately do not re-evaluate routing.
final onboardingVersionProvider = StreamProvider<int>((ref) {
  return ref
      .watch(navisDatabaseProvider)
      .appSettingsDao
      .watchOnboardingVersion();
});

final onboardingRequiredProvider = Provider<bool?>((ref) {
  final version = ref.watch(onboardingVersionProvider);
  return version.when(
    data: (value) => value < currentOnboardingVersion,
    loading: () => null,
    error: (_, _) => true,
  );
});
