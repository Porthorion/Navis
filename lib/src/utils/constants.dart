/// Compile-time constants for the Navis Forgejo repository.
///
/// These are intentionally not user-configurable — they are hardcoded to the
/// project's own Forgejo instance and repo.
abstract final class AppConstants {
  /// Base URL of the Forgejo instance hosting the Navis repository.
  static const String forgejoBaseUrl = 'https://git.porthorion.com';

  /// Repository owner (Forgejo username).
  static const String forgejoOwner = 'khalifa';

  /// Repository name.
  static const String forgejoRepo = 'Navis';

  /// Full URL of the Navis Forgejo repository (browse page).
  static const String repoUrl = '$forgejoBaseUrl/$forgejoOwner/$forgejoRepo';

  /// URL of the Forgejo Releases API endpoint for update checks.
  static const String releasesApiUrl =
      '$forgejoBaseUrl/api/v1/repos/$forgejoOwner/$forgejoRepo/releases';

  /// Update channel for release selection.
  ///
  /// Set via `--dart-define=NAVIS_UPDATE_CHANNEL=dev` for sidecar/dev builds.
  static const String updateChannel = String.fromEnvironment(
    'NAVIS_UPDATE_CHANNEL',
    defaultValue: 'stable',
  );

  /// Expected APK asset prefix for the active update channel.
  static const String updateAssetPrefix = updateChannel == 'dev'
      ? 'navis-dev'
      : 'navis';

  /// Whether this build can self-update via APK install (Forgejo/sideload APKs).
  ///
  /// Set to `false` for Google Play App Bundle builds via
  /// `--dart-define=NAVIS_SELF_UPDATE=false`.
  static const bool selfUpdateEnabled = bool.fromEnvironment(
    'NAVIS_SELF_UPDATE',
    defaultValue: true,
  );

  /// Google Play listing for the stable Android package.
  static const String playStorePackageName = 'com.navis.app.navis';

  static const String playStoreListingUrl =
      'https://play.google.com/store/apps/details?id=$playStorePackageName';

  /// Last.fm API key used by the Same Vibes mix mode.
  ///
  /// Inject at build time via:
  /// `--dart-define=NAVIS_LASTFM_API_KEY=...`
  static const String lastFmApiKey = String.fromEnvironment(
    'NAVIS_LASTFM_API_KEY',
    defaultValue: '',
  );
}
