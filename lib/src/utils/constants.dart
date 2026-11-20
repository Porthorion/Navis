import 'package:navis/src/features/changelog/changelog_data.dart';

/// Compile-time configuration for Navis services and distribution.
abstract final class AppConstants {
  /// Porthorion's public pages for Navis, linked from About and Privacy.
  static const String websiteUrl = 'https://navis.porthorion.com';
  static const String privacyPolicyUrl = '$websiteUrl/privacy/app';
  static const String sourceCodeUrl = 'https://github.com/Porthorion/Navis';
  static const String githubReleasesBaseUrl = '$sourceCodeUrl/releases';
  static const String issuesUrl = '$sourceCodeUrl/issues';
  static const String licenseUrl = '$sourceCodeUrl/blob/main/LICENSE';
  static const String supportEmail = 'support@porthorion.com';

  /// Shared HTTP identity derived from the current app changelog version.
  static final String userAgent =
      'Navis/${changelogs.first.version} '
      '(+https://navis.porthorion.com; support@porthorion.com)';

  /// Root of the signed update manifests and release artifacts.
  static const String updateBaseUrl = 'https://downloads.porthorion.com/navis/';

  /// Raw Ed25519 public key used to verify update manifests.
  static const String updateSigningPublicKey =
      'vSq61OOmfZS6CNYHeddKudoDAjZa179002wz/wnKtGk=';

  static const String updateManualDownloadUrl = '$websiteUrl/download';

  /// Update channel for release selection.
  ///
  /// Set via `--dart-define=NAVIS_UPDATE_CHANNEL=dev` for sidecar/dev builds.
  static const String updateChannel = String.fromEnvironment(
    'NAVIS_UPDATE_CHANNEL',
    defaultValue: 'stable',
  );

  /// Whether this is a dev-channel build: developer tools such as the playback
  /// trace and Copy Playback Trace are on only then.
  static const bool isDevChannel = updateChannel == 'dev';

  /// Whether this build can self-update via APK install (sideload APKs).
  ///
  /// Set to `false` for Google Play App Bundle builds via
  /// `--dart-define=NAVIS_SELF_UPDATE=false`.
  static const bool selfUpdateEnabled = bool.fromEnvironment(
    'NAVIS_SELF_UPDATE',
    defaultValue: true,
  );

  /// Whether this is the unsigned iOS build attached to GitHub releases for
  /// AltStore/SideStore. Only that build checks for updates, and it can only
  /// link to the release page: iOS cannot install an update by itself.
  ///
  /// Set by `tool/release.sh` via `--dart-define=NAVIS_IOS_SIDELOAD=true`;
  /// App Store, TestFlight, dev and simulator builds leave it `false`.
  static const bool iosSideload = bool.fromEnvironment('NAVIS_IOS_SIDELOAD');

  /// Google Play listing for the stable Android package.
  static const String playStorePackageName = 'com.navis.app.navis';

  static const String playStoreListingUrl =
      'https://play.google.com/store/apps/details?id=$playStorePackageName';

  /// Last.fm API key from the `NAVIS_LASTFM_API_KEY` dart-define. Local
  /// development only: no build or release script sets it, and Navis ships
  /// without a bundled key. Users add their own key in Settings >
  /// Integrations, which `lastFmApiKeyProvider` falls back to when this is
  /// empty.
  static final String lastFmApiKey = const String.fromEnvironment(
    'NAVIS_LASTFM_API_KEY',
    defaultValue: '',
  ).trim();
}
