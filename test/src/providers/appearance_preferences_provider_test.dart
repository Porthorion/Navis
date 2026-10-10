import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/album_title_shade.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
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
        expect(container.read(densityProvider), NavisDensity.comfortable);
        expect(container.read(flatAreasProvider), const FlatAreas());
        expect(container.read(albumArtColoredShadeProvider), isFalse);
        expect(container.read(albumArtShadeProvider), isFalse);
        expect(
          container.read(albumTitleShadeModeProvider),
          AlbumTitleShade.classic,
        );
      },
    );
  }

  test('shade mode follows persisted parent and colour toggles', () async {
    final database = createTestDatabase();
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    container.listen(appSettingsProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    final dao = database.appSettingsDao;
    for (final (shade, colored, mode) in [
      (false, true, AlbumTitleShade.classic),
      (true, true, AlbumTitleShade.color),
      (true, false, AlbumTitleShade.dark),
      (false, false, AlbumTitleShade.classic),
    ]) {
      final updated = Completer<void>();
      final subscription = container.listen(appSettingsProvider, (_, next) {
        next.whenData((settings) {
          if (settings.albumArtShade == shade &&
              settings.albumArtColoredShade == colored &&
              !updated.isCompleted) {
            updated.complete();
          }
        });
      });
      await dao.updateAlbumArtShade(enabled: shade);
      await dao.updateAlbumArtColoredShade(enabled: colored);
      await updated.future;
      subscription.close();
      expect(container.read(albumArtShadeProvider), shade);
      expect(container.read(albumArtColoredShadeProvider), colored);
      expect(container.read(albumTitleShadeModeProvider), mode);
    }
  }, skip: !sqliteAvailable);

  test('area and shade providers expose persisted values', () async {
    final database = createTestDatabase();
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    await database.appSettingsDao.getSettings();
    await database.appSettingsDao.updateFlatAreas(2);
    await database.appSettingsDao.updateAlbumArtColoredShade(enabled: true);
    container.listen(appSettingsProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    expect(container.read(flatAreasProvider), FlatAreas.fromBits(2));
    expect(container.read(albumArtColoredShadeProvider), isTrue);
  }, skip: !sqliteAvailable);

  for (final background in NowPlayingBackground.values) {
    for (final density in NavisDensity.values) {
      test('providers expose $background and $density', () async {
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
        expect(container.read(densityProvider), density);
      });
    }
  }

  test('targeted persistence updates reach providers', () async {
    final database = createTestDatabase();
    final container = ProviderContainer(overrides: withTestDatabase(database));
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
      expect(container.read(densityProvider), density);
    }
  }, skip: !sqliteAvailable);
}
