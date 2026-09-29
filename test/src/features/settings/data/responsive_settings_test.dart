import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/routing/content_layout.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test(
    'fresh appearance defaults and reset disable automatic movement',
    () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      final repository = SettingsRepository(db.appSettingsDao);
      final initial = await repository.getSettings();
      expect(initial.gridArtworkSize, GridArtworkSize.auto);
      expect(initial.homeRecommendationsAutoAdvance, isFalse);
      await db.appSettingsDao.updateGridArtworkSize('large');
      await db.appSettingsDao.updateHomeRecommendationsAutoAdvance(
        enabled: true,
      );
      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.gridArtworkSize, GridArtworkSize.auto);
      expect(reset.homeRecommendationsAutoAdvance, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'targeted and full settings saves retain independent appearance choices',
    () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      final repository = SettingsRepository(db.appSettingsDao);
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          themeMode: 'oled',
          homeDensity: 'compact',
        ),
      );
      await db.appSettingsDao.updateGridArtworkSize('small');
      await db.appSettingsDao.updateHomeRecommendationsAutoAdvance(
        enabled: true,
      );
      var saved = await repository.getSettings();
      expect(saved.gridArtworkSize, GridArtworkSize.small);
      expect(saved.homeRecommendationsAutoAdvance, isTrue);
      expect(saved.homeDensity, 'compact');
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
