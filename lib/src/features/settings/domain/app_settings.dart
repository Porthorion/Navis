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
  });

  const AppSettingsModel.defaults()
    : wifiMaxBitRate = null,
      wifiFormat = null,
      cellularMaxBitRate = AppSettingsDao.defaultCellularBitRate,
      cellularFormat = AppSettingsDao.defaultCellularFormat,
      scrobbleEnabled = true,
      gaplessEnabled = true,
      skipSilenceEnabled = false;

  final int? wifiMaxBitRate;
  final String? wifiFormat;
  final int? cellularMaxBitRate;
  final String? cellularFormat;
  final bool scrobbleEnabled;
  final bool gaplessEnabled;
  // Compatibility-only persisted field retained to keep schema upgrades safe.
  // Runtime playback behavior intentionally does not consume this setting.
  final bool skipSilenceEnabled;

  AppSettingsModel copyWith({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    bool? scrobbleEnabled,
    bool? gaplessEnabled,
    bool? skipSilenceEnabled,
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
    );
  }
}
