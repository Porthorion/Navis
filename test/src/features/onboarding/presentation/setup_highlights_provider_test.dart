import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../helpers/test_database.dart';

PackageInfo _info(String version) => PackageInfo(
  appName: 'Navis',
  packageName: 'test.navis',
  version: version,
  buildNumber: '1',
);

/// The highlights of the release these tests run as; later releases add
/// their own group (see setup_highlights_test.dart).
final _highlights150 = setupHighlightsFor('1.5.0');

void main() {
  for (final required in <bool?>[true, null, false]) {
    test('pending highlights with onboarding required = $required', () async {
      final container = ProviderContainer(
        overrides: [
          onboardingRequiredProvider.overrideWithValue(required),
          appSettingsProvider.overrideWith(
            (ref) => Stream.value(const AppSettingsModel.defaults()),
          ),
          packageInfoProvider.overrideWith((ref) async => _info('1.5.0')),
        ],
      );
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(packageInfoProvider, (_, _) {});
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      expect(
        container.read(pendingSetupHighlightsProvider),
        required == false ? _highlights150.toSet() : isEmpty,
      );
      expect(
        container.read(setupHighlightsCardVisibleProvider),
        required == false,
      );
    });
  }

  for (final seen in ['1.4.9', '1.5.0', '1.5.0+1', '1.6.0', 'malformed']) {
    test('seen release $seen uses semver ordering', () async {
      final container = ProviderContainer(
        overrides: [
          onboardingRequiredProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith(
            (ref) => Stream.value(
              const AppSettingsModel.defaults().copyWith(
                setupHighlightsSeenRelease: seen,
              ),
            ),
          ),
          packageInfoProvider.overrideWith((ref) async => _info('1.5.0+1')),
        ],
      );
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(packageInfoProvider, (_, _) {});
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      expect(
        container.read(pendingSetupHighlightsProvider),
        ['1.4.9', 'malformed'].contains(seen)
            ? _highlights150.toSet()
            : isEmpty,
      );
    });
  }

  for (final dismissed in ['1.4.9', '1.5.0', '1.5.0+1', '1.6.0']) {
    test('card dismissal $dismissed leaves tags pending', () async {
      final container = ProviderContainer(
        overrides: [
          onboardingRequiredProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith(
            (ref) => Stream.value(
              const AppSettingsModel.defaults().copyWith(
                setupCardDismissedRelease: dismissed,
              ),
            ),
          ),
          packageInfoProvider.overrideWith((ref) async => _info('1.5.0')),
        ],
      );
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(packageInfoProvider, (_, _) {});
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      expect(
        container.read(pendingSetupHighlightsProvider),
        _highlights150.toSet(),
      );
      expect(
        container.read(setupHighlightsCardVisibleProvider),
        dismissed == '1.4.9',
      );
    });
  }

  group('Genres page tag (standalone, 1.5.2)', () {
    Future<ProviderContainer> open({
      String? seenRelease,
      Set<String> seen = const <String>{},
    }) async {
      final container = ProviderContainer(
        overrides: [
          onboardingRequiredProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith(
            (ref) => Stream.value(
              const AppSettingsModel.defaults().copyWith(
                setupHighlightsSeenRelease: seenRelease,
                setupHighlightsSeen: seen,
              ),
            ),
          ),
          packageInfoProvider.overrideWith((ref) async => _info('1.5.2')),
        ],
      );
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(packageInfoProvider, (_, _) {});
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      return container;
    }

    test('does not create the Home setup card', () async {
      final container = await open(seenRelease: '1.5.0');
      expect(container.read(pendingSetupHighlightsProvider), {
        SetupHighlight.genresPage,
      });
      expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
      // The tag still leads somewhere: Appearance shows it on its group.
      expect(container.read(settingsHasNewOptionsProvider), isTrue);
      expect(container.read(quickCustomizationHasNewOptionsProvider), isFalse);
    });

    test('leaves unseen 1.5.0 highlights pending', () async {
      final container = await open();
      expect(container.read(pendingSetupHighlightsProvider), {
        ..._highlights150,
        SetupHighlight.genresPage,
      });
      expect(container.read(setupHighlightsCardVisibleProvider), isTrue);
    });

    test('is cleared by marking it seen, and Finish leaves it alone', () async {
      final database = createTestDatabase();
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.completeOnboarding(
        currentOnboardingVersion,
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            packageInfoProvider.overrideWith((ref) async => _info('1.5.2')),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(onboardingRequiredProvider, (_, _) {});
      await container.read(onboardingVersionProvider.future);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      final service = container.read(setupHighlightsServiceProvider);
      final finished = container
          .read(settingsRepositoryProvider)
          .watchSettings()
          .firstWhere((s) => s.setupHighlightsSeenRelease == '1.5.0');
      await service.markSeen();
      await finished;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingSetupHighlightsProvider), {
        SetupHighlight.genresPage,
      });

      final seen = container
          .read(settingsRepositoryProvider)
          .watchSettings()
          .firstWhere((s) => s.setupHighlightsSeen.isNotEmpty);
      await service.markOptionSeen(SetupHighlight.genresPage);
      await seen;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingSetupHighlightsProvider), isEmpty);
    }, skip: !sqliteAvailable);
  });

  test('settings and metadata loading or errors hide highlights', () async {
    for (final settingsReady in [false, true]) {
      final metadata = Completer<PackageInfo>();
      final settings = StreamController<AppSettingsModel>();
      final container = ProviderContainer(
        overrides: [
          onboardingRequiredProvider.overrideWithValue(false),
          appSettingsProvider.overrideWith((ref) => settings.stream),
          packageInfoProvider.overrideWith((ref) => metadata.future),
        ],
      );
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(packageInfoProvider, (_, _) {});
      addTearDown(container.dispose);
      addTearDown(settings.close);
      if (settingsReady) {
        settings.add(const AppSettingsModel.defaults());
        await container.read(appSettingsProvider.future);
      } else {
        metadata.complete(_info('1.5.0'));
        await container.read(packageInfoProvider.future);
      }
      expect(container.read(pendingSetupHighlightsProvider), isEmpty);
      expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
      if (settingsReady) {
        metadata.completeError(StateError('metadata unavailable'));
        await expectLater(
          container.read(packageInfoProvider.future),
          throwsStateError,
        );
      } else {
        settings.addError(StateError('settings unavailable'));
        await expectLater(
          container.read(appSettingsProvider.future),
          throwsStateError,
        );
      }
      expect(container.read(pendingSetupHighlightsProvider), isEmpty);
    }
  });

  test('major release without highlights hides tags and card', () async {
    final container = ProviderContainer(
      overrides: [
        onboardingRequiredProvider.overrideWithValue(false),
        appSettingsProvider.overrideWith(
          (ref) => Stream.value(const AppSettingsModel.defaults()),
        ),
        packageInfoProvider.overrideWith((ref) async => _info('2.0.0')),
      ],
    );
    container.listen(appSettingsProvider, (_, _) {});
    container.listen(packageInfoProvider, (_, _) {});
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(packageInfoProvider.future);
    expect(container.read(setupWhatsNewReleaseProvider), isNull);
    expect(container.read(pendingSetupHighlightsProvider), isEmpty);
    expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
  });

  test(
    'dismissCard hides only the card; markSeen clears pending tags',
    () async {
      final database = createTestDatabase();
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.completeOnboarding(
        currentOnboardingVersion,
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            packageInfoProvider.overrideWith((ref) async => _info('1.5.0+1')),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(onboardingRequiredProvider, (_, _) {});
      await container.read(onboardingVersionProvider.future);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      expect(
        container.read(pendingSetupHighlightsProvider),
        _highlights150.toSet(),
      );
      final service = container.read(setupHighlightsServiceProvider);
      // Listen before writing so assertions observe the committed stream value.
      final cardHidden = container
          .read(settingsRepositoryProvider)
          .watchSettings()
          .firstWhere((s) => s.setupCardDismissedRelease == '1.5.0');
      await service.dismissCard();
      await cardHidden;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
      expect(
        container.read(pendingSetupHighlightsProvider),
        _highlights150.toSet(),
      );
      final seen = container
          .read(settingsRepositoryProvider)
          .watchSettings()
          .firstWhere((s) => s.setupHighlightsSeenRelease == '1.5.0');
      await service.markSeen();
      await seen;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingSetupHighlightsProvider), isEmpty);
      expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'option acknowledgements are idempotent, concurrent and hide an empty card',
    () async {
      final database = createTestDatabase();
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.completeOnboarding(
        currentOnboardingVersion,
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            packageInfoProvider.overrideWith((ref) async => _info('1.5.0')),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      container.listen(appSettingsProvider, (_, _) {});
      container.listen(onboardingRequiredProvider, (_, _) {});
      await container.read(onboardingVersionProvider.future);
      await container.read(appSettingsProvider.future);
      await container.read(packageInfoProvider.future);
      final service = container.read(setupHighlightsServiceProvider);
      final repository = container.read(settingsRepositoryProvider);
      final initial = await repository.getSettings();
      final firstSeen = repository.watchSettings().firstWhere(
        (s) => s.setupHighlightsSeen.contains(
          SetupHighlight.colorStyle.storageKey,
        ),
      );
      await service.markOptionSeen(SetupHighlight.colorStyle);
      await firstSeen;
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(pendingSetupHighlightsProvider),
        _highlights150.where((h) => h != SetupHighlight.colorStyle).toSet(),
      );
      expect(container.read(setupHighlightsCardVisibleProvider), isTrue);
      final completed = repository.watchSettings().firstWhere(
        (s) => s.setupHighlightsSeen.length == _highlights150.length,
      );
      await Future.wait([
        for (final option in _highlights150) service.markOptionSeen(option),
        service.markOptionSeen(SetupHighlight.colorStyle),
      ]);
      await completed;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(pendingSetupHighlightsProvider), isEmpty);
      expect(container.read(setupHighlightsCardVisibleProvider), isFalse);
      expect(
        (await repository.getSettings()).setupHighlightsSeenRelease,
        isNull,
      );
      await repository.saveSettings(initial);
      expect(
        (await repository.getSettings()).setupHighlightsSeen.length,
        _highlights150.length,
      );
      // Unknown and malformed persisted keys never clear an unrelated option.
      await database.customStatement(
        "UPDATE app_settings SET setup_highlights_seen = 'invalid'",
      );
      expect((await repository.getSettings()).setupHighlightsSeen, isEmpty);
      await service.markOptionSeen(SetupHighlight.cornerStyle);
      expect((await repository.getSettings()).setupHighlightsSeen, {
        SetupHighlight.cornerStyle.storageKey,
      });
    },
    skip: !sqliteAvailable,
  );

  test('markSeen waits for loading metadata before writing', () async {
    final metadata = Completer<PackageInfo>();
    final database = createTestDatabase();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          packageInfoProvider.overrideWith((ref) => metadata.future),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await database.appSettingsDao.getSettings();
    final operation = container.read(setupHighlightsServiceProvider).markSeen();
    expect(
      (await database.appSettingsDao.getSettings())!.setupHighlightsSeenRelease,
      isNull,
    );
    metadata.complete(_info('1.5.0'));
    await operation;
    expect(
      (await database.appSettingsDao.getSettings())!.setupHighlightsSeenRelease,
      '1.5.0',
    );
  }, skip: !sqliteAvailable);
}
