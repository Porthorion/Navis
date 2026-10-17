import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:navis/src/database/navis_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/routing/content_layout.dart';
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
      coverArtShape: 'circle',
      nowPlayingArtShape: 'square',
      artistCardShape: 'rounded',
      gridArtworkSize: GridArtworkSize.large,
      albumGridDensity: 6,
      density: NavisDensity.compact,
      artistViewMode: 'list',
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
      27,
    ); // Every Look setting; tuning is Custom.
    await dao.applyAppearanceSnapshot(
      AppearanceSnapshot.capture(const AppSettingsModel.defaults()),
    );
    await repository.saveSettings(const AppSettingsModel.defaults());
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
    test('old stored Look restores layout keys ($legacyDensity)', () async {
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
      expect(after.density, NavisDensity.compact);
      expect(after.artistViewMode, 'list');
      expect(after.gridArtworkSize, GridArtworkSize.large);
      expect(after.coverArtShape, 'circle');
      expect(after.nowPlayingArtShape, 'square');
      expect(after.artistCardShape, 'rounded');
      expect(after.albumGridDensity, legacyDensity);
      expect(matchingAppearanceLookId(after), 'old');
    }, skip: !sqliteAvailable);
  }

  test(
    'stored Look without layout keys leaves layout unchanged and still matches',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final dao = database.appSettingsDao;
      final repository = SettingsRepository(dao);
      await dao.updateDensity(NavisDensity.compact);
      await dao.updateArtistViewMode('list');
      await dao.updateGridArtworkSize('large');
      await dao.updateCoverArtShape('circle');
      await dao.updateNowPlayingArtShape('square');
      await dao.updateArtistCardShape('rounded');
      await database
          .update(database.appSettingsTable)
          .write(const AppSettingsTableCompanion(albumGridDensity: Value(6)));
      final before = await repository.getSettings();
      final json = AppearanceSnapshot.capture(before).toJson();
      <String>[
        'coverArtShape',
        'nowPlayingArtShape',
        'artistCardShape',
        'gridArtworkSize',
        'albumGridDensity',
        'density',
        'artistViewMode',
      ].forEach(json.remove);
      json['themeMode'] = 'light';
      await dao.updateAppearanceLooks(
        selectedLookId: 'partial',
        looksJson: jsonEncode([
          {'id': 'partial', 'name': 'Partial', 'version': 1, 'snapshot': json},
        ]),
      );
      final look = (await repository.getSettings()).appearanceLooks.single;
      await dao.applyAppearanceSnapshot(look.snapshot);
      final after = await repository.getSettings();
      expect(
        AppearanceSnapshot.capture(after),
        AppearanceSnapshot.capture(before.copyWith(themeMode: 'light')),
      );
      expect(matchingAppearanceLookId(after), 'partial');
      expect(after.appearanceLooks.single.snapshot.toJson(), json);
    },
    skip: !sqliteAvailable,
  );

  test('captured null clears seed and legacy artwork size', () async {
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
          'coverArtShape': 'bad',
          'nowPlayingArtShape': false,
          'artistCardShape': 2,
          'gridArtworkSize': 'huge',
          'albumGridDensity': 0,
          'density': 'dense',
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
}
