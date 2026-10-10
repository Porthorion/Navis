import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
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
      flatSurfaces: true,
      flatAreas: FlatAreas.fromBits(2),
      cornerStyle: NavisCornerStyle.square,
      coverArtShape: 'rounded',
      nowPlayingArtShape: 'circle',
      artistCardShape: 'square',
      gridArtworkSize: GridArtworkSize.large,
      albumGridDensity: 6,
      density: NavisDensity.compact,
      artistViewMode: 'list',
      nowPlayingBackground: NowPlayingBackground.artwork,
      appLocale: 'en',
      homeRecommendationsAutoAdvance: true,
    );
    await repository.saveSettings(settings);
    final original = AppearanceSnapshot.capture(await repository.getSettings());
    expect(
      original.toJson().length,
      24,
    ); // Every appearance setting; tuning is Custom.
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

  test('captured null clears seed and legacy artwork size', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final repository = SettingsRepository(database.appSettingsDao);
    final initial = AppearanceSnapshot.capture(await repository.getSettings());
    await repository.saveSettings(
      const AppSettingsModel.defaults().copyWith(
        colorSchemeSeed: 1,
        albumGridDensity: 4,
      ),
    );
    await database.appSettingsDao.applyAppearanceSnapshot(
      AppearanceSnapshot.fromJson(initial.toJson()),
    );
    final restored = await repository.getSettings();
    expect(restored.colorSchemeSeed, isNull);
    expect(restored.albumGridDensity, isNull);
  }, skip: !sqliteAvailable);

  test(
    'optional invalid fields retain current values, valid field applies',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      await dao.updateColorTuning(
        const ColorTuning(vividness: 2, lightDepth: 4, darkDepth: -3),
      );
      final before = await repository.getSettings();
      await dao.applyAppearanceSnapshot(
        AppearanceSnapshot.fromJson(const {
          'themeMode': 'bad',
          'colorSchemeSeed': 'bad',
          'surfaceDepthLight': -6,
          'nightScheduleStartMinutes': 1440,
          'artistViewMode': 'list',
        }),
      );
      final after = await repository.getSettings();
      expect(
        AppearanceSnapshot.capture(after),
        AppearanceSnapshot.capture(before.copyWith(artistViewMode: 'list')),
      );
    },
    skip: !sqliteAvailable,
  );

  test('live tuning reference uses current values, deleted reference uses snapshot values', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final dao = database.appSettingsDao;
    final repository = SettingsRepository(dao);
    const stored = ColorTuningPreset(
      id: 't',
      name: 'Warm',
      tuning: ColorTuning(vividness: -2, lightDepth: -4, darkDepth: -5),
    );
    const captured = ColorTuning(vividness: 1, lightDepth: 2, darkDepth: 3);
    final snapshot = AppearanceSnapshot.capture(
      const AppSettingsModel.defaults().copyWith(
        colorVividness: captured.vividness,
        surfaceDepthLight: captured.lightDepth,
        surfaceDepthDark: captured.darkDepth,
      ),
      tuningPresetId: 't',
    );
    await dao.updateColorTuning(
      ColorTuning.none,
      presetsJson: jsonEncode([stored.toJson()]),
    );
    await dao.applyAppearanceSnapshot(snapshot);
    var settings = await repository.getSettings();
    expect(settings.colorTuning, stored.tuning);
    expect(settings.selectedColorTuningPresetId, 't');
    await dao.updateColorTuning(ColorTuning.none, presetsJson: '[]');
    await dao.applyAppearanceSnapshot(snapshot);
    settings = await repository.getSettings();
    expect(settings.colorTuning, captured);
    expect(settings.selectedColorTuningPresetId, isNull);
  }, skip: !sqliteAvailable);

  test(
    'reset retains tuning and Look libraries and resets selected markers',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      const tuning = ColorTuningPreset(
        id: 'a',
        name: 'Warm',
        tuning: ColorTuning(darkDepth: 3),
      );
      final look = AppearanceLook(
        id: 'l',
        name: 'My look',
        snapshot: AppearanceSnapshot.capture(
          const AppSettingsModel.defaults().copyWith(themeMode: 'light'),
        ),
      );
      await dao.updateColorTuning(
        tuning.tuning,
        selectedPresetId: tuning.id,
        presetsJson: jsonEncode([tuning.toJson()]),
      );
      await dao.updateAppearanceLooks(
        selectedLookId: look.id,
        looksJson: jsonEncode([look.toJson()]),
      );
      await repository.resetDefaults();
      final settings = await repository.getSettings();
      expect(settings.colorTuning, ColorTuning.none);
      expect(settings.colorTuningPresets.single.id, 'a');
      expect(settings.appearanceLooks.single.id, 'l');
      expect(settings.selectedColorTuningPresetId, isNull);
      expect(settings.selectedAppearanceLookId, isNull);
    },
    skip: !sqliteAvailable,
  );
}
