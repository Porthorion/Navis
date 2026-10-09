import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';

void main() {
  for (final failed in [false, true]) {
    test(
      'appearance defaults while settings ${failed ? 'fail' : 'load'}',
      () async {
        final controller = StreamController<AppSettingsModel>();
        addTearDown(controller.close);
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            appSettingsProvider.overrideWith((ref) => controller.stream),
          ],
        );
        addTearDown(container.dispose);
        container.listen(appSettingsProvider, (_, _) {});
        if (failed) {
          final future = container.read(appSettingsProvider.future);
          final expectation = expectLater(future, throwsStateError);
          controller.addError(StateError('fixture'));
          await expectation;
        }
        expect(
          container.read(nowPlayingBackgroundProvider),
          NowPlayingBackground.tinted,
        );
        expect(container.read(artTintedNowPlayingProvider), isTrue);
        expect(container.read(densityProvider), NavisDensity.comfortable);
        expect(container.read(homeDensityProvider), 'comfortable');
      },
    );
  }

  for (final background in NowPlayingBackground.values) {
    for (final density in NavisDensity.values) {
      test(
        'providers expose $background and $density with legacy aliases',
        () async {
          final settings = const AppSettingsModel.defaults().copyWith(
            nowPlayingBackground: background,
            density: density,
          );
          final container = ProviderContainer(
            overrides: [
              appSettingsProvider.overrideWith((ref) => Stream.value(settings)),
            ],
          );
          addTearDown(container.dispose);
          container.listen(appSettingsProvider, (_, _) {});
          await container.read(appSettingsProvider.future);
          expect(container.read(nowPlayingBackgroundProvider), background);
          expect(
            container.read(artTintedNowPlayingProvider),
            background != NowPlayingBackground.plain,
          );
          expect(container.read(densityProvider), density);
          expect(container.read(homeDensityProvider), density.storageKey);
        },
      );
    }
  }

  test(
    'targeted persistence updates reach providers and compatibility aliases',
    () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      container.listen(appSettingsProvider, (_, _) {});
      await container.read(appSettingsProvider.future);
      final dao = container.read(navisDatabaseProvider).appSettingsDao;
      for (final (background, density) in [
        (NowPlayingBackground.artwork, NavisDensity.compact),
        (NowPlayingBackground.plain, NavisDensity.comfortable),
      ]) {
        final updated = Completer<void>();
        final subscription = container.listen(appSettingsProvider, (_, next) {
          next.whenData((settings) {
            if (settings.nowPlayingBackground == background &&
                settings.density == density &&
                !updated.isCompleted) {
              updated.complete();
            }
          });
        });
        await dao.updateNowPlayingBackground(background.storageKey);
        await dao.updateDensity(density);
        await updated.future;
        subscription.close();
        expect(container.read(nowPlayingBackgroundProvider), background);
        expect(
          container.read(artTintedNowPlayingProvider),
          background != NowPlayingBackground.plain,
        );
        expect(container.read(densityProvider), density);
        expect(container.read(homeDensityProvider), density.storageKey);
      }
    },
    skip: !sqliteAvailable,
  );
}
