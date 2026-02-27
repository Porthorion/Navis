import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import '../../../helpers/test_database.dart';

void main() {
  group('AppSettingsDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'saveSettings writes and overwrites single-row settings',
      () async {
        await database.appSettingsDao.saveSettings(
          wifiMaxBitRate: 320,
          wifiFormat: 'opus',
          cellularMaxBitRate: 128,
          cellularFormat: 'aac',
          scrobbleEnabled: false,
          gaplessEnabled: false,
          skipSilenceEnabled: true,
          showRadioPage: false,
          showPlaylistsPage: true,
          showArtistsPage: true,
          equalizerEnabled: true,
          equalizerBandGains: '[1,2,3,4,5]',
          loudnessEnabled: true,
          loudnessTargetGainDb: 8,
          wifiOnlyDownloads: false,
          themeMode: 'dark',
          colorSchemeSeed: null,
          crossfadeEnabled: false,
          crossfadeDurationSeconds: 5,
          crossfadeType: 'normal',
          artTintedNowPlaying: false,
          updateCheckEnabled: true,
          updateChannel: 'stable',
          audioMuseEnabled: false,
          syncIntervalMinutes: 60,
        );

        final first = await database.appSettingsDao.getSettings();
        expect(first, isNotNull);
        expect(first!.id, AppSettingsDao.primarySettingsId);
        expect(first.wifiMaxBitRate, 320);
        expect(first.wifiFormat, 'opus');
        expect(first.cellularMaxBitRate, 128);
        expect(first.cellularFormat, 'aac');
        expect(first.scrobbleEnabled, isFalse);
        expect(first.gaplessEnabled, isFalse);
        expect(first.skipSilenceEnabled, isTrue);
        expect(first.showRadioPage, isFalse);
        expect(first.equalizerEnabled, isTrue);
        expect(first.equalizerBandGains, '[1,2,3,4,5]');
        expect(first.loudnessEnabled, isTrue);
        expect(first.loudnessTargetGainDb, 8);

        await database.appSettingsDao.saveSettings(
          wifiMaxBitRate: null,
          wifiFormat: null,
          cellularMaxBitRate: 192,
          cellularFormat: 'mp3',
          scrobbleEnabled: true,
          gaplessEnabled: true,
          skipSilenceEnabled: false,
          showRadioPage: true,
          showPlaylistsPage: true,
          showArtistsPage: true,
          equalizerEnabled: false,
          equalizerBandGains: null,
          loudnessEnabled: false,
          loudnessTargetGainDb: 0,
          wifiOnlyDownloads: false,
          themeMode: 'dark',
          colorSchemeSeed: null,
          crossfadeEnabled: false,
          crossfadeDurationSeconds: 5,
          crossfadeType: 'normal',
          artTintedNowPlaying: false,
          updateCheckEnabled: false,
          updateChannel: 'beta',
          audioMuseEnabled: false,
          syncIntervalMinutes: 60,
        );

        final second = await database.appSettingsDao.getSettings();
        expect(second, isNotNull);
        expect(second!.id, AppSettingsDao.primarySettingsId);
        expect(second.wifiMaxBitRate, isNull);
        expect(second.wifiFormat, isNull);
        expect(second.cellularMaxBitRate, 192);
        expect(second.cellularFormat, 'mp3');
        expect(second.scrobbleEnabled, isTrue);
        expect(second.gaplessEnabled, isTrue);
        expect(second.skipSilenceEnabled, isFalse);
        expect(second.showRadioPage, isTrue);
        expect(second.equalizerEnabled, isFalse);
        expect(second.equalizerBandGains, isNull);
        expect(second.loudnessEnabled, isFalse);
        expect(second.loudnessTargetGainDb, 0);
      },
      skip: !sqliteAvailable,
    );

    test('resetDefaults restores app defaults', () async {
      await database.appSettingsDao.saveSettings(
        wifiMaxBitRate: 320,
        wifiFormat: 'opus',
        cellularMaxBitRate: 96,
        cellularFormat: 'aac',
        scrobbleEnabled: false,
        gaplessEnabled: false,
        skipSilenceEnabled: true,
        showRadioPage: false,
        showPlaylistsPage: true,
        showArtistsPage: true,
        equalizerEnabled: true,
        equalizerBandGains: '[3,2,1]',
        loudnessEnabled: true,
        loudnessTargetGainDb: 6,
        wifiOnlyDownloads: true,
        themeMode: 'oled',
        colorSchemeSeed: 4283215696,
        crossfadeEnabled: false,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        artTintedNowPlaying: false,
        updateCheckEnabled: false,
        updateChannel: 'beta',
        audioMuseEnabled: false,
        syncIntervalMinutes: 60,
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
      expect(settings.scrobbleEnabled, isTrue);
      expect(settings.gaplessEnabled, isTrue);
      expect(settings.skipSilenceEnabled, isFalse);
      expect(settings.showRadioPage, isTrue);
      expect(settings.equalizerEnabled, isFalse);
      expect(settings.equalizerBandGains, isNull);
      expect(settings.loudnessEnabled, isFalse);
      expect(settings.loudnessTargetGainDb, 0);
    }, skip: !sqliteAvailable);
  });
}
