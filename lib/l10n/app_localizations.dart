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
  /// **'Configuration'**
  String get settingsServerTitle;

  /// No description provided for @settingsServerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Server connection, account, and external services.'**
  String get settingsServerSubtitle;

  /// No description provided for @settingsCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get settingsCacheTitle;

  /// No description provided for @settingsCacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage storage for audio, cover art and downloads.'**
  String get settingsCacheSubtitle;

  /// No description provided for @settingsDownloadsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage offline downloads and queue.'**
  String get settingsDownloadsSubtitle;

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

  /// No description provided for @settingsPlaybackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Stream quality, gapless, crossfade and equalizer.'**
  String get settingsPlaybackSubtitle;

  /// No description provided for @settingsAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceTitle;

  /// No description provided for @settingsAppearanceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Themes, colors and display preferences.'**
  String get settingsAppearanceSubtitle;

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

  /// No description provided for @syncSettingsIntervalLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-sync interval'**
  String get syncSettingsIntervalLabel;

  /// No description provided for @syncSettingsIntervalManual.
  ///
  /// In en, this message translates to:
  /// **'Manual only'**
  String get syncSettingsIntervalManual;

  /// No description provided for @syncSettingsIntervalMinutes.
  ///
  /// In en, this message translates to:
  /// **'Every {minutes} minutes'**
  String syncSettingsIntervalMinutes(Object minutes);

  /// No description provided for @syncSettingsIntervalHours.
  ///
  /// In en, this message translates to:
  /// **'Every {hours} hour(s)'**
  String syncSettingsIntervalHours(Object hours);

  /// No description provided for @syncSettingsIntervalDescription.
  ///
  /// In en, this message translates to:
  /// **'How often the library syncs automatically in the background.'**
  String get syncSettingsIntervalDescription;

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

  /// No description provided for @playbackSettingsCachedFirstTitle.
  ///
  /// In en, this message translates to:
  /// **'Cached First'**
  String get playbackSettingsCachedFirstTitle;

  /// No description provided for @playbackSettingsCachedFirstSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Prefer any complete cached file before requesting the active streaming profile.'**
  String get playbackSettingsCachedFirstSubtitle;

  /// No description provided for @playbackSettingsScrobbleTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable scrobbling'**
  String get playbackSettingsScrobbleTitle;

  /// No description provided for @playbackSettingsScrobbleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Report tracks you play to the server (now-playing and play counts). Disable to listen anonymously.'**
  String get playbackSettingsScrobbleSubtitle;

  /// No description provided for @playbackSettingsLrclibTitle.
  ///
  /// In en, this message translates to:
  /// **'Use LRCLIB fallback'**
  String get playbackSettingsLrclibTitle;

  /// No description provided for @playbackSettingsLrclibSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When server lyrics are unavailable, try LRCLIB and cache per song.'**
  String get playbackSettingsLrclibSubtitle;

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

  /// No description provided for @playbackSettingsLegacyInstantMixTitle.
  ///
  /// In en, this message translates to:
  /// **'Legacy Instant Mix'**
  String get playbackSettingsLegacyInstantMixTitle;

  /// No description provided for @playbackSettingsLegacyInstantMixSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use local-only similar songs instead of Last.fm recommendations.'**
  String get playbackSettingsLegacyInstantMixSubtitle;

  /// No description provided for @playbackSettingsLegacyInstantMixLocked.
  ///
  /// In en, this message translates to:
  /// **'This build has no Last.fm API key, so Legacy Instant Mix is required.'**
  String get playbackSettingsLegacyInstantMixLocked;

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
  /// **'Android Audio Effects'**
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

  /// No description provided for @playbackSettingsCrossfadeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Cross-fade'**
  String get playbackSettingsCrossfadeSectionTitle;

  /// No description provided for @playbackSettingsCrossfadeEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable cross-fade'**
  String get playbackSettingsCrossfadeEnableTitle;

  /// No description provided for @playbackSettingsCrossfadeEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Smoothly blend the end of one track into the start of the next.'**
  String get playbackSettingsCrossfadeEnableSubtitle;

  /// No description provided for @playbackSettingsCrossfadeDurationLabel.
  ///
  /// In en, this message translates to:
  /// **'Duration: {seconds}s'**
  String playbackSettingsCrossfadeDurationLabel(int seconds);

  /// No description provided for @playbackSettingsCrossfadeTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Cross-fade mode'**
  String get playbackSettingsCrossfadeTypeLabel;

  /// No description provided for @playbackSettingsCrossfadeTypeNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get playbackSettingsCrossfadeTypeNormal;

  /// No description provided for @playbackSettingsCrossfadeTypeNormalDescription.
  ///
  /// In en, this message translates to:
  /// **'Cross-fade between every track.'**
  String get playbackSettingsCrossfadeTypeNormalDescription;

  /// No description provided for @playbackSettingsCrossfadeTypeSmart.
  ///
  /// In en, this message translates to:
  /// **'Smart'**
  String get playbackSettingsCrossfadeTypeSmart;

  /// No description provided for @playbackSettingsCrossfadeTypeSmartDescription.
  ///
  /// In en, this message translates to:
  /// **'Only cross-fade between tracks from different albums.'**
  String get playbackSettingsCrossfadeTypeSmartDescription;

  /// No description provided for @playbackSettingsCrossfadeGaplessWarning.
  ///
  /// In en, this message translates to:
  /// **'Crossfade and gapless playback are both enabled. These features conflict — crossfade may not work correctly. Consider disabling one.'**
  String get playbackSettingsCrossfadeGaplessWarning;

  /// No description provided for @playbackSettingsReplayGainSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Volume Normalization (ReplayGain)'**
  String get playbackSettingsReplayGainSectionTitle;

  /// No description provided for @playbackSettingsReplayGainModeLabel.
  ///
  /// In en, this message translates to:
  /// **'ReplayGain mode'**
  String get playbackSettingsReplayGainModeLabel;

  /// No description provided for @playbackSettingsReplayGainModeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get playbackSettingsReplayGainModeOff;

  /// No description provided for @playbackSettingsReplayGainModeOffDescription.
  ///
  /// In en, this message translates to:
  /// **'No volume normalization applied.'**
  String get playbackSettingsReplayGainModeOffDescription;

  /// No description provided for @playbackSettingsReplayGainModeTrack.
  ///
  /// In en, this message translates to:
  /// **'Track'**
  String get playbackSettingsReplayGainModeTrack;

  /// No description provided for @playbackSettingsReplayGainModeTrackDescription.
  ///
  /// In en, this message translates to:
  /// **'Normalize volume on a per-track basis.'**
  String get playbackSettingsReplayGainModeTrackDescription;

  /// No description provided for @playbackSettingsReplayGainModeAlbum.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get playbackSettingsReplayGainModeAlbum;

  /// No description provided for @playbackSettingsReplayGainModeAlbumDescription.
  ///
  /// In en, this message translates to:
  /// **'Normalize volume on a per-album basis, preserving relative loudness.'**
  String get playbackSettingsReplayGainModeAlbumDescription;

  /// No description provided for @playbackSettingsReplayGainPreampLabel.
  ///
  /// In en, this message translates to:
  /// **'Pre-amp (dB)'**
  String get playbackSettingsReplayGainPreampLabel;

  /// No description provided for @playbackSettingsReplayGainPreampSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Additional gain adjustment. Range: −6 to +6 dB.'**
  String get playbackSettingsReplayGainPreampSubtitle;

  /// No description provided for @playbackSettingsPlaybackSpeedLabel.
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get playbackSettingsPlaybackSpeedLabel;

  /// No description provided for @playbackSettingsPlaybackSpeedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adjust playback tempo (0.5× – 2.0×). Default: 1.0×.'**
  String get playbackSettingsPlaybackSpeedSubtitle;

  /// No description provided for @playbackSettingsAlbumQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Album Queue'**
  String get playbackSettingsAlbumQueueTitle;

  /// No description provided for @playbackSettingsAlbumQueueSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tapping a track in an album queues the entire album and starts playback at that track.'**
  String get playbackSettingsAlbumQueueSubtitle;

  /// No description provided for @playbackSettingsLikedQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked Queue'**
  String get playbackSettingsLikedQueueTitle;

  /// No description provided for @playbackSettingsLikedQueueSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tapping a track on the Liked page queues all your liked songs and starts at that track.'**
  String get playbackSettingsLikedQueueSubtitle;

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

  /// No description provided for @homeContinueListeningTitle.
  ///
  /// In en, this message translates to:
  /// **'Continue listening'**
  String get homeContinueListeningTitle;

  /// No description provided for @homeContinueListeningResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get homeContinueListeningResume;

  /// No description provided for @homeContinueListeningOpenNowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Open player'**
  String get homeContinueListeningOpenNowPlaying;

  /// No description provided for @homeRecentlyLikedAlbumsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently liked albums'**
  String get homeRecentlyLikedAlbumsTitle;

  /// No description provided for @homeRecentlyLikedAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No liked albums yet'**
  String get homeRecentlyLikedAlbumsEmptyTitle;

  /// No description provided for @homeRecentlyLikedAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like albums to pin your favorites here.'**
  String get homeRecentlyLikedAlbumsEmptySubtitle;

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
  /// **'Frequent albums'**
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
  /// **'You Might Like'**
  String get homeRandomTitle;

  /// No description provided for @homeRandomEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recommendations available'**
  String get homeRandomEmptyTitle;

  /// No description provided for @homeRandomEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like more songs or pull to refresh to discover new picks.'**
  String get homeRandomEmptySubtitle;

  /// No description provided for @homeStarredTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked tracks'**
  String get homeStarredTitle;

  /// No description provided for @homeStarredEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No liked tracks'**
  String get homeStarredEmptyTitle;

  /// No description provided for @homeStarredEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like tracks on your server to see them here.'**
  String get homeStarredEmptySubtitle;

  /// No description provided for @homeSeeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get homeSeeAll;

  /// No description provided for @homeMostPlayedTracksTitle.
  ///
  /// In en, this message translates to:
  /// **'Most played tracks'**
  String get homeMostPlayedTracksTitle;

  /// No description provided for @homeMostPlayedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No play data yet'**
  String get homeMostPlayedTracksEmptyTitle;

  /// No description provided for @homeMostPlayedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Play more music to populate this section.'**
  String get homeMostPlayedTracksEmptySubtitle;

  /// No description provided for @homeRecentlyPlayedTracksTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently played tracks'**
  String get homeRecentlyPlayedTracksTitle;

  /// No description provided for @homeRecentlyPlayedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recently played tracks'**
  String get homeRecentlyPlayedTracksEmptyTitle;

  /// No description provided for @homeRecentlyPlayedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start listening to populate this section.'**
  String get homeRecentlyPlayedTracksEmptySubtitle;

  /// No description provided for @homeRecentlyPlayedAlbumsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently played albums'**
  String get homeRecentlyPlayedAlbumsTitle;

  /// No description provided for @homeRecentlyPlayedAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recently played albums'**
  String get homeRecentlyPlayedAlbumsEmptyTitle;

  /// No description provided for @homeRecentlyPlayedAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start listening to populate this section.'**
  String get homeRecentlyPlayedAlbumsEmptySubtitle;

  /// No description provided for @homeQuickActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get homeQuickActionsTitle;

  /// No description provided for @homeQuickActionShuffleLiked.
  ///
  /// In en, this message translates to:
  /// **'Shuffle liked'**
  String get homeQuickActionShuffleLiked;

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

  /// No description provided for @radioStopStation.
  ///
  /// In en, this message translates to:
  /// **'Stop radio'**
  String get radioStopStation;

  /// No description provided for @radioPlaybackError.
  ///
  /// In en, this message translates to:
  /// **'Could not play this radio station.'**
  String get radioPlaybackError;

  /// No description provided for @radioStreamUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Radio stream unavailable.'**
  String get radioStreamUnavailable;

  /// No description provided for @radioNowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Now playing on radio'**
  String get radioNowPlaying;

  /// No description provided for @radioLive.
  ///
  /// In en, this message translates to:
  /// **'LIVE'**
  String get radioLive;

  /// No description provided for @serverSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get serverSettingsTitle;

  /// No description provided for @serverSettingsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load server settings.'**
  String get serverSettingsLoadError;

  /// No description provided for @serverSettingsSaveError.
  ///
  /// In en, this message translates to:
  /// **'Failed to save. Please try again.'**
  String get serverSettingsSaveError;

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

  /// No description provided for @configurationServerSection.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get configurationServerSection;

  /// No description provided for @configurationExternalServicesSection.
  ///
  /// In en, this message translates to:
  /// **'External services'**
  String get configurationExternalServicesSection;

  /// No description provided for @configurationLastFmSection.
  ///
  /// In en, this message translates to:
  /// **'Last.fm'**
  String get configurationLastFmSection;

  /// No description provided for @configurationLastFmApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get configurationLastFmApiKeyLabel;

  /// No description provided for @configurationLastFmApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Paste your Last.fm API key here'**
  String get configurationLastFmApiKeyHint;

  /// No description provided for @configurationLastFmGetApiKey.
  ///
  /// In en, this message translates to:
  /// **'Get API Key'**
  String get configurationLastFmGetApiKey;

  /// No description provided for @configurationLastFmApiKeySaved.
  ///
  /// In en, this message translates to:
  /// **'Last.fm API key saved.'**
  String get configurationLastFmApiKeySaved;

  /// No description provided for @configurationLastFmApiKeyCleared.
  ///
  /// In en, this message translates to:
  /// **'Last.fm API key removed.'**
  String get configurationLastFmApiKeyCleared;

  /// No description provided for @configurationLastFmBundledNotice.
  ///
  /// In en, this message translates to:
  /// **'API key bundled with this build'**
  String get configurationLastFmBundledNotice;

  /// No description provided for @configurationLastFmBundledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This build includes a Last.fm API key. You do not need to provide your own.'**
  String get configurationLastFmBundledSubtitle;

  /// No description provided for @commonQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get commonQueued;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

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

  /// No description provided for @libraryTabLiked.
  ///
  /// In en, this message translates to:
  /// **'Liked'**
  String get libraryTabLiked;

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

  /// No description provided for @libraryLikedAlbumsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked Albums'**
  String get libraryLikedAlbumsSectionTitle;

  /// No description provided for @libraryLikedAlbumsSeeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get libraryLikedAlbumsSeeAll;

  /// No description provided for @libraryLikedAlbumsAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked Albums'**
  String get libraryLikedAlbumsAllTitle;

  /// No description provided for @libraryLikedSongsSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked Songs'**
  String get libraryLikedSongsSectionTitle;

  /// No description provided for @libraryLikedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing liked yet'**
  String get libraryLikedEmptyTitle;

  /// No description provided for @libraryLikedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like albums or songs to see them here.'**
  String get libraryLikedEmptySubtitle;

  /// No description provided for @libraryLikedOnlyFilter.
  ///
  /// In en, this message translates to:
  /// **'Liked'**
  String get libraryLikedOnlyFilter;

  /// No description provided for @libraryLikedOnlyEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No liked matches'**
  String get libraryLikedOnlyEmptyTitle;

  /// No description provided for @libraryLikedOnlyEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try turning off the liked filter or like more content.'**
  String get libraryLikedOnlyEmptySubtitle;

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

  /// No description provided for @libraryAlbumsByYearEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No albums with year data'**
  String get libraryAlbumsByYearEmptyTitle;

  /// No description provided for @libraryAlbumsByYearEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync more metadata or change filters to browse by year.'**
  String get libraryAlbumsByYearEmptySubtitle;

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

  /// No description provided for @librarySortRecentlyAdded.
  ///
  /// In en, this message translates to:
  /// **'Recently Added'**
  String get librarySortRecentlyAdded;

  /// No description provided for @librarySortNewest.
  ///
  /// In en, this message translates to:
  /// **'Newest (Year)'**
  String get librarySortNewest;

  /// No description provided for @librarySortByYear.
  ///
  /// In en, this message translates to:
  /// **'By Year'**
  String get librarySortByYear;

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

  /// No description provided for @artistDetailFeaturedSection.
  ///
  /// In en, this message translates to:
  /// **'Featured In'**
  String get artistDetailFeaturedSection;

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

  /// No description provided for @artistTopTracksSection.
  ///
  /// In en, this message translates to:
  /// **'Top Tracks'**
  String get artistTopTracksSection;

  /// No description provided for @artistTopTracksShowMore.
  ///
  /// In en, this message translates to:
  /// **'Show more'**
  String get artistTopTracksShowMore;

  /// No description provided for @artistTopTracksShowLess.
  ///
  /// In en, this message translates to:
  /// **'Show less'**
  String get artistTopTracksShowLess;

  /// Formatted listener count for a Last.fm top track, e.g. '1.2M listeners'.
  ///
  /// In en, this message translates to:
  /// **'{count} listeners'**
  String artistTopTracksListeners(String count);

  /// No description provided for @artistTopTracksNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Track not available in your library.'**
  String get artistTopTracksNotAvailable;

  /// No description provided for @artistTopTracksPlayError.
  ///
  /// In en, this message translates to:
  /// **'Could not play track. Try again.'**
  String get artistTopTracksPlayError;

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

  /// No description provided for @albumDetailLikedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No liked tracks in this album'**
  String get albumDetailLikedTracksEmptyTitle;

  /// No description provided for @albumDetailLikedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'None of the tracks in this album have been liked yet.'**
  String get albumDetailLikedTracksEmptySubtitle;

  /// No description provided for @albumDetailShowAllTracksAction.
  ///
  /// In en, this message translates to:
  /// **'Show all tracks'**
  String get albumDetailShowAllTracksAction;

  /// Label above the filter chips in the album detail screen
  ///
  /// In en, this message translates to:
  /// **'Filters'**
  String get albumDetailFilterLabel;

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
  /// **'Like'**
  String get albumDetailStarAction;

  /// No description provided for @albumDetailDownloadAction.
  ///
  /// In en, this message translates to:
  /// **'Download Album'**
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

  /// No description provided for @albumDetailStarFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not update like status.'**
  String get albumDetailStarFailure;

  /// No description provided for @albumDetailAboutSection.
  ///
  /// In en, this message translates to:
  /// **'About this album'**
  String get albumDetailAboutSection;

  /// No description provided for @albumDetailMenuShowAlbumArt.
  ///
  /// In en, this message translates to:
  /// **'Show album art'**
  String get albumDetailMenuShowAlbumArt;

  /// No description provided for @albumDetailLastFm.
  ///
  /// In en, this message translates to:
  /// **'Last.fm'**
  String get albumDetailLastFm;

  /// No description provided for @albumDetailMusicBrainz.
  ///
  /// In en, this message translates to:
  /// **'MusicBrainz'**
  String get albumDetailMusicBrainz;

  /// No description provided for @albumDetailDiscHeader.
  ///
  /// In en, this message translates to:
  /// **'Disc {number}'**
  String albumDetailDiscHeader(int number);

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

  /// No description provided for @miniPlayerSkipNext.
  ///
  /// In en, this message translates to:
  /// **'Skip to next'**
  String get miniPlayerSkipNext;

  /// No description provided for @playbackBootstrapLoadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Preparing playback'**
  String get playbackBootstrapLoadingTitle;

  /// No description provided for @playbackBootstrapLoadingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restoring your listening session…'**
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

  /// No description provided for @commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get commonLoading;

  /// No description provided for @queueTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queueTitle;

  /// No description provided for @queueUnknownTrack.
  ///
  /// In en, this message translates to:
  /// **'Unknown track'**
  String get queueUnknownTrack;

  /// No description provided for @queueUnknownArtist.
  ///
  /// In en, this message translates to:
  /// **'Unknown artist'**
  String get queueUnknownArtist;

  /// No description provided for @queueTrackLoadError.
  ///
  /// In en, this message translates to:
  /// **'Error loading track'**
  String get queueTrackLoadError;

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

  /// No description provided for @nowPlayingTitle.
  ///
  /// In en, this message translates to:
  /// **'Now Playing'**
  String get nowPlayingTitle;

  /// No description provided for @nowPlayingUnknownTrack.
  ///
  /// In en, this message translates to:
  /// **'Unknown track'**
  String get nowPlayingUnknownTrack;

  /// No description provided for @nowPlayingUnknownArtist.
  ///
  /// In en, this message translates to:
  /// **'Unknown artist'**
  String get nowPlayingUnknownArtist;

  /// No description provided for @nowPlayingUnknownAlbum.
  ///
  /// In en, this message translates to:
  /// **'Unknown album'**
  String get nowPlayingUnknownAlbum;

  /// No description provided for @nowPlayingShuffle.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get nowPlayingShuffle;

  /// No description provided for @nowPlayingShuffleOff.
  ///
  /// In en, this message translates to:
  /// **'Shuffle off'**
  String get nowPlayingShuffleOff;

  /// No description provided for @nowPlayingPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get nowPlayingPrevious;

  /// No description provided for @nowPlayingPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get nowPlayingPlay;

  /// No description provided for @nowPlayingPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get nowPlayingPause;

  /// No description provided for @nowPlayingNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get nowPlayingNext;

  /// No description provided for @nowPlayingRepeatOff.
  ///
  /// In en, this message translates to:
  /// **'Repeat off'**
  String get nowPlayingRepeatOff;

  /// No description provided for @nowPlayingRepeatAll.
  ///
  /// In en, this message translates to:
  /// **'Repeat all'**
  String get nowPlayingRepeatAll;

  /// No description provided for @nowPlayingRepeatOne.
  ///
  /// In en, this message translates to:
  /// **'Repeat one'**
  String get nowPlayingRepeatOne;

  /// No description provided for @nowPlayingStar.
  ///
  /// In en, this message translates to:
  /// **'Like'**
  String get nowPlayingStar;

  /// No description provided for @nowPlayingLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get nowPlayingLyrics;

  /// No description provided for @nowPlayingQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get nowPlayingQueue;

  /// No description provided for @nowPlayingQueuePosition.
  ///
  /// In en, this message translates to:
  /// **'Playing {current} of {total}'**
  String nowPlayingQueuePosition(int current, int total);

  /// No description provided for @nowPlayingInstantMix.
  ///
  /// In en, this message translates to:
  /// **'Start Instant Mix'**
  String get nowPlayingInstantMix;

  /// No description provided for @nowPlayingInstantMixLabel.
  ///
  /// In en, this message translates to:
  /// **'Instant Mix'**
  String get nowPlayingInstantMixLabel;

  /// No description provided for @nowPlayingInstantMixStop.
  ///
  /// In en, this message translates to:
  /// **'Stop Instant Mix'**
  String get nowPlayingInstantMixStop;

  /// No description provided for @nowPlayingInstantMixActive.
  ///
  /// In en, this message translates to:
  /// **'Instant Mix — tap to stop'**
  String get nowPlayingInstantMixActive;

  /// No description provided for @nowPlayingInstantMixDescription.
  ///
  /// In en, this message translates to:
  /// **'Classic similar-song queueing'**
  String get nowPlayingInstantMixDescription;

  /// No description provided for @nowPlayingInstantMixStarted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No similar tracks found.} =1{Instant Mix started — 1 similar track queued.} other{Instant Mix started — {count} similar tracks queued.}}'**
  String nowPlayingInstantMixStarted(int count);

  /// No description provided for @nowPlayingInstantMixUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Your server doesn\'t support Instant Mix.'**
  String get nowPlayingInstantMixUnsupported;

  /// No description provided for @nowPlayingInstantMixError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start Instant Mix.'**
  String get nowPlayingInstantMixError;

  /// No description provided for @nowPlayingSameVibesLabel.
  ///
  /// In en, this message translates to:
  /// **'Same Vibes'**
  String get nowPlayingSameVibesLabel;

  /// No description provided for @nowPlayingSameVibesDescription.
  ///
  /// In en, this message translates to:
  /// **'Last.fm similar-song queueing'**
  String get nowPlayingSameVibesDescription;

  /// No description provided for @nowPlayingSameVibesStarted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No similar tracks found.} =1{Same Vibes started — 1 similar track queued.} other{Same Vibes started — {count} similar tracks queued.}}'**
  String nowPlayingSameVibesStarted(int count);

  /// No description provided for @nowPlayingSameVibesUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Your server doesn\'t support similar-track lookups.'**
  String get nowPlayingSameVibesUnsupported;

  /// No description provided for @nowPlayingSameVibesError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start Same Vibes.'**
  String get nowPlayingSameVibesError;

  /// No description provided for @nowPlayingSameVibesStopped.
  ///
  /// In en, this message translates to:
  /// **'Same Vibes stopped.'**
  String get nowPlayingSameVibesStopped;

  /// No description provided for @nowPlayingMixTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue modes'**
  String get nowPlayingMixTitle;

  /// No description provided for @nowPlayingMixSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose how similar tracks should be added next.'**
  String get nowPlayingMixSubtitle;

  /// No description provided for @nowPlayingMore.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get nowPlayingMore;

  /// No description provided for @nowPlayingGoToAlbum.
  ///
  /// In en, this message translates to:
  /// **'Go to album'**
  String get nowPlayingGoToAlbum;

  /// No description provided for @nowPlayingGoToArtist.
  ///
  /// In en, this message translates to:
  /// **'Go to artist'**
  String get nowPlayingGoToArtist;

  /// No description provided for @nowPlayingAudioQuality.
  ///
  /// In en, this message translates to:
  /// **'Audio quality'**
  String get nowPlayingAudioQuality;

  /// No description provided for @nowPlayingReleaseDate.
  ///
  /// In en, this message translates to:
  /// **'Release date'**
  String get nowPlayingReleaseDate;

  /// No description provided for @lyricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get lyricsTitle;

  /// No description provided for @lyricsNoneAvailable.
  ///
  /// In en, this message translates to:
  /// **'No lyrics available'**
  String get lyricsNoneAvailable;

  /// No description provided for @lyricsError.
  ///
  /// In en, this message translates to:
  /// **'Could not load lyrics. Check your connection.'**
  String get lyricsError;

  /// No description provided for @lyricsUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Lyrics not supported by this server.'**
  String get lyricsUnsupported;

  /// No description provided for @lyricsSourceServerSynced.
  ///
  /// In en, this message translates to:
  /// **'Lyrics source: Server (synced)'**
  String get lyricsSourceServerSynced;

  /// No description provided for @lyricsSourceServerPlain.
  ///
  /// In en, this message translates to:
  /// **'Lyrics source: Server'**
  String get lyricsSourceServerPlain;

  /// No description provided for @lyricsSourceLrclibSynced.
  ///
  /// In en, this message translates to:
  /// **'Lyrics source: LRCLIB (synced)'**
  String get lyricsSourceLrclibSynced;

  /// No description provided for @lyricsSourceLrclibPlain.
  ///
  /// In en, this message translates to:
  /// **'Lyrics source: LRCLIB'**
  String get lyricsSourceLrclibPlain;

  /// No description provided for @lyricsAttributionLrclib.
  ///
  /// In en, this message translates to:
  /// **'Lyrics provided by LRCLIB'**
  String get lyricsAttributionLrclib;

  /// No description provided for @ratingTitle.
  ///
  /// In en, this message translates to:
  /// **'Rating'**
  String get ratingTitle;

  /// No description provided for @ratingHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a star to set or clear'**
  String get ratingHint;

  /// No description provided for @ratingNoValue.
  ///
  /// In en, this message translates to:
  /// **'No rating'**
  String get ratingNoValue;

  /// No description provided for @ratingNotLiked.
  ///
  /// In en, this message translates to:
  /// **'Not liked'**
  String get ratingNotLiked;

  /// No description provided for @ratingValueShort.
  ///
  /// In en, this message translates to:
  /// **'{rating}/5'**
  String ratingValueShort(int rating);

  /// No description provided for @ratingUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update rating.'**
  String get ratingUpdateFailed;

  /// No description provided for @queueSaveAsPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Save as playlist'**
  String get queueSaveAsPlaylist;

  /// No description provided for @queueSaveAsPlaylistName.
  ///
  /// In en, this message translates to:
  /// **'Playlist name'**
  String get queueSaveAsPlaylistName;

  /// No description provided for @queueSaveAsPlaylistSaved.
  ///
  /// In en, this message translates to:
  /// **'Playlist saved'**
  String get queueSaveAsPlaylistSaved;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search artists, albums, songs...'**
  String get searchHint;

  /// No description provided for @searchRecentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent searches'**
  String get searchRecentTitle;

  /// No description provided for @searchClearRecent.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchClearRecent;

  /// No description provided for @searchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get searchNoResults;

  /// No description provided for @searchNoResultsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a different search term.'**
  String get searchNoResultsSubtitle;

  /// No description provided for @searchArtistsSection.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get searchArtistsSection;

  /// No description provided for @searchAlbumsSection.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get searchAlbumsSection;

  /// No description provided for @searchSongsSection.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get searchSongsSection;

  /// No description provided for @searchShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get searchShowAll;

  /// No description provided for @searchShowLess.
  ///
  /// In en, this message translates to:
  /// **'Show less'**
  String get searchShowLess;

  /// No description provided for @searchAlbumCount.
  ///
  /// In en, this message translates to:
  /// **'{count} albums'**
  String searchAlbumCount(int count);

  /// No description provided for @searchPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Play next'**
  String get searchPlayNext;

  /// No description provided for @searchAddToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get searchAddToQueue;

  /// No description provided for @searchFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get searchFilterAll;

  /// No description provided for @searchLocalOfflineBanner.
  ///
  /// In en, this message translates to:
  /// **'Searching local library (offline)'**
  String get searchLocalOfflineBanner;

  /// No description provided for @playlistsTitle.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get playlistsTitle;

  /// No description provided for @playlistsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No playlists yet'**
  String get playlistsEmpty;

  /// No description provided for @playlistsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a playlist to get started.'**
  String get playlistsEmptySubtitle;

  /// No description provided for @playlistsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load playlists'**
  String get playlistsLoadError;

  /// No description provided for @playlistsSongCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No songs} =1{1 song} other{{count} songs}}'**
  String playlistsSongCount(int count);

  /// No description provided for @playlistsCreateAction.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get playlistsCreateAction;

  /// No description provided for @playlistsCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'Create playlist'**
  String get playlistsCreateTitle;

  /// No description provided for @playlistsCreateNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Playlist name'**
  String get playlistsCreateNameLabel;

  /// No description provided for @playlistsCreateSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playlist created'**
  String get playlistsCreateSuccess;

  /// No description provided for @playlistsCreateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create playlist'**
  String get playlistsCreateFailed;

  /// No description provided for @playlistsDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete playlist?'**
  String get playlistsDeleteConfirmTitle;

  /// No description provided for @playlistsDeleteConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete \"{name}\".'**
  String playlistsDeleteConfirmMessage(String name);

  /// No description provided for @playlistsDeleteSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playlist deleted'**
  String get playlistsDeleteSuccess;

  /// No description provided for @playlistsDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete playlist'**
  String get playlistsDeleteFailed;

  /// No description provided for @playlistsRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename playlist'**
  String get playlistsRenameTitle;

  /// No description provided for @playlistsRenameLabel.
  ///
  /// In en, this message translates to:
  /// **'New name'**
  String get playlistsRenameLabel;

  /// No description provided for @playlistsRenameSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playlist renamed'**
  String get playlistsRenameSuccess;

  /// No description provided for @playlistsRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to rename playlist'**
  String get playlistsRenameFailed;

  /// No description provided for @playlistDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Playlist'**
  String get playlistDetailTitle;

  /// No description provided for @playlistDetailPlayAction.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get playlistDetailPlayAction;

  /// No description provided for @playlistDetailShuffleAction.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get playlistDetailShuffleAction;

  /// No description provided for @playlistDetailMeta.
  ///
  /// In en, this message translates to:
  /// **'{owner} · {count, plural, =0{No songs} =1{1 song} other{{count} songs}}'**
  String playlistDetailMeta(String owner, int count);

  /// No description provided for @playlistDetailNotFound.
  ///
  /// In en, this message translates to:
  /// **'Playlist not found'**
  String get playlistDetailNotFound;

  /// No description provided for @playlistDetailNotFoundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'It may have been deleted.'**
  String get playlistDetailNotFoundSubtitle;

  /// No description provided for @playlistDetailLoadError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load playlist'**
  String get playlistDetailLoadError;

  /// No description provided for @playlistDetailEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No tracks'**
  String get playlistDetailEmptyTitle;

  /// No description provided for @playlistDetailEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add songs from the library.'**
  String get playlistDetailEmptySubtitle;

  /// No description provided for @playlistDetailRemoveTrack.
  ///
  /// In en, this message translates to:
  /// **'Remove from playlist'**
  String get playlistDetailRemoveTrack;

  /// No description provided for @playlistDetailTrackRemoved.
  ///
  /// In en, this message translates to:
  /// **'Track removed'**
  String get playlistDetailTrackRemoved;

  /// No description provided for @playlistDetailTrackRemoveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to remove track'**
  String get playlistDetailTrackRemoveFailed;

  /// No description provided for @addToPlaylistTitle.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get addToPlaylistTitle;

  /// No description provided for @addToPlaylistSuccess.
  ///
  /// In en, this message translates to:
  /// **'Added to \"{name}\"'**
  String addToPlaylistSuccess(String name);

  /// No description provided for @addToPlaylistFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to add to playlist'**
  String get addToPlaylistFailed;

  /// No description provided for @addToPlaylistNewPlaylist.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get addToPlaylistNewPlaylist;

  /// No description provided for @librarySongMenuAddToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get librarySongMenuAddToPlaylist;

  /// No description provided for @cacheSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Cache & Storage'**
  String get cacheSettingsTitle;

  /// No description provided for @cacheSettingsRollingSection.
  ///
  /// In en, this message translates to:
  /// **'Streaming cache'**
  String get cacheSettingsRollingSection;

  /// No description provided for @cacheSettingsRollingDescription.
  ///
  /// In en, this message translates to:
  /// **'Recently streamed tracks are cached automatically. Oldest tracks are evicted when the budget is exceeded.'**
  String get cacheSettingsRollingDescription;

  /// No description provided for @cacheSettingsRollingBudgetLabel.
  ///
  /// In en, this message translates to:
  /// **'Cache budget'**
  String get cacheSettingsRollingBudgetLabel;

  /// No description provided for @cacheSettingsRollingCurrentSize.
  ///
  /// In en, this message translates to:
  /// **'{used} / {budget}'**
  String cacheSettingsRollingCurrentSize(String used, String budget);

  /// No description provided for @cacheSettingsRollingTrackCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No cached tracks} =1{1 cached track} other{{count} cached tracks}}'**
  String cacheSettingsRollingTrackCount(int count);

  /// No description provided for @cacheSettingsClearRolling.
  ///
  /// In en, this message translates to:
  /// **'Clear streaming cache'**
  String get cacheSettingsClearRolling;

  /// No description provided for @cacheSettingsClearRollingConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all cached streaming audio? This cannot be undone.'**
  String get cacheSettingsClearRollingConfirm;

  /// No description provided for @cacheSettingsPermanentSection.
  ///
  /// In en, this message translates to:
  /// **'Downloaded tracks'**
  String get cacheSettingsPermanentSection;

  /// No description provided for @cacheSettingsPermanentTrackCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No downloaded tracks} =1{1 downloaded track} other{{count} downloaded tracks}}'**
  String cacheSettingsPermanentTrackCount(int count);

  /// No description provided for @cacheSettingsClearPermanent.
  ///
  /// In en, this message translates to:
  /// **'Remove all downloads'**
  String get cacheSettingsClearPermanent;

  /// No description provided for @cacheSettingsClearPermanentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove all downloaded tracks? This cannot be undone.'**
  String get cacheSettingsClearPermanentConfirm;

  /// No description provided for @cacheSettingsClearCoverArt.
  ///
  /// In en, this message translates to:
  /// **'Clear cover art cache'**
  String get cacheSettingsClearCoverArt;

  /// No description provided for @cacheSettingsClearCoverArtConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all cached cover art images?'**
  String get cacheSettingsClearCoverArtConfirm;

  /// No description provided for @cacheSettingsClearSuccess.
  ///
  /// In en, this message translates to:
  /// **'Cache cleared.'**
  String get cacheSettingsClearSuccess;

  /// No description provided for @cacheSettingsBudgetSaved.
  ///
  /// In en, this message translates to:
  /// **'Cache budget updated.'**
  String get cacheSettingsBudgetSaved;

  /// No description provided for @cacheSettingsBudgetGb.
  ///
  /// In en, this message translates to:
  /// **'{gb} GB'**
  String cacheSettingsBudgetGb(String gb);

  /// No description provided for @cacheSettingsUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get cacheSettingsUnlimited;

  /// No description provided for @downloadQualityTitle.
  ///
  /// In en, this message translates to:
  /// **'Download quality'**
  String get downloadQualityTitle;

  /// No description provided for @downloadQualityOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original quality'**
  String get downloadQualityOriginal;

  /// No description provided for @downloadQualityOriginalSub.
  ///
  /// In en, this message translates to:
  /// **'Lossless / as stored on server'**
  String get downloadQualityOriginalSub;

  /// No description provided for @downloadQuality320.
  ///
  /// In en, this message translates to:
  /// **'320 kbps MP3'**
  String get downloadQuality320;

  /// No description provided for @downloadQuality192.
  ///
  /// In en, this message translates to:
  /// **'192 kbps MP3'**
  String get downloadQuality192;

  /// No description provided for @downloadQuality128.
  ///
  /// In en, this message translates to:
  /// **'128 kbps MP3'**
  String get downloadQuality128;

  /// No description provided for @downloadAction.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get downloadAction;

  /// No description provided for @downloadSongQueued.
  ///
  /// In en, this message translates to:
  /// **'Download queued.'**
  String get downloadSongQueued;

  /// No description provided for @downloadAlbumQueued.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{All tracks already downloaded} =1{1 track queued for download} other{{count} tracks queued for download}}'**
  String downloadAlbumQueued(int count);

  /// No description provided for @downloadPlaylistQueued.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{All tracks already downloaded} =1{1 track queued for download} other{{count} tracks queued for download}}'**
  String downloadPlaylistQueued(int count);

  /// No description provided for @downloadsTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloadsTitle;

  /// No description provided for @downloadsTabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get downloadsTabSettings;

  /// No description provided for @downloadsTabQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get downloadsTabQueue;

  /// No description provided for @downloadsTabDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get downloadsTabDownloaded;

  /// No description provided for @downloadsQueueEmpty.
  ///
  /// In en, this message translates to:
  /// **'No pending downloads'**
  String get downloadsQueueEmpty;

  /// No description provided for @downloadsQueueEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download tracks from albums or playlists for offline listening.'**
  String get downloadsQueueEmptySubtitle;

  /// No description provided for @downloadsDownloadedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloaded tracks'**
  String get downloadsDownloadedEmpty;

  /// No description provided for @downloadsDownloadedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Downloaded tracks will appear here.'**
  String get downloadsDownloadedEmptySubtitle;

  /// No description provided for @downloadsRemoveAction.
  ///
  /// In en, this message translates to:
  /// **'Remove download'**
  String get downloadsRemoveAction;

  /// No description provided for @downloadsOpenFolderAction.
  ///
  /// In en, this message translates to:
  /// **'Open downloaded folder'**
  String get downloadsOpenFolderAction;

  /// No description provided for @downloadsOpenFolderError.
  ///
  /// In en, this message translates to:
  /// **'Could not open the downloaded folder.'**
  String get downloadsOpenFolderError;

  /// No description provided for @downloadsRedownloadOriginal.
  ///
  /// In en, this message translates to:
  /// **'Re-download in original quality'**
  String get downloadsRedownloadOriginal;

  /// No description provided for @downloadsRedownloadOriginalSub.
  ///
  /// In en, this message translates to:
  /// **'Replace with an untranscoded copy from server'**
  String get downloadsRedownloadOriginalSub;

  /// No description provided for @downloadsRedownloadQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued for re-download'**
  String get downloadsRedownloadQueued;

  /// No description provided for @downloadsChangeQuality.
  ///
  /// In en, this message translates to:
  /// **'Change Download Quality'**
  String get downloadsChangeQuality;

  /// No description provided for @downloadsChangeQualityCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {quality}'**
  String downloadsChangeQualityCurrent(String quality);

  /// No description provided for @downloadsCancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get downloadsCancelAction;

  /// No description provided for @downloadsClearCompleted.
  ///
  /// In en, this message translates to:
  /// **'Clear completed'**
  String get downloadsClearCompleted;

  /// No description provided for @downloadsRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry failed'**
  String get downloadsRetryFailed;

  /// No description provided for @downloadsStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get downloadsStatusFailed;

  /// No description provided for @downloadsRetryAllFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry all failed'**
  String get downloadsRetryAllFailed;

  /// No description provided for @downloadsErrorLoadingQueue.
  ///
  /// In en, this message translates to:
  /// **'Could not load download queue.'**
  String get downloadsErrorLoadingQueue;

  /// No description provided for @downloadsClearQueue.
  ///
  /// In en, this message translates to:
  /// **'Clear queue'**
  String get downloadsClearQueue;

  /// No description provided for @downloadsClearQueueConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove all queued downloads? Active downloads will be cancelled.'**
  String get downloadsClearQueueConfirm;

  /// No description provided for @downloadsQueueSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search queue...'**
  String get downloadsQueueSearchHint;

  /// No description provided for @downloadsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search downloads...'**
  String get downloadsSearchHint;

  /// No description provided for @downloadsCustomFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom Folder'**
  String get downloadsCustomFolderTitle;

  /// No description provided for @downloadsCustomFolderSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Store permanent downloads in a folder you choose. Existing downloads will be moved and renamed into artist folders.'**
  String get downloadsCustomFolderSubtitle;

  /// No description provided for @downloadsCustomFolderUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Custom download folders are not available on this platform.'**
  String get downloadsCustomFolderUnsupported;

  /// No description provided for @downloadsCustomFolderChooseAction.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get downloadsCustomFolderChooseAction;

  /// No description provided for @downloadsCustomFolderSaved.
  ///
  /// In en, this message translates to:
  /// **'Download folder updated.'**
  String get downloadsCustomFolderSaved;

  /// No description provided for @downloadsCustomFolderDisabled.
  ///
  /// In en, this message translates to:
  /// **'Custom download folder disabled.'**
  String get downloadsCustomFolderDisabled;

  /// No description provided for @downloadsCustomFolderUpdating.
  ///
  /// In en, this message translates to:
  /// **'Moving downloaded tracks...'**
  String get downloadsCustomFolderUpdating;

  /// No description provided for @downloadsCustomFolderError.
  ///
  /// In en, this message translates to:
  /// **'Could not update download folder: {message}'**
  String downloadsCustomFolderError(String message);

  /// No description provided for @downloadsSearchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String downloadsSearchNoResults(String query);

  /// No description provided for @libraryDownloadedOnlyFilter.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get libraryDownloadedOnlyFilter;

  /// No description provided for @libraryDownloadedOnlyEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloaded content'**
  String get libraryDownloadedOnlyEmpty;

  /// No description provided for @libraryDownloadedOnlyEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download albums or tracks to see them here.'**
  String get libraryDownloadedOnlyEmptySubtitle;

  /// No description provided for @libraryUnknownYear.
  ///
  /// In en, this message translates to:
  /// **'Unknown year'**
  String get libraryUnknownYear;

  /// No description provided for @cacheSettingsWifiOnlyDownloads.
  ///
  /// In en, this message translates to:
  /// **'Download on Wi-Fi only'**
  String get cacheSettingsWifiOnlyDownloads;

  /// No description provided for @cacheSettingsWifiOnlyDownloadsSub.
  ///
  /// In en, this message translates to:
  /// **'Pause downloads when not connected to Wi-Fi.'**
  String get cacheSettingsWifiOnlyDownloadsSub;

  /// No description provided for @cacheSettingsAutoDownloadStarred.
  ///
  /// In en, this message translates to:
  /// **'Auto-download liked'**
  String get cacheSettingsAutoDownloadStarred;

  /// No description provided for @cacheSettingsAutoDownloadStarredSub.
  ///
  /// In en, this message translates to:
  /// **'Queue liked albums and songs for download automatically.'**
  String get cacheSettingsAutoDownloadStarredSub;

  /// No description provided for @cacheSettingsAutoDownloadCellularWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow liked downloads on mobile data?'**
  String get cacheSettingsAutoDownloadCellularWarningTitle;

  /// No description provided for @cacheSettingsAutoDownloadCellularWarning.
  ///
  /// In en, this message translates to:
  /// **'Your liked library can use a large amount of storage and mobile data when Wi-Fi-only downloads are off.'**
  String get cacheSettingsAutoDownloadCellularWarning;

  /// No description provided for @cacheSettingsAutoDownloadCellularWarningContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get cacheSettingsAutoDownloadCellularWarningContinue;

  /// No description provided for @cacheBadgeDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get cacheBadgeDownloaded;

  /// No description provided for @cacheBadgeCached.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get cacheBadgeCached;

  /// No description provided for @appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceTitle;

  /// No description provided for @appearanceThemeModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme Mode'**
  String get appearanceThemeModeLabel;

  /// No description provided for @appearanceThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceThemeLight;

  /// No description provided for @appearanceThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceThemeDark;

  /// No description provided for @appearanceThemeOled.
  ///
  /// In en, this message translates to:
  /// **'OLED'**
  String get appearanceThemeOled;

  /// No description provided for @appearanceThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get appearanceThemeSystem;

  /// No description provided for @appearanceLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get appearanceLanguageLabel;

  /// No description provided for @appearanceLanguageSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get appearanceLanguageSystemDefault;

  /// No description provided for @appearanceColorSchemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Color Scheme'**
  String get appearanceColorSchemeLabel;

  /// No description provided for @appearanceColorSchemeSub.
  ///
  /// In en, this message translates to:
  /// **'Choose a seed color for the app\'s color palette.'**
  String get appearanceColorSchemeSub;

  /// No description provided for @appearanceColorDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get appearanceColorDefault;

  /// No description provided for @appearanceColorCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get appearanceColorCustom;

  /// No description provided for @appearanceColorPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a custom color'**
  String get appearanceColorPickerTitle;

  /// No description provided for @appearanceColorPickerSave.
  ///
  /// In en, this message translates to:
  /// **'Save as preset'**
  String get appearanceColorPickerSave;

  /// No description provided for @appearanceColorPickerApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get appearanceColorPickerApply;

  /// No description provided for @appearanceColorPresetSaved.
  ///
  /// In en, this message translates to:
  /// **'Custom preset saved'**
  String get appearanceColorPresetSaved;

  /// No description provided for @appearanceColorPresetDeleted.
  ///
  /// In en, this message translates to:
  /// **'Custom preset deleted'**
  String get appearanceColorPresetDeleted;

  /// No description provided for @appearanceColorDeletePreset.
  ///
  /// In en, this message translates to:
  /// **'Delete preset'**
  String get appearanceColorDeletePreset;

  /// No description provided for @appearanceColorDeletePresetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this custom color preset?'**
  String get appearanceColorDeletePresetConfirm;

  /// No description provided for @appearanceLongPressHint.
  ///
  /// In en, this message translates to:
  /// **'{label} (long-press to delete)'**
  String appearanceLongPressHint(Object label);

  /// No description provided for @appearanceArtTintedLabel.
  ///
  /// In en, this message translates to:
  /// **'Art-tinted Now Playing'**
  String get appearanceArtTintedLabel;

  /// No description provided for @appearanceArtTintedSub.
  ///
  /// In en, this message translates to:
  /// **'Tint the Now Playing background with colours from the album art.'**
  String get appearanceArtTintedSub;

  /// No description provided for @cacheSettingsCoverArtSection.
  ///
  /// In en, this message translates to:
  /// **'Cover art cache'**
  String get cacheSettingsCoverArtSection;

  /// No description provided for @cacheSettingsCoverArtDescription.
  ///
  /// In en, this message translates to:
  /// **'Cached album artwork images. Larger limits reduce network requests but use more storage.'**
  String get cacheSettingsCoverArtDescription;

  /// No description provided for @cacheSettingsCoverArtMaxLabel.
  ///
  /// In en, this message translates to:
  /// **'Maximum images'**
  String get cacheSettingsCoverArtMaxLabel;

  /// No description provided for @cacheSettingsCoverArtMaxValue.
  ///
  /// In en, this message translates to:
  /// **'{count} images'**
  String cacheSettingsCoverArtMaxValue(int count);

  /// No description provided for @cacheSettingsCoverArtMaxSaved.
  ///
  /// In en, this message translates to:
  /// **'Cover art cache limit updated.'**
  String get cacheSettingsCoverArtMaxSaved;

  /// No description provided for @cacheSettingsCoverArtRestart.
  ///
  /// In en, this message translates to:
  /// **'Changes take effect after restarting the app.'**
  String get cacheSettingsCoverArtRestart;

  /// No description provided for @cacheSettingsCoverArtUnlimitedLabel.
  ///
  /// In en, this message translates to:
  /// **'No limit'**
  String get cacheSettingsCoverArtUnlimitedLabel;

  /// No description provided for @cacheSettingsCoverArtUnlimitedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Store all cover art on disk without restriction.'**
  String get cacheSettingsCoverArtUnlimitedSubtitle;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersion;

  /// No description provided for @aboutChangelog.
  ///
  /// In en, this message translates to:
  /// **'What\'s New'**
  String get aboutChangelog;

  /// No description provided for @aboutChangelogSub.
  ///
  /// In en, this message translates to:
  /// **'See what changed in this version.'**
  String get aboutChangelogSub;

  /// No description provided for @whatsNewTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s New'**
  String get whatsNewTitle;

  /// No description provided for @changelogEmpty.
  ///
  /// In en, this message translates to:
  /// **'No changelog entries yet.'**
  String get changelogEmpty;

  /// No description provided for @aboutLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get aboutLicenses;

  /// No description provided for @aboutLicensesSub.
  ///
  /// In en, this message translates to:
  /// **'View third-party software licenses.'**
  String get aboutLicensesSub;

  /// No description provided for @privacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacyTitle;

  /// No description provided for @privacySub.
  ///
  /// In en, this message translates to:
  /// **'How Navis handles app data and optional service sharing.'**
  String get privacySub;

  /// No description provided for @aboutCodename.
  ///
  /// In en, this message translates to:
  /// **'Cape Horn'**
  String get aboutCodename;

  /// No description provided for @aboutDataUsageTitle.
  ///
  /// In en, this message translates to:
  /// **'Data Usage'**
  String get aboutDataUsageTitle;

  /// No description provided for @aboutDataUsageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Local network usage estimates by feature and network type.'**
  String get aboutDataUsageSubtitle;

  /// No description provided for @aboutDataUsageToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get aboutDataUsageToday;

  /// No description provided for @aboutDataUsageSevenDays.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get aboutDataUsageSevenDays;

  /// No description provided for @aboutDataUsageThirtyDays.
  ///
  /// In en, this message translates to:
  /// **'Last 30 days'**
  String get aboutDataUsageThirtyDays;

  /// No description provided for @aboutDataUsageBreakdown.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days by feature'**
  String get aboutDataUsageBreakdown;

  /// No description provided for @aboutDataUsageEmpty.
  ///
  /// In en, this message translates to:
  /// **'No usage recorded yet.'**
  String get aboutDataUsageEmpty;

  /// No description provided for @aboutDataUsageLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading usage stats...'**
  String get aboutDataUsageLoading;

  /// No description provided for @aboutDataUsageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Usage stats unavailable.'**
  String get aboutDataUsageUnavailable;

  /// No description provided for @aboutDataUsageRequests.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No requests} =1{1 request} other{{count} requests}}'**
  String aboutDataUsageRequests(int count);

  /// No description provided for @aboutDataUsageReset.
  ///
  /// In en, this message translates to:
  /// **'Reset usage stats'**
  String get aboutDataUsageReset;

  /// No description provided for @aboutDataUsageResetConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset usage stats?'**
  String get aboutDataUsageResetConfirmTitle;

  /// No description provided for @aboutDataUsageResetConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This clears local network usage totals on this device.'**
  String get aboutDataUsageResetConfirmMessage;

  /// No description provided for @aboutDataUsageResetCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get aboutDataUsageResetCancel;

  /// No description provided for @aboutDataUsageResetConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get aboutDataUsageResetConfirmAction;

  /// No description provided for @aboutDataUsageResetComplete.
  ///
  /// In en, this message translates to:
  /// **'Usage stats reset.'**
  String get aboutDataUsageResetComplete;

  /// No description provided for @aboutDataUsageResetFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not reset usage stats.'**
  String get aboutDataUsageResetFailed;

  /// No description provided for @aboutDataUsageNetworkWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get aboutDataUsageNetworkWifi;

  /// No description provided for @aboutDataUsageNetworkMobile.
  ///
  /// In en, this message translates to:
  /// **'Mobile'**
  String get aboutDataUsageNetworkMobile;

  /// No description provided for @aboutDataUsageNetworkOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get aboutDataUsageNetworkOffline;

  /// No description provided for @aboutDataUsageNetworkOther.
  ///
  /// In en, this message translates to:
  /// **'Other network'**
  String get aboutDataUsageNetworkOther;

  /// No description provided for @aboutDataUsageCategoryAudioStreaming.
  ///
  /// In en, this message translates to:
  /// **'Audio streaming'**
  String get aboutDataUsageCategoryAudioStreaming;

  /// No description provided for @aboutDataUsageCategoryDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get aboutDataUsageCategoryDownloads;

  /// No description provided for @aboutDataUsageCategoryCoverArt.
  ///
  /// In en, this message translates to:
  /// **'Cover art'**
  String get aboutDataUsageCategoryCoverArt;

  /// No description provided for @aboutDataUsageCategoryLibrarySync.
  ///
  /// In en, this message translates to:
  /// **'Library sync'**
  String get aboutDataUsageCategoryLibrarySync;

  /// No description provided for @aboutDataUsageCategoryLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get aboutDataUsageCategoryLyrics;

  /// No description provided for @aboutDataUsageCategoryScrobbling.
  ///
  /// In en, this message translates to:
  /// **'Scrobbling'**
  String get aboutDataUsageCategoryScrobbling;

  /// No description provided for @aboutDataUsageCategoryRecommendations.
  ///
  /// In en, this message translates to:
  /// **'Recommendations'**
  String get aboutDataUsageCategoryRecommendations;

  /// No description provided for @aboutDataUsageCategoryUpdates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get aboutDataUsageCategoryUpdates;

  /// No description provided for @aboutDataUsageCategoryOtherApi.
  ///
  /// In en, this message translates to:
  /// **'Other API'**
  String get aboutDataUsageCategoryOtherApi;

  /// No description provided for @updateCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckTitle;

  /// No description provided for @updateCheckSub.
  ///
  /// In en, this message translates to:
  /// **'Currently on {version}. Tap to check now.'**
  String updateCheckSub(String version);

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailableTitle;

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'{version} is ready to download.'**
  String updateAvailableBody(String version);

  /// No description provided for @updateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get updateDownload;

  /// No description provided for @updateDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get updateDismiss;

  /// No description provided for @updateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Navis is up to date.'**
  String get updateUpToDate;

  /// No description provided for @updateInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get updateInstall;

  /// No description provided for @updateRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get updateRetry;

  /// No description provided for @updateReleaseNotes.
  ///
  /// In en, this message translates to:
  /// **'Release notes'**
  String get updateReleaseNotes;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading {version}…'**
  String updateDownloading(String version);

  /// No description provided for @updateReadyToInstall.
  ///
  /// In en, this message translates to:
  /// **'Download complete. Ready to install.'**
  String get updateReadyToInstall;

  /// No description provided for @updateDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed. Please try again.'**
  String get updateDownloadFailed;

  /// No description provided for @updateApplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not apply the update automatically.'**
  String get updateApplyFailed;

  /// No description provided for @updateReadyToRestart.
  ///
  /// In en, this message translates to:
  /// **'Download complete. Restart the app to apply the update.'**
  String get updateReadyToRestart;

  /// No description provided for @updateRestartAndUpdate.
  ///
  /// In en, this message translates to:
  /// **'Restart & Update'**
  String get updateRestartAndUpdate;

  /// No description provided for @updateApplying.
  ///
  /// In en, this message translates to:
  /// **'Applying update…'**
  String get updateApplying;

  /// No description provided for @updateNoWriteAccess.
  ///
  /// In en, this message translates to:
  /// **'Navis cannot update itself from this location. Please download manually.'**
  String get updateNoWriteAccess;

  /// No description provided for @updateSignatureMismatch.
  ///
  /// In en, this message translates to:
  /// **'This update is signed with a different key than your installed version. Uninstall Navis, then install the new version manually.'**
  String get updateSignatureMismatch;

  /// No description provided for @updateDownloadManually.
  ///
  /// In en, this message translates to:
  /// **'Download Manually'**
  String get updateDownloadManually;

  /// No description provided for @updateAutoCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatically check for updates'**
  String get updateAutoCheckTitle;

  /// No description provided for @updateAutoCheckSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Check for new releases on each app launch.'**
  String get updateAutoCheckSubtitle;

  /// No description provided for @updatesSettingsSectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updatesSettingsSectionLabel;

  /// No description provided for @updateChannelTitle.
  ///
  /// In en, this message translates to:
  /// **'Update channel'**
  String get updateChannelTitle;

  /// No description provided for @updateChannelStable.
  ///
  /// In en, this message translates to:
  /// **'Stable'**
  String get updateChannelStable;

  /// No description provided for @updateChannelBeta.
  ///
  /// In en, this message translates to:
  /// **'Beta'**
  String get updateChannelBeta;

  /// No description provided for @updateChannelBetaDescription.
  ///
  /// In en, this message translates to:
  /// **'Includes pre-release builds'**
  String get updateChannelBetaDescription;

  /// No description provided for @updateChannelDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Select update channel'**
  String get updateChannelDialogTitle;

  /// No description provided for @appearancePagesSectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Page Visibility'**
  String get appearancePagesSectionLabel;

  /// No description provided for @appearanceShowRadioPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Radio Tab'**
  String get appearanceShowRadioPageTitle;

  /// No description provided for @appearanceShowRadioPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show the Radio tab in the Library screen.'**
  String get appearanceShowRadioPageSubtitle;

  /// No description provided for @appearanceShowPlaylistsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Playlists Tab'**
  String get appearanceShowPlaylistsPageTitle;

  /// No description provided for @appearanceShowPlaylistsPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show the Playlists tab in the Library screen.'**
  String get appearanceShowPlaylistsPageSubtitle;

  /// No description provided for @appearanceShowArtistsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Artists Tab'**
  String get appearanceShowArtistsPageTitle;

  /// No description provided for @appearanceShowArtistsPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show the Artists tab in the Library screen.'**
  String get appearanceShowArtistsPageSubtitle;

  /// No description provided for @appearanceShowLikedPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Liked Tab'**
  String get appearanceShowLikedPageTitle;

  /// No description provided for @appearanceShowLikedPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show the Liked tab in the Library screen.'**
  String get appearanceShowLikedPageSubtitle;

  /// No description provided for @appearanceGridDensityLabel.
  ///
  /// In en, this message translates to:
  /// **'Grid Density'**
  String get appearanceGridDensityLabel;

  /// No description provided for @appearanceGridDensitySub.
  ///
  /// In en, this message translates to:
  /// **'Number of columns in album and artist grids.'**
  String get appearanceGridDensitySub;

  /// No description provided for @appearanceGridDensityAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get appearanceGridDensityAuto;

  /// No description provided for @appearanceGridDensityCompact.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get appearanceGridDensityCompact;

  /// No description provided for @appearanceGridDensityCozy.
  ///
  /// In en, this message translates to:
  /// **'Cozy'**
  String get appearanceGridDensityCozy;

  /// No description provided for @appearanceGridDensitySpaciousLabel.
  ///
  /// In en, this message translates to:
  /// **'Spacious'**
  String get appearanceGridDensitySpaciousLabel;

  /// No description provided for @appearanceCoverArtShapeLabel.
  ///
  /// In en, this message translates to:
  /// **'Cover Art Shape'**
  String get appearanceCoverArtShapeLabel;

  /// No description provided for @appearanceCoverArtShapeSubLabel.
  ///
  /// In en, this message translates to:
  /// **'Library & Carousel Art'**
  String get appearanceCoverArtShapeSubLabel;

  /// No description provided for @appearanceNpArtShapeLabel.
  ///
  /// In en, this message translates to:
  /// **'Now Playing Art'**
  String get appearanceNpArtShapeLabel;

  /// No description provided for @appearanceArtistCardShapeLabel.
  ///
  /// In en, this message translates to:
  /// **'Artist Card Art'**
  String get appearanceArtistCardShapeLabel;

  /// No description provided for @shapeSquare.
  ///
  /// In en, this message translates to:
  /// **'Square'**
  String get shapeSquare;

  /// No description provided for @shapeRounded.
  ///
  /// In en, this message translates to:
  /// **'Rounded'**
  String get shapeRounded;

  /// No description provided for @shapeCircle.
  ///
  /// In en, this message translates to:
  /// **'Circle'**
  String get shapeCircle;

  /// No description provided for @appearanceArtistViewModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Artist View Mode'**
  String get appearanceArtistViewModeLabel;

  /// No description provided for @appearanceArtistViewModeGrid.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get appearanceArtistViewModeGrid;

  /// No description provided for @appearanceArtistViewModeList.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get appearanceArtistViewModeList;

  /// No description provided for @appearanceHomeSectionsLabel.
  ///
  /// In en, this message translates to:
  /// **'Home Sections'**
  String get appearanceHomeSectionsLabel;

  /// No description provided for @appearanceHomeSectionsSub.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder, toggle to show or hide.'**
  String get appearanceHomeSectionsSub;

  /// No description provided for @appearanceHomeDensityLabel.
  ///
  /// In en, this message translates to:
  /// **'Home Density'**
  String get appearanceHomeDensityLabel;

  /// No description provided for @appearanceHomeDensitySub.
  ///
  /// In en, this message translates to:
  /// **'Choose spacing style for Home cards and lists.'**
  String get appearanceHomeDensitySub;

  /// No description provided for @appearanceHomeDensityComfortable.
  ///
  /// In en, this message translates to:
  /// **'Comfortable'**
  String get appearanceHomeDensityComfortable;

  /// No description provided for @appearanceHomeDensityCompact.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get appearanceHomeDensityCompact;

  /// No description provided for @desktopNavbarSectionLabel.
  ///
  /// In en, this message translates to:
  /// **'Desktop Navigation'**
  String get desktopNavbarSectionLabel;

  /// No description provided for @desktopNavbarStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Navigation Style'**
  String get desktopNavbarStyleLabel;

  /// No description provided for @desktopNavbarStyleComfortable.
  ///
  /// In en, this message translates to:
  /// **'Comfortable'**
  String get desktopNavbarStyleComfortable;

  /// No description provided for @desktopNavbarStyleCompact.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get desktopNavbarStyleCompact;

  /// No description provided for @desktopNavbarStyleIcons.
  ///
  /// In en, this message translates to:
  /// **'Icons'**
  String get desktopNavbarStyleIcons;

  /// No description provided for @desktopNavbarAutohideLabel.
  ///
  /// In en, this message translates to:
  /// **'Autohide Sidebar'**
  String get desktopNavbarAutohideLabel;

  /// No description provided for @desktopNavbarAutohideSub.
  ///
  /// In en, this message translates to:
  /// **'Sidebar slides away automatically; hover the left edge to reveal it.'**
  String get desktopNavbarAutohideSub;

  /// No description provided for @desktopNavbarLockTooltip.
  ///
  /// In en, this message translates to:
  /// **'Lock sidebar'**
  String get desktopNavbarLockTooltip;

  /// No description provided for @desktopNavbarUnlockTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unlock sidebar'**
  String get desktopNavbarUnlockTooltip;

  /// No description provided for @homeSectionContinueListening.
  ///
  /// In en, this message translates to:
  /// **'Continue Listening'**
  String get homeSectionContinueListening;

  /// No description provided for @homeSectionRecentlyLikedAlbums.
  ///
  /// In en, this message translates to:
  /// **'Recently Liked Albums'**
  String get homeSectionRecentlyLikedAlbums;

  /// No description provided for @homeSectionLikedTracks.
  ///
  /// In en, this message translates to:
  /// **'Liked Tracks'**
  String get homeSectionLikedTracks;

  /// No description provided for @homeSectionListenBrainzDiscover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get homeSectionListenBrainzDiscover;

  /// No description provided for @homeSectionRecentlyAdded.
  ///
  /// In en, this message translates to:
  /// **'Recently Added'**
  String get homeSectionRecentlyAdded;

  /// No description provided for @homeSectionRecentlyPlayed.
  ///
  /// In en, this message translates to:
  /// **'Recently Played'**
  String get homeSectionRecentlyPlayed;

  /// No description provided for @homeSectionRandomAlbums.
  ///
  /// In en, this message translates to:
  /// **'You Might Like'**
  String get homeSectionRandomAlbums;

  /// No description provided for @homeSectionMostPlayed.
  ///
  /// In en, this message translates to:
  /// **'Most Played'**
  String get homeSectionMostPlayed;

  /// No description provided for @homeSectionRecentlyPlayedTracks.
  ///
  /// In en, this message translates to:
  /// **'Recently Played Tracks'**
  String get homeSectionRecentlyPlayedTracks;

  /// No description provided for @homeSectionFrequentAlbums.
  ///
  /// In en, this message translates to:
  /// **'Frequent Albums'**
  String get homeSectionFrequentAlbums;

  /// No description provided for @homeSectionQuickActions.
  ///
  /// In en, this message translates to:
  /// **'Quick Actions'**
  String get homeSectionQuickActions;

  /// No description provided for @cacheSettingsCoverArtSizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Storage used: {size}'**
  String cacheSettingsCoverArtSizeLabel(String size);

  /// No description provided for @cacheSettingsPrecacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Pre-cache all album art'**
  String get cacheSettingsPrecacheTitle;

  /// No description provided for @cacheSettingsPrecacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download artwork for every album to the device now. Only available when cover art cache has no limit.'**
  String get cacheSettingsPrecacheSubtitle;

  /// No description provided for @cacheSettingsPrecachingProgress.
  ///
  /// In en, this message translates to:
  /// **'Caching {done} of {total}...'**
  String cacheSettingsPrecachingProgress(int done, int total);

  /// No description provided for @cacheSettingsPrecacheSuccess.
  ///
  /// In en, this message translates to:
  /// **'Done — cached {total} album art image(s).'**
  String cacheSettingsPrecacheSuccess(int total);

  /// No description provided for @serverSettingsSignOutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get serverSettingsSignOutConfirmTitle;

  /// No description provided for @serverSettingsSignOutConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'How would you like to handle your local library data?'**
  String get serverSettingsSignOutConfirmMessage;

  /// No description provided for @serverSettingsConnectionInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection info'**
  String get serverSettingsConnectionInfoTitle;

  /// No description provided for @audioMuseSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'AudioMuse AI'**
  String get audioMuseSettingsTitle;

  /// No description provided for @audioMuseSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'AI-powered smart queuing & discovery'**
  String get audioMuseSettingsSubtitle;

  /// No description provided for @audioMuseEnabledLabel.
  ///
  /// In en, this message translates to:
  /// **'Enable AudioMuse'**
  String get audioMuseEnabledLabel;

  /// No description provided for @audioMuseEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to an AudioMuse server for AI recommendations'**
  String get audioMuseEnabledSubtitle;

  /// No description provided for @audioMuseServerUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get audioMuseServerUrlLabel;

  /// No description provided for @audioMuseServerUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://audiomuse.example.com'**
  String get audioMuseServerUrlHint;

  /// No description provided for @audioMuseApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get audioMuseApiKeyLabel;

  /// No description provided for @audioMuseApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Optional — leave blank if not required'**
  String get audioMuseApiKeyHint;

  /// No description provided for @audioMuseTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get audioMuseTestConnection;

  /// No description provided for @audioMuseTestConnectionSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connected to AudioMuse (v{version}).'**
  String audioMuseTestConnectionSuccess(String version);

  /// No description provided for @audioMuseTestConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to AudioMuse server.'**
  String get audioMuseTestConnectionFailed;

  /// No description provided for @audioMuseSimilarArtists.
  ///
  /// In en, this message translates to:
  /// **'AI Similar Artists'**
  String get audioMuseSimilarArtists;

  /// No description provided for @audioMuseSimilarAlbums.
  ///
  /// In en, this message translates to:
  /// **'You might also like'**
  String get audioMuseSimilarAlbums;

  /// No description provided for @audioMuseSmartQueue.
  ///
  /// In en, this message translates to:
  /// **'Smart Queue'**
  String get audioMuseSmartQueue;

  /// No description provided for @audioMuseSmartQueueActive.
  ///
  /// In en, this message translates to:
  /// **'AI auto-queue is active'**
  String get audioMuseSmartQueueActive;

  /// No description provided for @audioMuseSmartQueueStopped.
  ///
  /// In en, this message translates to:
  /// **'AI auto-queue stopped'**
  String get audioMuseSmartQueueStopped;

  /// No description provided for @audioMuseSmartQueueQueued.
  ///
  /// In en, this message translates to:
  /// **'{count} AI-recommended tracks queued.'**
  String audioMuseSmartQueueQueued(int count);

  /// No description provided for @audioMuseGenerateMix.
  ///
  /// In en, this message translates to:
  /// **'Create AI Mix'**
  String get audioMuseGenerateMix;

  /// No description provided for @audioMuseGenerateMixSeed.
  ///
  /// In en, this message translates to:
  /// **'Generate a mix based on this {seedType}'**
  String audioMuseGenerateMixSeed(String seedType);

  /// No description provided for @audioMuseMixGenerated.
  ///
  /// In en, this message translates to:
  /// **'AI Mix created — {count} tracks queued.'**
  String audioMuseMixGenerated(int count);

  /// No description provided for @audioMuseMixFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not generate AI mix. Try again later.'**
  String get audioMuseMixFailed;

  /// No description provided for @audioMuseNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'AudioMuse is not configured. Set it up in Settings.'**
  String get audioMuseNotConfigured;

  /// No description provided for @audioMuseConnectionSection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get audioMuseConnectionSection;

  /// No description provided for @audioMuseDisabledHint.
  ///
  /// In en, this message translates to:
  /// **'Enable AudioMuse above to configure the server.'**
  String get audioMuseDisabledHint;

  /// No description provided for @smartQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Smart Queues'**
  String get smartQueueTitle;

  /// No description provided for @smartQueueSubtitle.
  ///
  /// In en, this message translates to:
  /// **'AI-powered queuing based on sonic analysis'**
  String get smartQueueSubtitle;

  /// No description provided for @smartQueueButton.
  ///
  /// In en, this message translates to:
  /// **'Smart Queue'**
  String get smartQueueButton;

  /// No description provided for @smartQueueActive.
  ///
  /// In en, this message translates to:
  /// **'Smart Queue active'**
  String get smartQueueActive;

  /// No description provided for @smartQueueStopped.
  ///
  /// In en, this message translates to:
  /// **'Smart Queue stopped'**
  String get smartQueueStopped;

  /// No description provided for @smartQueueStarted.
  ///
  /// In en, this message translates to:
  /// **'{count} tracks queued via Smart Queue.'**
  String smartQueueStarted(int count);

  /// No description provided for @smartQueueUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Smart Queues require the AudioMuse plugin on your server.'**
  String get smartQueueUnsupported;

  /// No description provided for @smartQueueError.
  ///
  /// In en, this message translates to:
  /// **'Smart Queue encountered an error. Please try again.'**
  String get smartQueueError;

  /// No description provided for @smartQueueSteadyVibes.
  ///
  /// In en, this message translates to:
  /// **'Steady Vibes'**
  String get smartQueueSteadyVibes;

  /// No description provided for @smartQueueSteadyVibesDesc.
  ///
  /// In en, this message translates to:
  /// **'Consistent mood — stays close to the original feel'**
  String get smartQueueSteadyVibesDesc;

  /// No description provided for @smartQueueDiscoveryMix.
  ///
  /// In en, this message translates to:
  /// **'Discovery Mix'**
  String get smartQueueDiscoveryMix;

  /// No description provided for @smartQueueDiscoveryMixDesc.
  ///
  /// In en, this message translates to:
  /// **'Explore new artists with maximum variety'**
  String get smartQueueDiscoveryMixDesc;

  /// No description provided for @smartQueueDeepDive.
  ///
  /// In en, this message translates to:
  /// **'Deep Dive'**
  String get smartQueueDeepDive;

  /// No description provided for @smartQueueDeepDiveDesc.
  ///
  /// In en, this message translates to:
  /// **'Stay immersed in the same artist and style'**
  String get smartQueueDeepDiveDesc;

  /// No description provided for @smartQueueEnergyFlow.
  ///
  /// In en, this message translates to:
  /// **'Energy Flow'**
  String get smartQueueEnergyFlow;

  /// No description provided for @smartQueueEnergyFlowDesc.
  ///
  /// In en, this message translates to:
  /// **'Let the mood gradually evolve track by track'**
  String get smartQueueEnergyFlowDesc;

  /// No description provided for @songStatusQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued for download'**
  String get songStatusQueued;

  /// No description provided for @songStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get songStatusDownloading;

  /// No description provided for @songStatusDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get songStatusDownloaded;

  /// No description provided for @songStatusCachedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Temporarily cached — will be removed when cache fills up or when the track is downloaded'**
  String get songStatusCachedTooltip;

  /// No description provided for @downloadsRemoveConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove download?'**
  String get downloadsRemoveConfirmTitle;

  /// No description provided for @downloadsRemoveConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'The downloaded file will be permanently deleted.'**
  String get downloadsRemoveConfirmContent;

  /// No description provided for @deleteDownloadAction.
  ///
  /// In en, this message translates to:
  /// **'Delete download'**
  String get deleteDownloadAction;

  /// No description provided for @libraryAlbumMenuPlay.
  ///
  /// In en, this message translates to:
  /// **'Play album'**
  String get libraryAlbumMenuPlay;

  /// No description provided for @libraryAlbumMenuAddToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get libraryAlbumMenuAddToQueue;

  /// No description provided for @libraryAlbumMenuDownload.
  ///
  /// In en, this message translates to:
  /// **'Download album'**
  String get libraryAlbumMenuDownload;

  /// No description provided for @libraryAlbumPlayQueued.
  ///
  /// In en, this message translates to:
  /// **'Album queued to play'**
  String get libraryAlbumPlayQueued;

  /// No description provided for @libraryAlbumAddedToQueue.
  ///
  /// In en, this message translates to:
  /// **'Album added to queue'**
  String get libraryAlbumAddedToQueue;

  /// No description provided for @actionLike.
  ///
  /// In en, this message translates to:
  /// **'Like'**
  String get actionLike;

  /// No description provided for @actionLiked.
  ///
  /// In en, this message translates to:
  /// **'Liked'**
  String get actionLiked;

  /// No description provided for @remoteSourceActionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available for remote tracks.'**
  String get remoteSourceActionUnavailable;

  /// No description provided for @remoteSourceInstantMixUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Instant Mix requires a locally scanned track.'**
  String get remoteSourceInstantMixUnavailable;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get commonRename;

  /// No description provided for @commonRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get commonRemove;

  /// No description provided for @commonReorder.
  ///
  /// In en, this message translates to:
  /// **'Reorder'**
  String get commonReorder;

  /// No description provided for @matchFlowTitle.
  ///
  /// In en, this message translates to:
  /// **'Match Flow'**
  String get matchFlowTitle;

  /// No description provided for @matchFlowPlaybackSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Expand a selected master song into a saved local playback flow.'**
  String get matchFlowPlaybackSettingsSubtitle;

  /// No description provided for @matchFlowManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage Match Flows'**
  String get matchFlowManageTitle;

  /// No description provided for @matchFlowCreateAction.
  ///
  /// In en, this message translates to:
  /// **'New Flow'**
  String get matchFlowCreateAction;

  /// No description provided for @matchFlowEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Match Flows yet'**
  String get matchFlowEmptyTitle;

  /// No description provided for @matchFlowEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a flow, choose a master song, then add the songs that should follow it.'**
  String get matchFlowEmptySubtitle;

  /// No description provided for @matchFlowLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load Match Flow: {error}'**
  String matchFlowLoadError(String error);

  /// No description provided for @matchFlowSaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save Match Flow: {error}'**
  String matchFlowSaveError(String error);

  /// No description provided for @matchFlowSongCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No songs} =1{1 song} other{{count} songs}}'**
  String matchFlowSongCount(int count);

  /// No description provided for @matchFlowContentsTitle.
  ///
  /// In en, this message translates to:
  /// **'Flow Contents'**
  String get matchFlowContentsTitle;

  /// No description provided for @matchFlowExpandContents.
  ///
  /// In en, this message translates to:
  /// **'Expand Flow Contents'**
  String get matchFlowExpandContents;

  /// No description provided for @matchFlowCollapseContents.
  ///
  /// In en, this message translates to:
  /// **'Collapse Flow Contents'**
  String get matchFlowCollapseContents;

  /// No description provided for @matchFlowNoSongs.
  ///
  /// In en, this message translates to:
  /// **'Add a song to set the master.'**
  String get matchFlowNoSongs;

  /// No description provided for @matchFlowAddSongAction.
  ///
  /// In en, this message translates to:
  /// **'Add song'**
  String get matchFlowAddSongAction;

  /// No description provided for @matchFlowAddSongTitle.
  ///
  /// In en, this message translates to:
  /// **'Add song'**
  String get matchFlowAddSongTitle;

  /// No description provided for @matchFlowSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs'**
  String get matchFlowSearchHint;

  /// No description provided for @matchFlowNoSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No songs found'**
  String get matchFlowNoSearchResults;

  /// No description provided for @matchFlowRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename flow'**
  String get matchFlowRenameTitle;

  /// No description provided for @matchFlowNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Flow name'**
  String get matchFlowNameLabel;

  /// No description provided for @matchFlowDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete flow?'**
  String get matchFlowDeleteTitle;

  /// No description provided for @matchFlowDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}” and its song order?'**
  String matchFlowDeleteMessage(String name);

  /// No description provided for @matchFlowMasterLabel.
  ///
  /// In en, this message translates to:
  /// **'Master'**
  String get matchFlowMasterLabel;

  /// No description provided for @matchFlowUnresolvedSong.
  ///
  /// In en, this message translates to:
  /// **'Unresolved song {songId}'**
  String matchFlowUnresolvedSong(String songId);

  /// No description provided for @matchFlowSongAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {title}.'**
  String matchFlowSongAdded(String title);
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
