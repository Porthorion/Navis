import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
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

    test(
      'setup Finish preserves values changed elsewhere after entry',
      () async {
        final initial = await repository.getSettings();
        await repository.saveDesktopPlaybackVolume(
          volume: 0.3,
          lastAudibleVolume: 0.3,
        );
        await database.appSettingsDao.updateColorStyle('immersive');
        await database.appSettingsDao.updateNightSchedule(startMinutes: 1000);
        final draft = initial.copyWith(
          themeMode: 'oled',
          nightScheduleEnabled: true,
          wifiMaxBitRate: 128,
          clearWifiFormat: true,
          albumQueueEnabled: false,
        );
        await repository.saveOnboardingChanges(initial, draft);
        final saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0.3);
        expect(saved.colorStyle, 'immersive');
        expect(saved.nightScheduleStartMinutes, 1000);
        expect(saved.nightScheduleEnabled, isTrue);
        expect(saved.themeMode, 'oled');
        expect(saved.wifiMaxBitRate, 128);
        expect(saved.wifiFormat, isNull);
        expect(saved.albumQueueEnabled, isFalse);
      },
    );

    test('Flat areas and shade round trip and reset independently', () async {
      final initial = await repository.getSettings();
      expect(initial.flatAreas.bits, 7);
      expect(initial.albumArtColoredShade, isFalse);
      for (var bits = 0; bits <= 7; bits++) {
        final areas = FlatAreas.fromBits(bits);
        await repository.saveSettings(
          initial.copyWith(flatAreas: areas, albumArtColoredShade: true),
        );
        final saved = await repository.getSettings();
        expect(saved.flatAreas, areas);
        expect(saved.albumArtColoredShade, isTrue);
        expect((await repository.watchSettings().first).flatAreas, areas);
        expect((await database.appSettingsDao.getSettings())!.flatAreas, bits);
      }
      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.flatAreas.bits, 7);
      expect(reset.albumArtColoredShade, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'setup diffs preserve concurrent area/shade writes until changed',
      () async {
        final initial = await repository.getSettings();
        await database.appSettingsDao.updateFlatAreas(0);
        await database.appSettingsDao.updateAlbumArtColoredShade(enabled: true);
        await repository.saveOnboardingChanges(
          initial,
          initial.copyWith(themeMode: 'oled'),
        );
        var saved = await repository.getSettings();
        expect(saved.flatAreas.bits, 0);
        expect(saved.albumArtColoredShade, isTrue);
        await repository.saveOnboardingChanges(
          initial,
          initial.copyWith(
            flatAreas: const FlatAreas(nowPlaying: false),
            albumArtColoredShade: true,
          ),
        );
        saved = await repository.getSettings();
        expect(saved.flatAreas.bits, 5);
        expect(saved.albumArtColoredShade, isTrue);
        await repository.saveOnboardingChanges(
          saved,
          saved.copyWith(albumArtColoredShade: false),
        );
        expect((await repository.getSettings()).albumArtColoredShade, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('corner style maps, saves, watches and resets', () async {
      final defaults = await repository.getSettings();
      expect(defaults.cornerStyle, NavisCornerStyle.rounded);
      expect(
        const AppSettingsModel.defaults().cornerStyle,
        NavisCornerStyle.rounded,
      );
      for (final style in NavisCornerStyle.values) {
        await database.appSettingsDao.updateCornerStyle(style.name);
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
      await database.appSettingsDao.updateCornerStyle('soft');
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
      await database.appSettingsDao.updateNowPlayingBackground('artwork');
      await database.appSettingsDao.updateDensity(NavisDensity.compact);
      final targeted = await repository.getSettings();
      expect(targeted.nowPlayingBackground, NowPlayingBackground.artwork);
      expect(targeted.homeDensity, NavisDensity.compact);
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
        expect(watched.density, NavisDensity.compact);
        final row = (await database.appSettingsDao.getSettings())!;
        expect(row.nowPlayingBackground, background.storageKey);
      }
      await database.customStatement(
        "UPDATE app_settings SET now_playing_background = 'unknown', art_tinted_now_playing = 0, home_density = 'unknown'",
      );
      final unknown = await repository.getSettings();
      expect(unknown.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(unknown.density, NavisDensity.comfortable);
      await repository.resetDefaults();
      final reset = await repository.getSettings();
      expect(reset.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(reset.density, NavisDensity.comfortable);
    }, skip: !sqliteAvailable);

    test('stale onboarding drafts preserve setup release markers', () async {
      final stale = await repository.getSettings();
      await repository.updateSetupHighlightsSeenRelease('1.5.0');
      await repository.updateSetupCardDismissedRelease('1.5.0');
      await repository.saveSettings(stale.copyWith(colorStyle: 'night'));
      final saved = await repository.getSettings();
      expect(saved.setupHighlightsSeenRelease, '1.5.0');
      expect(saved.setupCardDismissedRelease, '1.5.0');
      expect(saved.colorStyle, 'night');
      final watched = await repository.watchSettings().first;
      expect(watched.setupHighlightsSeenRelease, '1.5.0');
      expect(watched.setupCardDismissedRelease, '1.5.0');
      final cleared = saved.copyWith(
        clearSetupHighlightsSeenRelease: true,
        clearSetupCardDismissedRelease: true,
      );
      expect(cleared.setupHighlightsSeenRelease, isNull);
      expect(cleared.setupCardDismissedRelease, isNull);
      expect(
        saved.copyWith(themeMode: 'oled').setupHighlightsSeenRelease,
        '1.5.0',
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
