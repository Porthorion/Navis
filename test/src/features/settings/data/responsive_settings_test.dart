import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/routing/content_layout.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('fresh appearance defaults disable automatic movement', () async {
    final db = createTestDatabase();
    addTearDown(db.close);
    final repository = SettingsRepository(db.appSettingsDao);
    final initial = await repository.getSettings();
    expect(initial.gridArtworkSize, GridArtworkSize.auto);
    expect(initial.homeRecommendationsAutoAdvance, isFalse);
    await db.appSettingsDao.updateGridArtworkSize('large');
    await db.appSettingsDao.updateHomeRecommendationsAutoAdvance(enabled: true);
    final written = await repository.getSettings();
    expect(written.gridArtworkSize, GridArtworkSize.large);
    expect(written.homeRecommendationsAutoAdvance, isTrue);
  }, skip: !sqliteAvailable);

  test(
    'targeted and full settings saves retain independent appearance choices',
    () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      final repository = SettingsRepository(db.appSettingsDao);
      await db.appSettingsDao.updateThemeMode('oled');
      await db.appSettingsDao.updateDensity(NavisDensity.compact);
      await db.appSettingsDao.updateGridArtworkSize('small');
      await db.appSettingsDao.updateHomeRecommendationsAutoAdvance(
        enabled: true,
      );
      var saved = await repository.getSettings();
      expect(saved.gridArtworkSize, GridArtworkSize.small);
      expect(saved.homeRecommendationsAutoAdvance, isTrue);
      expect(saved.homeDensity, NavisDensity.compact);
      expect(saved.themeMode, 'oled');
      await repository.saveSettings(saved.copyWith(cachedPlaybackFirst: true));
      saved = await repository.getSettings();
      expect(saved.gridArtworkSize, GridArtworkSize.small);
      expect(saved.homeRecommendationsAutoAdvance, isTrue);
      expect(saved.cachedPlaybackFirst, isTrue);
      await db.appSettingsDao.updateGridArtworkSize('future-preset');
      expect(
        (await repository.getSettings()).gridArtworkSize,
        GridArtworkSize.auto,
      );
    },
    skip: !sqliteAvailable,
  );
}
