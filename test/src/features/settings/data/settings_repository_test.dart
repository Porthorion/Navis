import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('SettingsRepository', () {
    late NavisDatabase database;
    late SettingsRepository repository;

    setUp(() {
      database = createTestDatabase();
      repository = SettingsRepository(database.appSettingsDao);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'stale generic saves preserve integration switches and credentials',
      () async {
        await repository.updateListenBrainzConnection(
          tokenValid: true,
          userName: 'fixture',
          scrobblingEnabled: true,
        );
        final stale = await repository.getSettings();
        await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
        await repository.setIntegrationEnabled(
          'updates.automatic',
          enabled: false,
        );
        await repository.setIntegrationEnabled(
          'lastfm.sameVibes',
          enabled: false,
        );
        await repository.setIntegrationEnabled(
          'listenbrainz.scrobbling',
          enabled: false,
        );
        await repository.updateListenBrainzConnection(tokenValid: false);
        await repository.saveSettings(stale.copyWith(themeMode: 'dark'));
        final saved = await repository.getSettings();
        expect(saved.useLrclib, isFalse);
        expect(saved.updateCheckEnabled, isFalse);
        expect(saved.legacyInstantMixEnabled, isTrue);
        expect(saved.listenBrainzScrobblingEnabled, isFalse);
        expect(saved.listenBrainzTokenValid, isFalse);
        expect(saved.listenBrainzUserName, isNull);
        expect(saved.themeMode, 'dark');
      },
      skip: !sqliteAvailable,
    );

    test('stale saves cannot restore a cleared Last.fm key', () async {
      await repository.updateLastFmApiKey('fixture-key');
      final stale = await repository.getSettings();
      await repository.updateLastFmApiKey(null);
      await repository.saveSettings(stale);
      expect((await repository.getSettings()).lastFmApiKey, isNull);
      await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
      await repository.updateLastFmApiKey('replacement-fixture-key');
      expect((await repository.getSettings()).useLrclib, isFalse);
    }, skip: !sqliteAvailable);

    test('the key writer writes only the key', () async {
      await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
      await repository.updateListenBrainzConnection(
        tokenValid: true,
        userName: 'fixture',
        scrobblingEnabled: true,
      );
      await repository.updateLastFmApiKey('fixture-key');
      final saved = await repository.getSettings();
      expect(saved.lastFmApiKey, 'fixture-key');
      expect(saved.useLrclib, isFalse);
      expect(saved.listenBrainzTokenValid, isTrue);
      expect(saved.listenBrainzUserName, 'fixture');
      expect(saved.listenBrainzScrobblingEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test(
      'resetDefaults clears the key and the ListenBrainz connection',
      () async {
        await repository.updateLastFmApiKey('fixture-key');
        await repository.updateListenBrainzConnection(
          tokenValid: true,
          userName: 'fixture',
          scrobblingEnabled: true,
        );
        await repository.resetDefaults();
        final saved = await repository.getSettings();
        expect(saved.lastFmApiKey, isNull);
        expect(saved.listenBrainzTokenValid, isFalse);
        expect(saved.listenBrainzUserName, isNull);
        expect(saved.listenBrainzScrobblingEnabled, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('persists cached playback preference', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(cachedPlaybackFirst: true),
      );

      final saved = await repository.getSettings();
      expect(saved.cachedPlaybackFirst, isTrue);

      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.cachedPlaybackFirst, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'persists and normalizes desktop playback volume atomically',
      () async {
        await repository.saveSettings(
          const AppSettingsModel.defaults().copyWith(themeMode: 'oled'),
        );

        await repository.saveDesktopPlaybackVolume(
          volume: 0.37,
          lastAudibleVolume: 0.37,
        );
        var saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0.37);
        expect(saved.desktopLastAudibleVolume, 0.37);
        expect(saved.themeMode, 'oled');

        await repository.saveDesktopPlaybackVolume(
          volume: -1,
          lastAudibleVolume: 0,
        );
        saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0);
        expect(saved.desktopLastAudibleVolume, 1);

        await repository.resetDefaults();
        saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 1);
        expect(saved.desktopLastAudibleVolume, 1);
      },
      skip: !sqliteAvailable,
    );

    test(
      'resetDefaults clears credentials saved by the retired AudioMuse client',
      () async {
        await database.appSettingsDao.getSettings();
        await database.customStatement('''
UPDATE app_settings
SET audio_muse_server_url = 'https://audiomuse.example.com',
    audio_muse_api_key = 'legacy-key',
    audio_muse_enabled = 1
WHERE id = 1;
''');

        await repository.resetDefaults();

        final row = await database.customSelect('''
SELECT audio_muse_server_url, audio_muse_api_key, audio_muse_enabled
FROM app_settings
WHERE id = 1;
''').getSingle();
        expect(row.readNullable<String>('audio_muse_server_url'), isNull);
        expect(row.readNullable<String>('audio_muse_api_key'), isNull);
        expect(row.read<int>('audio_muse_enabled'), 0);
      },
      skip: !sqliteAvailable,
    );
  });
}
