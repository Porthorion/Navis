import 'package:drift/drift.dart' show Variable;
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
      'normalizes retired group listening settings to disabled',
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

        expect(saved.groupListeningEnabled, isFalse);
        expect(saved.voyageServerUrl, isNull);
        expect(saved.voyageDisplayName, isNull);
        expect(saved.voyageDeviceLabel, isNull);
        expect(
          saved.voyageAutoFollowHost,
          AppSettingsDao.defaultVoyageAutoFollowHost,
        );
        expect(saved.lastFmApiKey, isNull);

        final row = await database
            .customSelect(
              '''
SELECT group_listening_enabled,
       voyage_server_url,
       voyage_display_name,
       voyage_device_label,
       custom_voyage_servers
FROM app_settings
WHERE id = ?;
''',
              variables: [
                Variable.withInt(AppSettingsDao.primarySettingsId),
              ],
            )
            .getSingle();
        expect(row.read<int>('group_listening_enabled'), 0);
        expect(row.readNullable<String>('voyage_server_url'), isNull);
        expect(row.readNullable<String>('voyage_display_name'), isNull);
        expect(row.readNullable<String>('voyage_device_label'), isNull);
        expect(row.readNullable<String>('custom_voyage_servers'), isNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'maps stale raw Voyage settings as retired and clears on save',
      () async {
        await database.appSettingsDao.getSettings();
        await database.customStatement(
          '''
UPDATE app_settings
SET group_listening_enabled = 1,
    voyage_server_url = 'https://voyage.example.com',
    voyage_display_name = 'Living Room',
    voyage_device_label = 'Desktop',
    voyage_auto_follow_host = 0,
    custom_voyage_servers = '[{"label":"Custom","url":"https://custom.example.com"}]'
WHERE id = ?;
''',
          [AppSettingsDao.primarySettingsId],
        );

        final mapped = await repository.getSettings();
        expect(mapped.groupListeningEnabled, isFalse);
        expect(mapped.voyageServerUrl, isNull);
        expect(mapped.voyageDisplayName, isNull);
        expect(mapped.voyageDeviceLabel, isNull);
        expect(mapped.customVoyageServers, isEmpty);

        await repository.saveSettings(
          mapped.copyWith(cachedPlaybackFirst: true),
        );

        final row = await database
            .customSelect(
              '''
SELECT group_listening_enabled,
       voyage_server_url,
       voyage_display_name,
       voyage_device_label,
       custom_voyage_servers
FROM app_settings
WHERE id = ?;
''',
              variables: [
                Variable.withInt(AppSettingsDao.primarySettingsId),
              ],
            )
            .getSingle();
        expect(row.read<int>('group_listening_enabled'), 0);
        expect(row.readNullable<String>('voyage_server_url'), isNull);
        expect(row.readNullable<String>('voyage_display_name'), isNull);
        expect(row.readNullable<String>('voyage_device_label'), isNull);
        expect(row.readNullable<String>('custom_voyage_servers'), isNull);
      },
      skip: !sqliteAvailable,
    );

    test('persists cached playback preference', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          cachedPlaybackFirst: true,
        ),
      );

      final saved = await repository.getSettings();
      expect(saved.cachedPlaybackFirst, isTrue);

      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.cachedPlaybackFirst, isFalse);
    }, skip: !sqliteAvailable);

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

      final row = await database
          .customSelect(
            '''
SELECT group_listening_enabled,
       voyage_server_url,
       voyage_display_name,
       voyage_device_label,
       custom_voyage_servers
FROM app_settings
WHERE id = ?;
''',
            variables: [Variable.withInt(AppSettingsDao.primarySettingsId)],
          )
          .getSingle();
      expect(row.read<int>('group_listening_enabled'), 0);
      expect(row.readNullable<String>('voyage_server_url'), isNull);
      expect(row.readNullable<String>('voyage_display_name'), isNull);
      expect(row.readNullable<String>('voyage_device_label'), isNull);
      expect(row.readNullable<String>('custom_voyage_servers'), isNull);
    }, skip: !sqliteAvailable);
  });
}
