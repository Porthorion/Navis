import 'package:flutter_test/flutter_test.dart';
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
        themeMode: 'dark',
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        artTintedNowPlaying: false,
        dynamicAlbumColorEnabled: false,
        updateCheckEnabled: updateCheckEnabled,
        updateChannel: 'stable',
        audioMuseEnabled: false,
        syncIntervalMinutes: 60,
        useLrclib: useLrclib,
        legacyInstantMixEnabled: legacyInstantMixEnabled,
        replayGainMode: 'off',
        replayGainPreamp: 0,
        coverArtShape: 'rounded',
        nowPlayingArtShape: 'rounded',
        artistCardShape: 'circle',
        artistViewMode: 'grid',
        homeDensity: 'comfortable',
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

      test('resetDefaults resets the policy but not the notice', () async {
        final dao = database.appSettingsDao;
        await dao.updateIntegrationPolicy(
          master: false,
          disabledJson: '["deezer","radio"]',
        );
        await dao.updateIntegrationsNoticeDismissed(dismissed: true);
        await saveFullRow(useLrclib: false, updateCheckEnabled: false);

        await dao.resetDefaults();

        final settings = (await dao.getSettings())!;
        expect(settings.externalIntegrationsEnabled, isTrue);
        expect(settings.disabledIntegrations, '[]');
        expect(settings.useLrclib, isTrue);
        expect(settings.updateCheckEnabled, isTrue);
        expect(settings.legacyInstantMixEnabled, isFalse);
        expect(settings.integrationsNoticeDismissed, isTrue);
      });
    });
  });
}
