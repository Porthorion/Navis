import 'dart:convert';

import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

class SettingsRepository {
  SettingsRepository(this._dao);

  final AppSettingsDao _dao;

  Stream<AppSettingsModel> watchSettings() {
    return _dao.watchSettings().map(_mapOrDefault);
  }

  Future<AppSettingsModel> getSettings() async {
    final row = await _dao.getSettings();
    return _mapOrDefault(row);
  }

  Future<void> saveSettings(AppSettingsModel settings) {
    // skipSilenceEnabled is persisted for compatibility with older schema
    // versions but is currently not applied at runtime playback level.
    return _dao.saveSettings(
      wifiMaxBitRate: settings.wifiMaxBitRate,
      wifiFormat: settings.wifiFormat,
      cellularMaxBitRate: settings.cellularMaxBitRate,
      cellularFormat: settings.cellularFormat,
      scrobbleEnabled: settings.scrobbleEnabled,
      gaplessEnabled: settings.gaplessEnabled,
      skipSilenceEnabled: settings.skipSilenceEnabled,
      showRadioPage: settings.showRadioPage,
      showPlaylistsPage: settings.showPlaylistsPage,
      showArtistsPage: settings.showArtistsPage,
      showLikedPage: settings.showLikedPage,
      equalizerEnabled: settings.equalizerEnabled,
      equalizerBandGains: _encodeBandGains(settings.equalizerBandGains),
      loudnessEnabled: settings.loudnessEnabled,
      loudnessTargetGainDb: settings.loudnessTargetGainDb,
      wifiOnlyDownloads: settings.wifiOnlyDownloads,
      autoDownloadStarredOnWifi: settings.autoDownloadStarredOnWifi,
      themeMode: settings.themeMode,
      colorSchemeSeed: settings.colorSchemeSeed,
      appLocale: settings.appLocale,
      crossfadeEnabled: settings.crossfadeEnabled,
      crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
      crossfadeType: settings.crossfadeType,
      artTintedNowPlaying: settings.artTintedNowPlaying,
      dynamicAlbumColorEnabled: settings.dynamicAlbumColorEnabled,
      updateCheckEnabled: settings.updateCheckEnabled,
      updateChannel: settings.updateChannel,
      audioMuseServerUrl: settings.audioMuseServerUrl,
      audioMuseApiKey: settings.audioMuseApiKey,
      audioMuseEnabled: settings.audioMuseEnabled,
      syncIntervalMinutes: settings.syncIntervalMinutes,
      useLrclib: settings.useLrclib,
      legacyInstantMixEnabled: settings.legacyInstantMixEnabled,
      replayGainMode: settings.replayGainMode,
      replayGainPreamp: settings.replayGainPreamp,
      playbackSpeed: settings.playbackSpeed,
      albumGridDensity: settings.albumGridDensity,
      coverArtShape: settings.coverArtShape,
      nowPlayingArtShape: settings.nowPlayingArtShape,
      artistCardShape: settings.artistCardShape,
      artistViewMode: settings.artistViewMode,
      homeDensity: settings.homeDensity,
      homeSectionOrder: _encodeStringList(settings.homeSectionOrder),
      homeSectionsHidden: _encodeStringList(settings.homeSectionsHidden),
    );
  }

  Future<void> resetDefaults() => _dao.resetDefaults();

  AppSettingsModel _mapOrDefault(AppSettingsTableData? row) {
    if (row == null) {
      return const AppSettingsModel.defaults();
    }
    return AppSettingsModel(
      wifiMaxBitRate: row.wifiMaxBitRate,
      wifiFormat: row.wifiFormat,
      cellularMaxBitRate: row.cellularMaxBitRate,
      cellularFormat: row.cellularFormat,
      scrobbleEnabled: row.scrobbleEnabled,
      gaplessEnabled: row.gaplessEnabled,
      skipSilenceEnabled: row.skipSilenceEnabled,
      showRadioPage: row.showRadioPage,
      showPlaylistsPage: row.showPlaylistsPage,
      showArtistsPage: row.showArtistsPage,
      showLikedPage: row.showLikedPage,
      equalizerEnabled: row.equalizerEnabled,
      equalizerBandGains: _decodeBandGains(row.equalizerBandGains),
      loudnessEnabled: row.loudnessEnabled,
      loudnessTargetGainDb: row.loudnessTargetGainDb ?? 0,
      wifiOnlyDownloads: row.wifiOnlyDownloads,
      autoDownloadStarredOnWifi: row.autoDownloadStarredOnWifi,
      themeMode: row.themeMode,
      colorSchemeSeed: row.colorSchemeSeed,
      appLocale: row.appLocale,
      crossfadeEnabled: row.crossfadeEnabled,
      crossfadeDurationSeconds: row.crossfadeDurationSeconds,
      crossfadeType: row.crossfadeType,
      artTintedNowPlaying: row.artTintedNowPlaying,
      dynamicAlbumColorEnabled: row.dynamicAlbumColorEnabled,
      updateCheckEnabled: row.updateCheckEnabled,
      updateChannel: row.updateChannel,
      audioMuseServerUrl: row.audioMuseServerUrl,
      audioMuseApiKey: row.audioMuseApiKey,
      audioMuseEnabled: row.audioMuseEnabled,
      syncIntervalMinutes: row.syncIntervalMinutes,
      useLrclib: row.useLrclib,
      legacyInstantMixEnabled: row.legacyInstantMixEnabled,
      replayGainMode: row.replayGainMode,
      replayGainPreamp: row.replayGainPreamp,
      playbackSpeed: row.playbackSpeed,
      albumGridDensity: row.albumGridDensity,
      coverArtShape: row.coverArtShape,
      nowPlayingArtShape: row.nowPlayingArtShape,
      artistCardShape: row.artistCardShape,
      artistViewMode: row.artistViewMode,
      homeDensity: row.homeDensity,
      homeSectionOrder: _decodeStringList(row.homeSectionOrder),
      homeSectionsHidden: _decodeStringList(row.homeSectionsHidden),
    );
  }

  String? _encodeBandGains(List<double> values) {
    if (values.isEmpty) {
      return null;
    }
    return jsonEncode(values);
  }

  List<double> _decodeBandGains(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <double>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <double>[];
      }
      return decoded
          .map((value) => value is num ? value.toDouble() : null)
          .whereType<double>()
          .toList(growable: false);
    } on FormatException {
      return const <double>[];
    }
  }

  String? _encodeStringList(List<String>? values) {
    if (values == null || values.isEmpty) {
      return null;
    }
    return jsonEncode(values);
  }

  List<String>? _decodeStringList(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return null;
      }
      return decoded.cast<String>().toList(growable: false);
    } on FormatException {
      return null;
    }
  }
}
