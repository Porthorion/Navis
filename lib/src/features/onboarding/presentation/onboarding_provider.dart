import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

const int currentOnboardingVersion = 1;

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
