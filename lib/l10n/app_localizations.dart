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

  /// No description provided for @navigationBackToExitPrompt.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get navigationBackToExitPrompt;

  /// No description provided for @loginTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
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

  /// No description provided for @loginShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get loginShowPassword;

  /// No description provided for @loginHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get loginHidePassword;

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

  /// No description provided for @loginReplaceServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace Local Server Data?'**
  String get loginReplaceServerTitle;

  /// No description provided for @loginReplaceServerMessage.
  ///
  /// In en, this message translates to:
  /// **'This device keeps one local server catalog. Continuing will remove the retained library, downloads, caches, history, playlists, and Match Flows from the previous server account.'**
  String get loginReplaceServerMessage;

  /// No description provided for @loginReplaceServerAction.
  ///
  /// In en, this message translates to:
  /// **'Replace Local Data'**
  String get loginReplaceServerAction;

  /// No description provided for @initialSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Initial Server Sync'**
  String get initialSyncTitle;

  /// No description provided for @initialSyncDoNotClose.
  ///
  /// In en, this message translates to:
  /// **'Navis is building this server\'s local library. Do not close the app during setup.'**
  String get initialSyncDoNotClose;

  /// No description provided for @initialSyncWaitingForNetwork.
  ///
  /// In en, this message translates to:
  /// **'Connect to a network, then retry to continue setup.'**
  String get initialSyncWaitingForNetwork;

  /// No description provided for @initialSyncMobileDataRequired.
  ///
  /// In en, this message translates to:
  /// **'Initial setup requires a full library download. Confirm to use this metered connection.'**
  String get initialSyncMobileDataRequired;

  /// No description provided for @initialSyncUseMobileData.
  ///
  /// In en, this message translates to:
  /// **'Sync using mobile data'**
  String get initialSyncUseMobileData;

  /// No description provided for @initialSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Initial sync could not complete.'**
  String get initialSyncFailed;

  /// No description provided for @initialSyncCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling and signing out...'**
  String get initialSyncCancelling;

  /// No description provided for @initialSyncCancelAndLogout.
  ///
  /// In en, this message translates to:
  /// **'Cancel and sign out'**
  String get initialSyncCancelAndLogout;

  /// No description provided for @requiredSyncInitialTitle.
  ///
  /// In en, this message translates to:
  /// **'Building Your Library'**
  String get requiredSyncInitialTitle;

  /// No description provided for @requiredSyncRebuildTitle.
  ///
  /// In en, this message translates to:
  /// **'Rebuilding Your Library'**
  String get requiredSyncRebuildTitle;

  /// No description provided for @requiredSyncRepairTitle.
  ///
  /// In en, this message translates to:
  /// **'Repairing Your Library'**
  String get requiredSyncRepairTitle;

  /// No description provided for @requiredSyncInitialBody.
  ///
  /// In en, this message translates to:
  /// **'Navis is preparing this server for the first time.'**
  String get requiredSyncInitialBody;

  /// No description provided for @requiredSyncRebuildBody.
  ///
  /// In en, this message translates to:
  /// **'Navis is clearing recoverable library data and downloading a fresh library. Your downloads are kept.'**
  String get requiredSyncRebuildBody;

  /// No description provided for @requiredSyncRepairBody.
  ///
  /// In en, this message translates to:
  /// **'Navis is checking every album and song to rebuild a complete, up-to-date library.'**
  String get requiredSyncRepairBody;

  /// No description provided for @requiredSyncClearingCache.
  ///
  /// In en, this message translates to:
  /// **'Clearing library cache'**
  String get requiredSyncClearingCache;

  /// No description provided for @requiredSyncRebuildFailed.
  ///
  /// In en, this message translates to:
  /// **'Library rebuild could not complete.'**
  String get requiredSyncRebuildFailed;

  /// No description provided for @requiredSyncSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get requiredSyncSignOut;

  /// No description provided for @requiredSyncCancelAndSignOut.
  ///
  /// In en, this message translates to:
  /// **'Cancel and sign out'**
  String get requiredSyncCancelAndSignOut;

  /// No description provided for @requiredSyncStagePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing library'**
  String get requiredSyncStagePreparing;

  /// No description provided for @requiredSyncStageArtistIndex.
  ///
  /// In en, this message translates to:
  /// **'Getting artist index'**
  String get requiredSyncStageArtistIndex;

  /// No description provided for @requiredSyncStageSongIndex.
  ///
  /// In en, this message translates to:
  /// **'Getting song index'**
  String get requiredSyncStageSongIndex;

  /// No description provided for @requiredSyncStageAlbums.
  ///
  /// In en, this message translates to:
  /// **'Syncing albums'**
  String get requiredSyncStageAlbums;

  /// No description provided for @requiredSyncStageSongs.
  ///
  /// In en, this message translates to:
  /// **'Syncing songs'**
  String get requiredSyncStageSongs;

  /// No description provided for @requiredSyncStageFinalizing.
  ///
  /// In en, this message translates to:
  /// **'Finalizing library'**
  String get requiredSyncStageFinalizing;

  /// No description provided for @initialSyncComplete.
  ///
  /// In en, this message translates to:
  /// **'Library ready'**
  String get initialSyncComplete;

  /// No description provided for @initialSyncCompletedWithWarnings.
  ///
  /// In en, this message translates to:
  /// **'Your library is ready. A few items are still syncing in the background.'**
  String get initialSyncCompletedWithWarnings;

  /// No description provided for @serverOfflineBanner.
  ///
  /// In en, this message translates to:
  /// **'Server unreachable. Retrying every 30s.'**
  String get serverOfflineBanner;

  /// No description provided for @serverOfflineQuietBanner.
  ///
  /// In en, this message translates to:
  /// **'Offline mode'**
  String get serverOfflineQuietBanner;

  /// No description provided for @batteryOptimizationPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep Background Sync Alive'**
  String get batteryOptimizationPromptTitle;

  /// No description provided for @batteryOptimizationPromptBody.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization is still enabled for Navis. Disabling it helps background sync finish reliably without the system shutting the app down early.'**
  String get batteryOptimizationPromptBody;

  /// No description provided for @batteryOptimizationPromptRecommendation.
  ///
  /// In en, this message translates to:
  /// **'Recommended if you rely on automatic library scans.'**
  String get batteryOptimizationPromptRecommendation;

  /// No description provided for @batteryOptimizationPromptLaterAction.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get batteryOptimizationPromptLaterAction;

  /// No description provided for @batteryOptimizationPromptOpenSettingsAction.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get batteryOptimizationPromptOpenSettingsAction;

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
  /// **'Device storage & cache'**
  String get settingsCacheTitle;

  /// No description provided for @settingsCacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage on-device audio, artwork, and download storage.'**
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

  /// No description provided for @settingsGroupConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsGroupConnection;

  /// No description provided for @settingsGroupStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsGroupStorage;

  /// No description provided for @settingsGroupDeviceStorageCache.
  ///
  /// In en, this message translates to:
  /// **'Device storage & cache'**
  String get settingsGroupDeviceStorageCache;

  /// No description provided for @settingsGroupPlayback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get settingsGroupPlayback;

  /// No description provided for @settingsGroupAutomation.
  ///
  /// In en, this message translates to:
  /// **'Automation'**
  String get settingsGroupAutomation;

  /// No description provided for @settingsGroupLibrarySynchronization.
  ///
  /// In en, this message translates to:
  /// **'Library synchronization'**
  String get settingsGroupLibrarySynchronization;

  /// No description provided for @settingsGroupOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get settingsGroupOther;

  /// No description provided for @settingsRunQuickCustomizationTitle.
  ///
  /// In en, this message translates to:
  /// **'Run Quick Customization'**
  String get settingsRunQuickCustomizationTitle;

  /// No description provided for @settingsRunQuickCustomizationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Review your listening and appearance preferences.'**
  String get settingsRunQuickCustomizationSubtitle;

  /// No description provided for @settingsGroupDesktop.
  ///
  /// In en, this message translates to:
  /// **'Desktop'**
  String get settingsGroupDesktop;

  /// No description provided for @settingsDesktopShortcutsTitle.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Shortcuts'**
  String get settingsDesktopShortcutsTitle;

  /// No description provided for @settingsDesktopShortcutsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Customize desktop key bindings'**
  String get settingsDesktopShortcutsSubtitle;

  /// No description provided for @desktopShortcutsReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get desktopShortcutsReset;

  /// No description provided for @desktopShortcutsCustomizable.
  ///
  /// In en, this message translates to:
  /// **'Customizable'**
  String get desktopShortcutsCustomizable;

  /// No description provided for @desktopShortcutsBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get desktopShortcutsBuiltIn;

  /// No description provided for @desktopShortcutsCaptureSaved.
  ///
  /// In en, this message translates to:
  /// **'Enter to save · Backspace to clear · Esc to cancel'**
  String get desktopShortcutsCaptureSaved;

  /// No description provided for @desktopShortcutsCapturePrompt.
  ///
  /// In en, this message translates to:
  /// **'Hold modifiers then press a key (e.g. Ctrl+Shift+F)'**
  String get desktopShortcutsCapturePrompt;

  /// No description provided for @desktopShortcutsWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for new input…'**
  String get desktopShortcutsWaiting;

  /// No description provided for @desktopShortcutsNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get desktopShortcutsNotSet;

  /// No description provided for @desktopShortcutsQuickSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick Search'**
  String get desktopShortcutsQuickSearchTitle;

  /// No description provided for @desktopShortcutsQuickSearchDescription.
  ///
  /// In en, this message translates to:
  /// **'Open the quick-search overlay'**
  String get desktopShortcutsQuickSearchDescription;

  /// No description provided for @desktopShortcutsFocusSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Focus Search'**
  String get desktopShortcutsFocusSearchTitle;

  /// No description provided for @desktopShortcutsFocusSearchDescription.
  ///
  /// In en, this message translates to:
  /// **'Navigate to search and focus the input'**
  String get desktopShortcutsFocusSearchDescription;

  /// No description provided for @desktopShortcutsToggleQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Toggle Queue'**
  String get desktopShortcutsToggleQueueTitle;

  /// No description provided for @desktopShortcutsToggleQueueDescription.
  ///
  /// In en, this message translates to:
  /// **'Show or hide the playback queue'**
  String get desktopShortcutsToggleQueueDescription;

  /// No description provided for @desktopShortcutsGoHomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Go to Home'**
  String get desktopShortcutsGoHomeTitle;

  /// No description provided for @desktopShortcutsGoHomeDescription.
  ///
  /// In en, this message translates to:
  /// **'Navigate to the home screen'**
  String get desktopShortcutsGoHomeDescription;

  /// No description provided for @desktopShortcutsGoLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Go to Library'**
  String get desktopShortcutsGoLibraryTitle;

  /// No description provided for @desktopShortcutsGoLibraryDescription.
  ///
  /// In en, this message translates to:
  /// **'Navigate to the library'**
  String get desktopShortcutsGoLibraryDescription;

  /// No description provided for @desktopShortcutsGoSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Go to Search'**
  String get desktopShortcutsGoSearchTitle;

  /// No description provided for @desktopShortcutsGoSearchDescription.
  ///
  /// In en, this message translates to:
  /// **'Navigate to search'**
  String get desktopShortcutsGoSearchDescription;

  /// No description provided for @desktopShortcutsGoSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Go to Settings'**
  String get desktopShortcutsGoSettingsTitle;

  /// No description provided for @desktopShortcutsGoSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get desktopShortcutsGoSettingsDescription;

  /// No description provided for @desktopShortcutsToggleNowPlayingTitle.
  ///
  /// In en, this message translates to:
  /// **'Toggle Now Playing'**
  String get desktopShortcutsToggleNowPlayingTitle;

  /// No description provided for @desktopShortcutsToggleNowPlayingDescription.
  ///
  /// In en, this message translates to:
  /// **'Expand or collapse now playing'**
  String get desktopShortcutsToggleNowPlayingDescription;

  /// No description provided for @desktopShortcutsPlayPauseTitle.
  ///
  /// In en, this message translates to:
  /// **'Play / Pause'**
  String get desktopShortcutsPlayPauseTitle;

  /// No description provided for @desktopShortcutsTogglePlaybackDescription.
  ///
  /// In en, this message translates to:
  /// **'Toggle playback'**
  String get desktopShortcutsTogglePlaybackDescription;

  /// No description provided for @desktopShortcutsNextTrackTitle.
  ///
  /// In en, this message translates to:
  /// **'Next Track'**
  String get desktopShortcutsNextTrackTitle;

  /// No description provided for @desktopShortcutsNextTrackDescription.
  ///
  /// In en, this message translates to:
  /// **'Skip to next track'**
  String get desktopShortcutsNextTrackDescription;

  /// No description provided for @desktopShortcutsPreviousTrackTitle.
  ///
  /// In en, this message translates to:
  /// **'Previous Track'**
  String get desktopShortcutsPreviousTrackTitle;

  /// No description provided for @desktopShortcutsPreviousTrackDescription.
  ///
  /// In en, this message translates to:
  /// **'Skip to previous track'**
  String get desktopShortcutsPreviousTrackDescription;

  /// No description provided for @desktopShortcutsRefreshLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Refresh Library'**
  String get desktopShortcutsRefreshLibraryTitle;

  /// No description provided for @desktopShortcutsRefreshLibraryDescription.
  ///
  /// In en, this message translates to:
  /// **'Sync new changes to the library'**
  String get desktopShortcutsRefreshLibraryDescription;

  /// No description provided for @desktopShortcutsForceRescanTitle.
  ///
  /// In en, this message translates to:
  /// **'Force Full Rescan'**
  String get desktopShortcutsForceRescanTitle;

  /// No description provided for @desktopShortcutsForceRescanDescription.
  ///
  /// In en, this message translates to:
  /// **'Force a complete rescan of all library files'**
  String get desktopShortcutsForceRescanDescription;

  /// No description provided for @desktopShortcutsSpace.
  ///
  /// In en, this message translates to:
  /// **'Space'**
  String get desktopShortcutsSpace;

  /// No description provided for @desktopShortcutsPreviousBindingMac.
  ///
  /// In en, this message translates to:
  /// **'← or Option+,'**
  String get desktopShortcutsPreviousBindingMac;

  /// No description provided for @desktopShortcutsPreviousBinding.
  ///
  /// In en, this message translates to:
  /// **'← or Alt+'**
  String get desktopShortcutsPreviousBinding;

  /// No description provided for @desktopShortcutsNextBindingMac.
  ///
  /// In en, this message translates to:
  /// **'→ or Option+.'**
  String get desktopShortcutsNextBindingMac;

  /// No description provided for @desktopShortcutsNextBinding.
  ///
  /// In en, this message translates to:
  /// **'→ or Alt+.'**
  String get desktopShortcutsNextBinding;

  /// No description provided for @desktopShortcutsDismissOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'Dismiss Overlay'**
  String get desktopShortcutsDismissOverlayTitle;

  /// No description provided for @desktopShortcutsDismissOverlayDescription.
  ///
  /// In en, this message translates to:
  /// **'Close the topmost overlay or dialog'**
  String get desktopShortcutsDismissOverlayDescription;

  /// No description provided for @desktopShortcutsEscape.
  ///
  /// In en, this message translates to:
  /// **'Esc'**
  String get desktopShortcutsEscape;

  /// No description provided for @settingsDesktopWorkspaceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop workspace controls and app preferences'**
  String get settingsDesktopWorkspaceSubtitle;

  /// No description provided for @privacyAccountsTitle.
  ///
  /// In en, this message translates to:
  /// **'Accounts and Credentials'**
  String get privacyAccountsTitle;

  /// No description provided for @privacyAccountsBody.
  ///
  /// In en, this message translates to:
  /// **'Navis connects directly to the Subsonic or OpenSubsonic servers you configure. Server addresses and usernames are stored in the app database. Passwords and external service tokens are stored through the platform secure credential store when available.'**
  String get privacyAccountsBody;

  /// No description provided for @privacyScrobblingTitle.
  ///
  /// In en, this message translates to:
  /// **'External Scrobbling'**
  String get privacyScrobblingTitle;

  /// No description provided for @privacyScrobblingBody.
  ///
  /// In en, this message translates to:
  /// **'If you enable ListenBrainz, Navis sends listening activity for played tracks to those services. This can include track title, artist, album, duration, play time, and now-playing status. ListenBrainz user tokens remain on your device.'**
  String get privacyScrobblingBody;

  /// No description provided for @privacyDownloadsTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloads and Cache'**
  String get privacyDownloadsTitle;

  /// No description provided for @privacyDownloadsBody.
  ///
  /// In en, this message translates to:
  /// **'Offline downloads, playback cache, artwork, lyrics, and library metadata are stored on your device so playback and browsing can work without repeatedly fetching the same data. You can clear cache data from Settings.'**
  String get privacyDownloadsBody;

  /// No description provided for @privacyDiagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get privacyDiagnosticsTitle;

  /// No description provided for @privacyDiagnosticsBody.
  ///
  /// In en, this message translates to:
  /// **'Navis avoids logging raw credentials and redacts sensitive authentication values from diagnostics. Network errors may still include service names or non-secret request context needed to troubleshoot failures.'**
  String get privacyDiagnosticsBody;

  /// No description provided for @privacySummary.
  ///
  /// In en, this message translates to:
  /// **'Navis does not operate a central account service for your music library. Data is exchanged with the servers and optional third-party services you configure.'**
  String get privacySummary;

  /// No description provided for @syncSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync Settings'**
  String get syncSettingsTitle;

  /// No description provided for @syncSettingsStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Current Sync Status'**
  String get syncSettingsStatusLabel;

  /// No description provided for @syncSettingsLastSyncedLabel.
  ///
  /// In en, this message translates to:
  /// **'Server Last Synced'**
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

  /// No description provided for @syncSettingsStatusPartial.
  ///
  /// In en, this message translates to:
  /// **'Sync paused with work remaining'**
  String get syncSettingsStatusPartial;

  /// No description provided for @syncSettingsStatusDeferred.
  ///
  /// In en, this message translates to:
  /// **'Sync deferred'**
  String get syncSettingsStatusDeferred;

  /// No description provided for @syncSettingsStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Sync cancelled; work saved'**
  String get syncSettingsStatusCancelled;

  /// No description provided for @syncSettingsStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Last sync failed'**
  String get syncSettingsStatusFailed;

  /// No description provided for @syncSettingsFailureDescription.
  ///
  /// In en, this message translates to:
  /// **'Could not refresh your library. Check your connection and try again.'**
  String get syncSettingsFailureDescription;

  /// No description provided for @syncSettingsPlanLabel.
  ///
  /// In en, this message translates to:
  /// **'Sync Plan'**
  String get syncSettingsPlanLabel;

  /// No description provided for @syncSettingsPendingWorkLabel.
  ///
  /// In en, this message translates to:
  /// **'Pending Work'**
  String get syncSettingsPendingWorkLabel;

  /// No description provided for @syncSettingsPendingWorkValue.
  ///
  /// In en, this message translates to:
  /// **'{count} task(s) pending'**
  String syncSettingsPendingWorkValue(Object count);

  /// No description provided for @syncSettingsCatalogUpdateLabel.
  ///
  /// In en, this message translates to:
  /// **'Catalog Update'**
  String get syncSettingsCatalogUpdateLabel;

  /// No description provided for @syncSettingsCatalogUpdateValue.
  ///
  /// In en, this message translates to:
  /// **'{milliseconds} ms'**
  String syncSettingsCatalogUpdateValue(Object milliseconds);

  /// No description provided for @syncSettingsLastRunLabel.
  ///
  /// In en, this message translates to:
  /// **'Last Run'**
  String get syncSettingsLastRunLabel;

  /// No description provided for @syncSettingsLastRunValue.
  ///
  /// In en, this message translates to:
  /// **'{requests} request(s) • {bytes}'**
  String syncSettingsLastRunValue(Object requests, Object bytes);

  /// No description provided for @syncSettingsLastCheckedLabel.
  ///
  /// In en, this message translates to:
  /// **'Last Checked'**
  String get syncSettingsLastCheckedLabel;

  /// No description provided for @syncSettingsNextAutomaticCheckLabel.
  ///
  /// In en, this message translates to:
  /// **'Next Automatic Check'**
  String get syncSettingsNextAutomaticCheckLabel;

  /// No description provided for @syncSettingsNextAutomaticCheckScheduling.
  ///
  /// In en, this message translates to:
  /// **'Scheduling…'**
  String get syncSettingsNextAutomaticCheckScheduling;

  /// No description provided for @syncSettingsNextRetryLabel.
  ///
  /// In en, this message translates to:
  /// **'Automatic Retry After Failure'**
  String get syncSettingsNextRetryLabel;

  /// No description provided for @syncSettingsLastCatalogUpdateLabel.
  ///
  /// In en, this message translates to:
  /// **'Last Catalog Update'**
  String get syncSettingsLastCatalogUpdateLabel;

  /// No description provided for @syncSettingsLastAuxiliaryUpdateLabel.
  ///
  /// In en, this message translates to:
  /// **'Starred and Playlist Headers'**
  String get syncSettingsLastAuxiliaryUpdateLabel;

  /// No description provided for @syncSettingsLastGenresUpdateLabel.
  ///
  /// In en, this message translates to:
  /// **'Genres'**
  String get syncSettingsLastGenresUpdateLabel;

  /// No description provided for @syncSettingsLastLibraryChangeLabel.
  ///
  /// In en, this message translates to:
  /// **'Last Library Change'**
  String get syncSettingsLastLibraryChangeLabel;

  /// No description provided for @syncSettingsAndroidBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Android Background Sync'**
  String get syncSettingsAndroidBackgroundTitle;

  /// No description provided for @syncSettingsBackToSettings.
  ///
  /// In en, this message translates to:
  /// **'Back to Settings'**
  String get syncSettingsBackToSettings;

  /// No description provided for @syncSettingsAndroidBackgroundDisabled.
  ///
  /// In en, this message translates to:
  /// **'Foreground checks remain available. Android background scheduling is disabled for this app build while its reliability certification is incomplete.'**
  String get syncSettingsAndroidBackgroundDisabled;

  /// No description provided for @syncSettingsAndroidBackgroundManual.
  ///
  /// In en, this message translates to:
  /// **'Manual-only sync has no Android background schedule.'**
  String get syncSettingsAndroidBackgroundManual;

  /// No description provided for @syncSettingsAndroidBackgroundCadence.
  ///
  /// In en, this message translates to:
  /// **'Requested cadence: every {minutes} minutes. Android may delay runs to meet system conditions.'**
  String syncSettingsAndroidBackgroundCadence(Object minutes);

  /// No description provided for @syncSettingsAndroidBackgroundLastAttempt.
  ///
  /// In en, this message translates to:
  /// **'Last Android attempt'**
  String get syncSettingsAndroidBackgroundLastAttempt;

  /// No description provided for @syncSettingsAndroidBackgroundNoAttempt.
  ///
  /// In en, this message translates to:
  /// **'No Android attempt recorded yet.'**
  String get syncSettingsAndroidBackgroundNoAttempt;

  /// No description provided for @syncSettingsAndroidBackgroundWaitingUnmetered.
  ///
  /// In en, this message translates to:
  /// **'Waiting for an unmetered network.'**
  String get syncSettingsAndroidBackgroundWaitingUnmetered;

  /// No description provided for @syncSettingsAndroidBackgroundOutcome.
  ///
  /// In en, this message translates to:
  /// **'Outcome: {outcome}'**
  String syncSettingsAndroidBackgroundOutcome(Object outcome);

  /// No description provided for @syncSettingsCatalogPromotionRemovalSummary.
  ///
  /// In en, this message translates to:
  /// **'Catalog promotion removed {artists} artist(s), {albums} album(s), and {songs} song(s).'**
  String syncSettingsCatalogPromotionRemovalSummary(
    Object artists,
    Object albums,
    Object songs,
  );

  /// No description provided for @syncSettingsStarredReconciliationRemovalSummary.
  ///
  /// In en, this message translates to:
  /// **'Confirmed server update removed {artists} artist(s), {albums} album(s), and {songs} song(s) from Liked.'**
  String syncSettingsStarredReconciliationRemovalSummary(
    Object artists,
    Object albums,
    Object songs,
  );

  /// No description provided for @syncSettingsDegradation.
  ///
  /// In en, this message translates to:
  /// **'Degraded domain: {category}'**
  String syncSettingsDegradation(Object category);

  /// No description provided for @syncSettingsStrategy.
  ///
  /// In en, this message translates to:
  /// **'Strategy: {strategy} — {reason}'**
  String syncSettingsStrategy(Object strategy, Object reason);

  /// No description provided for @syncSettingsPendingWork.
  ///
  /// In en, this message translates to:
  /// **'{count} resumable task(s) pending'**
  String syncSettingsPendingWork(Object count);

  /// No description provided for @librarySyncBacklogBanner.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Library synced, 1 album is still loading details} other{Library synced, {count} albums are still loading details}}'**
  String librarySyncBacklogBanner(int count);

  /// No description provided for @syncSettingsCandidate.
  ///
  /// In en, this message translates to:
  /// **'Candidate generation {generation}: {status}'**
  String syncSettingsCandidate(Object generation, Object status);

  /// No description provided for @syncSettingsCarriedForward.
  ///
  /// In en, this message translates to:
  /// **'{count} unavailable album(s) kept from the previous catalog'**
  String syncSettingsCarriedForward(Object count);

  /// No description provided for @syncSettingsApplyDuration.
  ///
  /// In en, this message translates to:
  /// **'Catalog applied in {milliseconds} ms'**
  String syncSettingsApplyDuration(Object milliseconds);

  /// No description provided for @syncSettingsUsage.
  ///
  /// In en, this message translates to:
  /// **'Last run: {requests} request(s) • {bytes}'**
  String syncSettingsUsage(Object requests, Object bytes);

  /// No description provided for @syncSettingsCheckForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get syncSettingsCheckForUpdates;

  /// No description provided for @syncSettingsFreshnessCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get syncSettingsFreshnessCurrent;

  /// No description provided for @syncSettingsFreshnessPending.
  ///
  /// In en, this message translates to:
  /// **'Verification pending'**
  String get syncSettingsFreshnessPending;

  /// No description provided for @syncSettingsFreshnessRepair.
  ///
  /// In en, this message translates to:
  /// **'Repair recommended'**
  String get syncSettingsFreshnessRepair;

  /// No description provided for @syncSettingsRemainingVerification.
  ///
  /// In en, this message translates to:
  /// **'{count} artists remain to verify'**
  String syncSettingsRemainingVerification(Object count);

  /// No description provided for @syncSettingsIdentitySummary.
  ///
  /// In en, this message translates to:
  /// **'{canonicalized} cached songs canonicalized; {ambiguous} ambiguous matches retained'**
  String syncSettingsIdentitySummary(Object canonicalized, Object ambiguous);

  /// No description provided for @syncSettingsIntervalLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-Sync Interval'**
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

  /// No description provided for @syncSettingsBackgroundUnmeteredOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Background Sync Only on Unmetered Networks'**
  String get syncSettingsBackgroundUnmeteredOnlyLabel;

  /// No description provided for @syncSettingsBackgroundUnmeteredOnlyDescription.
  ///
  /// In en, this message translates to:
  /// **'On mobile or metered Wi-Fi, Navis checks for updates with a single lightweight request and waits for unmetered data before downloading catalog changes.'**
  String get syncSettingsBackgroundUnmeteredOnlyDescription;

  /// No description provided for @syncSettingsUpdatesAvailable.
  ///
  /// In en, this message translates to:
  /// **'Library updates are available and waiting for an unmetered connection.'**
  String get syncSettingsUpdatesAvailable;

  /// No description provided for @syncSettingsUpdatesAvailableMetered.
  ///
  /// In en, this message translates to:
  /// **'Library updates are available. Use mobile data now or wait for unmetered Wi-Fi.'**
  String get syncSettingsUpdatesAvailableMetered;

  /// No description provided for @syncSettingsSyncUsingMobileData.
  ///
  /// In en, this message translates to:
  /// **'Sync using mobile data'**
  String get syncSettingsSyncUsingMobileData;

  /// No description provided for @syncSettingsRepairLibraryMetadata.
  ///
  /// In en, this message translates to:
  /// **'Repair Library'**
  String get syncSettingsRepairLibraryMetadata;

  /// No description provided for @syncSettingsRepairLibraryMetadataDescription.
  ///
  /// In en, this message translates to:
  /// **'Reconcile your local library with the server. Keeps downloads, streaming cache, and artwork.'**
  String get syncSettingsRepairLibraryMetadataDescription;

  /// No description provided for @syncSettingsRepairLibraryMetadataRunning.
  ///
  /// In en, this message translates to:
  /// **'Repairing library...'**
  String get syncSettingsRepairLibraryMetadataRunning;

  /// No description provided for @syncSettingsRepairDeletionConfirmationPending.
  ///
  /// In en, this message translates to:
  /// **'{count} server-missing item(s) are waiting for your confirmation before Navis removes them from the local library.'**
  String syncSettingsRepairDeletionConfirmationPending(Object count);

  /// No description provided for @syncSettingsRepairDeletionConfirmationTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Library Repair'**
  String get syncSettingsRepairDeletionConfirmationTitle;

  /// No description provided for @syncSettingsRepairDeletionConfirmationBody.
  ///
  /// In en, this message translates to:
  /// **'The server no longer reports {count} item(s). Applying this repair will remove them from Navis\'s local library. Downloads and cached audio are kept.'**
  String syncSettingsRepairDeletionConfirmationBody(Object count);

  /// No description provided for @syncSettingsRepairDeletionConfirmationAction.
  ///
  /// In en, this message translates to:
  /// **'Apply Library Repair'**
  String get syncSettingsRepairDeletionConfirmationAction;

  /// No description provided for @syncSettingsRepairDiscardCandidate.
  ///
  /// In en, this message translates to:
  /// **'Discard Repair Candidate'**
  String get syncSettingsRepairDiscardCandidate;

  /// No description provided for @syncSettingsRepairDiscardCandidateTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard Pending Library Repair?'**
  String get syncSettingsRepairDiscardCandidateTitle;

  /// No description provided for @syncSettingsRepairDiscardCandidateBody.
  ///
  /// In en, this message translates to:
  /// **'This removes the uncommitted repair candidate and its deletion confirmation. Your current local library, downloads, and cached audio stay unchanged.'**
  String get syncSettingsRepairDiscardCandidateBody;

  /// No description provided for @syncSettingsRepairMeteredConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Repair Library on Mobile Data?'**
  String get syncSettingsRepairMeteredConfirmTitle;

  /// No description provided for @syncSettingsRepairMeteredConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Repairing your library can download a large amount of metadata over your current connection.'**
  String get syncSettingsRepairMeteredConfirmBody;

  /// No description provided for @syncSettingsRepairMeteredConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Repair on Mobile Data'**
  String get syncSettingsRepairMeteredConfirmAction;

  /// No description provided for @cacheSettingsResetLibraryCache.
  ///
  /// In en, this message translates to:
  /// **'Reset caches & rebuild library'**
  String get cacheSettingsResetLibraryCache;

  /// No description provided for @cacheSettingsResetLibraryCacheDescription.
  ///
  /// In en, this message translates to:
  /// **'Clear local streaming and artwork caches plus library metadata, then rebuild from the server. Downloaded music is kept.'**
  String get cacheSettingsResetLibraryCacheDescription;

  /// No description provided for @cacheSettingsResetLibraryCacheConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset caches & rebuild library?'**
  String get cacheSettingsResetLibraryCacheConfirmTitle;

  /// No description provided for @cacheSettingsResetLibraryCacheConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes your streaming cache, cover art cache, and local library metadata. Downloaded music will be kept. Navis will then rebuild your library from the server.'**
  String get cacheSettingsResetLibraryCacheConfirmBody;

  /// No description provided for @cacheSettingsResetLibraryCacheConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Reset caches & rebuild'**
  String get cacheSettingsResetLibraryCacheConfirmAction;

  /// No description provided for @cacheSettingsResetLibraryCacheMeteredConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Rebuild Library on Mobile Data?'**
  String get cacheSettingsResetLibraryCacheMeteredConfirmTitle;

  /// No description provided for @cacheSettingsResetLibraryCacheMeteredConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Rebuilding your library can download a large amount of metadata over your current connection.'**
  String get cacheSettingsResetLibraryCacheMeteredConfirmBody;

  /// No description provided for @cacheSettingsResetLibraryCacheMeteredConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Rebuild on Mobile Data'**
  String get cacheSettingsResetLibraryCacheMeteredConfirmAction;

  /// No description provided for @cacheSettingsResetLibraryCacheSuccess.
  ///
  /// In en, this message translates to:
  /// **'Library cache reset and full metadata resync completed.'**
  String get cacheSettingsResetLibraryCacheSuccess;

  /// No description provided for @cacheSettingsResetLibraryCacheFailure.
  ///
  /// In en, this message translates to:
  /// **'Cache was reset, but full metadata resync failed.'**
  String get cacheSettingsResetLibraryCacheFailure;

  /// No description provided for @playbackSettingsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Playback Settings'**
  String get playbackSettingsLoadError;

  /// No description provided for @playbackSettingsWifiSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Streaming'**
  String get playbackSettingsWifiSectionTitle;

  /// No description provided for @playbackSettingsWifiQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Max Bitrate'**
  String get playbackSettingsWifiQualityLabel;

  /// No description provided for @playbackSettingsWifiFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Preferred Format'**
  String get playbackSettingsWifiFormatLabel;

  /// No description provided for @playbackSettingsCellularSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Cellular Streaming'**
  String get playbackSettingsCellularSectionTitle;

  /// No description provided for @playbackSettingsCellularQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Max Bitrate'**
  String get playbackSettingsCellularQualityLabel;

  /// No description provided for @playbackSettingsCellularFormatLabel.
  ///
  /// In en, this message translates to:
  /// **'Preferred Format'**
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
  /// **'Enable Scrobbling'**
  String get playbackSettingsScrobbleTitle;

  /// No description provided for @playbackSettingsScrobbleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Report tracks you play to the server (now-playing and play counts). Disable to listen anonymously.'**
  String get playbackSettingsScrobbleSubtitle;

  /// No description provided for @playbackSettingsLrclibTitle.
  ///
  /// In en, this message translates to:
  /// **'Use LRCLIB Fallback'**
  String get playbackSettingsLrclibTitle;

  /// No description provided for @playbackSettingsLrclibSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When server lyrics are unavailable, try LRCLIB and cache per song.'**
  String get playbackSettingsLrclibSubtitle;

  /// No description provided for @playbackSettingsGaplessTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Gapless Playback'**
  String get playbackSettingsGaplessTitle;

  /// No description provided for @playbackSettingsGaplessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Preload tracks to reduce gaps between songs.'**
  String get playbackSettingsGaplessSubtitle;

  /// No description provided for @playbackSettingsLegacyInstantMixTitle.
  ///
  /// In en, this message translates to:
  /// **'Server mix'**
  String get playbackSettingsLegacyInstantMixTitle;

  /// No description provided for @playbackSettingsLegacyInstantMixSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your server\'s song recommendations. Turn off for Last.fm · Same Vibes.'**
  String get playbackSettingsLegacyInstantMixSubtitle;

  /// No description provided for @playbackSettingsLastFmSameVibesTitle.
  ///
  /// In en, this message translates to:
  /// **'Last.fm · Same Vibes'**
  String get playbackSettingsLastFmSameVibesTitle;

  /// No description provided for @playbackSettingsLastFmSameVibesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Match Last.fm recommendations to your library. Turn on for Server mix.'**
  String get playbackSettingsLastFmSameVibesSubtitle;

  /// No description provided for @playbackSettingsLegacyInstantMixLocked.
  ///
  /// In en, this message translates to:
  /// **'This build has no Last.fm API key, so Server mix is required.'**
  String get playbackSettingsLegacyInstantMixLocked;

  /// No description provided for @playbackSettingsShowRadioPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Radio Page'**
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
  /// **'Enable Equalizer'**
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
  /// **'Enable Loudness Enhancer'**
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
  /// **'Reset Defaults'**
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
  /// **'Could not save playback settings. Try again.'**
  String get playbackSettingsSaveFailure;

  /// No description provided for @playbackSettingsResetSuccess.
  ///
  /// In en, this message translates to:
  /// **'Playback settings reset to defaults.'**
  String get playbackSettingsResetSuccess;

  /// No description provided for @playbackSettingsResetFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not reset playback settings. Try again.'**
  String get playbackSettingsResetFailure;

  /// No description provided for @playbackSettingsCrossfadeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Cross-fade'**
  String get playbackSettingsCrossfadeSectionTitle;

  /// No description provided for @playbackSettingsCrossfadeEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Cross-Fade'**
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
  /// **'Cross-Fade Mode'**
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

  /// No description provided for @playbackVolumeSemanticLabel.
  ///
  /// In en, this message translates to:
  /// **'Playback volume'**
  String get playbackVolumeSemanticLabel;

  /// No description provided for @playbackMuteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Mute playback'**
  String get playbackMuteTooltip;

  /// No description provided for @playbackUnmuteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unmute playback'**
  String get playbackUnmuteTooltip;

  /// No description provided for @playbackSettingsReplayGainModeLabel.
  ///
  /// In en, this message translates to:
  /// **'ReplayGain Mode'**
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
  /// **'Playback Speed'**
  String get playbackSettingsPlaybackSpeedLabel;

  /// No description provided for @playbackSettingsCloseAction.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get playbackSettingsCloseAction;

  /// No description provided for @playbackSettingsFullscreenLyricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Fullscreen Mode Lyrics'**
  String get playbackSettingsFullscreenLyricsTitle;

  /// No description provided for @playbackSettingsFullscreenLyricsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open lyrics in fullscreen directly from Now Playing.'**
  String get playbackSettingsFullscreenLyricsSubtitle;

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

  /// No description provided for @playbackSettingsExperimentalTitle.
  ///
  /// In en, this message translates to:
  /// **'Experimental'**
  String get playbackSettingsExperimentalTitle;

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
  /// **'Could Not Load Section'**
  String get homeLoadErrorTitle;

  /// No description provided for @weeklyPlaylistTitle.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz Weekly'**
  String get weeklyPlaylistTitle;

  /// No description provided for @weeklyPlaylistJamsTitle.
  ///
  /// In en, this message translates to:
  /// **'Weekly Jams'**
  String get weeklyPlaylistJamsTitle;

  /// No description provided for @weeklyPlaylistExplorationTitle.
  ///
  /// In en, this message translates to:
  /// **'Weekly Exploration'**
  String get weeklyPlaylistExplorationTitle;

  /// No description provided for @weeklyPlaylistServiceName.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz'**
  String get weeklyPlaylistServiceName;

  /// No description provided for @weeklyPlaylistLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Weekly Playlist'**
  String get weeklyPlaylistLoadError;

  /// No description provided for @weeklyPlaylistUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'No Weekly Playlist Available'**
  String get weeklyPlaylistUnavailableTitle;

  /// No description provided for @weeklyPlaylistUnavailableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Refresh to check for a new playlist.'**
  String get weeklyPlaylistUnavailableSubtitle;

  /// No description provided for @weeklyPlaylistMatchAction.
  ///
  /// In en, this message translates to:
  /// **'Match'**
  String get weeklyPlaylistMatchAction;

  /// No description provided for @weeklyPlaylistMatchSuccess.
  ///
  /// In en, this message translates to:
  /// **'Matched {matched} of {total} tracks'**
  String weeklyPlaylistMatchSuccess(int matched, int total);

  /// No description provided for @weeklyPlaylistMatchError.
  ///
  /// In en, this message translates to:
  /// **'Could not match this playlist. Try again.'**
  String get weeklyPlaylistMatchError;

  /// No description provided for @weeklyPlaylistTrackCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No tracks} =1{1 track} other{{count} tracks}}'**
  String weeklyPlaylistTrackCount(int count);

  /// No description provided for @weeklyPlaylistAvailableMatching.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No tracks available, matching} =1{1 track available, matching} other{{count} tracks available, matching}}'**
  String weeklyPlaylistAvailableMatching(int count);

  /// No description provided for @weeklyPlaylistAvailableCount.
  ///
  /// In en, this message translates to:
  /// **'{matched} of {total} available'**
  String weeklyPlaylistAvailableCount(int matched, int total);

  /// No description provided for @weeklyPlaylistFetching.
  ///
  /// In en, this message translates to:
  /// **'Fetching ListenBrainz playlist...'**
  String get weeklyPlaylistFetching;

  /// No description provided for @weeklyPlaylistLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading playlist...'**
  String get weeklyPlaylistLoading;

  /// No description provided for @weeklyPlaylistNoTracksYet.
  ///
  /// In en, this message translates to:
  /// **'No tracks yet'**
  String get weeklyPlaylistNoTracksYet;

  /// No description provided for @weeklyPlaylistReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get weeklyPlaylistReady;

  /// No description provided for @weeklyPlaylistMatching.
  ///
  /// In en, this message translates to:
  /// **'Matching'**
  String get weeklyPlaylistMatching;

  /// No description provided for @weeklyPlaylistSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get weeklyPlaylistSearchAction;

  /// No description provided for @weeklyPlaylistAmbiguousMatch.
  ///
  /// In en, this message translates to:
  /// **'Ambiguous match'**
  String get weeklyPlaylistAmbiguousMatch;

  /// No description provided for @weeklyPlaylistTrackUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available on your server'**
  String get weeklyPlaylistTrackUnavailable;

  /// No description provided for @homeContinueListeningTitle.
  ///
  /// In en, this message translates to:
  /// **'Continue Listening'**
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
  /// **'Recently Liked Albums'**
  String get homeRecentlyLikedAlbumsTitle;

  /// No description provided for @homeRecentlyLikedAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Liked Albums Yet'**
  String get homeRecentlyLikedAlbumsEmptyTitle;

  /// No description provided for @homeRecentlyLikedAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like albums to pin your favorites here.'**
  String get homeRecentlyLikedAlbumsEmptySubtitle;

  /// No description provided for @homeRecentlyPlayedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently Played'**
  String get homeRecentlyPlayedTitle;

  /// No description provided for @homeRecentlyPlayedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Recent Plays Yet'**
  String get homeRecentlyPlayedEmptyTitle;

  /// No description provided for @homeRecentlyPlayedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start playback to populate this section.'**
  String get homeRecentlyPlayedEmptySubtitle;

  /// No description provided for @homeRecentlyAddedTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently Added'**
  String get homeRecentlyAddedTitle;

  /// No description provided for @homeRecentlyAddedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Recently Added Albums'**
  String get homeRecentlyAddedEmptyTitle;

  /// No description provided for @homeRecentlyAddedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pull to refresh to fetch newly added albums.'**
  String get homeRecentlyAddedEmptySubtitle;

  /// No description provided for @homeFrequentTitle.
  ///
  /// In en, this message translates to:
  /// **'Frequent Albums'**
  String get homeFrequentTitle;

  /// No description provided for @homeFrequentEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Frequent Albums Yet'**
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
  /// **'No Recommendations Available'**
  String get homeRandomEmptyTitle;

  /// No description provided for @homeRandomEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Like more songs or pull to refresh to discover new picks.'**
  String get homeRandomEmptySubtitle;

  /// No description provided for @homeStarredTitle.
  ///
  /// In en, this message translates to:
  /// **'Liked Tracks'**
  String get homeStarredTitle;

  /// No description provided for @homeStarredEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Liked Tracks'**
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
  /// **'Most Played Tracks'**
  String get homeMostPlayedTracksTitle;

  /// No description provided for @homeMostPlayedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Play Data Yet'**
  String get homeMostPlayedTracksEmptyTitle;

  /// No description provided for @homeMostPlayedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Play more music to populate this section.'**
  String get homeMostPlayedTracksEmptySubtitle;

  /// No description provided for @homeRecentlyPlayedTracksTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently Played Tracks'**
  String get homeRecentlyPlayedTracksTitle;

  /// No description provided for @homeRecentlyPlayedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Recently Played Tracks'**
  String get homeRecentlyPlayedTracksEmptyTitle;

  /// No description provided for @homeRecentlyPlayedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start listening to populate this section.'**
  String get homeRecentlyPlayedTracksEmptySubtitle;

  /// No description provided for @homeRecentlyPlayedAlbumsTitle.
  ///
  /// In en, this message translates to:
  /// **'Recently Played Albums'**
  String get homeRecentlyPlayedAlbumsTitle;

  /// No description provided for @homeRecentlyPlayedAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Recently Played Albums'**
  String get homeRecentlyPlayedAlbumsEmptyTitle;

  /// No description provided for @homeRecentlyPlayedAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start listening to populate this section.'**
  String get homeRecentlyPlayedAlbumsEmptySubtitle;

  /// No description provided for @homeQuickActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick Actions'**
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
  /// **'No Radio Stations Found'**
  String get radioEmptyTitle;

  /// No description provided for @radioEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add internet radio stations on your server to see them here.'**
  String get radioEmptySubtitle;

  /// No description provided for @radioFilteredEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Stations Match “{query}”'**
  String radioFilteredEmptyTitle(String query);

  /// No description provided for @radioFilteredEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a different filter, or show all stations.'**
  String get radioFilteredEmptySubtitle;

  /// No description provided for @radioFilteredEmptyAction.
  ///
  /// In en, this message translates to:
  /// **'Show All Stations'**
  String get radioFilteredEmptyAction;

  /// No description provided for @radioLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Radio Stations'**
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
  /// **'Could Not Load Server Settings.'**
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
  /// **'API Version'**
  String get serverSettingsApiVersionLabel;

  /// No description provided for @serverSettingsAuthModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Auth Mode'**
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
  /// **'Repair Library'**
  String get serverSettingsForceFullSync;

  /// No description provided for @serverSettingsForceFullSyncRunning.
  ///
  /// In en, this message translates to:
  /// **'Repair in progress...'**
  String get serverSettingsForceFullSyncRunning;

  /// No description provided for @serverSettingsForceFullSyncSuccess.
  ///
  /// In en, this message translates to:
  /// **'Library repair completed.'**
  String get serverSettingsForceFullSyncSuccess;

  /// No description provided for @serverSettingsForceFullSyncFailure.
  ///
  /// In en, this message translates to:
  /// **'Library repair failed: {message}'**
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
  /// **'External Services'**
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

  /// No description provided for @configurationLastFmApiKeyInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid Last.fm API key.'**
  String get configurationLastFmApiKeyInvalid;

  /// No description provided for @configurationLastFmApiKeyRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Last.fm is rate limiting validation. Try again later.'**
  String get configurationLastFmApiKeyRateLimited;

  /// No description provided for @configurationLastFmApiKeyValidationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not validate this Last.fm API key.'**
  String get configurationLastFmApiKeyValidationFailed;

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

  /// No description provided for @configurationShowSecret.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get configurationShowSecret;

  /// No description provided for @configurationHideSecret.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get configurationHideSecret;

  /// No description provided for @configurationClearSecret.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get configurationClearSecret;

  /// No description provided for @configurationListenBrainzTokenLabel.
  ///
  /// In en, this message translates to:
  /// **'User Token'**
  String get configurationListenBrainzTokenLabel;

  /// No description provided for @configurationListenBrainzTokenRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a ListenBrainz user token.'**
  String get configurationListenBrainzTokenRequired;

  /// No description provided for @configurationListenBrainzTokenInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid ListenBrainz token.'**
  String get configurationListenBrainzTokenInvalid;

  /// No description provided for @configurationListenBrainzTokenValidated.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz token validated.'**
  String get configurationListenBrainzTokenValidated;

  /// No description provided for @configurationListenBrainzUnavailable.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz is unavailable. Check your connection and try again.'**
  String get configurationListenBrainzUnavailable;

  /// No description provided for @configurationListenBrainzValidateAndSave.
  ///
  /// In en, this message translates to:
  /// **'Validate and save'**
  String get configurationListenBrainzValidateAndSave;

  /// No description provided for @configurationListenBrainzGetToken.
  ///
  /// In en, this message translates to:
  /// **'Get Token'**
  String get configurationListenBrainzGetToken;

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

  /// No description provided for @commonErrorRecoveryHint.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get commonErrorRecoveryHint;

  /// No description provided for @detailUnavailableBackToLibrary.
  ///
  /// In en, this message translates to:
  /// **'Back to Library'**
  String get detailUnavailableBackToLibrary;

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

  /// No description provided for @libraryFilteringLabel.
  ///
  /// In en, this message translates to:
  /// **'Filtering: \"{query}\"'**
  String libraryFilteringLabel(String query);

  /// No description provided for @libraryFilterNoResults.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String libraryFilterNoResults(String query);

  /// No description provided for @libraryFilterNoResultsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a different search'**
  String get libraryFilterNoResultsSubtitle;

  /// No description provided for @libraryTabArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get libraryTabArtists;

  /// No description provided for @librarySwitchToArtistGrid.
  ///
  /// In en, this message translates to:
  /// **'Switch to artist grid view'**
  String get librarySwitchToArtistGrid;

  /// No description provided for @librarySwitchToArtistList.
  ///
  /// In en, this message translates to:
  /// **'Switch to artist list view'**
  String get librarySwitchToArtistList;

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
  /// **'Scanning songs'**
  String get librarySyncStageSongs;

  /// No description provided for @librarySyncStageStarred.
  ///
  /// In en, this message translates to:
  /// **'Updating liked items'**
  String get librarySyncStageStarred;

  /// No description provided for @librarySyncStageGenres.
  ///
  /// In en, this message translates to:
  /// **'Fetching genres'**
  String get librarySyncStageGenres;

  /// No description provided for @librarySyncStagePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Updating playlists'**
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

  /// No description provided for @librarySyncScanningSongIndex.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Scanning song index ({count} songs found)'**
  String librarySyncScanningSongIndex(int count);

  /// No description provided for @librarySyncHydratingUnknown.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Fetching remaining album details...'**
  String get librarySyncHydratingUnknown;

  /// No description provided for @librarySyncHydratingProgress.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Fetching remaining album details ({processed}/{total}, {pending} remaining)'**
  String librarySyncHydratingProgress(int processed, int total, int pending);

  /// No description provided for @librarySyncHydratingProgressWithRate.
  ///
  /// In en, this message translates to:
  /// **'Metadata ready. Fetching remaining album details ({processed}/{total}, {pending} remaining, {rate} albums/s)'**
  String librarySyncHydratingProgressWithRate(
    int processed,
    int total,
    int pending,
    Object rate,
  );

  /// No description provided for @libraryArtistsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Artists Found'**
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
  /// **'Could Not Load Artists'**
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
  /// **'Nothing Liked Yet'**
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
  /// **'No Liked Matches'**
  String get libraryLikedOnlyEmptyTitle;

  /// No description provided for @libraryNoPagesEnabledTitle.
  ///
  /// In en, this message translates to:
  /// **'No Library Pages Enabled'**
  String get libraryNoPagesEnabledTitle;

  /// No description provided for @libraryNoPagesEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable a page in Appearance settings to browse your library.'**
  String get libraryNoPagesEnabledSubtitle;

  /// No description provided for @libraryNoPagesEnabledAction.
  ///
  /// In en, this message translates to:
  /// **'Open Appearance Settings'**
  String get libraryNoPagesEnabledAction;

  /// No description provided for @libraryLikedOnlyEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try turning off the liked filter or like more content.'**
  String get libraryLikedOnlyEmptySubtitle;

  /// No description provided for @libraryAlbumsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Albums Found'**
  String get libraryAlbumsEmptyTitle;

  /// No description provided for @libraryAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get libraryAlbumsEmptySubtitle;

  /// No description provided for @libraryAlbumsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Albums'**
  String get libraryAlbumsErrorTitle;

  /// No description provided for @libraryAlbumsByYearEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Albums with Year Data'**
  String get libraryAlbumsByYearEmptyTitle;

  /// No description provided for @libraryAlbumsByYearEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync more metadata or change filters to browse by year.'**
  String get libraryAlbumsByYearEmptySubtitle;

  /// No description provided for @libraryAlbumsSortLabel.
  ///
  /// In en, this message translates to:
  /// **'Sort Albums By'**
  String get libraryAlbumsSortLabel;

  /// No description provided for @libraryAlbumsPagingProgress.
  ///
  /// In en, this message translates to:
  /// **'Loaded {loaded} of {total} albums'**
  String libraryAlbumsPagingProgress(int loaded, int total);

  /// No description provided for @librarySongsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Songs Found'**
  String get librarySongsEmptyTitle;

  /// No description provided for @librarySongsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get librarySongsEmptySubtitle;

  /// No description provided for @librarySongsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Songs'**
  String get librarySongsErrorTitle;

  /// No description provided for @librarySongsSortLabel.
  ///
  /// In en, this message translates to:
  /// **'Sort Songs By'**
  String get librarySongsSortLabel;

  /// No description provided for @libraryGenresEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Genres Found'**
  String get libraryGenresEmptyTitle;

  /// No description provided for @libraryGenresEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Run a sync to populate your library.'**
  String get libraryGenresEmptySubtitle;

  /// No description provided for @libraryGenresErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Genres'**
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

  /// No description provided for @libraryArtistAddedToQueue.
  ///
  /// In en, this message translates to:
  /// **'Artist added to queue'**
  String get libraryArtistAddedToQueue;

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
  /// **'Add to Queue'**
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
  /// **'No Albums in This Genre'**
  String get libraryGenreAlbumsEmptyTitle;

  /// No description provided for @libraryGenreAlbumsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync to refresh genre albums.'**
  String get libraryGenreAlbumsEmptySubtitle;

  /// No description provided for @libraryGenreSongsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Songs in This Genre'**
  String get libraryGenreSongsEmptyTitle;

  /// No description provided for @libraryGenreSongsEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync to refresh genre songs.'**
  String get libraryGenreSongsEmptySubtitle;

  /// No description provided for @libraryGenreLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Genre'**
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
  /// **'Artist Not Found'**
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
  /// **'No Albums for This Artist'**
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
  /// **'Similar Artists'**
  String get artistDetailSimilarSection;

  /// No description provided for @artistDetailAlbumsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Artist Albums'**
  String get artistDetailAlbumsErrorTitle;

  /// No description provided for @artistDetailLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Artist Details'**
  String get artistDetailLoadErrorTitle;

  /// No description provided for @artistDetailLoadingLabel.
  ///
  /// In en, this message translates to:
  /// **'Loading Artist Details'**
  String get artistDetailLoadingLabel;

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

  /// No description provided for @artistTopTracksPlaylistTitle.
  ///
  /// In en, this message translates to:
  /// **'This Is {artist}'**
  String artistTopTracksPlaylistTitle(String artist);

  /// No description provided for @artistTopTracksPlaylistUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available in your library'**
  String get artistTopTracksPlaylistUnavailable;

  /// No description provided for @artistTopTracksPlaylistSearchAction.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get artistTopTracksPlaylistSearchAction;

  /// No description provided for @artistTopTracksPlaylistEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Top Tracks'**
  String get artistTopTracksPlaylistEmptyTitle;

  /// No description provided for @artistTopTracksPlaylistEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Last.fm did not return tracks for this artist.'**
  String get artistTopTracksPlaylistEmptySubtitle;

  /// No description provided for @artistTopTracksPlaylistErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Failed to Load Top Tracks'**
  String get artistTopTracksPlaylistErrorTitle;

  /// No description provided for @albumDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get albumDetailTitle;

  /// No description provided for @albumDetailNotFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Album Not Found'**
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
  /// **'No Tracks for This Album'**
  String get albumDetailTracksEmptyTitle;

  /// No description provided for @albumDetailTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync your library to load album tracks.'**
  String get albumDetailTracksEmptySubtitle;

  /// No description provided for @albumDetailLikedTracksEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No Liked Tracks in This Album'**
  String get albumDetailLikedTracksEmptyTitle;

  /// No description provided for @albumDetailLikedTracksEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'None of the tracks in this album have been liked yet.'**
  String get albumDetailLikedTracksEmptySubtitle;

  /// No description provided for @albumDetailShowAllTracksAction.
  ///
  /// In en, this message translates to:
  /// **'Show All Tracks'**
  String get albumDetailShowAllTracksAction;

  /// Label above the filter chips in the album detail screen
  ///
  /// In en, this message translates to:
  /// **'Filters'**
  String get albumDetailFilterLabel;

  /// No description provided for @albumDetailLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Album Details'**
  String get albumDetailLoadErrorTitle;

  /// No description provided for @albumDetailRefreshError.
  ///
  /// In en, this message translates to:
  /// **'Could not refresh this album. Check your connection and try again.'**
  String get albumDetailRefreshError;

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
  /// **'About This Album'**
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
  /// **'Preparing Playback'**
  String get playbackBootstrapLoadingTitle;

  /// No description provided for @playbackBootstrapLoadingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restoring your listening session…'**
  String get playbackBootstrapLoadingSubtitle;

  /// No description provided for @playbackBootstrapRecoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Playback Is Taking Longer Than Usual'**
  String get playbackBootstrapRecoveryTitle;

  /// No description provided for @playbackBootstrapRecoverySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Navis will keep retrying. You can also recover local playback data or continue without playback.'**
  String get playbackBootstrapRecoverySubtitle;

  /// No description provided for @playbackBootstrapContinueToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Continue to sign in'**
  String get playbackBootstrapContinueToSignIn;

  /// No description provided for @playbackRecoveryRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry playback'**
  String get playbackRecoveryRetry;

  /// No description provided for @playbackRecoveryResetCache.
  ///
  /// In en, this message translates to:
  /// **'Reset library cache and retry'**
  String get playbackRecoveryResetCache;

  /// No description provided for @playbackRecoveryResetConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset Library Cache?'**
  String get playbackRecoveryResetConfirmTitle;

  /// No description provided for @playbackRecoveryResetConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes your streaming cache, cover art cache, and local library metadata. Downloaded music and your sign-in will be kept.'**
  String get playbackRecoveryResetConfirmBody;

  /// No description provided for @playbackRecoveryResetConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Reset Cache'**
  String get playbackRecoveryResetConfirmAction;

  /// No description provided for @playbackRecoveryWipeConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign Out and Clear Local Data?'**
  String get playbackRecoveryWipeConfirmTitle;

  /// No description provided for @playbackRecoveryWipeConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes your sign-in, downloaded music, caches, library metadata, and history from this device.'**
  String get playbackRecoveryWipeConfirmBody;

  /// No description provided for @playbackRecoveryWipeConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Clear Local Data'**
  String get playbackRecoveryWipeConfirmAction;

  /// No description provided for @playbackRecoveryActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete playback recovery. Try again.'**
  String get playbackRecoveryActionFailed;

  /// No description provided for @playbackRecoverySheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Playback Unavailable'**
  String get playbackRecoverySheetTitle;

  /// No description provided for @playbackRecoverySheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You can keep browsing Navis. Choose a recovery action before trying playback again.'**
  String get playbackRecoverySheetSubtitle;

  /// No description provided for @playbackUnavailableInitializing.
  ///
  /// In en, this message translates to:
  /// **'Playback is still initializing. Try again in a moment.'**
  String get playbackUnavailableInitializing;

  /// No description provided for @playbackUnavailableStartupFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback is restarting. Try again in a moment.'**
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

  /// No description provided for @queueUnavailableTrackDescription.
  ///
  /// In en, this message translates to:
  /// **'This track is no longer available in your library.'**
  String get queueUnavailableTrackDescription;

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

  /// No description provided for @queueTrackLoadErrorDescription.
  ///
  /// In en, this message translates to:
  /// **'This track couldn\'t be loaded. You can remove it from the queue or try again later.'**
  String get queueTrackLoadErrorDescription;

  /// No description provided for @queueClearAction.
  ///
  /// In en, this message translates to:
  /// **'Clear Queue'**
  String get queueClearAction;

  /// No description provided for @queueClearConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear Queue?'**
  String get queueClearConfirmTitle;

  /// No description provided for @queueClearConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This will remove all tracks from the queue.'**
  String get queueClearConfirmMessage;

  /// No description provided for @queueEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Queue Is Empty'**
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

  /// No description provided for @nowPlayingRestartCurrent.
  ///
  /// In en, this message translates to:
  /// **'Restarting current track'**
  String get nowPlayingRestartCurrent;

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

  /// No description provided for @nowPlayingNoNextTrack.
  ///
  /// In en, this message translates to:
  /// **'No next track'**
  String get nowPlayingNoNextTrack;

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
  /// **'Queue Modes'**
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

  /// No description provided for @nowPlayingTranscodedPlayback.
  ///
  /// In en, this message translates to:
  /// **'Transcoded playback'**
  String get nowPlayingTranscodedPlayback;

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
  /// **'No Lyrics Available'**
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
  /// **'No Rating'**
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

  /// No description provided for @quickSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search library...'**
  String get quickSearchHint;

  /// No description provided for @quickSearchSubmitTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get quickSearchSubmitTooltip;

  /// No description provided for @quickSearchEverything.
  ///
  /// In en, this message translates to:
  /// **'Search Everything'**
  String get quickSearchEverything;

  /// No description provided for @instantRadioAction.
  ///
  /// In en, this message translates to:
  /// **'Instant Radio'**
  String get instantRadioAction;

  /// No description provided for @instantRadioLoading.
  ///
  /// In en, this message translates to:
  /// **'Starting radio…'**
  String get instantRadioLoading;

  /// No description provided for @instantRadioStop.
  ///
  /// In en, this message translates to:
  /// **'Stop radio'**
  String get instantRadioStop;

  /// No description provided for @instantRadioEmpty.
  ///
  /// In en, this message translates to:
  /// **'No playable songs match these filters.'**
  String get instantRadioEmpty;

  /// No description provided for @instantRadioError.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t start radio. Check your connection or try again.'**
  String get instantRadioError;

  /// No description provided for @instantRadioFallback.
  ///
  /// In en, this message translates to:
  /// **'Radio is using music from your library.'**
  String get instantRadioFallback;

  /// No description provided for @instantRadioRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry radio'**
  String get instantRadioRetry;

  /// No description provided for @sameVibesInvalidKey.
  ///
  /// In en, this message translates to:
  /// **'Last.fm rejected the API key. Update it in Settings and retry.'**
  String get sameVibesInvalidKey;

  /// No description provided for @sameVibesRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Last.fm is limiting requests. Try again later.'**
  String get sameVibesRateLimited;

  /// No description provided for @searchRecentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent Searches'**
  String get searchRecentTitle;

  /// No description provided for @searchClearRecent.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchClearRecent;

  /// No description provided for @searchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No Results Found'**
  String get searchNoResults;

  /// No description provided for @searchNoResultsForQuery.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String searchNoResultsForQuery(String query);

  /// No description provided for @searchNoResultsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a different search term.'**
  String get searchNoResultsSubtitle;

  /// No description provided for @searchLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Search Results'**
  String get searchLoadError;

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
  /// **'Add to Queue'**
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
  /// **'No Playlists Yet'**
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
  /// **'New Playlist'**
  String get playlistsCreateAction;

  /// No description provided for @playlistsCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Playlist'**
  String get playlistsCreateTitle;

  /// No description provided for @playlistsCreateNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Playlist Name'**
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
  /// **'Delete Playlist?'**
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
  /// **'Rename Playlist'**
  String get playlistsRenameTitle;

  /// No description provided for @playlistsRenameLabel.
  ///
  /// In en, this message translates to:
  /// **'New Name'**
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
  /// **'No Tracks'**
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
  /// **'Add to Playlist'**
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
  /// **'Streaming Cache'**
  String get cacheSettingsRollingSection;

  /// No description provided for @cacheSettingsRollingDescription.
  ///
  /// In en, this message translates to:
  /// **'Recently streamed tracks are cached automatically. Oldest tracks are evicted when the budget is exceeded.'**
  String get cacheSettingsRollingDescription;

  /// No description provided for @cacheSettingsRollingBudgetLabel.
  ///
  /// In en, this message translates to:
  /// **'Cache Budget'**
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

  /// No description provided for @cacheSettingsRollingCaching.
  ///
  /// In en, this message translates to:
  /// **'Caching current track…'**
  String get cacheSettingsRollingCaching;

  /// No description provided for @cacheSettingsRollingCachingProgress.
  ///
  /// In en, this message translates to:
  /// **'Caching current track… {percent}%'**
  String cacheSettingsRollingCachingProgress(int percent);

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
  /// **'Downloaded Tracks'**
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
  /// **'Download Quality'**
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
  /// **'No Pending Downloads'**
  String get downloadsQueueEmpty;

  /// No description provided for @downloadsQueueEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download tracks from albums or playlists for offline listening.'**
  String get downloadsQueueEmptySubtitle;

  /// No description provided for @downloadsDownloadedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No Downloaded Tracks'**
  String get downloadsDownloadedEmpty;

  /// No description provided for @downloadsDownloadedEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Downloaded tracks will appear here.'**
  String get downloadsDownloadedEmptySubtitle;

  /// No description provided for @downloadsRemoveAction.
  ///
  /// In en, this message translates to:
  /// **'Remove Download'**
  String get downloadsRemoveAction;

  /// No description provided for @downloadsOpenFolderAction.
  ///
  /// In en, this message translates to:
  /// **'Open Downloaded Folder'**
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
  /// **'Cancel Download'**
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
  /// **'Could Not Load Download Queue.'**
  String get downloadsErrorLoadingQueue;

  /// No description provided for @downloadsClearQueue.
  ///
  /// In en, this message translates to:
  /// **'Clear Queue'**
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
  /// **'Choose Folder'**
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
  /// **'No Downloaded Content'**
  String get libraryDownloadedOnlyEmpty;

  /// No description provided for @libraryDownloadedOnlyEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download albums or tracks to see them here.'**
  String get libraryDownloadedOnlyEmptySubtitle;

  /// No description provided for @libraryClearFiltersAction.
  ///
  /// In en, this message translates to:
  /// **'Show All'**
  String get libraryClearFiltersAction;

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
  /// **'Allow Liked Downloads on Mobile Data?'**
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

  /// No description provided for @externalSourceBadgeLabel.
  ///
  /// In en, this message translates to:
  /// **'Remote source — not in your server library.'**
  String get externalSourceBadgeLabel;

  /// No description provided for @remoteSourceLabel.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get remoteSourceLabel;

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

  /// No description provided for @appearanceLanguageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Language switching is disabled in this build.'**
  String get appearanceLanguageUnavailable;

  /// No description provided for @appearanceLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get appearanceLanguageEnglish;

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

  /// No description provided for @appearanceColorSchemeDynamicSub.
  ///
  /// In en, this message translates to:
  /// **'Selected colors are used when album art has no available accent.'**
  String get appearanceColorSchemeDynamicSub;

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

  /// No description provided for @appearanceColorCustomSemantics.
  ///
  /// In en, this message translates to:
  /// **'{label}, custom color'**
  String appearanceColorCustomSemantics(Object label);

  /// No description provided for @appearanceColorPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a Custom Color'**
  String get appearanceColorPickerTitle;

  /// No description provided for @appearanceColorPickerHexLabel.
  ///
  /// In en, this message translates to:
  /// **'Hex'**
  String get appearanceColorPickerHexLabel;

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

  /// No description provided for @appearanceDynamicAlbumColorLabel.
  ///
  /// In en, this message translates to:
  /// **'Dynamic Album Color'**
  String get appearanceDynamicAlbumColorLabel;

  /// No description provided for @appearanceDynamicAlbumColorEnabledSub.
  ///
  /// In en, this message translates to:
  /// **'Album art is currently overriding the selected color when artwork is available.'**
  String get appearanceDynamicAlbumColorEnabledSub;

  /// No description provided for @appearanceDynamicAlbumColorDisabledSub.
  ///
  /// In en, this message translates to:
  /// **'Use the currently playing album art to theme app accent colors.'**
  String get appearanceDynamicAlbumColorDisabledSub;

  /// No description provided for @cacheSettingsCoverArtSection.
  ///
  /// In en, this message translates to:
  /// **'Cover Art Cache'**
  String get cacheSettingsCoverArtSection;

  /// No description provided for @cacheSettingsCoverArtDescription.
  ///
  /// In en, this message translates to:
  /// **'Cached album artwork images. Larger limits reduce network requests but use more storage.'**
  String get cacheSettingsCoverArtDescription;

  /// No description provided for @cacheSettingsCoverArtMaxLabel.
  ///
  /// In en, this message translates to:
  /// **'Maximum Images'**
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
  /// **'No Limit'**
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
  /// **'Changelog'**
  String get aboutChangelog;

  /// No description provided for @aboutChangelogSub.
  ///
  /// In en, this message translates to:
  /// **'See every version\'s changes and bug fixes.'**
  String get aboutChangelogSub;

  /// No description provided for @whatsNewTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s New'**
  String get whatsNewTitle;

  /// No description provided for @changelogDialogBugFixesTitle.
  ///
  /// In en, this message translates to:
  /// **'Bug Fixes'**
  String get changelogDialogBugFixesTitle;

  /// No description provided for @changelogDialogOtherBugFixes.
  ///
  /// In en, this message translates to:
  /// **'Other bug fixes'**
  String get changelogDialogOtherBugFixes;

  /// No description provided for @changelogSpecialThanks.
  ///
  /// In en, this message translates to:
  /// **'Special Thanks'**
  String get changelogSpecialThanks;

  /// No description provided for @changelogDialogViewAll.
  ///
  /// In en, this message translates to:
  /// **'View full changelog'**
  String get changelogDialogViewAll;

  /// No description provided for @changelogDialogGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get changelogDialogGotIt;

  /// No description provided for @changelogDiscoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'What’s New'**
  String get changelogDiscoveryTitle;

  /// No description provided for @changelogDiscoveryVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String changelogDiscoveryVersion(String version);

  /// No description provided for @changelogDiscoveryFixesSummary.
  ///
  /// In en, this message translates to:
  /// **'This update includes reliability and polish improvements.'**
  String get changelogDiscoveryFixesSummary;

  /// No description provided for @changelogDiscoveryAction.
  ///
  /// In en, this message translates to:
  /// **'View Updates'**
  String get changelogDiscoveryAction;

  /// No description provided for @changelogDiscoveryDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss update notes'**
  String get changelogDiscoveryDismiss;

  /// No description provided for @changelogDiscoverySemanticLabel.
  ///
  /// In en, this message translates to:
  /// **'What’s new in version {version}'**
  String changelogDiscoverySemanticLabel(String version);

  /// No description provided for @changelogEmpty.
  ///
  /// In en, this message translates to:
  /// **'No Changelog Entries Yet.'**
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
  /// **'No Usage Recorded Yet.'**
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
  /// **'Reset Usage Stats?'**
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
  /// **'Check for Updates'**
  String get updateCheckTitle;

  /// No description provided for @updateCheckSub.
  ///
  /// In en, this message translates to:
  /// **'Currently on {version}. Tap to check now.'**
  String updateCheckSub(String version);

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update Available'**
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

  /// No description provided for @updatePlayStoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Update on Google Play'**
  String get updatePlayStoreTitle;

  /// No description provided for @updatePlayStoreBody.
  ///
  /// In en, this message translates to:
  /// **'{version} is available on Google Play. Update there to get the latest release.'**
  String updatePlayStoreBody(String version);

  /// No description provided for @updateOpenPlayStore.
  ///
  /// In en, this message translates to:
  /// **'Open in Play Store'**
  String get updateOpenPlayStore;

  /// No description provided for @updatePlayStoreFallbackNotice.
  ///
  /// In en, this message translates to:
  /// **'Could not open Google Play. Opening the release page instead.'**
  String get updatePlayStoreFallbackNotice;

  /// No description provided for @updateAutoCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatically Check for Updates'**
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
  /// **'Update Channel'**
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
  /// **'Select Update Channel'**
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
  /// **'Collapse Sidebar'**
  String get desktopNavbarAutohideLabel;

  /// No description provided for @desktopNavbarAutohideSub.
  ///
  /// In en, this message translates to:
  /// **'When inactive, the sidebar collapses to icons. Hover it to expand.'**
  String get desktopNavbarAutohideSub;

  /// No description provided for @desktopNavbarLockTooltip.
  ///
  /// In en, this message translates to:
  /// **'Keep Sidebar Expanded'**
  String get desktopNavbarLockTooltip;

  /// No description provided for @desktopNavbarUnlockTooltip.
  ///
  /// In en, this message translates to:
  /// **'Collapse Sidebar When Inactive'**
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
  /// **'Pre-Cache All Album Art'**
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
  /// **'Sign Out'**
  String get serverSettingsSignOutConfirmTitle;

  /// No description provided for @serverSettingsSignOutConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'How would you like to handle your local library data?'**
  String get serverSettingsSignOutConfirmMessage;

  /// No description provided for @serverSettingsConnectionInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection Info'**
  String get serverSettingsConnectionInfoTitle;

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
  /// **'Remove Download?'**
  String get downloadsRemoveConfirmTitle;

  /// No description provided for @downloadsRemoveConfirmContent.
  ///
  /// In en, this message translates to:
  /// **'The downloaded file will be permanently deleted.'**
  String get downloadsRemoveConfirmContent;

  /// No description provided for @deleteDownloadAction.
  ///
  /// In en, this message translates to:
  /// **'Delete Download'**
  String get deleteDownloadAction;

  /// No description provided for @libraryAlbumMenuPlay.
  ///
  /// In en, this message translates to:
  /// **'Play album'**
  String get libraryAlbumMenuPlay;

  /// No description provided for @libraryAlbumMenuAddToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to Queue'**
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

  /// No description provided for @actionMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get actionMore;

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
  /// **'No Match Flows Yet'**
  String get matchFlowEmptyTitle;

  /// No description provided for @matchFlowEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a flow, choose a master song, then add the songs that should follow it.'**
  String get matchFlowEmptySubtitle;

  /// No description provided for @matchFlowLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could Not Load Match Flow'**
  String get matchFlowLoadError;

  /// No description provided for @matchFlowSaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save Match Flow. Try again.'**
  String get matchFlowSaveError;

  /// No description provided for @matchFlowSongAlreadyInFlow.
  ///
  /// In en, this message translates to:
  /// **'This song is already in the flow.'**
  String get matchFlowSongAlreadyInFlow;

  /// No description provided for @matchFlowMissing.
  ///
  /// In en, this message translates to:
  /// **'Match Flow no longer exists.'**
  String get matchFlowMissing;

  /// No description provided for @matchFlowMasterSongInAnotherFlow.
  ///
  /// In en, this message translates to:
  /// **'This song is already the master song in another flow.'**
  String get matchFlowMasterSongInAnotherFlow;

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
  /// **'Add Song'**
  String get matchFlowAddSongAction;

  /// No description provided for @matchFlowAddSongTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Song'**
  String get matchFlowAddSongTitle;

  /// No description provided for @matchFlowSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs'**
  String get matchFlowSearchHint;

  /// No description provided for @matchFlowNoSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No Songs Found'**
  String get matchFlowNoSearchResults;

  /// No description provided for @matchFlowRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename Flow'**
  String get matchFlowRenameTitle;

  /// No description provided for @matchFlowNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Flow Name'**
  String get matchFlowNameLabel;

  /// No description provided for @matchFlowDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Flow?'**
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

  /// No description provided for @desktopWindowTitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop Window'**
  String get desktopWindowTitle;

  /// No description provided for @desktopViewTitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop View'**
  String get desktopViewTitle;

  /// No description provided for @desktopWindowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose how Navis behaves as a full or compact desktop window.'**
  String get desktopWindowSubtitle;

  /// No description provided for @desktopWindowUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Desktop window controls are only available in the desktop app.'**
  String get desktopWindowUnavailable;

  /// No description provided for @desktopMiniPlayerTitle.
  ///
  /// In en, this message translates to:
  /// **'Mini Player'**
  String get desktopMiniPlayerTitle;

  /// No description provided for @desktopMiniPlayerDescription.
  ///
  /// In en, this message translates to:
  /// **'Use a compact, playback-focused Navis window.'**
  String get desktopMiniPlayerDescription;

  /// No description provided for @desktopMiniPlayerOpen.
  ///
  /// In en, this message translates to:
  /// **'Open Mini Player'**
  String get desktopMiniPlayerOpen;

  /// No description provided for @desktopReturnToView.
  ///
  /// In en, this message translates to:
  /// **'Return to Desktop View'**
  String get desktopReturnToView;

  /// No description provided for @desktopMiniPlayerKeepOnTop.
  ///
  /// In en, this message translates to:
  /// **'Keep Mini Player on top'**
  String get desktopMiniPlayerKeepOnTop;

  /// No description provided for @desktopMiniPlayerStopOnTop.
  ///
  /// In en, this message translates to:
  /// **'Stop keeping Mini Player on top'**
  String get desktopMiniPlayerStopOnTop;

  /// No description provided for @desktopMiniPlayerKeepOnTopDescription.
  ///
  /// In en, this message translates to:
  /// **'Keep the compact player above other windows. This only applies in Mini Player.'**
  String get desktopMiniPlayerKeepOnTopDescription;

  /// No description provided for @desktopMiniPlayerKeepOnTopUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Always-on-top is unavailable in this Linux Wayland session. Your desktop compositor controls window stacking.'**
  String get desktopMiniPlayerKeepOnTopUnavailable;

  /// No description provided for @desktopMiniPlayerTooSmallTitle.
  ///
  /// In en, this message translates to:
  /// **'Mini Player Is Too Small'**
  String get desktopMiniPlayerTooSmallTitle;

  /// No description provided for @desktopMiniPlayerTooSmallDescription.
  ///
  /// In en, this message translates to:
  /// **'Mini Player needs at least 560 by 360 logical pixels. Restoring its last valid size.'**
  String get desktopMiniPlayerTooSmallDescription;

  /// No description provided for @desktopNothingPlaying.
  ///
  /// In en, this message translates to:
  /// **'Nothing playing'**
  String get desktopNothingPlaying;

  /// No description provided for @desktopChooseSomething.
  ///
  /// In en, this message translates to:
  /// **'Choose something to play'**
  String get desktopChooseSomething;

  /// No description provided for @desktopNothingPlayingPrompt.
  ///
  /// In en, this message translates to:
  /// **'Return to Desktop View to choose something to play.'**
  String get desktopNothingPlayingPrompt;

  /// No description provided for @desktopPlaybackUnavailableTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unavailable Until Something Is Playing'**
  String get desktopPlaybackUnavailableTooltip;

  /// No description provided for @desktopFavoriteUnavailableForRadio.
  ///
  /// In en, this message translates to:
  /// **'Favorite is unavailable for radio'**
  String get desktopFavoriteUnavailableForRadio;

  /// No description provided for @desktopLyricsUnavailableForRadio.
  ///
  /// In en, this message translates to:
  /// **'Lyrics are unavailable for radio'**
  String get desktopLyricsUnavailableForRadio;

  /// No description provided for @desktopQueueUnavailableForRadio.
  ///
  /// In en, this message translates to:
  /// **'Queue is unavailable for radio'**
  String get desktopQueueUnavailableForRadio;

  /// No description provided for @desktopWindowTooSmallTitle.
  ///
  /// In en, this message translates to:
  /// **'This Window Is Too Small for Desktop View'**
  String get desktopWindowTooSmallTitle;

  /// No description provided for @desktopWindowMinimumDescription.
  ///
  /// In en, this message translates to:
  /// **'Desktop View needs at least 800 by 600 logical pixels.'**
  String get desktopWindowMinimumDescription;

  /// No description provided for @desktopReturnQuestion.
  ///
  /// In en, this message translates to:
  /// **'Return to Desktop View?'**
  String get desktopReturnQuestion;

  /// No description provided for @desktopReturnDescription.
  ///
  /// In en, this message translates to:
  /// **'The window is now large enough for the full desktop interface.'**
  String get desktopReturnDescription;

  /// No description provided for @desktopSwitchToMiniPlayer.
  ///
  /// In en, this message translates to:
  /// **'Switch to Mini Player'**
  String get desktopSwitchToMiniPlayer;

  /// No description provided for @desktopRestoreSize.
  ///
  /// In en, this message translates to:
  /// **'Restore Desktop Size'**
  String get desktopRestoreSize;

  /// No description provided for @desktopKeepMiniPlayer.
  ///
  /// In en, this message translates to:
  /// **'Keep Mini Player'**
  String get desktopKeepMiniPlayer;

  /// No description provided for @desktopViewUnavailableOnDisplay.
  ///
  /// In en, this message translates to:
  /// **'This display cannot fit Desktop View. Mini Player is available until Navis moves to a larger display.'**
  String get desktopViewUnavailableOnDisplay;

  /// No description provided for @cacheSystemUpgradeTitle.
  ///
  /// In en, this message translates to:
  /// **'Update Library Cache'**
  String get cacheSystemUpgradeTitle;

  /// No description provided for @cacheSystemUpgradeBody.
  ///
  /// In en, this message translates to:
  /// **'This installation uses an older library cache system. Navis needs to clear its recoverable library cache and rebuild your library once to use the newer cache system. Your downloaded music will be kept.'**
  String get cacheSystemUpgradeBody;

  /// No description provided for @cacheSystemUpgradeAction.
  ///
  /// In en, this message translates to:
  /// **'Clear Library Cache'**
  String get cacheSystemUpgradeAction;

  /// No description provided for @cacheSystemUpgradeDismiss.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get cacheSystemUpgradeDismiss;

  /// No description provided for @cacheSystemUpgradeResetting.
  ///
  /// In en, this message translates to:
  /// **'Updating library cache…'**
  String get cacheSystemUpgradeResetting;

  /// No description provided for @cacheSystemUpgradeFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not update the library cache. Please try again.'**
  String get cacheSystemUpgradeFailure;

  /// No description provided for @unavailableReviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Unavailable Items'**
  String get unavailableReviewTitle;

  /// No description provided for @unavailableReviewEmpty.
  ///
  /// In en, this message translates to:
  /// **'No unavailable items are waiting for review.'**
  String get unavailableReviewEmpty;

  /// No description provided for @unavailableReviewLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load the review list.'**
  String get unavailableReviewLoadError;

  /// No description provided for @unavailableReviewUnknownTitle.
  ///
  /// In en, this message translates to:
  /// **'Unknown item'**
  String get unavailableReviewUnknownTitle;

  /// No description provided for @unavailableReviewReasonMissing.
  ///
  /// In en, this message translates to:
  /// **'No longer on the server. Favorites, ratings, history, and downloads are kept until you decide.'**
  String get unavailableReviewReasonMissing;

  /// No description provided for @unavailableReviewReasonAmbiguous.
  ///
  /// In en, this message translates to:
  /// **'Several possible replacements were found. Decide which one is correct before anything is relinked.'**
  String get unavailableReviewReasonAmbiguous;

  /// No description provided for @unavailableReviewReasonConflicting.
  ///
  /// In en, this message translates to:
  /// **'Conflicting identifiers were found in the catalog. Review before anything is relinked.'**
  String get unavailableReviewReasonConflicting;

  /// No description provided for @unavailableReviewTypeSong.
  ///
  /// In en, this message translates to:
  /// **'Song'**
  String get unavailableReviewTypeSong;

  /// No description provided for @unavailableReviewTypeAlbum.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get unavailableReviewTypeAlbum;

  /// No description provided for @unavailableReviewTypeArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get unavailableReviewTypeArtist;

  /// No description provided for @unavailableReviewFindMatch.
  ///
  /// In en, this message translates to:
  /// **'Find match'**
  String get unavailableReviewFindMatch;

  /// No description provided for @unavailableReviewKeepForLater.
  ///
  /// In en, this message translates to:
  /// **'Keep for later'**
  String get unavailableReviewKeepForLater;

  /// No description provided for @unavailableReviewRemoveFromLiked.
  ///
  /// In en, this message translates to:
  /// **'Remove from Liked'**
  String get unavailableReviewRemoveFromLiked;

  /// No description provided for @unavailableReviewNoMatchFound.
  ///
  /// In en, this message translates to:
  /// **'No matching item found in the current library.'**
  String get unavailableReviewNoMatchFound;

  /// No description provided for @unavailableReviewRelinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Relink item'**
  String get unavailableReviewRelinkTitle;

  /// No description provided for @unavailableReviewRelinkOld.
  ///
  /// In en, this message translates to:
  /// **'Unavailable item'**
  String get unavailableReviewRelinkOld;

  /// No description provided for @unavailableReviewRelinkNew.
  ///
  /// In en, this message translates to:
  /// **'Selected replacement'**
  String get unavailableReviewRelinkNew;

  /// No description provided for @unavailableReviewReferences.
  ///
  /// In en, this message translates to:
  /// **'References carried over'**
  String get unavailableReviewReferences;

  /// No description provided for @unavailableReviewRelinkApply.
  ///
  /// In en, this message translates to:
  /// **'Relink'**
  String get unavailableReviewRelinkApply;

  /// No description provided for @unavailableReviewRelinkDismiss.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get unavailableReviewRelinkDismiss;

  /// No description provided for @unavailableReviewPossibleReplacements.
  ///
  /// In en, this message translates to:
  /// **'Possible replacements'**
  String get unavailableReviewPossibleReplacements;

  /// No description provided for @unavailableReviewStaleSelection.
  ///
  /// In en, this message translates to:
  /// **'This selection is no longer current. Nothing was changed; the list was refreshed.'**
  String get unavailableReviewStaleSelection;

  /// No description provided for @unavailableReviewAlreadyResolved.
  ///
  /// In en, this message translates to:
  /// **'This entry was already resolved.'**
  String get unavailableReviewAlreadyResolved;

  /// No description provided for @unavailableReviewRefCopies.
  ///
  /// In en, this message translates to:
  /// **'Downloads and cached copies: {count}'**
  String unavailableReviewRefCopies(int count);

  /// No description provided for @unavailableReviewRefPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlist entries: {count}'**
  String unavailableReviewRefPlaylists(int count);

  /// No description provided for @unavailableReviewRefHistory.
  ///
  /// In en, this message translates to:
  /// **'Played before: {count}'**
  String unavailableReviewRefHistory(int count);

  /// No description provided for @unavailableReviewRefQueue.
  ///
  /// In en, this message translates to:
  /// **'Play queue entries: {count}'**
  String unavailableReviewRefQueue(int count);

  /// No description provided for @unavailableReviewRefLikes.
  ///
  /// In en, this message translates to:
  /// **'Pending like or rating actions: {count}'**
  String unavailableReviewRefLikes(int count);

  /// No description provided for @unavailableReviewRefSongs.
  ///
  /// In en, this message translates to:
  /// **'Songs that follow this item: {count}'**
  String unavailableReviewRefSongs(int count);

  /// No description provided for @unavailableReviewRefNone.
  ///
  /// In en, this message translates to:
  /// **'No local references to carry over.'**
  String get unavailableReviewRefNone;

  /// No description provided for @unavailableReviewEntry.
  ///
  /// In en, this message translates to:
  /// **'Unavailable items'**
  String get unavailableReviewEntry;

  /// No description provided for @unavailableReviewEntryWithCount.
  ///
  /// In en, this message translates to:
  /// **'Unavailable items ({count})'**
  String unavailableReviewEntryWithCount(Object count);
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
