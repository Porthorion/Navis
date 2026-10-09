import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

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

    test('corner style maps, saves, watches and resets', () async {
      final defaults = await repository.getSettings();
      expect(defaults.cornerStyle, NavisCornerStyle.rounded);
      expect(
        const AppSettingsModel.defaults().cornerStyle,
        NavisCornerStyle.rounded,
      );
      for (final style in NavisCornerStyle.values) {
        await repository.updateCornerStyle(style);
        final targeted = await repository.getSettings();
        expect(targeted.cornerStyle, style);
        expect(targeted.copyWith(themeMode: 'oled').cornerStyle, style);
        await repository.saveSettings(targeted.copyWith(themeMode: 'oled'));
        expect((await repository.getSettings()).cornerStyle, style);
        expect(
          (await database.appSettingsDao.getSettings())!.cornerStyle,
          style.name,
        );
        final savedStyle = style == NavisCornerStyle.square
            ? NavisCornerStyle.soft
            : NavisCornerStyle.square;
        await repository.saveSettings(
          defaults.copyWith(cornerStyle: savedStyle),
        );
        expect(
          (await repository.watchSettings().first).cornerStyle,
          savedStyle,
        );
        expect(
          (await database.appSettingsDao.getSettings())!.cornerStyle,
          savedStyle.name,
        );
      }
      await database.customStatement(
        "UPDATE app_settings SET corner_style = 'unknown'",
      );
      expect(
        (await repository.getSettings()).cornerStyle,
        NavisCornerStyle.rounded,
      );
      await repository.updateCornerStyle(NavisCornerStyle.soft);
      await repository.resetDefaults();
      expect(
        (await repository.getSettings()).cornerStyle,
        NavisCornerStyle.rounded,
      );
    }, skip: !sqliteAvailable);

    test('background and density map, save, watch and reset', () async {
      final defaults = await repository.getSettings();
      expect(defaults.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(defaults.density, NavisDensity.comfortable);
      await repository.updateNowPlayingBackground(NowPlayingBackground.artwork);
      await repository.updateDensity(NavisDensity.compact);
      final targeted = await repository.getSettings();
      expect(targeted.nowPlayingBackground, NowPlayingBackground.artwork);
      expect(targeted.artTintedNowPlaying, isTrue);
      expect(targeted.homeDensity, 'compact');
      await repository.saveSettings(targeted.copyWith(themeMode: 'light'));
      expect(
        (await repository.getSettings()).nowPlayingBackground,
        NowPlayingBackground.artwork,
      );
      for (final background in NowPlayingBackground.values) {
        await repository.saveSettings(
          defaults.copyWith(
            nowPlayingBackground: background,
            density: NavisDensity.compact,
          ),
        );
        final watched = await repository.watchSettings().first;
        expect(watched.nowPlayingBackground, background);
        expect(
          watched.artTintedNowPlaying,
          background != NowPlayingBackground.plain,
        );
        expect(watched.density, NavisDensity.compact);
        final row = (await database.appSettingsDao.getSettings())!;
        expect(row.nowPlayingBackground, background.storageKey);
        expect(
          row.artTintedNowPlaying,
          background != NowPlayingBackground.plain,
        );
      }
      await database.customStatement(
        "UPDATE app_settings SET now_playing_background = 'unknown', art_tinted_now_playing = 0, home_density = 'unknown'",
      );
      final unknown = await repository.getSettings();
      expect(unknown.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(unknown.artTintedNowPlaying, isTrue);
      expect(unknown.density, NavisDensity.comfortable);
      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(reset.density, NavisDensity.comfortable);
    }, skip: !sqliteAvailable);

    test('stale onboarding drafts preserve setup release markers', () async {
      final stale = await repository.getSettings();
      await repository.updateSetupHighlightsSeenRelease('1.4.3');
      await repository.updateSetupCardDismissedRelease('1.4.3');
      await repository.saveSettings(stale.copyWith(colorStyle: 'night'));
      final saved = await repository.getSettings();
      expect(saved.setupHighlightsSeenRelease, '1.4.3');
      expect(saved.setupCardDismissedRelease, '1.4.3');
      expect(saved.colorStyle, 'night');
      final watched = await repository.watchSettings().first;
      expect(watched.setupHighlightsSeenRelease, '1.4.3');
      expect(watched.setupCardDismissedRelease, '1.4.3');
      final cleared = saved.copyWith(
        clearSetupHighlightsSeenRelease: true,
        clearSetupCardDismissedRelease: true,
      );
      expect(cleared.setupHighlightsSeenRelease, isNull);
      expect(cleared.setupCardDismissedRelease, isNull);
      expect(
        saved.copyWith(themeMode: 'oled').setupHighlightsSeenRelease,
        '1.4.3',
      );
    }, skip: !sqliteAvailable);

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

    test('normalizes retired group listening settings to disabled', () async {
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
            variables: [Variable.withInt(AppSettingsDao.primarySettingsId)],
          )
          .getSingle();
      expect(row.read<int>('group_listening_enabled'), 0);
      expect(row.readNullable<String>('voyage_server_url'), isNull);
      expect(row.readNullable<String>('voyage_display_name'), isNull);
      expect(row.readNullable<String>('voyage_device_label'), isNull);
      expect(row.readNullable<String>('custom_voyage_servers'), isNull);
    }, skip: !sqliteAvailable);

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
              variables: [Variable.withInt(AppSettingsDao.primarySettingsId)],
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
        const AppSettingsModel.defaults().copyWith(cachedPlaybackFirst: true),
      );

      final saved = await repository.getSettings();
      expect(saved.cachedPlaybackFirst, isTrue);

      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.cachedPlaybackFirst, isFalse);
    }, skip: !sqliteAvailable);

    test('round trips appearance settings and restores defaults', () async {
      final defaults = await repository.getSettings();
      expect(defaults.oledForAuto, isFalse);
      expect(defaults.nightScheduleEnabled, isFalse);
      expect(defaults.nightScheduleStartMinutes, 1320);
      expect(defaults.nightScheduleEndMinutes, 420);
      expect(defaults.flatSurfaces, isFalse);
      await repository.saveSettings(
        defaults.copyWith(
          oledForAuto: true,
          nightScheduleEnabled: true,
          nightScheduleStartMinutes: 1200,
          nightScheduleEndMinutes: 480,
          flatSurfaces: true,
        ),
      );
      final saved = await repository.getSettings();
      expect(saved.oledForAuto, isTrue);
      expect(saved.nightScheduleEnabled, isTrue);
      expect(saved.nightScheduleStartMinutes, 1200);
      expect(saved.nightScheduleEndMinutes, 480);
      expect(saved.flatSurfaces, isTrue);
      await repository.saveSettings(saved.copyWith(themeMode: 'system'));
      final preserved = await repository.getSettings();
      expect(preserved.oledForAuto, isTrue);
      expect(preserved.nightScheduleEnabled, isTrue);
      expect(preserved.nightScheduleStartMinutes, 1200);
      expect(preserved.nightScheduleEndMinutes, 480);
      expect(preserved.flatSurfaces, isTrue);

      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.oledForAuto, isFalse);
      expect(reset.nightScheduleEnabled, isFalse);
      expect(reset.nightScheduleStartMinutes, 1320);
      expect(reset.nightScheduleEndMinutes, 420);
      expect(reset.flatSurfaces, isFalse);
    }, skip: !sqliteAvailable);

    test('full-row saves clamp Night schedule minutes', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(
          nightScheduleStartMinutes: -1,
          nightScheduleEndMinutes: 1440,
        ),
      );
      final saved = await repository.getSettings();
      expect(saved.nightScheduleStartMinutes, 0);
      expect(saved.nightScheduleEndMinutes, 1439);
    }, skip: !sqliteAvailable);

    test('round trips colour style independently of theme mode', () async {
      final defaults = await repository.getSettings();
      expect(defaults.colorStyle, 'neutral');
      await repository.saveSettings(
        defaults.copyWith(themeMode: 'oled', colorStyle: 'pastel'),
      );

      final saved = await repository.getSettings();
      expect(saved.colorStyle, 'pastel');
      expect(saved.themeMode, 'oled');
      await repository.saveSettings(saved.copyWith(themeMode: 'light'));
      expect((await repository.getSettings()).colorStyle, 'pastel');

      await repository.resetDefaults();
      expect((await repository.getSettings()).colorStyle, 'neutral');
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
