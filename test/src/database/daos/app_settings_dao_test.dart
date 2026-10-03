import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';

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

    test('saveSettings writes and overwrites single-row settings', () async {
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
        themeMode: 'dark',
        colorSchemeSeed: null,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        artTintedNowPlaying: false,
        dynamicAlbumColorEnabled: false,
        updateCheckEnabled: true,
        updateChannel: 'stable',
        audioMuseEnabled: false,
        syncIntervalMinutes: 60,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
        coverArtShape: 'rounded',
        nowPlayingArtShape: 'rounded',
        artistCardShape: 'circle',
        artistViewMode: 'grid',
        homeDensity: 'comfortable',
      );

      final first = await database.appSettingsDao.getSettings();
      expect(first, isNotNull);
      expect(first!.id, AppSettingsDao.primarySettingsId);
      expect(first.wifiMaxBitRate, 320);
      expect(first.wifiFormat, 'opus');
      expect(first.cellularMaxBitRate, 128);
      expect(first.cellularFormat, 'aac');
      expect(first.cachedPlaybackFirst, isTrue);
      expect(first.scrobbleEnabled, isFalse);
      expect(first.gaplessEnabled, isFalse);
      expect(first.skipSilenceEnabled, isTrue);
      expect(first.showAlbumsPage, isFalse);
      expect(first.showRadioPage, isFalse);

      expect(first.customDownloadFolderEnabled, isFalse);
      expect(first.customDownloadFolderPath, isNull);

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
        themeMode: 'dark',
        colorSchemeSeed: null,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        artTintedNowPlaying: false,
        dynamicAlbumColorEnabled: false,
        updateCheckEnabled: false,
        updateChannel: 'beta',
        audioMuseEnabled: false,
        syncIntervalMinutes: 60,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
        coverArtShape: 'rounded',
        nowPlayingArtShape: 'rounded',
        artistCardShape: 'circle',
        artistViewMode: 'grid',
        homeDensity: 'compact',
      );

      final second = await database.appSettingsDao.getSettings();
      expect(second, isNotNull);
      expect(second!.id, AppSettingsDao.primarySettingsId);
      expect(second.wifiMaxBitRate, isNull);
      expect(second.wifiFormat, isNull);
      expect(second.cellularMaxBitRate, 192);
      expect(second.cellularFormat, 'mp3');
      expect(second.cachedPlaybackFirst, isFalse);
      expect(second.scrobbleEnabled, isTrue);
      expect(second.gaplessEnabled, isTrue);
      expect(second.skipSilenceEnabled, isFalse);
      expect(second.showAlbumsPage, isTrue);
      expect(second.showRadioPage, isTrue);

      expect(second.customDownloadFolderEnabled, isFalse);
      expect(second.customDownloadFolderPath, isNull);
    }, skip: !sqliteAvailable);

    test('resetDefaults restores app defaults', () async {
      await database.appSettingsDao.saveSettings(
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

        wifiOnlyDownloads: true,
        autoDownloadStarredOnWifi: false,
        customDownloadFolderEnabled: false,
        customDownloadFolderPath: null,
        themeMode: 'oled',
        colorSchemeSeed: 4283215696,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        artTintedNowPlaying: false,
        dynamicAlbumColorEnabled: false,
        updateCheckEnabled: false,
        updateChannel: 'beta',
        audioMuseEnabled: false,
        syncIntervalMinutes: 60,
        useLrclib: true,
        legacyInstantMixEnabled: false,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
        coverArtShape: 'rounded',
        nowPlayingArtShape: 'rounded',
        artistCardShape: 'circle',
        artistViewMode: 'grid',
        homeDensity: 'compact',
      );
      await database.appSettingsDao.saveGroupListeningSettings(
        groupListeningEnabled: true,
        voyageServerUrl: 'https://voyage.example.com',
        voyageDisplayName: 'Alice',
        voyageDeviceLabel: 'Kitchen Speaker',
        voyageAutoFollowHost: false,
      );

      await database.appSettingsDao.resetDefaults();

      final settings = await database.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.wifiMaxBitRate, isNull);
      expect(settings.wifiFormat, isNull);
      expect(
        settings.cellularMaxBitRate,
        AppSettingsDao.defaultCellularBitRate,
      );
      expect(settings.cellularFormat, AppSettingsDao.defaultCellularFormat);
      expect(settings.cachedPlaybackFirst, isFalse);
      expect(settings.scrobbleEnabled, isTrue);
      expect(settings.gaplessEnabled, isTrue);
      expect(settings.skipSilenceEnabled, isFalse);
      expect(settings.showAlbumsPage, isTrue);
      expect(settings.showRadioPage, isTrue);

      expect(settings.customDownloadFolderEnabled, isFalse);
      expect(settings.customDownloadFolderPath, isNull);
      expect(settings.dynamicAlbumColorEnabled, isFalse);
      expect(settings.homeDensity, 'comfortable');
      final groupListening = await database.appSettingsDao
          .getGroupListeningSettings();
      expect(groupListening.groupListeningEnabled, isFalse);
      expect(groupListening.voyageServerUrl, isNull);
      expect(groupListening.voyageDisplayName, isNull);
      expect(groupListening.voyageDeviceLabel, isNull);
      expect(
        groupListening.voyageAutoFollowHost,
        AppSettingsDao.defaultVoyageAutoFollowHost,
      );
    }, skip: !sqliteAvailable);

    test(
      'group listening settings persist outside the typed Drift model',
      () async {
        await database.appSettingsDao.saveGroupListeningSettings(
          groupListeningEnabled: true,
          voyageServerUrl: 'https://voyage.example.com',
          voyageDisplayName: 'Alice',
          voyageDeviceLabel: 'Office Desktop',
          voyageAutoFollowHost: false,
        );

        final settings = await database.appSettingsDao
            .getGroupListeningSettings();

        expect(settings.groupListeningEnabled, isTrue);
        expect(settings.voyageServerUrl, 'https://voyage.example.com');
        expect(settings.voyageDisplayName, 'Alice');
        expect(settings.voyageDeviceLabel, 'Office Desktop');
        expect(settings.voyageAutoFollowHost, isFalse);
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

    test('settings resets leave the download preferences alone', () async {
      final dao = database.appSettingsDao;
      await dao.updateDownloadQuality(mode: DownloadQualityMode.original);
      await dao.updateDownloadQualityPrompted(prompted: true);
      await dao.updateMaxConcurrentDownloads(3);

      await dao.resetDefaults();

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
  });
}
