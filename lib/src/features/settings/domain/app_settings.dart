import 'package:flutter/foundation.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';

@immutable
class AppSettingsModel {
  const AppSettingsModel({
    required this.wifiMaxBitRate,
    required this.wifiFormat,
    required this.cellularMaxBitRate,
    required this.cellularFormat,
    required this.scrobbleEnabled,
    required this.gaplessEnabled,
    required this.skipSilenceEnabled,
    required this.showRadioPage,
    required this.showPlaylistsPage,
    required this.showArtistsPage,
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
    required this.wifiOnlyDownloads,
    required this.themeMode,
    required this.colorSchemeSeed,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    required this.artTintedNowPlaying,
    required this.updateCheckEnabled,
    required this.updateChannel,
    required this.audioMuseServerUrl,
    required this.audioMuseApiKey,
    required this.audioMuseEnabled,
  });

  const AppSettingsModel.defaults()
    : wifiMaxBitRate = null,
      wifiFormat = null,
      cellularMaxBitRate = AppSettingsDao.defaultCellularBitRate,
      cellularFormat = AppSettingsDao.defaultCellularFormat,
      scrobbleEnabled = true,
      gaplessEnabled = true,
      skipSilenceEnabled = false,
      showRadioPage = true,
      showPlaylistsPage = true,
      showArtistsPage = true,
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0,
      wifiOnlyDownloads = false,
      themeMode = 'dark',
      colorSchemeSeed = null,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      artTintedNowPlaying = true,
      updateCheckEnabled = true,
      updateChannel = 'stable',
      audioMuseServerUrl = null,
      audioMuseApiKey = null,
      audioMuseEnabled = false;

  final int? wifiMaxBitRate;
  final String? wifiFormat;
  final int? cellularMaxBitRate;
  final String? cellularFormat;
  final bool scrobbleEnabled;
  final bool gaplessEnabled;
  // Compatibility-only persisted field retained to keep schema upgrades safe.
  // Runtime playback behavior intentionally does not consume this setting.
  final bool skipSilenceEnabled;
  final bool showRadioPage;
  final bool showPlaylistsPage;
  final bool showArtistsPage;
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
  final bool wifiOnlyDownloads;
  final String themeMode;
  final int? colorSchemeSeed;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;
  final bool artTintedNowPlaying;
  final bool updateCheckEnabled;
  final String updateChannel;
  final String? audioMuseServerUrl;
  final String? audioMuseApiKey;
  final bool audioMuseEnabled;

  AppSettingsModel copyWith({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    bool? scrobbleEnabled,
    bool? gaplessEnabled,
    bool? skipSilenceEnabled,
    bool? showRadioPage,
    bool? showPlaylistsPage,
    bool? showArtistsPage,
    bool? equalizerEnabled,
    List<double>? equalizerBandGains,
    bool? loudnessEnabled,
    double? loudnessTargetGainDb,
    bool? wifiOnlyDownloads,
    String? themeMode,
    int? colorSchemeSeed,
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    String? crossfadeType,
    bool? artTintedNowPlaying,
    bool? updateCheckEnabled,
    String? updateChannel,
    String? audioMuseServerUrl,
    String? audioMuseApiKey,
    bool? audioMuseEnabled,
    bool clearWifiBitRate = false,
    bool clearWifiFormat = false,
    bool clearCellularBitRate = false,
    bool clearCellularFormat = false,
    bool clearColorSchemeSeed = false,
    bool clearAudioMuseServerUrl = false,
    bool clearAudioMuseApiKey = false,
  }) {
    return AppSettingsModel(
      wifiMaxBitRate: clearWifiBitRate
          ? null
          : wifiMaxBitRate ?? this.wifiMaxBitRate,
      wifiFormat: clearWifiFormat ? null : wifiFormat ?? this.wifiFormat,
      cellularMaxBitRate: clearCellularBitRate
          ? null
          : cellularMaxBitRate ?? this.cellularMaxBitRate,
      cellularFormat: clearCellularFormat
          ? null
          : cellularFormat ?? this.cellularFormat,
      scrobbleEnabled: scrobbleEnabled ?? this.scrobbleEnabled,
      gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
      skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
      showRadioPage: showRadioPage ?? this.showRadioPage,
      showPlaylistsPage: showPlaylistsPage ?? this.showPlaylistsPage,
      showArtistsPage: showArtistsPage ?? this.showArtistsPage,
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerBandGains:
          equalizerBandGains ?? List<double>.from(this.equalizerBandGains),
      loudnessEnabled: loudnessEnabled ?? this.loudnessEnabled,
      loudnessTargetGainDb: loudnessTargetGainDb ?? this.loudnessTargetGainDb,
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      themeMode: themeMode ?? this.themeMode,
      colorSchemeSeed: clearColorSchemeSeed
          ? null
          : colorSchemeSeed ?? this.colorSchemeSeed,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDurationSeconds:
          crossfadeDurationSeconds ?? this.crossfadeDurationSeconds,
      crossfadeType: crossfadeType ?? this.crossfadeType,
      artTintedNowPlaying: artTintedNowPlaying ?? this.artTintedNowPlaying,
      updateCheckEnabled: updateCheckEnabled ?? this.updateCheckEnabled,
      updateChannel: updateChannel ?? this.updateChannel,
      audioMuseServerUrl: clearAudioMuseServerUrl
          ? null
          : audioMuseServerUrl ?? this.audioMuseServerUrl,
      audioMuseApiKey: clearAudioMuseApiKey
          ? null
          : audioMuseApiKey ?? this.audioMuseApiKey,
      audioMuseEnabled: audioMuseEnabled ?? this.audioMuseEnabled,
    );
  }
}
