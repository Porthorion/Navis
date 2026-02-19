// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Navis';

  @override
  String get loginTitle => 'Sign in';

  @override
  String get loginSubtitle => 'Connect to your Subsonic or Navidrome server.';

  @override
  String get loginServerUrlLabel => 'Server URL';

  @override
  String get loginUsernameLabel => 'Username';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginTestConnection => 'Test connection';

  @override
  String get loginTestingConnection => 'Testing connection...';

  @override
  String get loginConnect => 'Connect';

  @override
  String get loginConnecting => 'Connecting...';

  @override
  String get loginConnectSuccess => 'Connected successfully.';

  @override
  String get loginValidationServerUrlRequired => 'Server URL is required.';

  @override
  String get loginValidationServerUrlInvalid => 'Enter a valid server URL.';

  @override
  String get loginValidationServerUrlHttpsOnly => 'Use HTTPS for server URL.';

  @override
  String get loginInsecureHttpWarning =>
      'HTTP does not encrypt traffic. Use HTTPS when possible.';

  @override
  String get loginValidationUsernameRequired => 'Username is required.';

  @override
  String get loginValidationPasswordRequired => 'Password is required.';

  @override
  String get loginErrorAuthentication =>
      'Authentication failed. Check your credentials.';

  @override
  String get loginErrorConnection =>
      'Could not reach server. Check URL and network.';

  @override
  String get loginErrorUnknown => 'Unexpected error while connecting.';

  @override
  String loginTestConnectionSuccess(Object apiVersion) {
    return 'Connection successful (API $apiVersion).';
  }

  @override
  String get serverOfflineBanner => 'Server unreachable. Retrying every 30s.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsServerTitle => 'Server';

  @override
  String get settingsServerSubtitle =>
      'View, test, and update connection settings.';

  @override
  String get settingsCacheTitle => 'Cache';

  @override
  String get settingsPlaybackTitle => 'Playback';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get serverSettingsTitle => 'Server Settings';

  @override
  String get serverSettingsLoadError => 'Could not load server settings.';

  @override
  String get serverSettingsNotAuthenticated =>
      'No active server session. Sign in to manage server settings.';

  @override
  String get serverSettingsCurrentConnection => 'Current connection';

  @override
  String get serverSettingsNameLabel => 'Name';

  @override
  String get serverSettingsUrlLabel => 'URL';

  @override
  String get serverSettingsUsernameLabel => 'Username';

  @override
  String get serverSettingsApiVersionLabel => 'API version';

  @override
  String get serverSettingsAuthModeLabel => 'Auth mode';

  @override
  String get serverSettingsAuthModeToken => 'Token';

  @override
  String get serverSettingsAuthModeLegacy => 'Legacy password';

  @override
  String get serverSettingsCapabilitiesLabel => 'Capabilities';

  @override
  String get serverSettingsCapabilitiesEmpty => 'None detected';

  @override
  String serverSettingsCapabilitiesCount(int count) {
    return '$count extension(s)';
  }

  @override
  String get serverSettingsUnknownValue => 'Unknown';

  @override
  String get serverSettingsTestConnection => 'Test connection';

  @override
  String get serverSettingsSave => 'Save';

  @override
  String get serverSettingsSaving => 'Saving...';

  @override
  String get serverSettingsSaveSuccess => 'Server settings saved.';

  @override
  String get serverSettingsSignOut => 'Sign out';

  @override
  String get serverSettingsSignOutKeepData => 'Sign out (keep local data)';

  @override
  String get serverSettingsSignOutKeepDataSubtitle =>
      'Remove credentials but keep downloaded and cached metadata.';

  @override
  String get serverSettingsSignOutWipeData => 'Sign out and clear local data';

  @override
  String get serverSettingsSignOutWipeDataSubtitle =>
      'Remove credentials and wipe local library, cache, and history metadata.';

  @override
  String get serverSettingsSignOutSuccess =>
      'Signed out. Local data was preserved.';

  @override
  String get serverSettingsSignOutWipeSuccess =>
      'Signed out and local data cleared.';

  @override
  String get serverSettingsSignOutError =>
      'Could not complete sign out. Try again.';
}
