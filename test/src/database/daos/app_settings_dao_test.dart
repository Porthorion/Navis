import 'package:navis/src/theme/color_adjustment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('AppSettingsDao', () {
    late NavisDatabase database;

    setUp(() {
      database = createTestDatabase();
    });

    tearDown(() async {
      await database.close();
    });

    for (final legacy in [false, true]) {
      test(
        'delete all presets clears libraries and selections, legacy=$legacy',
        () async {
          final dao = database.appSettingsDao;
          await dao.updatePlaybackAdjustments(
            speed: 1.25,
            pitchSemitones: 2,
            selectedPresetId: 'old',
            presetsJson: '[{"id":"old"}]',
          );
          await dao.updateAppearanceLooks(
            selectedLookId: 'look',
            looksJson: '[{"id":"look"}]',
          );
          await dao.updateColorTuning(const ColorTuning(vividness: 3));
          if (legacy) {
            await database.customStatement(
              "ALTER TABLE app_settings ADD COLUMN color_tuning_presets TEXT DEFAULT '[]'",
            );
            await database.customStatement(
              'ALTER TABLE app_settings ADD COLUMN selected_color_tuning_preset_id TEXT',
            );
            await database.customStatement(
              "UPDATE app_settings SET color_tuning_presets = '[{}]', selected_color_tuning_preset_id = 'old'",
            );
          }
          await dao.deleteAllPresets();
          final row = (await dao.getSettings())!;
          expect(row.playbackPresets, '[]');
          expect(row.appearanceLooks, '[]');
          expect(row.selectedPlaybackPresetId, isNull);
          expect(row.selectedAppearanceLookId, isNull);
          expect(row.playbackSpeed, 1.25);
          expect(row.playbackPitchSemitones, 2);
          expect(row.colorVividness, 3);
          if (legacy) {
            final raw = await database
                .customSelect(
                  'SELECT color_tuning_presets, selected_color_tuning_preset_id FROM app_settings',
                )
                .getSingle();
            expect(raw.read<String>('color_tuning_presets'), '[]');
            expect(
              raw.readNullable<String>('selected_color_tuning_preset_id'),
              isNull,
            );
          }
        },
      );
    }

    test('color tuning writes both axes, watches, clamps and resets', () async {
      final dao = database.appSettingsDao;
      final initial = (await dao.getSettings())!;
      expect(initial.colorVividness, 0);
      expect(initial.surfaceDepthLight, 0);
      await dao.updateThemeMode('oled');
      for (final adj in [
        const ColorTuning(
          vividness: -5,
          lightDepth: 5,
          darkDepth: -3,
          lightTint: 3,
          darkTint: 5,
          controls: NavisControlColor.white,
        ),
        const ColorTuning(
          vividness: 50,
          lightDepth: -50,
          darkDepth: 50,
          lightTint: 50,
          darkTint: -50,
        ),
        ColorTuning.none,
      ]) {
        await dao.updateColorTuning(adj);
        final row = (await dao.getSettings())!;
        final watched = (await dao.watchSettings().first)!;
        expect(row.colorVividness, adj.vividness);
        expect(row.surfaceDepthLight, adj.lightDepth);
        expect(row.surfaceDepthDark, adj.darkDepth);
        expect(watched.colorVividness, adj.vividness);
        expect(watched.surfaceDepthLight, adj.lightDepth);
        expect(watched.surfaceDepthDark, adj.darkDepth);
        expect(row.surfaceTintLight, adj.lightTint);
        expect(row.surfaceTintDark, adj.darkTint);
        expect(row.controlColor, adj.controls.name);
        expect(watched.surfaceTintLight, adj.lightTint);
        expect(watched.surfaceTintDark, adj.darkTint);
        expect(watched.controlColor, adj.controls.name);
        expect(row.themeMode, 'oled');
      }
    }, skip: !sqliteAvailable);

    test(
      'corner style round trips, watches and resets independently',
      () async {
        final dao = database.appSettingsDao;
        final initial = (await dao.getSettings())!;
        expect(initial.cornerStyle, 'rounded');
        await dao.updateThemeMode('oled');
        await dao.updateNowPlayingBackground('artwork');
        for (final style in ['soft', 'square', 'rounded']) {
          await dao.updateCornerStyle(style);
          final row = (await dao.getSettings())!;
          expect(row.cornerStyle, style);
          expect((await dao.watchSettings().first)!.cornerStyle, style);
          expect(row.themeMode, 'oled');
          expect(row.nowPlayingBackground, 'artwork');
          expect(row.updatedAt.isBefore(initial.updatedAt), isFalse);
        }
        await dao.updateCornerStyle('unknown');
        expect((await dao.getSettings())!.cornerStyle, 'rounded');
      },
      skip: !sqliteAvailable,
    );

    test(
      'background and density round trip through targeted writers',
      () async {
        final dao = database.appSettingsDao;
        final initial = (await dao.getSettings())!;
        expect(initial.nowPlayingBackground, 'tinted');
        expect(initial.homeDensity, 'comfortable');
        for (final value in ['artwork', 'plain', 'tinted']) {
          await dao.updateNowPlayingBackground(value);
          final row = (await dao.getSettings())!;
          expect(row.nowPlayingBackground, value);
          expect(row.themeMode, initial.themeMode);
        }
        await dao.updateNowPlayingBackground('unknown');
        expect((await dao.getSettings())!.nowPlayingBackground, 'tinted');
        await dao.updateNowPlayingBackground('plain');
        expect((await dao.getSettings())!.nowPlayingBackground, 'plain');
        await dao.updateNowPlayingBackground('tinted');
        expect((await dao.getSettings())!.nowPlayingBackground, 'tinted');
        await dao.updateDensity(NavisDensity.compact);
        expect((await dao.getSettings())!.homeDensity, 'compact');
        await dao.updateDensity(NavisDensity.comfortable);
        expect((await dao.getSettings())!.homeDensity, 'comfortable');
      },
      skip: !sqliteAvailable,
    );

    test('background writes leave the legacy migration source alone', () async {
      await database.customStatement(
        'UPDATE app_settings SET art_tinted_now_playing = 0',
      );
      final dao = database.appSettingsDao;
      await dao.updateNowPlayingBackground('artwork');
      final legacy = await database
          .customSelect('SELECT art_tinted_now_playing FROM app_settings')
          .getSingle();
      expect(legacy.read<int>('art_tinted_now_playing'), 0);
      expect((await dao.getSettings())!.nowPlayingBackground, 'artwork');
    }, skip: !sqliteAvailable);

    test(
      'setup release writers round trip and preserve other settings',
      () async {
        final dao = database.appSettingsDao;
        final initial = (await dao.getSettings())!;
        expect(initial.setupHighlightsSeenRelease, isNull);
        expect(initial.setupCardDismissedRelease, isNull);
        await dao.updateSetupHighlightsSeenRelease('1.5.0');
        await dao.updateSetupCardDismissedRelease('1.5.0');
        var row = (await dao.getSettings())!;
        expect(row.setupHighlightsSeenRelease, '1.5.0');
        expect(row.setupCardDismissedRelease, '1.5.0');
        expect(row.colorStyle, initial.colorStyle);
        expect(row.onboardingVersion, initial.onboardingVersion);
        expect(row.updatedAt.isBefore(initial.updatedAt), isFalse);
        await dao.updateSetupHighlightsSeenRelease(null);
        row = (await dao.getSettings())!;
        expect(row.setupHighlightsSeenRelease, isNull);
        expect(row.setupCardDismissedRelease, '1.5.0');
      },
      skip: !sqliteAvailable,
    );

    test(
      'colour style defaults to neutral and updates independently',
      () async {
        final initial = (await database.appSettingsDao.getSettings())!;
        expect(initial.colorStyle, 'neutral');

        await database.appSettingsDao.updateThemeMode('oled');
        await database.appSettingsDao.updateColorStyle('pastel');

        final saved = (await database.appSettingsDao.getSettings())!;
        expect(saved.colorStyle, 'pastel');
        expect(saved.themeMode, 'oled');
        expect(saved.updatedAt.isBefore(initial.updatedAt), isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('shade writes preserve colour and unrelated settings', () async {
      final dao = database.appSettingsDao;
      final initial = (await dao.getSettings())!;
      expect(initial.albumArtShade, isFalse);
      await dao.updateThemeMode('oled');
      await dao.updateAlbumArtColoredShade(enabled: true);
      for (final enabled in [true, false]) {
        await dao.updateAlbumArtShade(enabled: enabled);
        final row = (await dao.watchSettings().first)!;
        expect(row.albumArtShade, enabled);
        expect(row.albumArtColoredShade, isTrue);
        expect(row.themeMode, 'oled');
        expect(row.updatedAt.isBefore(initial.updatedAt), isFalse);
      }
      await dao.updateAlbumArtShade(enabled: true);
      await dao.updateAlbumArtColoredShade(enabled: false);
      expect((await dao.getSettings())!.albumArtShade, isTrue);
    }, skip: !sqliteAvailable);

    test('Flat areas and shade targeted writes preserve the switch', () async {
      final dao = database.appSettingsDao;
      final initial = (await dao.getSettings())!;
      expect(initial.flatAreas, 7);
      expect(initial.albumArtColoredShade, isFalse);
      await dao.updateFlatSurfaces(enabled: true);
      for (var bits = 0; bits <= 7; bits++) {
        await dao.updateFlatAreas(bits);
        await dao.updateAlbumArtColoredShade(enabled: bits.isOdd);
        final saved = (await dao.watchSettings().first)!;
        expect(saved.flatAreas, bits);
        expect(saved.albumArtColoredShade, bits.isOdd);
        expect(saved.flatSurfaces, isTrue);
      }
      for (final bits in [-1, 8]) {
        await expectLater(dao.updateFlatAreas(bits), throwsRangeError);
      }
      expect((await dao.getSettings())!.flatAreas, 7);
    }, skip: !sqliteAvailable);

    test('appearance settings default and update independently', () async {
      final initial = (await database.appSettingsDao.getSettings())!;
      expect(initial.oledForAuto, isFalse);
      expect(initial.nightScheduleEnabled, isFalse);
      expect(initial.nightScheduleStartMinutes, 1320);
      expect(initial.nightScheduleEndMinutes, 420);
      expect(initial.flatSurfaces, isFalse);

      await database.appSettingsDao.updateColorStyle('pastel');
      await database.appSettingsDao.updateOledForAuto(enabled: true);
      await database.appSettingsDao.updateFlatSurfaces(enabled: true);
      await database.appSettingsDao.updateNightSchedule(enabled: true);
      var saved = (await database.appSettingsDao.getSettings())!;
      expect(saved.oledForAuto, isTrue);
      expect(saved.flatSurfaces, isTrue);
      expect(saved.nightScheduleEnabled, isTrue);
      expect(saved.nightScheduleStartMinutes, 1320);
      expect(saved.nightScheduleEndMinutes, 420);
      expect(saved.colorStyle, 'pastel');
      expect(saved.themeMode, initial.themeMode);
      expect(saved.updatedAt.isBefore(initial.updatedAt), isFalse);

      await database.appSettingsDao.updateNightSchedule(startMinutes: -10);
      saved = (await database.appSettingsDao.getSettings())!;
      expect(saved.nightScheduleStartMinutes, 0);
      expect(saved.nightScheduleEndMinutes, 420);
      expect(saved.nightScheduleEnabled, isTrue);
      await database.appSettingsDao.updateNightSchedule(endMinutes: 1500);
      saved = (await database.appSettingsDao.getSettings())!;
      expect(saved.nightScheduleStartMinutes, 0);
      expect(saved.nightScheduleEndMinutes, 1439);
      await database.appSettingsDao.updateNightSchedule(
        enabled: false,
        startMinutes: 1500,
        endMinutes: -10,
      );
      saved = (await database.appSettingsDao.getSettings())!;
      expect(saved.nightScheduleEnabled, isFalse);
      expect(saved.nightScheduleStartMinutes, 1439);
      expect(saved.nightScheduleEndMinutes, 0);
      expect(saved.oledForAuto, isTrue);
      expect(saved.flatSurfaces, isTrue);
    }, skip: !sqliteAvailable);

    test('saveSettings writes and overwrites single-row settings', () async {
      await database.appSettingsDao.updateNowPlayingBackground('plain');
      await database.appSettingsDao.updateOledForAuto(enabled: true);
      await database.appSettingsDao.updateFlatSurfaces(enabled: true);
      await database.appSettingsDao.updateNightSchedule(
        enabled: true,
        startMinutes: 1200,
        endMinutes: 480,
      );
      await database.appSettingsDao.saveSettings(
        wifiMaxBitRate: 320,
        wifiFormat: 'opus',
        cellularMaxBitRate: 128,
        cellularFormat: 'aac',
        cachedPlaybackFirst: true,
        scrobbleEnabled: false,
        gaplessEnabled: false,
        skipSilenceEnabled: true,
        showAlbumsPage: false,
        showRadioPage: false,
        showPlaylistsPage: true,
        showArtistsPage: true,
        showLikedPage: true,

        wifiOnlyDownloads: false,
        autoDownloadStarredOnWifi: false,
        customDownloadFolderEnabled: false,
        customDownloadFolderPath: null,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        updateCheckEnabled: true,
        updateChannel: 'stable',
        syncIntervalMinutes: 60,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
      );

      final first = await database.appSettingsDao.getSettings();
      expect(first, isNotNull);
      expect(first!.id, AppSettingsDao.primarySettingsId);
      expect(first.wifiMaxBitRate, 320);
      expect(first.nowPlayingBackground, 'plain');
      expect(first.wifiFormat, 'opus');
      expect(first.cellularMaxBitRate, 128);
      expect(first.cellularFormat, 'aac');
      expect(first.cachedPlaybackFirst, isTrue);
      expect(first.oledForAuto, isTrue);
      expect(first.nightScheduleEnabled, isTrue);
      expect(first.nightScheduleStartMinutes, 1200);
      expect(first.nightScheduleEndMinutes, 480);
      expect(first.flatSurfaces, isTrue);
      expect(first.scrobbleEnabled, isFalse);
      expect(first.gaplessEnabled, isFalse);
      expect(first.skipSilenceEnabled, isTrue);
      expect(first.showAlbumsPage, isFalse);
      expect(first.showRadioPage, isFalse);

      expect(first.customDownloadFolderEnabled, isFalse);
      expect(first.customDownloadFolderPath, isNull);

      await database.appSettingsDao.updateOledForAuto(enabled: false);
      await database.appSettingsDao.updateFlatSurfaces(enabled: false);
      await database.appSettingsDao.updateNightSchedule(
        enabled: false,
        startMinutes: 1320,
        endMinutes: 420,
      );
      await database.appSettingsDao.saveSettings(
        wifiMaxBitRate: null,
        wifiFormat: null,
        cellularMaxBitRate: 192,
        cellularFormat: 'mp3',
        cachedPlaybackFirst: false,
        scrobbleEnabled: true,
        gaplessEnabled: true,
        skipSilenceEnabled: false,
        showAlbumsPage: true,
        showRadioPage: true,
        showPlaylistsPage: true,
        showArtistsPage: true,
        showLikedPage: true,

        wifiOnlyDownloads: false,
        autoDownloadStarredOnWifi: false,
        customDownloadFolderEnabled: false,
        customDownloadFolderPath: null,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        updateCheckEnabled: false,
        updateChannel: 'beta',
        syncIntervalMinutes: 60,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
      );

      final second = await database.appSettingsDao.getSettings();
      expect(second, isNotNull);
      expect(second!.id, AppSettingsDao.primarySettingsId);
      expect(second.wifiMaxBitRate, isNull);
      expect(second.wifiFormat, isNull);
      expect(second.cellularMaxBitRate, 192);
      expect(second.cellularFormat, 'mp3');
      expect(second.cachedPlaybackFirst, isFalse);
      expect(second.oledForAuto, isFalse);
      expect(second.nightScheduleEnabled, isFalse);
      expect(second.nightScheduleStartMinutes, 1320);
      expect(second.nightScheduleEndMinutes, 420);
      expect(second.flatSurfaces, isFalse);
      expect(second.scrobbleEnabled, isTrue);
      expect(second.gaplessEnabled, isTrue);
      expect(second.skipSilenceEnabled, isFalse);
      expect(second.showAlbumsPage, isTrue);
      expect(second.showRadioPage, isTrue);

      expect(second.customDownloadFolderEnabled, isFalse);
      expect(second.customDownloadFolderPath, isNull);
    }, skip: !sqliteAvailable);

    test(
      'playback reset restores playback fields and leaves the rest alone',
      () async {
        final dao = database.appSettingsDao;
        await dao.saveSettings(
          wifiMaxBitRate: 320,
          wifiFormat: 'opus',
          cellularMaxBitRate: 96,
          cellularFormat: 'aac',
          cachedPlaybackFirst: true,
          scrobbleEnabled: false,
          gaplessEnabled: false,
          skipSilenceEnabled: true,
          showAlbumsPage: false,
          showRadioPage: false,
          showPlaylistsPage: true,
          showArtistsPage: true,
          showLikedPage: true,

          wifiOnlyDownloads: false,
          autoDownloadStarredOnWifi: true,
          customDownloadFolderEnabled: true,
          customDownloadFolderPath: '/music/downloads',
          crossfadeEnabled: true,
          crossfadeDurationSeconds: 9,
          crossfadeType: 'smart',
          updateCheckEnabled: false,
          updateChannel: 'beta',
          syncIntervalMinutes: 15,
          useLrclib: false,
          legacyInstantMixEnabled: true,
          replayGainMode: 'track',
          replayGainPreamp: -4.5,
          playbackSpeed: 1,
          albumQueueEnabled: false,
          matchFlowEnabled: true,
          likedQueueEnabled: false,
        );
        await dao.updateThemeMode('light');
        await dao.updateColorStyle('night');
        await dao.updateOledForAuto(enabled: true);
        await dao.updateNightSchedule(
          enabled: true,
          startMinutes: 1200,
          endMinutes: 480,
        );
        await dao.updateFlatSurfaces(enabled: true);
        await dao.updateColorTuning(const ColorTuning(vividness: 3));
        await dao.updateNowPlayingBackground('plain');
        await dao.updateDynamicAlbumColorEnabled(enabled: true);
        await dao.updateCoverArtShape('rounded');
        await dao.updateNowPlayingArtShape('rounded');
        await dao.updateArtistCardShape('circle');
        await dao.updateArtistViewMode('list');
        await dao.updateDensity(NavisDensity.compact);
        await dao.updateAppearanceLooks(
          selectedLookId: 'look',
          looksJson: '[{"id":"look"}]',
        );
        await dao.updateLastFmApiKey('fixture-key');
        await dao.updateListenBrainzScrobblingState(
          enabled: true,
          tokenValid: true,
          userName: 'listener',
        );
        await dao.updateSetupHighlightsSeenRelease('1.5.0');
        await dao.markSetupHighlightSeen('wifi');
        await dao.updatePlaybackAdjustments(
          speed: 1.5,
          pitchSemitones: 3,
          lockPitchToSpeed: true,
          selectedPresetId: 'club',
          presetsJson: '[{"id":"club","name":"Club"}]',
        );

        await dao.resetPlaybackDefaults();

        final settings = (await dao.getSettings())!;
        // Fields shown on the Playback page are back to their defaults.
        expect(settings.wifiMaxBitRate, isNull);
        expect(settings.wifiFormat, isNull);
        expect(
          settings.cellularMaxBitRate,
          AppSettingsDao.defaultCellularBitRate,
        );
        expect(settings.cellularFormat, AppSettingsDao.defaultCellularFormat);
        expect(settings.cachedPlaybackFirst, isFalse);
        expect(settings.scrobbleEnabled, isTrue);
        expect(settings.gaplessEnabled, isTrue);
        expect(settings.crossfadeEnabled, isFalse);
        expect(settings.crossfadeDurationSeconds, 5);
        expect(settings.crossfadeType, 'normal');
        expect(settings.replayGainMode, 'off');
        expect(settings.replayGainPreamp, 0);
        expect(settings.albumQueueEnabled, isTrue);
        expect(settings.likedQueueEnabled, isTrue);
        expect(settings.matchFlowEnabled, isFalse);
        expect(settings.playbackSpeed, 1);
        expect(settings.playbackPitchSemitones, 0);
        expect(settings.lockPitchToSpeed, isFalse);
        expect(settings.selectedPlaybackPresetId, 'none');
        // Saved playback presets survive the reset.
        expect(settings.playbackPresets, '[{"id":"club","name":"Club"}]');
        // Fullscreen Mode Lyrics is a Playback page switch (stored in the
        // compatibility column), so it resets too.
        expect(settings.skipSilenceEnabled, isFalse);
        // Everything the Playback page does not show is untouched.
        expect(settings.themeMode, 'light');
        expect(settings.colorStyle, 'night');
        expect(settings.colorVividness, 3);
        expect(settings.selectedAppearanceLookId, 'look');
        expect(settings.appearanceLooks, '[{"id":"look"}]');
        expect(settings.wifiOnlyDownloads, isFalse);
        expect(settings.autoDownloadStarredOnWifi, isTrue);
        expect(settings.customDownloadFolderEnabled, isTrue);
        expect(settings.customDownloadFolderPath, '/music/downloads');
        expect(settings.lastFmApiKey, 'fixture-key');
        expect(settings.listenBrainzScrobblingEnabled, isTrue);
        expect(settings.listenBrainzTokenValid, isTrue);
        expect(settings.listenBrainzUserName, 'listener');
        expect(settings.setupHighlightsSeenRelease, '1.5.0');
        expect(settings.setupHighlightsSeen, contains('wifi'));
        expect(settings.updateChannel, 'beta');
        expect(settings.homeDensity, 'compact');
      },
      skip: !sqliteAvailable,
    );

    test('download preferences are written by targeted updates', () async {
      final dao = database.appSettingsDao;
      expect(
        await dao.getDownloadQualityPreference(),
        const DownloadQualityPreference(),
      );

      await dao.updateDownloadQuality(
        mode: DownloadQualityMode.transcode,
        bitRate: 192,
        format: 'opus',
      );
      await dao.updateDownloadQualityPrompted(prompted: true);
      await dao.updateMaxConcurrentDownloads(9);
      await dao.updateDownloadsPaused(paused: true);

      final preference = await dao.getDownloadQualityPreference();
      expect(preference.mode, DownloadQualityMode.transcode);
      expect(preference.bitRate, 192);
      expect(preference.format, 'opus');
      expect(preference.prompted, isTrue);
      expect(await dao.getMaxConcurrentDownloads(), kMaxConcurrentDownloads);
      expect(await dao.getDownloadsPaused(), isTrue);

      // Choosing Original keeps the transcode format for the picker.
      await dao.updateDownloadQuality(mode: DownloadQualityMode.original);
      expect((await dao.getDownloadQualityPreference()).format, 'opus');
      await dao.updateDownloadFormat('aac');
      expect((await dao.getDownloadQualityPreference()).format, 'aac');
    });

    test('playback reset leaves the download preferences alone', () async {
      final dao = database.appSettingsDao;
      await dao.updateDownloadQuality(mode: DownloadQualityMode.original);
      await dao.updateDownloadQualityPrompted(prompted: true);
      await dao.updateMaxConcurrentDownloads(3);

      await dao.resetPlaybackDefaults();

      final preference = await dao.getDownloadQualityPreference();
      expect(preference.mode, DownloadQualityMode.original);
      expect(preference.prompted, isTrue);
      expect(await dao.getMaxConcurrentDownloads(), 3);
    });

    test('download preference watchers emit changes', () async {
      final dao = database.appSettingsDao;
      final modes = dao
          .watchDownloadQualityPreference()
          .map((p) => p.mode)
          .take(2)
          .toList();
      final paused = dao.watchDownloadsPaused().take(2).toList();
      await pumpEventQueue();
      await dao.updateDownloadQuality(mode: DownloadQualityMode.original);
      await dao.updateDownloadsPaused(paused: true);
      expect(await modes, <DownloadQualityMode>[
        DownloadQualityMode.ask,
        DownloadQualityMode.original,
      ]);
      expect(await paused, <bool>[false, true]);
    });

    group('integration policy', () {
      Future<void> saveFullRow({
        bool useLrclib = true,
        bool updateCheckEnabled = true,
        bool legacyInstantMixEnabled = false,
        bool listenBrainzScrobblingEnabled = false,
      }) => database.appSettingsDao.saveSettings(
        cachedPlaybackFirst: false,
        scrobbleEnabled: true,
        gaplessEnabled: true,
        skipSilenceEnabled: false,
        showAlbumsPage: true,
        showRadioPage: true,
        showPlaylistsPage: true,
        showArtistsPage: true,
        showLikedPage: true,
        wifiOnlyDownloads: false,
        autoDownloadStarredOnWifi: false,
        customDownloadFolderEnabled: false,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        updateCheckEnabled: updateCheckEnabled,
        updateChannel: 'stable',
        syncIntervalMinutes: 60,
        useLrclib: useLrclib,
        legacyInstantMixEnabled: legacyInstantMixEnabled,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        listenBrainzScrobblingEnabled: listenBrainzScrobblingEnabled,
      );

      test('defaults: master on, nothing disabled, notice pending', () async {
        final settings = (await database.appSettingsDao.getSettings())!;
        expect(settings.externalIntegrationsEnabled, isTrue);
        expect(settings.disabledIntegrations, '[]');
        expect(settings.integrationsNoticeDismissed, isFalse);
      });

      test('updateIntegrationPolicy writes only the given columns', () async {
        final dao = database.appSettingsDao;
        await dao.updateIntegrationPolicy(master: false);
        var settings = (await dao.getSettings())!;
        expect(settings.externalIntegrationsEnabled, isFalse);
        expect(settings.disabledIntegrations, '[]');

        await dao.updateIntegrationPolicy(disabledJson: '["deezer"]');
        settings = (await dao.getSettings())!;
        expect(settings.externalIntegrationsEnabled, isFalse);
        expect(settings.disabledIntegrations, '["deezer"]');

        await dao.setExternalIntegrationsEnabled(enabled: true);
        expect((await dao.getSettings())!.externalIntegrationsEnabled, isTrue);
        expect((await dao.getSettings())!.disabledIntegrations, '["deezer"]');
      });

      test('notice dismissal is a targeted write', () async {
        final dao = database.appSettingsDao;
        await dao.updateIntegrationsNoticeDismissed(dismissed: true);
        expect((await dao.getSettings())!.integrationsNoticeDismissed, isTrue);
        await dao.updateIntegrationsNoticeDismissed(dismissed: false);
        expect((await dao.getSettings())!.integrationsNoticeDismissed, isFalse);
      });

      test(
        'updateLegacyInstantMixEnabled writes the column as given',
        () async {
          final dao = database.appSettingsDao;
          await dao.updateLegacyInstantMixEnabled(enabled: true);
          expect((await dao.getSettings())!.legacyInstantMixEnabled, isTrue);
          await dao.updateLegacyInstantMixEnabled(enabled: false);
          expect((await dao.getSettings())!.legacyInstantMixEnabled, isFalse);
        },
      );

      test('setIntegrationEnabled writes each column-backed feature', () async {
        final dao = database.appSettingsDao;
        await dao.setIntegrationEnabled('lrclib.lyrics', enabled: false);
        await dao.setIntegrationEnabled('updates.automatic', enabled: false);
        await dao.setIntegrationEnabled(
          'listenbrainz.scrobbling',
          enabled: true,
        );
        // Same Vibes off is stored as legacyInstantMixEnabled = true.
        await dao.setIntegrationEnabled('lastfm.sameVibes', enabled: false);
        var settings = (await dao.getSettings())!;
        expect(settings.useLrclib, isFalse);
        expect(settings.updateCheckEnabled, isFalse);
        expect(settings.listenBrainzScrobblingEnabled, isTrue);
        expect(settings.legacyInstantMixEnabled, isTrue);
        // None of them touch the JSON set.
        expect(settings.disabledIntegrations, '[]');

        await dao.setIntegrationEnabled('lastfm.sameVibes', enabled: true);
        await dao.setIntegrationEnabled('lrclib.lyrics', enabled: true);
        settings = (await dao.getSettings())!;
        expect(settings.legacyInstantMixEnabled, isFalse);
        expect(settings.useLrclib, isTrue);
      });

      test('setIntegrationEnabled edits the JSON set for other keys', () async {
        final dao = database.appSettingsDao;
        await dao.setIntegrationEnabled('deezer.topSongs', enabled: false);
        await dao.setIntegrationEnabled('autoeq', enabled: false);
        await dao.setIntegrationEnabled('deezer.topSongs', enabled: false);
        expect(
          (await dao.getSettings())!.disabledIntegrations,
          '["autoeq","deezer.topSongs"]',
        );
        await dao.setIntegrationEnabled('deezer.topSongs', enabled: true);
        expect((await dao.getSettings())!.disabledIntegrations, '["autoeq"]');
        // Re-enabling something that is not disabled changes nothing.
        await dao.setIntegrationEnabled('radio.nowPlaying', enabled: true);
        expect((await dao.getSettings())!.disabledIntegrations, '["autoeq"]');
      });

      test('concurrent toggles do not lose each other', () async {
        final dao = database.appSettingsDao;
        await Future.wait([
          dao.setIntegrationEnabled('deezer.topSongs', enabled: false),
          dao.setIntegrationEnabled('deezer.trending', enabled: false),
          dao.setIntegrationEnabled('radio', enabled: false),
        ]);
        expect(
          parseDisabledIntegrationKeys(
            (await dao.getSettings())!.disabledIntegrations,
          ),
          <String>{'deezer.topSongs', 'deezer.trending', 'radio'},
        );
      });

      test('setIntegrationEnabled rejects unknown keys', () async {
        final dao = database.appSettingsDao;
        expect(
          () => dao.setIntegrationEnabled('deezer.nope', enabled: false),
          throwsArgumentError,
        );
        expect((await dao.getSettings())!.disabledIntegrations, '[]');
      });

      test('a full-row save leaves the policy columns alone', () async {
        final dao = database.appSettingsDao;
        await dao.updateIntegrationPolicy(
          master: false,
          disabledJson: '["deezer"]',
        );
        await dao.updateIntegrationsNoticeDismissed(dismissed: true);

        await saveFullRow(useLrclib: false, legacyInstantMixEnabled: true);

        final settings = (await dao.getSettings())!;
        expect(settings.externalIntegrationsEnabled, isFalse);
        expect(settings.disabledIntegrations, '["deezer"]');
        expect(settings.integrationsNoticeDismissed, isTrue);
        // The column-backed switches are still part of the full-row save.
        expect(settings.useLrclib, isFalse);
        expect(settings.legacyInstantMixEnabled, isTrue);
      });
    });
  });
}
