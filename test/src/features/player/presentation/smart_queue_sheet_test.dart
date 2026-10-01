import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SpyInstantMixNotifier extends InstantMixNotifier {
  final List<String> activateCalls = <String>[];
  bool deactivateCalled = false;

  @override
  InstantMixState build() => const InstantMixState.inactive();

  @override
  Future<void> activate(String seedSongId) async {
    activateCalls.add(seedSongId);
    state = InstantMixState(active: true, seedSongId: seedSongId);
  }

  @override
  void deactivate() {
    deactivateCalled = true;
    state = const InstantMixState.inactive();
  }
}

class _SpySameVibesNotifier extends SameVibesNotifier {
  final List<String> activateCalls = <String>[];
  bool deactivateCalled = false;

  @override
  SameVibesState build() => const SameVibesState.inactive();

  @override
  Future<void> activate(String seedSongId) async {
    activateCalls.add(seedSongId);
    state = SameVibesState(active: true, seedSongId: seedSongId);
  }

  @override
  void deactivate() {
    deactivateCalled = true;
    state = const SameVibesState.inactive();
  }
}

AppSettingsModel _settings({required bool legacyInstantMixEnabled}) {
  return AppSettingsModel.defaults().copyWith(
    legacyInstantMixEnabled: legacyInstantMixEnabled,
    lastFmApiKey: 'test-key',
  );
}

class _MockSettingsRepository extends Mock implements SettingsRepository;

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  group('activatePreferredMixModeFromContainer', () {
    test('routes to instant mix when legacy mode is enabled', () async {
      final instantMixSpy = _SpyInstantMixNotifier();
      final sameVibesSpy = _SpySameVibesNotifier();
      final repository = _MockSettingsRepository();
      when(repository.watchSettings)
          .thenAnswer((_) => const Stream<AppSettingsModel>.empty());
      when(repository.getSettings)
          .thenAnswer((_) async => _settings(legacyInstantMixEnabled: true));
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          instantMixProvider.overrideWith(() => instantMixSpy),
          sameVibesProvider.overrideWith(() => sameVibesSpy),
        ],
      );
      addTearDown(container.dispose);

      await activatePreferredMixModeFromContainer(
        container,
        seedSongId: 'seed-1',
      );

      expect(instantMixSpy.activateCalls, ['seed-1']);
      expect(sameVibesSpy.deactivateCalled, isTrue);
      expect(sameVibesSpy.activateCalls, isEmpty);
    });

    test('routes to same vibes when legacy mode is disabled', () async {
      final instantMixSpy = _SpyInstantMixNotifier();
      final sameVibesSpy = _SpySameVibesNotifier();
      final repository = _MockSettingsRepository();
      when(repository.watchSettings)
          .thenAnswer((_) => const Stream<AppSettingsModel>.empty());
      when(repository.getSettings)
          .thenAnswer((_) async => _settings(legacyInstantMixEnabled: false));
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          instantMixProvider.overrideWith(() => instantMixSpy),
          sameVibesProvider.overrideWith(() => sameVibesSpy),
        ],
      );
      addTearDown(container.dispose);

      await activatePreferredMixModeFromContainer(
        container,
        seedSongId: 'seed-2',
      );

      expect(sameVibesSpy.activateCalls, ['seed-2']);
      expect(instantMixSpy.deactivateCalled, isTrue);
      expect(instantMixSpy.activateCalls, isEmpty);
    });

    test('awaits settings before routing to legacy instant mix', () async {
      final instantMixSpy = _SpyInstantMixNotifier();
      final sameVibesSpy = _SpySameVibesNotifier();
      final repository = _MockSettingsRepository();
      when(repository.watchSettings)
          .thenAnswer((_) => const Stream<AppSettingsModel>.empty());
      when(repository.getSettings).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _settings(legacyInstantMixEnabled: true);
      });

      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          instantMixProvider.overrideWith(() => instantMixSpy),
          sameVibesProvider.overrideWith(() => sameVibesSpy),
        ],
      );
      addTearDown(container.dispose);

      final activation = activatePreferredMixModeFromContainer(
        container,
        seedSongId: 'seed-3',
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(instantMixSpy.activateCalls, isEmpty);
      expect(sameVibesSpy.activateCalls, isEmpty);

      await activation;

      expect(instantMixSpy.activateCalls, ['seed-3']);
      expect(sameVibesSpy.deactivateCalled, isTrue);
    });
  });
}
