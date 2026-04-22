import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('SettingsRepository', () {
    late NavisDatabase database;
    late SettingsRepository repository;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      repository = SettingsRepository(database.appSettingsDao);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'persists only active group listening settings via app settings model',
      () async {
        final settings = const AppSettingsModel.defaults().copyWith(
          groupListeningEnabled: true,
          voyageServerUrl: 'https://voyage.example.com',
          voyageDisplayName: 'Living Room',
          voyageDeviceLabel: 'Pixel Tablet',
          voyageAutoFollowHost: false,
        );

        await repository.saveSettings(settings);
        final saved = await repository.getSettings();

        expect(saved.groupListeningEnabled, isTrue);
        expect(saved.voyageServerUrl, 'https://voyage.example.com');
        expect(saved.voyageDisplayName, isNull);
        expect(saved.voyageDeviceLabel, isNull);
        expect(
          saved.voyageAutoFollowHost,
          AppSettingsDao.defaultVoyageAutoFollowHost,
        );
        expect(saved.lastFmApiKey, isNull);
      },
      skip: !sqliteAvailable,
    );

    test('resetDefaults clears group listening settings', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          groupListeningEnabled: true,
          voyageServerUrl: 'https://voyage.example.com',
          voyageDisplayName: 'Alice',
          voyageDeviceLabel: 'Desktop',
          voyageAutoFollowHost: false,
        ),
      );

      await repository.resetDefaults();
      final saved = await repository.getSettings();

      expect(saved.groupListeningEnabled, isFalse);
      expect(saved.voyageServerUrl, isNull);
      expect(saved.voyageDisplayName, isNull);
      expect(saved.voyageDeviceLabel, isNull);
      expect(
        saved.voyageAutoFollowHost,
        AppSettingsDao.defaultVoyageAutoFollowHost,
      );
    }, skip: !sqliteAvailable);
  });
}
