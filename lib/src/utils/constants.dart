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
}
