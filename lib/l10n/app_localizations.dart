import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Navis'**
  String get appName;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// No description provided for @navSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get navSearch;

  /// No description provided for @navRadio.
  ///
  /// In en, this message translates to:
  /// **'Radio'**
  String get navRadio;

  /// No description provided for @navPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get navPlaylists;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @loginTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginTitle;

  /// No description provided for @loginSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to your Subsonic or Navidrome server.'**
  String get loginSubtitle;

  /// No description provided for @loginServerUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get loginServerUrlLabel;

  /// No description provided for @loginUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get loginUsernameLabel;

  /// No description provided for @loginPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPasswordLabel;

  /// No description provided for @loginTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get loginTestConnection;

  /// No description provided for @loginTestingConnection.
  ///
  /// In en, this message translates to:
  /// **'Testing connection...'**
  String get loginTestingConnection;

  /// No description provided for @loginConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get loginConnect;

  /// No description provided for @loginConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get loginConnecting;

  /// No description provided for @loginConnectSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connected successfully.'**
  String get loginConnectSuccess;

  /// No description provided for @loginValidationServerUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Server URL is required.'**
  String get loginValidationServerUrlRequired;

  /// No description provided for @loginValidationServerUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid server URL.'**
  String get loginValidationServerUrlInvalid;

  /// No description provided for @loginValidationServerUrlHttpsOnly.
  ///
  /// In en, this message translates to:
  /// **'Use HTTPS for server URL.'**
  String get loginValidationServerUrlHttpsOnly;

  /// No description provided for @loginInsecureHttpWarning.
  ///
  /// In en, this message translates to:
  /// **'HTTP does not encrypt traffic. Use HTTPS when possible.'**
  String get loginInsecureHttpWarning;

  /// No description provided for @loginValidationUsernameRequired.
  ///
  /// In en, this message translates to:
  /// **'Username is required.'**
  String get loginValidationUsernameRequired;

  /// No description provided for @loginValidationPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required.'**
  String get loginValidationPasswordRequired;

  /// No description provided for @loginErrorAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed. Check your credentials.'**
  String get loginErrorAuthentication;

  /// No description provided for @loginErrorConnection.
  ///
  /// In en, this message translates to:
  /// **'Could not reach server. Check URL and network.'**
  String get loginErrorConnection;

  /// No description provided for @loginErrorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unexpected error while connecting.'**
  String get loginErrorUnknown;

  /// No description provided for @loginTestConnectionSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connection successful (API {apiVersion}).'**
  String loginTestConnectionSuccess(Object apiVersion);

  /// No description provided for @serverOfflineBanner.
  ///
  /// In en, this message translates to:
  /// **'Server unreachable. Retrying every 30s.'**
  String get serverOfflineBanner;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get settingsServerTitle;

  /// No description provided for @settingsServerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'View, test, and update connection settings.'**
  String get settingsServerSubtitle;

  /// No description provided for @settingsCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get settingsCacheTitle;

  /// No description provided for @settingsSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get settingsSyncTitle;

  /// No description provided for @settingsSyncSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync progress, history, and manual controls.'**
  String get settingsSyncSubtitle;

  /// No description provided for @settingsPlaybackTitle.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get settingsPlaybackTitle;

  /// No description provided for @settingsAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceTitle;

  /// No description provided for @syncSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync Settings'**
  String get syncSettingsTitle;

  /// No description provided for @syncSettingsStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Current sync status'**
  String get syncSettingsStatusLabel;

  /// No description provided for @syncSettingsLastSyncedLabel.
  ///
  /// In en, this message translates to:
  /// **'Server last synced'**
  String get syncSettingsLastSyncedLabel;

  /// No description provided for @syncSettingsNeverSynced.
  ///
  /// In en, this message translates to:
  /// **'Never synced'**
  String get syncSettingsNeverSynced;

  /// No description provided for @syncSettingsStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get syncSettingsStatusIdle;

  /// No description provided for @syncSettingsStatusSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Last sync succeeded'**
  String get syncSettingsStatusSucceeded;

  /// No description provided for @syncSettingsStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Last sync failed'**
  String get syncSettingsStatusFailed;

  /// No description provided for @playbackSettingsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load playback settings: {message}'**
  String playbackSettingsLoadError(Object message);

  /// No description provided for @playbackSettingsWifiSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi streaming'**
  String get playbackSettingsWifiSectionTitle;

  /// No description provided for @playbackSettingsWifiQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Max bitrate'**
  String get playbackSettingsWifiQualityLabel;

  /// No description provided for @playbackSettingsWifiFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Preferred format'**
  String get playbackSettingsWifiFormatLabel;

  /// No description provided for @playbackSettingsCellularSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Cellular streaming'**
  String get playbackSettingsCellularSectionTitle;

  /// No description provided for @playbackSettingsCellularQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Max bitrate'**
  String get playbackSettingsCellularQualityLabel;

  /// No description provided for @playbackSettingsCellularFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Preferred format'**
  String get playbackSettingsCellularFormatLabel;

  /// No description provided for @playbackSettingsScrobbleTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable scrobbling'**
  String get playbackSettingsScrobbleTitle;

  /// No description provided for @playbackSettingsScrobbleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Send now-playing and listened-track updates to the server.'**
  String get playbackSettingsScrobbleSubtitle;

  /// No description provided for @playbackSettingsGaplessTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable gapless playback'**
  String get playbackSettingsGaplessTitle;

  /// No description provided for @playbackSettingsGaplessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Preload tracks to reduce gaps between songs.'**
  String get playbackSettingsGaplessSubtitle;

  /// No description provided for @playbackSettingsShowRadioPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Radio page'**
  String get playbackSettingsShowRadioPageTitle;

  /// No description provided for @playbackSettingsShowRadioPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Display the Radio tab in bottom navigation.'**
  String get playbackSettingsShowRadioPageSubtitle;

  /// No description provided for @playbackSettingsAndroidDspSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Android audio effects'**
  String get playbackSettingsAndroidDspSectionTitle;

  /// No description provided for @playbackSettingsEqualizerTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable equalizer'**
  String get playbackSettingsEqualizerTitle;

  /// No description provided for @playbackSettingsEqualizerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adjust frequency bands for Android playback.'**
  String get playbackSettingsEqualizerSubtitle;

  /// No description provided for @playbackSettingsEqualizerBandLabel.
  ///
  /// In en, this message translates to:
  /// **'Band {index}'**
  String playbackSettingsEqualizerBandLabel(int index);

  /// No description provided for @playbackSettingsLoudnessTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable loudness enhancer'**
  String get playbackSettingsLoudnessTitle;

  /// No description provided for @playbackSettingsLoudnessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Apply target gain in dB on Android playback.'**
  String get playbackSettingsLoudnessSubtitle;

  /// No description provided for @playbackSettingsSkipSilenceTitle.
  ///
  /// In en, this message translates to:
  /// **'Skip silence when possible'**
  String get playbackSettingsSkipSilenceTitle;

  /// No description provided for @playbackSettingsSkipSilenceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Automatically skip silent segments on supported platforms.'**
  String get playbackSettingsSkipSilenceSubtitle;

  /// No description provided for @playbackSettingsSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get playbackSettingsSaveAction;

  /// No description provided for @playbackSettingsResetAction.
  ///
  /// In en, this message translates to:
  /// **'Reset defaults'**
  String get playbackSettingsResetAction;

  /// No description provided for @playbackSettingsQualityOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original quality'**
  String get playbackSettingsQualityOriginal;

  /// No description provided for @playbackSettingsQualityKbps.
  ///
  /// In en, this message translates to:
  /// **'{kbps} kbps'**
  String playbackSettingsQualityKbps(int kbps);

  /// No description provided for @playbackSettingsFormatOriginal.
  ///
  /// In en, this message translates to:
  /// **'Server default'**
  String get playbackSettingsFormatOriginal;

  /// No description provided for @playbackSettingsSaveSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playback settings saved.'**
  String get playbackSettingsSaveSuccess;

  /// No description provided for @playbackSettingsSaveFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not save playback settings: {message}'**
  String playbackSettingsSaveFailure(Object message);

  /// No description provided for @playbackSettingsResetSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playback settings reset to defaults.'**
  String get playbackSettingsResetSuccess;

  /// No description provided for @playbackSettingsResetFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not reset playback settings: {message}'**
  String playbackSettingsResetFailure(Object message);

  /// No description provided for @homeTitle.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get homeTitle;

  /// No description provided for @homeLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load section'**
  String get homeLoadErrorTitle;

  /// No description provided for @homeRecentlyPlayedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently played'**
  String get homeRecentlyPlayedTitle;

  /// No description provided for @homeRecentlyPlayedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recent plays yet'**
  String get homeRecentlyPlayedEmptyTitle;

  /// No description provided for @homeRecentlyPlayedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start playback to populate this section.'**
  String get homeRecentlyPlayedEmptySubtitle;

  /// No description provided for @homeRecentlyAddedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently added'**
  String get homeRecentlyAddedTitle;

  /// No description provided for @homeRecentlyAddedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recently added albums'**
  String get homeRecentlyAddedEmptyTitle;

  /// No description provided for @homeRecentlyAddedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pull to refresh to fetch newly added albums.'**
  String get homeRecentlyAddedEmptySubtitle;

  /// No description provided for @homeFrequentTitle.
  ///
  /// In en, this message translates to:
  /// **'Most played'**
  String get homeFrequentTitle;

  /// No description provided for @homeFrequentEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No frequent albums yet'**
  String get homeFrequentEmptyTitle;

  /// No description provided for @homeFrequentEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Play more tracks to build listening history.'**
  String get homeFrequentEmptySubtitle;

  /// No description provided for @homeRandomTitle.
  ///
  /// In en, this message translates to:
  /// **'Random picks'**
  String get homeRandomTitle;

  /// No description provided for @homeRandomEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No random picks available'**
  String get homeRandomEmptyTitle;

  /// No description provided for @homeRandomEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pull to refresh to fetch random albums.'**
  String get homeRandomEmptySubtitle;

  /// No description provided for @homeStarredTitle.
  ///
  /// In en, this message translates to:
  /// **'Starred tracks'**
  String get homeStarredTitle;

  /// No description provided for @homeStarredEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No starred tracks'**
  String get homeStarredEmptyTitle;

  /// No description provided for @homeStarredEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Star tracks on your server to see them here.'**
  String get homeStarredEmptySubtitle;

  /// No description provided for @radioTitle.
  ///
  /// In en, this message translates to:
  /// **'Radio'**
  String get radioTitle;

  /// No description provided for @radioEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No radio stations found'**
  String get radioEmptyTitle;

  /// No description provided for @radioEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add internet radio stations on your server to see them here.'**
  String get radioEmptySubtitle;

  /// No description provided for @radioLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load radio stations'**
  String get radioLoadErrorTitle;

  /// No description provided for @radioUnsupportedMessage.
  ///
  /// In en, this message translates to:
  /// **'This server does not expose internet radio station endpoints.'**
  String get radioUnsupportedMessage;

  /// No description provided for @serverSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Server Settings'**
  String get serverSettingsTitle;

  /// No description provided for @serverSettingsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load server settings.'**
  String get serverSettingsLoadError;

  /// No description provided for @serverSettingsNotAuthenticated.
  ///
  /// In en, this message translates to:
  /// **'No active server session. Sign in to manage server settings.'**
  String get serverSettingsNotAuthenticated;

  /// No description provided for @serverSettingsCurrentConnection.
  ///
  /// In en, this message translates to:
  /// **'Current connection'**
  String get serverSettingsCurrentConnection;

  /// No description provided for @serverSettingsNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get serverSettingsNameLabel;

  /// No description provided for @serverSettingsUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get serverSettingsUrlLabel;

  /// No description provided for @serverSettingsUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serverSettingsUsernameLabel;

  /// No description provided for @serverSettingsApiVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'API version'**
  String get serverSettingsApiVersionLabel;

  /// No description provided for @serverSettingsAuthModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Auth mode'**
  String get serverSettingsAuthModeLabel;

  /// No description provided for @serverSettingsAuthModeToken.
  ///
  /// In en, this message translates to:
  /// **'Token'**
  String get serverSettingsAuthModeToken;

  /// No description provided for @serverSettingsAuthModeLegacy.
  ///
  /// In en, this message translates to:
  /// **'Legacy password'**
  String get serverSettingsAuthModeLegacy;

  /// No description provided for @serverSettingsCapabilitiesLabel.
  ///
  /// In en, this message translates to:
  /// **'Capabilities'**
  String get serverSettingsCapabilitiesLabel;

  /// No description provided for @serverSettingsCapabilitiesEmpty.
  ///
  /// In en, this message translates to:
  /// **'None detected'**
  String get serverSettingsCapabilitiesEmpty;

  /// No description provided for @serverSettingsCapabilitiesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} extension(s)'**
  String serverSettingsCapabilitiesCount(int count);

  /// No description provided for @serverSettingsUnknownValue.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get serverSettingsUnknownValue;

  /// No description provided for @serverSettingsTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get serverSettingsTestConnection;

  /// No description provided for @serverSettingsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get serverSettingsSave;

  /// No description provided for @serverSettingsSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving...'**
  String get serverSettingsSaving;

  /// No description provided for @serverSettingsSaveSuccess.
  ///
  /// In en, this message translates to:
  /// **'Server settings saved.'**
  String get serverSettingsSaveSuccess;

  /// No description provided for @serverSettingsForceFullSync.
  ///
  /// In en, this message translates to:
  /// **'Force Full Sync'**
  String get serverSettingsForceFullSync;

  /// No description provided for @serverSettingsForceFullSyncRunning.
  ///
  /// In en, this message translates to:
  /// **'Sync in progress...'**
  String get serverSettingsForceFullSyncRunning;

  /// No description provided for @serverSettingsForceFullSyncSuccess.
  ///
  /// In en, this message translates to:
  /// **'Full library sync completed.'**
  String get serverSettingsForceFullSyncSuccess;

  /// No description provided for @serverSettingsForceFullSyncFailure.
  ///
  /// In en, this message translates to:
  /// **'Full sync failed: {message}'**
  String serverSettingsForceFullSyncFailure(Object message);

  /// No description provided for @serverSettingsSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get serverSettingsSignOut;

  /// No description provided for @serverSettingsSignOutKeepData.
  ///
  /// In en, this message translates to:
  /// **'Sign out (keep local data)'**
  String get serverSettingsSignOutKeepData;

  /// No description provided for @serverSettingsSignOutKeepDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Remove credentials but keep downloaded and cached metadata.'**
  String get serverSettingsSignOutKeepDataSubtitle;

  /// No description provided for @serverSettingsSignOutWipeData.
  ///
  /// In en, this message translates to:
  /// **'Sign out and clear local data'**
  String get serverSettingsSignOutWipeData;

  /// No description provided for @serverSettingsSignOutWipeDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Remove credentials and wipe local library, cache, and history metadata.'**
  String get serverSettingsSignOutWipeDataSubtitle;

  /// No description provided for @serverSettingsSignOutSuccess.
  ///
  /// In en, this message translates to:
  /// **'Signed out. Local data was preserved.'**
  String get serverSettingsSignOutSuccess;

  /// No description provided for @serverSettingsSignOutWipeSuccess.
  ///
  /// In en, this message translates to:
  /// **'Signed out and local data cleared.'**
  String get serverSettingsSignOutWipeSuccess;

  /// No description provided for @serverSettingsSignOutError.
  ///
  /// In en, this message translates to:
  /// **'Could not complete sign out. Try again.'**
  String get serverSettingsSignOutError;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// No description provided for @libraryTabArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get libraryTabArtists;

  /// No description provided for @libraryTabAlbums.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get libraryTabAlbums;

  /// No description provided for @libraryTabSongs.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get libraryTabSongs;

  /// No description provided for @libraryTabGenres.
  ///
  /// In en, this message translates to:
  /// **'Genres'**
  String get libraryTabGenres;

  /// No description provided for @librarySyncRunning.
  ///
  /// In en, this message translates to:
  /// **'Syncing library metadata...'**
  String get librarySyncRunning;

  /// No description provided for @librarySyncRunningStage.
  ///
  /// In en, this message translates to:
  /// **'Syncing: {stage}'**
  String librarySyncRunningStage(Object stage);

  /// No description provided for @librarySyncRunningWithProgress.
  ///
  /// In en, this message translates to:
  /// **'Syncing library metadata ({processed}/{total})'**
  String librarySyncRunningWithProgress(int processed, int total);

  /// No description provided for @librarySyncLastSynced.
  ///
  /// In en, this message translates to:
  /// **'Last synced: {timestamp}'**
  String librarySyncLastSynced(Object timestamp);

  /// No description provided for @librarySyncStagePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get librarySyncStagePreparing;

  /// No description provided for @librarySyncStageArtists.
  ///
  /// In en, this message translates to:
  /// **'Fetching artists'**
  String get librarySyncStageArtists;

  /// No description provided for @librarySyncStageAlbums.
  ///
  /// In en, this message translates to:
  /// **'Fetching albums'**
  String get librarySyncStageAlbums;

  /// No description provided for @librarySyncStagePersisting.
  ///
  /// In en, this message translates to:
  /// **'Persisting metadata'**
  String get librarySyncStagePersisting;

  /// No description provided for @librarySyncStageSongs.
  ///
  /// In en, this message translates to:
  /// **'Hydrating songs'**
  String get librarySyncStageSongs;

  /// No description provided for @librarySyncStageGenres.
  ///
  /// In en, this message translates to:
  /// **'Fetching genres'**
  String get librarySyncStageGenres;

  /// No description provided for @librarySyncStagePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Fetching playlists'**
  String get librarySyncStagePlaylists;

  /// No description provided for @librarySyncStageFinalizing.
  ///
  /// In en, this message translates to:
  /// **'Finalizing'**
  String get librarySyncStageFinalizing;

  /// No description provided for @librarySyncFailureFallback.
  ///
  /// In en, this message translates to:
  /// **'Library sync failed.'**
  String get librarySyncFailureFallback;

  /// No description provided for @librarySyncHydratingUnknown.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Hydrating songs...'**
  String get librarySyncHydratingUnknown;

  /// No description provided for @librarySyncHydratingProgress.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Hydrating songs ({processed}/{total}, {pending} remaining)'**
  String librarySyncHydratingProgress(int processed, int total, int pending);

  /// No description provided for @librarySyncHydratingProgressWithRate.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Hydrating songs ({processed}/{total}, {pending} remaining, {rate} albums/s)'**
  String librarySyncHydratingProgressWithRate(
    int processed,
    int total,
    int pending,
    Object rate,
  );

  /// No description provided for @libraryArtistsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No artists found'**
  String get libraryArtistsEmptyTitle;

  /// No description provided for @libraryArtistsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get libraryArtistsEmptySubtitle;

  /// No description provided for @libraryArtistsIndexAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get libraryArtistsIndexAll;

  /// No description provided for @libraryArtistsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load artists'**
  String get libraryArtistsErrorTitle;

  /// No description provided for @libraryAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No albums found'**
  String get libraryAlbumsEmptyTitle;

  /// No description provided for @libraryAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get libraryAlbumsEmptySubtitle;

  /// No description provided for @libraryAlbumsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load albums'**
  String get libraryAlbumsErrorTitle;

  /// No description provided for @libraryAlbumsSortLabel.
  ///
  /// In en, this message translates to:
  /// **'Sort albums by'**
  String get libraryAlbumsSortLabel;

  /// No description provided for @libraryAlbumsPagingProgress.
  ///
  /// In en, this message translates to:
  /// **'Loaded {loaded} of {total} albums'**
  String libraryAlbumsPagingProgress(int loaded, int total);

  /// No description provided for @librarySongsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No songs found'**
  String get librarySongsEmptyTitle;

  /// No description provided for @librarySongsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get librarySongsEmptySubtitle;

  /// No description provided for @librarySongsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load songs'**
  String get librarySongsErrorTitle;

  /// No description provided for @librarySongsSortLabel.
  ///
  /// In en, this message translates to:
  /// **'Sort songs by'**
  String get librarySongsSortLabel;

  /// No description provided for @libraryGenresEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No genres found'**
  String get libraryGenresEmptyTitle;

  /// No description provided for @libraryGenresEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get libraryGenresEmptySubtitle;

  /// No description provided for @libraryGenresErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load genres'**
  String get libraryGenresErrorTitle;

  /// No description provided for @libraryGenresCount.
  ///
  /// In en, this message translates to:
  /// **'{albums} albums • {songs} songs'**
  String libraryGenresCount(int albums, int songs);

  /// No description provided for @librarySortNewest.
  ///
  /// In en, this message translates to:
  /// **'Newest'**
  String get librarySortNewest;

  /// No description provided for @librarySortOldest.
  ///
  /// In en, this message translates to:
  /// **'Oldest'**
  String get librarySortOldest;

  /// No description provided for @librarySortName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get librarySortName;

  /// No description provided for @librarySortArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get librarySortArtist;

  /// No description provided for @librarySortArtistAlbum.
  ///
  /// In en, this message translates to:
  /// **'Artist / Album'**
  String get librarySortArtistAlbum;

  /// No description provided for @librarySortTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get librarySortTitle;

  /// No description provided for @librarySortDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get librarySortDuration;

  /// No description provided for @libraryArtistMenuOpen.
  ///
  /// In en, this message translates to:
  /// **'Open artist'**
  String get libraryArtistMenuOpen;

  /// No description provided for @libraryAlbumMenuOpen.
  ///
  /// In en, this message translates to:
  /// **'Open album'**
  String get libraryAlbumMenuOpen;

  /// No description provided for @librarySongMenuPlayNow.
  ///
  /// In en, this message translates to:
  /// **'Play now'**
  String get librarySongMenuPlayNow;

  /// No description provided for @librarySongMenuAddToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get librarySongMenuAddToQueue;

  /// No description provided for @librarySongMenuPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Play next'**
  String get librarySongMenuPlayNext;

  /// No description provided for @librarySongMenuOpenAlbum.
  ///
  /// In en, this message translates to:
  /// **'Open album'**
  String get librarySongMenuOpenAlbum;

  /// No description provided for @librarySongMenuOpenArtist.
  ///
  /// In en, this message translates to:
  /// **'Open artist'**
  String get librarySongMenuOpenArtist;

  /// No description provided for @librarySongPlayNowQueued.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" queued to play now.'**
  String librarySongPlayNowQueued(Object title);

  /// No description provided for @librarySongAddedToQueue.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" added to queue.'**
  String librarySongAddedToQueue(Object title);

  /// No description provided for @librarySongPlayNextQueued.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" added to play next.'**
  String librarySongPlayNextQueued(Object title);

  /// No description provided for @libraryGenreDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'{genre}'**
  String libraryGenreDetailTitle(Object genre);

  /// No description provided for @libraryGenreAlbumsTab.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get libraryGenreAlbumsTab;

  /// No description provided for @libraryGenreSongsTab.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get libraryGenreSongsTab;

  /// No description provided for @libraryGenreAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No albums in this genre'**
  String get libraryGenreAlbumsEmptyTitle;

  /// No description provided for @libraryGenreAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync to refresh genre albums.'**
  String get libraryGenreAlbumsEmptySubtitle;

  /// No description provided for @libraryGenreSongsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No songs in this genre'**
  String get libraryGenreSongsEmptyTitle;

  /// No description provided for @libraryGenreSongsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync to refresh genre songs.'**
  String get libraryGenreSongsEmptySubtitle;

  /// No description provided for @libraryGenreLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load genre'**
  String get libraryGenreLoadErrorTitle;

  /// No description provided for @artistCardAlbumCount.
  ///
  /// In en, this message translates to:
  /// **'{count} albums'**
  String artistCardAlbumCount(int count);

  /// No description provided for @artistDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get artistDetailTitle;

  /// No description provided for @artistDetailNotFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Artist not found'**
  String get artistDetailNotFoundTitle;

  /// No description provided for @artistDetailNotFoundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This artist is not available in local data.'**
  String get artistDetailNotFoundSubtitle;

  /// No description provided for @artistDetailAlbumCount.
  ///
  /// In en, this message translates to:
  /// **'{count} albums'**
  String artistDetailAlbumCount(int count);

  /// No description provided for @artistDetailAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No albums for this artist'**
  String get artistDetailAlbumsEmptyTitle;

  /// No description provided for @artistDetailAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync your library to load artist albums.'**
  String get artistDetailAlbumsEmptySubtitle;

  /// No description provided for @artistDetailAlbumsSection.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get artistDetailAlbumsSection;

  /// No description provided for @artistDetailUnknownYear.
  ///
  /// In en, this message translates to:
  /// **'Unknown year'**
  String get artistDetailUnknownYear;

  /// No description provided for @artistDetailBioSection.
  ///
  /// In en, this message translates to:
  /// **'Biography'**
  String get artistDetailBioSection;

  /// No description provided for @artistDetailSimilarSection.
  ///
  /// In en, this message translates to:
  /// **'Similar artists'**
  String get artistDetailSimilarSection;

  /// No description provided for @artistDetailAlbumsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load artist albums'**
  String get artistDetailAlbumsErrorTitle;

  /// No description provided for @artistDetailLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load artist details'**
  String get artistDetailLoadErrorTitle;

  /// No description provided for @albumDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get albumDetailTitle;

  /// No description provided for @albumDetailNotFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Album not found'**
  String get albumDetailNotFoundTitle;

  /// No description provided for @albumDetailNotFoundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This album is not available in local data.'**
  String get albumDetailNotFoundSubtitle;

  /// No description provided for @albumDetailUnknownArtist.
  ///
  /// In en, this message translates to:
  /// **'Unknown artist'**
  String get albumDetailUnknownArtist;

  /// No description provided for @albumDetailMeta.
  ///
  /// In en, this message translates to:
  /// **'{artist} • {year} • {trackCount} tracks'**
  String albumDetailMeta(Object artist, Object year, int trackCount);

  /// No description provided for @albumDetailTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No tracks for this album'**
  String get albumDetailTracksEmptyTitle;

  /// No description provided for @albumDetailTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync your library to load album tracks.'**
  String get albumDetailTracksEmptySubtitle;

  /// No description provided for @albumDetailLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load album details'**
  String get albumDetailLoadErrorTitle;

  /// No description provided for @albumDetailPlayAction.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get albumDetailPlayAction;

  /// No description provided for @albumDetailShuffleAction.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get albumDetailShuffleAction;

  /// No description provided for @albumDetailStarAction.
  ///
  /// In en, this message translates to:
  /// **'Star'**
  String get albumDetailStarAction;

  /// No description provided for @albumDetailDownloadAction.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get albumDetailDownloadAction;

  /// No description provided for @albumDetailDownloadActionQueued.
  ///
  /// In en, this message translates to:
  /// **'Album queued for download.'**
  String get albumDetailDownloadActionQueued;

  /// No description provided for @albumDetailPlayActionQueued.
  ///
  /// In en, this message translates to:
  /// **'Album queued for playback.'**
  String get albumDetailPlayActionQueued;

  /// No description provided for @albumDetailShuffleActionQueued.
  ///
  /// In en, this message translates to:
  /// **'Album shuffled into queue.'**
  String get albumDetailShuffleActionQueued;

  /// No description provided for @albumDetailStarSuccess.
  ///
  /// In en, this message translates to:
  /// **'Album starred.'**
  String get albumDetailStarSuccess;

  /// No description provided for @albumDetailUnstarSuccess.
  ///
  /// In en, this message translates to:
  /// **'Album unstarred.'**
  String get albumDetailUnstarSuccess;

  /// No description provided for @albumDetailStarFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not update star status.'**
  String get albumDetailStarFailure;

  /// No description provided for @cacheBadgeLabel.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get cacheBadgeLabel;

  /// No description provided for @miniPlayerUnknownTrack.
  ///
  /// In en, this message translates to:
  /// **'Unknown track'**
  String get miniPlayerUnknownTrack;

  /// No description provided for @miniPlayerUnknownArtist.
  ///
  /// In en, this message translates to:
  /// **'Unknown artist'**
  String get miniPlayerUnknownArtist;

  /// No description provided for @miniPlayerPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get miniPlayerPlay;

  /// No description provided for @miniPlayerPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get miniPlayerPause;

  /// No description provided for @playbackBootstrapLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Preparing playback'**
  String get playbackBootstrapLoadingTitle;

  /// No description provided for @playbackBootstrapLoadingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Initializing audio services...'**
  String get playbackBootstrapLoadingSubtitle;

  /// No description provided for @playbackBootstrapFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Playback initialization failed'**
  String get playbackBootstrapFailedTitle;

  /// No description provided for @playbackBootstrapFailedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Could not initialize playback. Retry to continue.'**
  String get playbackBootstrapFailedSubtitle;

  /// No description provided for @playbackBootstrapRetryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry playback startup'**
  String get playbackBootstrapRetryAction;

  /// No description provided for @playbackUnavailableInitializing.
  ///
  /// In en, this message translates to:
  /// **'Playback is still initializing. Try again in a moment.'**
  String get playbackUnavailableInitializing;

  /// No description provided for @playbackUnavailableStartupFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback startup failed. Retry from the startup screen.'**
  String get playbackUnavailableStartupFailed;

  /// No description provided for @playbackUnavailableSource.
  ///
  /// In en, this message translates to:
  /// **'Could not resolve an audio source. Check server session and connection.'**
  String get playbackUnavailableSource;

  /// No description provided for @playbackUnavailableGeneric.
  ///
  /// In en, this message translates to:
  /// **'Playback is unavailable right now.'**
  String get playbackUnavailableGeneric;

  /// No description provided for @playbackActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback action failed. Please try again.'**
  String get playbackActionFailed;

  /// No description provided for @queueTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queueTitle;

  /// No description provided for @queueClearAction.
  ///
  /// In en, this message translates to:
  /// **'Clear queue'**
  String get queueClearAction;

  /// No description provided for @queueClearConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear queue?'**
  String get queueClearConfirmTitle;

  /// No description provided for @queueClearConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This will remove all tracks from the queue.'**
  String get queueClearConfirmMessage;

  /// No description provided for @queueEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue is empty'**
  String get queueEmptyTitle;

  /// No description provided for @queueEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add tracks to start playing.'**
  String get queueEmptySubtitle;

  /// No description provided for @cancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelAction;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
