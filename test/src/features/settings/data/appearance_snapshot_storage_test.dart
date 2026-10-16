import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:navis/src/database/navis_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('capture reset apply restores every appearance field, preserves unrelated fields', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final dao = database.appSettingsDao;
    final repository = SettingsRepository(dao);
    final settings = const AppSettingsModel.defaults().copyWith(
      themeMode: 'system',
      oledForAuto: true,
      colorStyle: 'immersive',
      colorSchemeSeed: 0xFFABCD12,
      dynamicAlbumColorEnabled: true,
      nightScheduleEnabled: true,
      nightScheduleStartMinutes: 123,
      nightScheduleEndMinutes: 456,
      albumArtShade: true,
      albumArtColoredShade: true,
      colorVividness: 4,
      surfaceDepthLight: -2,
      surfaceDepthDark: 3,
      surfaceTintLight: 5,
      surfaceTintDark: 3,
      controlColor: 'white',
      flatSurfaces: true,
      flatAreas: FlatAreas.fromBits(2),
      cornerStyle: NavisCornerStyle.square,
      nowPlayingBackground: NowPlayingBackground.artwork,
      appLocale: 'en',
      homeRecommendationsAutoAdvance: true,
    );
    await dao.applyAppearanceSnapshot(AppearanceSnapshot.capture(settings));
    await dao.updateAppLocale(settings.appLocale);
    await dao.updateHomeRecommendationsAutoAdvance(
      enabled: settings.homeRecommendationsAutoAdvance,
    );
    final original = AppearanceSnapshot.capture(await repository.getSettings());
    expect(
      original.toJson().length,
      20,
    ); // Every Look setting; tuning is Custom.
    await repository.resetDefaults();
    await dao.updateCustomColorPresets(jsonEncode([0xFF123456]));
    await dao.updateShowArtistsPage(enabled: false);
    await dao.updateDesktopNavbarStyle('icons');
    await dao.updateHomeSectionsHidden('["recentlyAdded"]');
    await dao.applyAppearanceSnapshot(
      AppearanceSnapshot.fromJson(original.toJson()),
    );
    final restored = await repository.getSettings();
    expect(AppearanceSnapshot.capture(restored), original);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    // Language, saved swatches and recommendation auto-advance are not part
    // of a Look: applying one leaves them as they were.
    container.listen(customColorPresetsProvider, (_, _) {});
    expect(await container.read(customColorPresetsProvider.future), [
      0xFF123456,
    ]);
    expect(restored.appLocale, isNull);
    expect(restored.homeRecommendationsAutoAdvance, isFalse);
    expect(restored.showArtistsPage, isFalse);
    expect(restored.desktopNavbarStyle, 'icons');
    expect(restored.homeSectionsHidden, ['recentlyAdded']);
    expect(restored.scrobbleEnabled, isTrue);
  }, skip: !sqliteAvailable);

  for (final legacyDensity in <int?>[null, 6]) {
    test('old stored Look ignores layout keys ($legacyDensity)', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      await dao.getSettings();
      await database
          .update(database.appSettingsTable)
          .write(const AppSettingsTableCompanion(albumGridDensity: Value(4)));
      final before = await repository.getSettings();
      final legacy = {
        'id': 'old',
        'name': 'Old Look',
        'version': 1,
        'snapshot': {
          ...AppearanceSnapshot.capture(before).toJson(),
          'themeMode': 'light',
          'density': 'compact',
          'artistViewMode': 'list',
          'gridArtworkSize': 'large',
          'coverArtShape': 'circle',
          'nowPlayingArtShape': 'square',
          'artistCardShape': 'rounded',
          'albumGridDensity': legacyDensity,
        },
      };
      await dao.updateAppearanceLooks(
        selectedLookId: 'old',
        looksJson: jsonEncode([legacy]),
      );
      final look = (await repository.getSettings()).appearanceLooks.single;
      await dao.applyAppearanceSnapshot(look.snapshot);
      final after = await repository.getSettings();
      expect(after.themeMode, 'light');
      expect(after.density, before.density);
      expect(after.artistViewMode, before.artistViewMode);
      expect(after.gridArtworkSize, before.gridArtworkSize);
      expect(after.coverArtShape, before.coverArtShape);
      expect(after.nowPlayingArtShape, before.nowPlayingArtShape);
      expect(after.artistCardShape, before.artistCardShape);
      expect(after.albumGridDensity, before.albumGridDensity);
      expect(matchingAppearanceLookId(after), 'old');
    }, skip: !sqliteAvailable);
  }

  test('captured null clears seed and preserves legacy artwork size', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final repository = SettingsRepository(database.appSettingsDao);
    final initial = AppearanceSnapshot.capture(await repository.getSettings());
    await database.appSettingsDao.updateColorSchemeSeed(1);
    await database
        .update(database.appSettingsTable)
        .write(const AppSettingsTableCompanion(albumGridDensity: Value(4)));
    await database.appSettingsDao.applyAppearanceSnapshot(
      AppearanceSnapshot.fromJson(initial.toJson()),
    );
    final restored = await repository.getSettings();
    expect(restored.colorSchemeSeed, isNull);
    expect(restored.albumGridDensity, 4);
  }, skip: !sqliteAvailable);

  test(
    'optional invalid fields retain current values, valid field applies',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      await dao.updateColorTuning(
        const ColorTuning(
          vividness: 2,
          lightDepth: 4,
          darkDepth: -3,
          lightTint: 3,
          darkTint: 5,
          controls: NavisControlColor.white,
        ),
      );
      final before = await repository.getSettings();
      await dao.applyAppearanceSnapshot(
        AppearanceSnapshot.fromJson(const {
          'themeMode': 'bad',
          'colorSchemeSeed': 'bad',
          'surfaceDepthLight': -6,
          'surfaceTintLight': 6,
          'surfaceTintDark': -1,
          'controlColor': 'unknown',
          'nightScheduleStartMinutes': 1440,
          'colorStyle': 'pastel',
        }),
      );
      final after = await repository.getSettings();
      expect(
        AppearanceSnapshot.capture(after),
        AppearanceSnapshot.capture(before.copyWith(colorStyle: 'pastel')),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'reset retains the Look library and resets its selected marker',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      final look = AppearanceLook(
        id: 'l',
        name: 'My look',
        snapshot: AppearanceSnapshot.capture(
          const AppSettingsModel.defaults().copyWith(themeMode: 'light'),
        ),
      );
      await dao.updateColorTuning(
        const ColorTuning(vividness: 2, lightDepth: -3, darkDepth: 4),
      );
      await dao.updateAppearanceLooks(
        selectedLookId: look.id,
        looksJson: jsonEncode([look.toJson()]),
      );
      await repository.resetDefaults();
      final settings = await repository.getSettings();
      expect(settings.colorTuning, ColorTuning.none);
      expect(settings.appearanceLooks.single.id, 'l');
      expect(settings.selectedAppearanceLookId, isNull);
    },
    skip: !sqliteAvailable,
  );
}
