import 'dart:convert';

import 'package:navis/src/utils/constants.dart';

/// The user's update host choice, stored beside integration switches.
enum UpdateSource {
  porthorion,
  github;

  /// Reserved metadata in the existing integration-settings JSON list.
  /// It is not a service or feature key and cannot be toggled as one.
  static const githubSettingsKey = 'updates.source.github';

  static UpdateSource fromIntegrationSettings(String? raw) {
    try {
      final entries = raw == null ? null : jsonDecode(raw);
      return entries is List && entries.contains(githubSettingsKey)
          ? github
          : porthorion;
    } on FormatException {
      return porthorion;
    }
  }

  UpdateSource effectiveFor(String channel) =>
      channel == 'stable' ? this : porthorion;

  String get host => switch (this) {
    porthorion => 'downloads.porthorion.com',
    github => 'github.com',
  };

  String get assetBaseUrl => switch (this) {
    porthorion => AppConstants.updateBaseUrl,
    github => '${AppConstants.githubReleasesBaseUrl}/download/',
  };
}

/// Whether the update source choice can be shown or changed.
enum UpdateSourceAvailability {
  available,
  devChannel,
  storeManaged,
  unsupportedPlatform,
}
