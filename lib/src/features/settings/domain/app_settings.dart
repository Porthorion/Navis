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
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
    required this.wifiOnlyDownloads,
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
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0,
      wifiOnlyDownloads = false;

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
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
  final bool wifiOnlyDownloads;

  AppSettingsModel copyWith({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    bool? scrobbleEnabled,
    bool? gaplessEnabled,
    bool? skipSilenceEnabled,
    bool? showRadioPage,
    bool? equalizerEnabled,
    List<double>? equalizerBandGains,
    bool? loudnessEnabled,
    double? loudnessTargetGainDb,
    bool? wifiOnlyDownloads,
    bool clearWifiBitRate = false,
    bool clearWifiFormat = false,
    bool clearCellularBitRate = false,
    bool clearCellularFormat = false,
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
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerBandGains:
          equalizerBandGains ?? List<double>.from(this.equalizerBandGains),
      loudnessEnabled: loudnessEnabled ?? this.loudnessEnabled,
      loudnessTargetGainDb: loudnessTargetGainDb ?? this.loudnessTargetGainDb,
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
    );
  }
}
