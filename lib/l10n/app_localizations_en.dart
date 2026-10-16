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
  String get navHome => 'Home';

  @override
  String get navLibrary => 'Library';

  @override
  String get navSearch => 'Search';

  @override
  String get navRadio => 'Radio';

  @override
  String get navPlaylists => 'Playlists';

  @override
  String get navSettings => 'Settings';

  @override
  String get navigationBackToExitPrompt => 'Press back again to exit';

  @override
  String get loginSubtitle => 'Connect to your Subsonic or Navidrome server.';

  @override
  String get loginServerUrlLabel => 'Server URL';

  @override
  String get loginUsernameLabel => 'Username';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginShowPassword => 'Show password';

  @override
  String get loginHidePassword => 'Hide password';

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
  String get loginInsecureHttpWarning =>
      'HTTP does not encrypt traffic. Use HTTPS when possible.';

  @override
  String get serverSettingsHttpReminder =>
      'This server uses HTTP. HTTPS is safer.';

  @override
  String get serverSettingsHttpLegacyReminder =>
      'This server uses HTTP and your password is sent in readable form. Switch the server to HTTPS.';

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
  String get loginErrorInsecureLegacyAuth =>
      'This server requires legacy authentication. Use HTTPS to protect your password.';

  @override
  String get loginErrorUnknown => 'Unexpected error while connecting.';

  @override
  String get loginErrorCredentialSave =>
      'Navis couldn\'t save your password securely on this device. Try again.';

  @override
  String loginTestConnectionSuccess(Object apiVersion) {
    return 'Connection successful (API $apiVersion).';
  }

  @override
  String get loginReplaceServerTitle => 'Replace Local Server Data?';

  @override
  String get loginReplaceServerMessage =>
      'This device keeps one local server catalog. Continuing will remove the retained library, downloads, caches, history, playlists, and Match Flows from the previous server account.';

  @override
  String get loginReplaceServerAction => 'Replace Local Data';

  @override
  String get initialSyncWaitingForNetwork =>
      'Connect to a network, then retry to continue setup.';

  @override
  String get initialSyncMobileDataRequired =>
      'Initial setup requires a full library download. Confirm to use this metered connection.';

  @override
  String get initialSyncUseMobileData => 'Sync using mobile data';

  @override
  String get initialSyncFailed => 'Your library could not be set up.';

  @override
  String get initialSyncCancelling => 'Cancelling and signing out...';

  @override
  String get requiredSyncInitialTitle => 'Building Your Library';

  @override
  String get requiredSyncRebuildTitle => 'Rebuilding Your Library';

  @override
  String get requiredSyncInitialBody =>
      'Navis is preparing this server for the first time.';

  @override
  String get requiredSyncRebuildBody =>
      'Navis is clearing recoverable library data and downloading a fresh library. Your downloads are kept.';

  @override
  String get requiredSyncClearingCache => 'Clearing library cache';

  @override
  String get requiredSyncRebuildFailed => 'Library rebuild could not complete.';

  @override
  String get requiredSyncFailureCacheReset =>
      'The library cache could not be cleared.';

  @override
  String get requiredSyncFailureCacheRenewal =>
      'The library cache still needs to be renewed.';

  @override
  String get requiredSyncFailureSignOut =>
      'Signing out did not finish. Try again.';

  @override
  String get requiredSyncSignOut => 'Sign out';

  @override
  String get requiredSyncCancelAndSignOut => 'Cancel and sign out';

  @override
  String get requiredSyncStagePreparing => 'Preparing library';

  @override
  String get requiredSyncStageArtistIndex => 'Getting artist index';

  @override
  String get requiredSyncStageSongIndex => 'Getting song index';

  @override
  String get requiredSyncStageAlbums => 'Syncing albums';

  @override
  String get requiredSyncStageSongs => 'Syncing songs';

  @override
  String get requiredSyncStageFinalizing => 'Finalizing library';

  @override
  String get initialSyncComplete => 'Library ready';

  @override
  String get initialSyncCompletedWithWarnings =>
      'Your library is ready. A few items are still syncing in the background.';

  @override
  String get serverOfflineBanner => 'Offline. Retrying…';

  @override
  String get serverOfflineChip => 'Offline';

  @override
  String get batteryOptimizationPromptTitle => 'Keep Background Sync Alive';

  @override
  String get batteryOptimizationPromptBody =>
      'Battery optimization is still enabled for Navis. Disabling it helps background sync finish reliably without the system shutting the app down early.';

  @override
  String get batteryOptimizationPromptRecommendation =>
      'Recommended if you rely on automatic library scans.';

  @override
  String get batteryOptimizationPromptLaterAction => 'Later';

  @override
  String get batteryOptimizationPromptOpenSettingsAction => 'Open Settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsServerTitle => 'Server Information';

  @override
  String get settingsServerSubtitle => 'Server connection and account.';

  @override
  String get settingsCacheTitle => 'Device Storage & Cache';

  @override
  String get settingsCacheSubtitle =>
      'Manage on-device audio, artwork, and download storage.';

  @override
  String get settingsDownloadsSubtitle => 'Manage offline downloads and queue.';

  @override
  String get settingsSyncTitle => 'Sync';

  @override
  String get settingsSyncSubtitle =>
      'Sync progress, history, and manual controls.';

  @override
  String get settingsPlaybackTitle => 'Playback';

  @override
  String get settingsPlaybackSubtitle =>
      'Stream quality, gapless, crossfade and equalizer.';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsAppearanceSubtitle =>
      'Themes, colors and display preferences.';

  @override
  String get settingsGroupConnection => 'Connection';

  @override
  String get settingsGroupStorage => 'Storage';

  @override
  String get settingsGroupDeviceStorageCache => 'Device storage & cache';

  @override
  String get settingsGroupPlayback => 'Playback';

  @override
  String get settingsGroupLibrarySynchronization => 'Library synchronization';

  @override
  String get settingsGroupOther => 'Other';

  @override
  String get settingsRunQuickCustomizationTitle => 'Run Quick Customization';

  @override
  String get settingsRunQuickCustomizationSubtitle =>
      'Review your listening and appearance preferences.';

  @override
  String get settingsGroupDesktop => 'Desktop';

  @override
  String get settingsDesktopShortcutsTitle => 'Keyboard Shortcuts';

  @override
  String get settingsDesktopShortcutsSubtitle =>
      'Customize desktop key bindings';

  @override
  String get desktopShortcutsReset => 'Reset to defaults';

  @override
  String get desktopShortcutsCustomizable => 'Customizable';

  @override
  String get desktopShortcutsBuiltIn => 'Built-in';

  @override
  String get desktopShortcutsCaptureSaved =>
      'Enter to save · Backspace to clear · Esc to cancel';

  @override
  String get desktopShortcutsCapturePrompt =>
      'Hold modifiers then press a key (e.g. Ctrl+Shift+F)';

  @override
  String get desktopShortcutsWaiting => 'Waiting for new input…';

  @override
  String get desktopShortcutsNotSet => 'Not set';

  @override
  String get desktopShortcutsQuickSearchTitle => 'Quick Search';

  @override
  String get desktopShortcutsQuickSearchDescription =>
      'Open the quick-search overlay';

  @override
  String get desktopShortcutsFocusSearchTitle => 'Focus Search';

  @override
  String get desktopShortcutsFocusSearchDescription =>
      'Navigate to search and focus the input';

  @override
  String get desktopShortcutsToggleQueueTitle => 'Toggle Queue';

  @override
  String get desktopShortcutsToggleQueueDescription =>
      'Show or hide the playback queue';

  @override
  String get desktopShortcutsGoHomeTitle => 'Go to Home';

  @override
  String get desktopShortcutsGoHomeDescription => 'Navigate to the home screen';

  @override
  String get desktopShortcutsGoLibraryTitle => 'Go to Library';

  @override
  String get desktopShortcutsGoLibraryDescription => 'Navigate to the library';

  @override
  String get desktopShortcutsGoSearchTitle => 'Go to Search';

  @override
  String get desktopShortcutsGoSearchDescription => 'Navigate to search';

  @override
  String get desktopShortcutsGoSettingsTitle => 'Go to Settings';

  @override
  String get desktopShortcutsGoSettingsDescription => 'Open settings';

  @override
  String get desktopShortcutsToggleNowPlayingTitle => 'Close overlay';

  @override
  String get desktopShortcutsToggleNowPlayingDescription =>
      'Close the top-most panel, overlay or dialog';

  @override
  String get desktopShortcutsPlayPauseTitle => 'Play / Pause';

  @override
  String get desktopShortcutsTogglePlaybackDescription => 'Toggle playback';

  @override
  String get desktopShortcutsNextTrackTitle => 'Next Track';

  @override
  String get desktopShortcutsNextTrackDescription => 'Skip to next track';

  @override
  String get desktopShortcutsPreviousTrackTitle => 'Previous Track';

  @override
  String get desktopShortcutsPreviousTrackDescription =>
      'Skip to previous track';

  @override
  String get desktopShortcutsRefreshLibraryTitle => 'Refresh Library';

  @override
  String get desktopShortcutsRefreshLibraryDescription =>
      'Sync new changes to the library';

  @override
  String get desktopShortcutsForceRescanTitle => 'Force Full Rescan';

  @override
  String get desktopShortcutsForceRescanDescription =>
      'Force a complete rescan of all library files';

  @override
  String get desktopShortcutsSpeedUpTitle => 'Increase Playback Speed';

  @override
  String get desktopShortcutsSpeedUpDescription => 'Speed up playback by 0.10×';

  @override
  String get desktopShortcutsSpeedDownTitle => 'Decrease Playback Speed';

  @override
  String get desktopShortcutsSpeedDownDescription =>
      'Slow down playback by 0.10×';

  @override
  String get desktopShortcutsSpeedResetTitle => 'Reset Playback Speed';

  @override
  String get desktopShortcutsSpeedResetDescription =>
      'Return playback to 1.00× speed';

  @override
  String get desktopShortcutsSpace => 'Space';

  @override
  String get desktopShortcutsPreviousBindingMac => '← or Option+,';

  @override
  String get desktopShortcutsPreviousBinding => '← or Alt+';

  @override
  String get desktopShortcutsNextBindingMac => '→ or Option+.';

  @override
  String get desktopShortcutsNextBinding => '→ or Alt+.';

  @override
  String get desktopShortcutsDismissOverlayTitle => 'Dismiss Overlay';

  @override
  String get desktopShortcutsDismissOverlayDescription =>
      'Close the topmost overlay or dialog';

  @override
  String get desktopShortcutsEscape => 'Esc';

  @override
  String get settingsDesktopWorkspaceSubtitle =>
      'Desktop workspace controls and app preferences';

  @override
  String get privacyAccountsTitle => 'Accounts and Credentials';

  @override
  String get privacyAccountsBody =>
      'Navis connects directly to the Subsonic or OpenSubsonic servers you configure. Server addresses and usernames are stored in the app database. Your server password and ListenBrainz token are stored in the platform\'s secure credential store when available. A Last.fm API key you enter yourself is stored in the app database.';

  @override
  String get privacyScrobblingTitle => 'External Scrobbling';

  @override
  String get privacyScrobblingBody =>
      'With a validated ListenBrainz token, Navis sends listening activity for played tracks to ListenBrainz while Scrobbling is on. This can include track title, artist, album, duration, play time and now-playing status. While Likes is on, songs you like are sent as loved. Your ListenBrainz token stays on your device.';

  @override
  String get privacyDownloadsTitle => 'Downloads and Cache';

  @override
  String get privacyDownloadsBody =>
      'Offline downloads, playback cache, artwork, lyrics, and library metadata are stored on your device so playback and browsing can work without repeatedly fetching the same data. You can clear cache data from Settings.';

  @override
  String get privacyDiagnosticsTitle => 'Diagnostics';

  @override
  String get privacyDiagnosticsBody =>
      'Navis avoids logging raw credentials and redacts sensitive authentication values from diagnostics. Network errors may still include service names or non-secret request context needed to troubleshoot failures. Startup details stay on this device until you copy them.';

  @override
  String get privacySummary =>
      'Navis does not operate a central account service for your music library. Data is exchanged with your servers and with the online services you leave on in Settings › Integrations.';

  @override
  String get privacyReadFullPolicy => 'Read the full privacy policy';

  @override
  String get syncSettingsTitle => 'Sync Settings';

  @override
  String get syncSettingsStatusLabel => 'Current Sync Status';

  @override
  String get syncSettingsNeverSynced => 'Never synced';

  @override
  String get syncSettingsStatusIdle => 'Idle';

  @override
  String get syncSettingsStatusSucceeded => 'Last sync succeeded';

  @override
  String get syncSettingsStatusPartial => 'Sync paused with work remaining';

  @override
  String get syncSettingsStatusDeferred => 'Sync deferred';

  @override
  String get syncSettingsStatusCancelled => 'Sync cancelled; work saved';

  @override
  String get syncSettingsStatusFailed => 'Last sync failed';

  @override
  String get syncSettingsFailureDescription =>
      'Could not refresh your library. Check your connection and try again.';

  @override
  String get syncSettingsPlanLabel => 'Sync Plan';

  @override
  String get syncSettingsPendingWorkLabel => 'Pending Work';

  @override
  String syncSettingsPendingWorkValue(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString tasks pending',
      one: '1 task pending',
    );
    return '$_temp0';
  }

  @override
  String get syncSettingsCatalogUpdateLabel => 'Catalog Update';

  @override
  String syncSettingsCatalogUpdateValue(Object milliseconds) {
    return '$milliseconds ms';
  }

  @override
  String get syncSettingsLastRunLabel => 'Last Run';

  @override
  String syncSettingsLastRunValue(int requests, String bytes) {
    final intl.NumberFormat requestsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String requestsString = requestsNumberFormat.format(requests);

    String _temp0 = intl.Intl.pluralLogic(
      requests,
      locale: localeName,
      other: '$requestsString requests',
      one: '1 request',
    );
    return '$_temp0 • $bytes';
  }

  @override
  String get syncSettingsLastCheckedLabel => 'Last Checked';

  @override
  String get syncSettingsNextAutomaticCheckLabel => 'Next Automatic Check';

  @override
  String get syncSettingsNextAutomaticCheckScheduling => 'Scheduling…';

  @override
  String get syncSettingsNextRetryLabel => 'Automatic Retry After Failure';

  @override
  String get syncSettingsLastCatalogUpdateLabel => 'Last Catalog Update';

  @override
  String get syncSettingsLastAuxiliaryUpdateLabel =>
      'Starred and Playlist Headers';

  @override
  String get syncSettingsLastLibraryChangeLabel => 'Last Library Change';

  @override
  String get syncSettingsAndroidBackgroundTitle => 'Android Background Sync';

  @override
  String get syncSettingsAndroidBackgroundDisabled =>
      'Foreground checks remain available. Android background scheduling is disabled for this app build while its reliability certification is incomplete.';

  @override
  String get syncSettingsAndroidBackgroundManual =>
      'Manual-only sync has no Android background schedule.';

  @override
  String syncSettingsAndroidBackgroundCadence(Object minutes) {
    return 'Requested cadence: every $minutes minutes. Android may delay runs to meet system conditions.';
  }

  @override
  String get syncSettingsAndroidBackgroundLastAttempt => 'Last Android attempt';

  @override
  String get syncSettingsAndroidBackgroundNoAttempt =>
      'No Android attempt recorded yet.';

  @override
  String get syncSettingsAndroidBackgroundWaitingUnmetered =>
      'Waiting for an unmetered network.';

  @override
  String get syncSettingsAndroidBackgroundDeferredSetup =>
      'waiting for first setup';

  @override
  String syncSettingsAndroidBackgroundOutcome(Object outcome) {
    return 'Outcome: $outcome';
  }

  @override
  String syncSettingsCatalogPromotionRemovalSummary(
    int artists,
    int albums,
    int songs,
  ) {
    final intl.NumberFormat artistsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String artistsString = artistsNumberFormat.format(artists);
    final intl.NumberFormat albumsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String albumsString = albumsNumberFormat.format(albums);
    final intl.NumberFormat songsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String songsString = songsNumberFormat.format(songs);

    String _temp0 = intl.Intl.pluralLogic(
      artists,
      locale: localeName,
      other: '$artistsString artists',
      one: '1 artist',
    );
    String _temp1 = intl.Intl.pluralLogic(
      albums,
      locale: localeName,
      other: '$albumsString albums',
      one: '1 album',
    );
    String _temp2 = intl.Intl.pluralLogic(
      songs,
      locale: localeName,
      other: '$songsString songs',
      one: '1 song',
    );
    return 'The last library update removed $_temp0, $_temp1 and $_temp2.';
  }

  @override
  String syncSettingsStarredReconciliationRemovalSummary(
    int artists,
    int albums,
    int songs,
  ) {
    final intl.NumberFormat artistsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String artistsString = artistsNumberFormat.format(artists);
    final intl.NumberFormat albumsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String albumsString = albumsNumberFormat.format(albums);
    final intl.NumberFormat songsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String songsString = songsNumberFormat.format(songs);

    String _temp0 = intl.Intl.pluralLogic(
      artists,
      locale: localeName,
      other: '$artistsString artists',
      one: '1 artist',
    );
    String _temp1 = intl.Intl.pluralLogic(
      albums,
      locale: localeName,
      other: '$albumsString albums',
      one: '1 album',
    );
    String _temp2 = intl.Intl.pluralLogic(
      songs,
      locale: localeName,
      other: '$songsString songs',
      one: '1 song',
    );
    return 'Removed from Liked after the server confirmed the change: $_temp0, $_temp1 and $_temp2.';
  }

  @override
  String syncSettingsDegradation(Object category) {
    return 'Degraded domain: $category';
  }

  @override
  String syncSettingsStrategy(Object strategy, Object reason) {
    return 'Strategy: $strategy — $reason';
  }

  @override
  String syncSettingsPendingWork(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString resumable tasks pending',
      one: '1 resumable task pending',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsPendingAlbumDetails(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString albums\' track lists haven\'t been fetched yet. They load when you open them or during upcoming checks.',
      one: '1 album\'s track list hasn\'t been fetched yet. It loads when you open it or during the next check.',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsIncompleteAlbumDetails(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString albums\' track lists couldn\'t be loaded because the server\'s details for them are incomplete, such as a song count that doesn\'t match their songs. A server rescan usually fixes this.',
      one: '1 album\'s track list couldn\'t be loaded because the server\'s details for it are incomplete, such as a song count that doesn\'t match its songs. A server rescan usually fixes this.',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsCandidate(String status) {
    return 'Prepared library update: $status';
  }

  @override
  String syncSettingsCarriedForward(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString unavailable albums kept from the previous catalog',
      one: '1 unavailable album kept from the previous catalog',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsApplyDuration(Object milliseconds) {
    return 'Catalog applied in $milliseconds ms';
  }

  @override
  String syncSettingsUsage(int requests, String bytes) {
    final intl.NumberFormat requestsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String requestsString = requestsNumberFormat.format(requests);

    String _temp0 = intl.Intl.pluralLogic(
      requests,
      locale: localeName,
      other: '$requestsString requests',
      one: '1 request',
    );
    return 'Last run: $_temp0 • $bytes';
  }

  @override
  String get syncSettingsSyncLibraryNow => 'Sync library now';

  @override
  String get syncSettingsFreshnessCurrent => 'Current';

  @override
  String get syncSettingsFreshnessPending => 'Verification pending';

  @override
  String get syncSettingsFreshnessRepair => 'Repair recommended';

  @override
  String syncSettingsRemainingVerification(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString artists remain to verify',
      one: '1 artist remains to verify',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsIdentitySummary(int canonicalized, int ambiguous) {
    final intl.NumberFormat canonicalizedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String canonicalizedString = canonicalizedNumberFormat.format(
      canonicalized,
    );
    final intl.NumberFormat ambiguousNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String ambiguousString = ambiguousNumberFormat.format(ambiguous);

    String _temp0 = intl.Intl.pluralLogic(
      canonicalized,
      locale: localeName,
      other: '$canonicalizedString cached songs canonicalized',
      one: '1 cached song canonicalized',
    );
    String _temp1 = intl.Intl.pluralLogic(
      ambiguous,
      locale: localeName,
      other: '$ambiguousString ambiguous matches retained',
      one: '1 ambiguous match retained',
    );
    return '$_temp0; $_temp1';
  }

  @override
  String get syncSettingsIntervalLabel => 'Auto-Sync Interval';

  @override
  String get syncSettingsIntervalManual => 'Manual only';

  @override
  String syncSettingsIntervalMinutes(int minutes) {
    final intl.NumberFormat minutesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String minutesString = minutesNumberFormat.format(minutes);

    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Every $minutesString minutes',
      one: 'Every minute',
    );
    return '$_temp0';
  }

  @override
  String syncSettingsIntervalHours(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Every $hoursString hours',
      one: 'Every hour',
    );
    return '$_temp0';
  }

  @override
  String get syncSettingsIntervalDescription =>
      'How often the library syncs automatically in the background.';

  @override
  String get syncSettingsBackgroundUnmeteredOnlyLabel =>
      'Background Sync Only on Unmetered Networks';

  @override
  String get syncSettingsBackgroundUnmeteredOnlyDescription =>
      'On mobile or metered Wi-Fi, Navis checks for updates with a single lightweight request and waits for unmetered data before downloading catalog changes.';

  @override
  String get syncSettingsUpdatesAvailable =>
      'Library updates are available and waiting for an unmetered connection.';

  @override
  String get syncSettingsUpdatesAvailableMetered =>
      'Library updates are available. Use mobile data now or wait for unmetered Wi-Fi.';

  @override
  String get syncSettingsSyncUsingMobileData => 'Sync using mobile data';

  @override
  String get syncSettingsRepairLibraryMetadata => 'Repair Library';

  @override
  String get syncSettingsRepairLibraryMetadataDescription =>
      'Reconcile your local library with the server. Keeps downloads, streaming cache, and artwork.';

  @override
  String get syncSettingsRepairLibraryMetadataRunning => 'Repairing library...';

  @override
  String syncSettingsRepairDeletionConfirmationPending(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString items the server no longer has are waiting for your confirmation before Navis removes them from the local library.',
      one: '1 item the server no longer has is waiting for your confirmation before Navis removes it from the local library.',
    );
    return '$_temp0';
  }

  @override
  String get syncSettingsRepairDeletionConfirmationTitle =>
      'Confirm Library Repair';

  @override
  String syncSettingsRepairDeletionConfirmationBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The server no longer reports $countString items. Applying this repair will remove them from Navis\'s local library.',
      one: 'The server no longer reports 1 item. Applying this repair will remove it from Navis\'s local library.',
    );
    return '$_temp0 Downloads and cached audio are kept.';
  }

  @override
  String get syncSettingsRepairDeletionConfirmationAction =>
      'Apply Library Repair';

  @override
  String get syncSettingsRepairDiscardCandidate => 'Discard Repair Candidate';

  @override
  String get syncSettingsRepairDiscardCandidateTitle =>
      'Discard Pending Library Repair?';

  @override
  String get syncSettingsRepairDiscardCandidateBody =>
      'This removes the uncommitted repair candidate and its deletion confirmation. Your current local library, downloads, and cached audio stay unchanged.';

  @override
  String get syncSettingsRepairMeteredConfirmTitle =>
      'Repair Library on Mobile Data?';

  @override
  String get syncSettingsRepairMeteredConfirmBody =>
      'Repairing your library can download a large amount of metadata over your current connection.';

  @override
  String get syncSettingsRepairMeteredConfirmAction => 'Repair on Mobile Data';

  @override
  String get cacheSettingsResetLibraryCache => 'Reset Caches & Rebuild Library';

  @override
  String get cacheSettingsResetLibraryCacheDescription =>
      'Clear local streaming and artwork caches plus library metadata, then rebuild from the server. Downloaded music is kept.';

  @override
  String get cacheSettingsResetLibraryCacheConfirmTitle =>
      'Reset Caches & Rebuild Library?';

  @override
  String get cacheSettingsResetLibraryCacheConfirmBody =>
      'This permanently deletes your streaming cache, cover art cache, and local library metadata. Downloaded music will be kept. Navis will then rebuild your library from the server.';

  @override
  String get cacheSettingsResetLibraryCacheConfirmAction =>
      'Reset Caches & Rebuild';

  @override
  String get cacheSettingsResetLibraryCacheMeteredConfirmTitle =>
      'Rebuild Library on Mobile Data?';

  @override
  String get cacheSettingsResetLibraryCacheMeteredConfirmBody =>
      'Rebuilding your library can download a large amount of metadata over your current connection.';

  @override
  String get cacheSettingsResetLibraryCacheMeteredConfirmAction =>
      'Rebuild on Mobile Data';

  @override
  String get playbackSettingsLoadError => 'Could Not Load Playback Settings';

  @override
  String get playbackSettingsWifiSectionTitle => 'Wi-Fi Streaming';

  @override
  String get playbackSettingsWifiQualityLabel => 'Max Bitrate';

  @override
  String get playbackSettingsWifiFormatLabel => 'Preferred Format';

  @override
  String get playbackSettingsCellularSectionTitle => 'Cellular Streaming';

  @override
  String get playbackSettingsCellularQualityLabel => 'Max Bitrate';

  @override
  String get playbackSettingsCellularFormatLabel => 'Preferred Format';

  @override
  String get playbackSettingsCachedFirstTitle =>
      'Play cached copies at any quality';

  @override
  String get playbackSettingsCachedFirstSubtitle =>
      'Use a song already cached on this device even if its quality differs from your streaming setting. Downloads always play from your device.';

  @override
  String get playbackSettingsScrobbleTitle => 'Enable Scrobbling';

  @override
  String get playbackSettingsScrobbleSubtitle =>
      'Report tracks you play to the server (now-playing and play counts). Disable to listen anonymously.';

  @override
  String get playbackSettingsGaplessTitle => 'Enable Gapless Playback';

  @override
  String get playbackSettingsGaplessSubtitle =>
      'Preload tracks to reduce gaps between songs.';

  @override
  String get playbackSettingsResetAction => 'Reset Defaults';

  @override
  String get playbackSettingsQualityOriginal => 'Original quality';

  @override
  String playbackSettingsQualityKbps(int kbps) {
    return '$kbps kbps';
  }

  @override
  String get playbackSettingsFormatOriginal => 'Server default';

  @override
  String get playbackSettingsSaveFailure =>
      'Could not save playback settings. Try again.';

  @override
  String get playbackSettingsResetSuccess =>
      'Playback settings reset to defaults.';

  @override
  String get playbackSettingsResetFailure =>
      'Could not reset playback settings. Try again.';

  @override
  String get playbackSettingsCrossfadeEnableTitle => 'Enable Cross-Fade';

  @override
  String get playbackSettingsCrossfadeEnableSubtitle =>
      'Smoothly blend the end of one track into the start of the next.';

  @override
  String playbackSettingsCrossfadeDurationLabel(int seconds) {
    return 'Duration: ${seconds}s';
  }

  @override
  String get playbackSettingsCrossfadeTypeLabel => 'Cross-Fade Mode';

  @override
  String get playbackSettingsCrossfadeTypeNormal => 'Normal';

  @override
  String get playbackSettingsCrossfadeTypeNormalDescription =>
      'Cross-fade between every track.';

  @override
  String get playbackSettingsCrossfadeTypeSmart => 'Smart';

  @override
  String get playbackSettingsCrossfadeTypeSmartDescription =>
      'Only cross-fade between tracks from different albums.';

  @override
  String get playbackSettingsReplayGainSectionTitle =>
      'Volume Normalization (ReplayGain)';

  @override
  String get playbackVolumeSemanticLabel => 'Playback volume';

  @override
  String get playbackMuteTooltip => 'Mute playback';

  @override
  String get playbackUnmuteTooltip => 'Unmute playback';

  @override
  String get playbackSettingsReplayGainModeLabel => 'ReplayGain Mode';

  @override
  String get playbackSettingsReplayGainModeOff => 'Off';

  @override
  String get playbackSettingsReplayGainModeOffDescription =>
      'No volume normalization applied.';

  @override
  String get playbackSettingsReplayGainModeTrack => 'Track';

  @override
  String get playbackSettingsReplayGainModeTrackDescription =>
      'Normalize volume on a per-track basis.';

  @override
  String get playbackSettingsReplayGainModeAlbum => 'Album';

  @override
  String get playbackSettingsReplayGainModeAlbumDescription =>
      'Normalize volume on a per-album basis, preserving relative loudness.';

  @override
  String get playbackSettingsReplayGainPreampLabel => 'Pre-amp (dB)';

  @override
  String get playbackSettingsReplayGainPreampSubtitle =>
      'Additional gain adjustment. Range: −6 to +6 dB.';

  @override
  String get playbackSettingsPlaybackSpeedLabel => 'Playback Speed';

  @override
  String get playbackSettingsFullscreenLyricsTitle => 'Fullscreen Mode Lyrics';

  @override
  String get playbackSettingsFullscreenLyricsSubtitle =>
      'Open lyrics in fullscreen directly from Now Playing.';

  @override
  String get playbackSettingsAlbumQueueTitle => 'Album Queue';

  @override
  String get playbackSettingsAlbumQueueSubtitle =>
      'Tapping a track in an album or playlist queues the whole list and starts playback at that track.';

  @override
  String get playbackSettingsExperimentalTitle => 'Experimental';

  @override
  String get playbackSettingsLikedQueueTitle => 'Liked Queue';

  @override
  String get playbackSettingsLikedQueueSubtitle =>
      'Tapping a track on the Liked page queues all your liked songs and starts at that track.';

  @override
  String get homeLoadErrorTitle => 'Could Not Load Section';

  @override
  String get weeklyPlaylistTitle => 'ListenBrainz Weekly';

  @override
  String get weeklyPlaylistJamsTitle => 'Weekly Jams';

  @override
  String get weeklyPlaylistExplorationTitle => 'Weekly Exploration';

  @override
  String get weeklyPlaylistServiceName => 'ListenBrainz';

  @override
  String get weeklyPlaylistLoadError => 'Could Not Load Weekly Playlist';

  @override
  String get weeklyPlaylistUnavailableTitle => 'No Weekly Playlist Available';

  @override
  String get weeklyPlaylistUnavailableSubtitle =>
      'Refresh to check for a new playlist.';

  @override
  String get weeklyPlaylistMatchAction => 'Match';

  @override
  String weeklyPlaylistMatchSuccess(int matched, int total) {
    final intl.NumberFormat matchedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String matchedString = matchedNumberFormat.format(matched);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString tracks',
      one: '1 track',
    );
    return 'Matched $matchedString of $_temp0';
  }

  @override
  String get weeklyPlaylistMatchError =>
      'Could not match this playlist. Try again.';

  @override
  String weeklyPlaylistTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks',
      one: '1 track',
      zero: 'No tracks',
    );
    return '$_temp0';
  }

  @override
  String weeklyPlaylistAvailableMatching(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks available, matching',
      one: '1 track available, matching',
      zero: 'No tracks available, matching',
    );
    return '$_temp0';
  }

  @override
  String weeklyPlaylistAvailableCount(int matched, int total) {
    return '$matched of $total available';
  }

  @override
  String get weeklyPlaylistFetching => 'Fetching ListenBrainz playlist...';

  @override
  String get weeklyPlaylistLoading => 'Loading playlist...';

  @override
  String get weeklyPlaylistNoTracksYet => 'No tracks yet';

  @override
  String get weeklyPlaylistReady => 'Ready';

  @override
  String get weeklyPlaylistMatching => 'Matching';

  @override
  String get weeklyPlaylistSearchAction => 'Search';

  @override
  String get weeklyPlaylistAmbiguousMatch => 'Ambiguous match';

  @override
  String get weeklyPlaylistTrackUnavailable => 'Not available on your server';

  @override
  String get weeklyPlaylistTrackUnavailableShort => 'Not on server';

  @override
  String get weeklyPlaylistAmbiguousMatchShort => 'Unclear match';

  @override
  String get homeShowcaseReasonLikedDiscovery => 'Similar to your likes';

  @override
  String get homeShowcaseReasonServer => 'From your server';

  @override
  String get homeShowcaseReasonLibrary => 'From your library';

  @override
  String get homeShowcaseReasonListenBrainz => 'ListenBrainz';

  @override
  String get homeShowcaseReasonTrending => 'Popular on Deezer';

  @override
  String get homeTrendingTitle => 'Trending Now';

  @override
  String trendingPlaylistMeta(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return 'Deezer chart • $_temp0';
  }

  @override
  String get trendingServiceName => 'Deezer';

  @override
  String get trendingEmptyTitle => 'No Trending Songs';

  @override
  String get trendingEmptySubtitle =>
      'Trending Now appears once your library has synced and Deezer\'s chart can be read.';

  @override
  String get trendingErrorTitle => 'Could Not Load Trending';

  @override
  String homeShowcasePlayTooltip(String album) {
    return 'Play $album';
  }

  @override
  String homeShowcaseAlbumSemantics(String album, String artist) {
    return 'Album, $album by $artist';
  }

  @override
  String get homeRecentlyLikedAlbumsTitle => 'Recently Liked Albums';

  @override
  String get homeRecentlyLikedAlbumsEmptyTitle => 'No Liked Albums Yet';

  @override
  String get homeRecentlyLikedAlbumsEmptySubtitle =>
      'Like albums to pin your favorites here.';

  @override
  String get homeRecentlyAddedTitle => 'Recently Added';

  @override
  String get homeRecentlyAddedEmptyTitle => 'No Recently Added Albums';

  @override
  String get homeRecentlyAddedEmptySubtitle =>
      'Pull to refresh to fetch newly added albums.';

  @override
  String get homeNewReleasesTitle => 'New Releases';

  @override
  String get homeFrequentTitle => 'Frequent Albums';

  @override
  String get homeFrequentEmptyTitle => 'No Frequent Albums Yet';

  @override
  String get homeFrequentEmptySubtitle =>
      'Play more tracks to build listening history.';

  @override
  String get homeRandomTitle => 'You Might Like';

  @override
  String get homeRandomEmptyTitle => 'No Recommendations Available';

  @override
  String get homeRandomEmptySubtitle =>
      'Like more songs or pull to refresh to discover new picks.';

  @override
  String get homeStarredTitle => 'Liked Tracks';

  @override
  String get homeStarredEmptyTitle => 'No Liked Tracks';

  @override
  String get homeStarredEmptySubtitle =>
      'Like tracks on your server to see them here.';

  @override
  String get homeMostPlayedTracksTitle => 'Most Played Tracks';

  @override
  String get homeMostPlayedTracksEmptyTitle => 'No Play Data Yet';

  @override
  String get homeMostPlayedTracksEmptySubtitle =>
      'Play more music to populate this section.';

  @override
  String get homeRecentlyPlayedTracksTitle => 'Recently Played Tracks';

  @override
  String get homeRecentlyPlayedTracksEmptyTitle => 'No Recently Played Tracks';

  @override
  String get homeRecentlyPlayedTracksEmptySubtitle =>
      'Start listening to populate this section.';

  @override
  String get homeRecentlyPlayedAlbumsTitle => 'Recently Played Albums';

  @override
  String get homeRecentlyPlayedAlbumsEmptyTitle => 'No Recently Played Albums';

  @override
  String get homeRecentlyPlayedAlbumsEmptySubtitle =>
      'Start listening to populate this section.';

  @override
  String get radioTitle => 'Radio';

  @override
  String get radioEmptyTitle => 'No Radio Stations Found';

  @override
  String get radioEmptySubtitle =>
      'Add a station to this device, or add internet radio stations on your server.';

  @override
  String radioFilteredEmptyTitle(String query) {
    return 'No Stations Match “$query”';
  }

  @override
  String get radioFilteredEmptySubtitle =>
      'Try a different filter, or show all stations.';

  @override
  String get radioFilteredEmptyAction => 'Show All Stations';

  @override
  String get radioLoadErrorTitle => 'Could Not Load Radio Stations';

  @override
  String get radioUnsupportedMessage =>
      'This server does not expose internet radio station endpoints.';

  @override
  String get radioStopStation => 'Stop radio';

  @override
  String get radioAddStation => 'Add station';

  @override
  String get radioEditStation => 'Edit station';

  @override
  String get radioDeleteStation => 'Delete station';

  @override
  String get radioSectionDevice => 'On this device';

  @override
  String get radioSectionServer => 'On your server';

  @override
  String get radioEditorNameLabel => 'Name';

  @override
  String get radioEditorStreamUrlLabel => 'Stream URL';

  @override
  String get radioEditorHomepageLabel => 'Homepage (optional)';

  @override
  String get radioEditorNameError => 'Enter a name for this station.';

  @override
  String get radioEditorUrlError =>
      'Enter a full address starting with http:// or https://.';

  @override
  String get radioEditorSaveToServer => 'Save to server';

  @override
  String get radioEditorSaveToServerHint =>
      'Visible to every user on this server. Off keeps the station on this device only.';

  @override
  String get radioEditorSaveFailed => 'Could not save this station. Try again.';

  @override
  String get radioDeleteTitle => 'Delete Station?';

  @override
  String get radioDeleteScopeDevice => 'Saved on this device only.';

  @override
  String get radioDeleteScopeServer =>
      'This removes the station from the server for everyone.';

  @override
  String get radioDeleteFailed => 'Could not delete this station. Try again.';

  @override
  String get radioPlaybackError => 'Could not play this radio station.';

  @override
  String get radioStreamUnavailable => 'Radio stream unavailable.';

  @override
  String get radioNowPlaying => 'Now playing on radio';

  @override
  String get radioLive => 'LIVE';

  @override
  String get serverSettingsTitle => 'Server Information';

  @override
  String get serverSettingsLoadError => 'Could Not Load Server Settings.';

  @override
  String get serverSettingsSaveError => 'Failed to save. Please try again.';

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
  String get serverSettingsApiVersionLabel => 'API Version';

  @override
  String get serverSettingsAuthModeLabel => 'Auth Mode';

  @override
  String get serverSettingsAuthModeToken => 'Token';

  @override
  String get serverSettingsAuthModeLegacy => 'Legacy password';

  @override
  String get serverSettingsTestConnection => 'Test connection';

  @override
  String get serverSettingsSave => 'Save';

  @override
  String get serverSettingsSignOut => 'Sign out';

  @override
  String get serverSettingsSignOutKeepData => 'Sign out (keep local data)';

  @override
  String get serverSettingsSignOutWipeData => 'Sign out and clear local data';

  @override
  String get serverSettingsSignOutSuccess =>
      'Signed out. Local data was preserved.';

  @override
  String get serverSettingsSignOutWipeSuccess =>
      'Signed out and local data cleared.';

  @override
  String get serverSettingsSignOutError =>
      'Could not complete sign out. Try again.';

  @override
  String get configurationServerSection => 'Server';

  @override
  String get configurationLastFmApiKeyLabel => 'API Key';

  @override
  String get configurationLastFmApiKeyHint => 'Paste your Last.fm API key here';

  @override
  String get configurationLastFmGetApiKey => 'Get API Key';

  @override
  String get configurationLastFmApiKeySaved => 'Last.fm API key saved.';

  @override
  String get configurationLastFmApiKeyCleared => 'Last.fm API key removed.';

  @override
  String get configurationLastFmApiKeyInvalid => 'Invalid Last.fm API key.';

  @override
  String get configurationLastFmApiKeyRateLimited =>
      'Last.fm is rate limiting validation. Try again later.';

  @override
  String get configurationLastFmApiKeyValidationFailed =>
      'Could not validate this Last.fm API key.';

  @override
  String get configurationShowSecret => 'Show';

  @override
  String get configurationHideSecret => 'Hide';

  @override
  String get configurationClearSecret => 'Clear';

  @override
  String get configurationListenBrainzTokenLabel => 'User Token';

  @override
  String get configurationListenBrainzTokenRequired =>
      'Enter a ListenBrainz user token.';

  @override
  String get configurationListenBrainzTokenInvalid =>
      'Invalid ListenBrainz token.';

  @override
  String get configurationListenBrainzUnavailable =>
      'ListenBrainz is unavailable right now. Your token was not rejected. Check your connection or try again later.';

  @override
  String get configurationListenBrainzValidateAndSave => 'Validate and save';

  @override
  String get configurationListenBrainzGetToken => 'Get Token';

  @override
  String get privacyOnlineServicesTitle => 'Online Services';

  @override
  String get privacyOnlineServicesBody =>
      'Besides your server, Navis can contact Deezer (artist, album and track names, plus images from Deezer\'s image servers), Last.fm (track and artist names, using the API key included with Navis or your own), ListenBrainz (your listens and likes), LRCLIB (track details, to find lyrics), downloads.porthorion.com (update checks), GitHub (raw.githubusercontent.com and api.github.com for AutoEQ headphone profiles, only when you ask), internet radio stations (streams and now-playing info) and the sites your server links images from. You can turn each one off in Settings › Integrations. With Online services off, Navis only talks to your server.';

  @override
  String get privacyOpenIntegrations => 'Open Integrations';

  @override
  String get integrationsTitle => 'Integrations';

  @override
  String get integrationsSubtitle =>
      'Deezer, Last.fm, ListenBrainz and other online services.';

  @override
  String get integrationsMasterTitle => 'Online services';

  @override
  String get integrationsMasterSubtitle =>
      'Off: Navis only talks to your server.';

  @override
  String get integrationsGroupDiscovery => 'Discovery';

  @override
  String get integrationsGroupListeningHistory => 'Listening history';

  @override
  String get integrationsGroupNowPlaying => 'Now Playing';

  @override
  String get integrationsGroupApp => 'App';

  @override
  String get integrationsServiceUpdates => 'Updates';

  @override
  String get integrationsServiceRadio => 'Internet radio';

  @override
  String get integrationsServiceArtwork => 'Artwork';

  @override
  String integrationsServiceSwitchLabel(String service) {
    return 'Use $service';
  }

  @override
  String integrationsDeezerSends(String host) {
    return 'Sends artist, album and track names to $host and loads images from Deezer\'s image servers.';
  }

  @override
  String integrationsLastFmSends(String host) {
    return 'Sends track and artist names to $host, using the API key included with Navis or your own.';
  }

  @override
  String integrationsListenBrainzSends(String host) {
    return 'Sends your listens and likes to $host.';
  }

  @override
  String integrationsLrclibSends(String host) {
    return 'Sends track title, artist, album and duration to $host.';
  }

  @override
  String integrationsUpdatesSends(String host) {
    return 'Sends an app version check to $host.';
  }

  @override
  String integrationsAutoEqSends(String host) {
    return 'Downloads headphone profiles from $host, only when you ask.';
  }

  @override
  String get integrationsRadioSends =>
      'Reads now-playing info from the station\'s server.';

  @override
  String get integrationsArtworkSends =>
      'Loads images your server links from other sites, such as artist photos.';

  @override
  String get integrationsFeatureDeezerTopSongsTitle => 'Top songs';

  @override
  String get integrationsFeatureDeezerTopSongsSubtitle =>
      'Popular songs on artist pages.';

  @override
  String get integrationsFeatureDeezerArtistImagesTitle => 'Artist photos';

  @override
  String get integrationsFeatureDeezerArtistImagesSubtitle =>
      'Header photo and fan count on artist pages.';

  @override
  String get integrationsFeatureDeezerSimilarArtistsTitle => 'Fans also like';

  @override
  String get integrationsFeatureDeezerSimilarArtistsSubtitle =>
      'Related artists on artist pages.';

  @override
  String get integrationsFeatureDeezerMissingAlbumsTitle => 'Missing albums';

  @override
  String get integrationsFeatureDeezerMissingAlbumsSubtitle =>
      'An artist\'s albums that aren\'t on your server.';

  @override
  String get integrationsFeatureDeezerNewReleasesTitle => 'New releases';

  @override
  String get integrationsFeatureDeezerNewReleasesSubtitle =>
      'New releases from your artists on Home.';

  @override
  String get integrationsFeatureDeezerTrendingTitle => 'Trending';

  @override
  String get integrationsFeatureDeezerTrendingSubtitle =>
      'Deezer\'s chart in You Might Like and your playlists.';

  @override
  String get integrationsFeatureLastFmSameVibesTitle => 'Same Vibes mixes';

  @override
  String get integrationsFeatureLastFmSameVibesSubtitle =>
      'On: Instant Mix finds similar songs through Last.fm. Off: Instant Mix uses your server\'s mix.';

  @override
  String get integrationsFeatureLastFmRadioTitle => 'Instant Radio';

  @override
  String get integrationsFeatureLastFmRadioSubtitle =>
      'Adds similar songs from Last.fm when your server\'s suggestions run short.';

  @override
  String get integrationsFeatureLastFmTopSongsTitle => 'Top songs';

  @override
  String get integrationsFeatureLastFmTopSongsSubtitle =>
      'Popular songs on artist pages when Deezer has none.';

  @override
  String get integrationsFeatureListenBrainzScrobblingTitle => 'Scrobbling';

  @override
  String get integrationsFeatureListenBrainzScrobblingSubtitle =>
      'Sends the songs you play.';

  @override
  String get integrationsFeatureListenBrainzFeedbackTitle => 'Likes';

  @override
  String get integrationsFeatureListenBrainzFeedbackSubtitle =>
      'Sends the songs you like as loved.';

  @override
  String get integrationsFeatureListenBrainzWeeklyPlaylistsTitle =>
      'Weekly playlists';

  @override
  String get integrationsFeatureListenBrainzWeeklyPlaylistsSubtitle =>
      'Your weekly ListenBrainz playlists on Home and in Library.';

  @override
  String get integrationsFeatureLrclibLyricsTitle => 'Synced lyrics';

  @override
  String get integrationsFeatureLrclibLyricsSubtitle =>
      'Synced lyrics from LRCLIB first, server lyrics as fallback.';

  @override
  String get integrationsFeatureUpdatesAutomaticTitle => 'Check automatically';

  @override
  String get integrationsFeatureUpdatesAutomaticSubtitle =>
      'Looks for a new version when Navis starts. Check now is in About.';

  @override
  String get integrationsFeatureAutoEqCatalogueTitle => 'Headphone profiles';

  @override
  String get integrationsFeatureAutoEqCatalogueSubtitle =>
      'Refresh the catalogue and download profiles in the equalizer.';

  @override
  String get integrationsFeatureRadioNowPlayingTitle => 'Now playing';

  @override
  String get integrationsFeatureRadioNowPlayingSubtitle =>
      'Song and artwork from the station while you listen.';

  @override
  String get integrationsFeatureArtworkServerLinkedTitle => 'Linked images';

  @override
  String get integrationsFeatureArtworkServerLinkedSubtitle =>
      'Artist photos and other images hosted outside your server.';

  @override
  String get integrationsLockedMasterOff => 'Online services are off.';

  @override
  String integrationsLockedServiceOff(String service) {
    return '$service is off.';
  }

  @override
  String get integrationsLockedNeedsLastFmKey =>
      'Needs a verified Last.fm API key.';

  @override
  String get integrationsLockedNeedsListenBrainzToken =>
      'Needs a verified ListenBrainz token.';

  @override
  String get integrationsLastFmKeyIncluded => 'Key included with this build';

  @override
  String get integrationsSaveError => 'Couldn\'t save this change. Try again.';

  @override
  String get integrationsLoadError => 'Could Not Load Integrations';

  @override
  String integrationsNoticeTitle(String version) {
    return 'New in $version';
  }

  @override
  String get integrationsNoticeBody =>
      'Navis can now use Deezer for top songs, artist photos and new releases. Review integrations.';

  @override
  String get setupHighlightsCardTitle => 'New appearance options';

  @override
  String get setupHighlightsCardBody =>
      'Color styles, corner style, Now Playing background and more. Try them in Quick Customization.';

  @override
  String get setupHighlightsCardDismiss => 'Dismiss';

  @override
  String get settingsAppearanceNewOptionsSemantics => 'Has new options';

  @override
  String get appearanceSectionTheme => 'Theme';

  @override
  String get appearanceSectionColor => 'Color';

  @override
  String get appearanceSectionShapeLayout => 'Shape & Layout';

  @override
  String get appearanceSectionNowPlaying => 'Now Playing';

  @override
  String get newFeatureTagSemantics => 'New option';

  @override
  String get integrationsNoticeDismiss => 'Dismiss';

  @override
  String get listenBrainzConnectedTitle => 'ListenBrainz connected';

  @override
  String listenBrainzConnectedAs(String account) {
    return 'Connected as $account.';
  }

  @override
  String get listenBrainzConnectedNoAccount => 'Your token is valid.';

  @override
  String get listenBrainzUpdateToken => 'Update';

  @override
  String get updateCheckOffInIntegrations =>
      'Update checks are off in Integrations.';

  @override
  String get commonQueued => 'Queued';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonErrorRecoveryHint => 'Check your connection and try again.';

  @override
  String get detailUnavailableBackToLibrary => 'Back to Library';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonUndo => 'Undo';

  @override
  String get libraryTitle => 'Library';

  @override
  String libraryFilteringLabel(String query) {
    return 'Filtering: \"$query\"';
  }

  @override
  String libraryFilterNoResults(String query) {
    return 'No results for \"$query\"';
  }

  @override
  String get libraryFilterNoResultsSubtitle => 'Try a different search';

  @override
  String get libraryTabArtists => 'Artists';

  @override
  String get librarySwitchToArtistGrid => 'Switch to artist grid view';

  @override
  String get librarySwitchToArtistList => 'Switch to artist list view';

  @override
  String get libraryTabAlbums => 'Albums';

  @override
  String get libraryTabLiked => 'Liked';

  @override
  String get librarySyncRunning => 'Syncing library metadata...';

  @override
  String librarySyncRunningStage(Object stage) {
    return 'Syncing: $stage';
  }

  @override
  String librarySyncRunningWithProgress(int processed, int total) {
    return 'Syncing library metadata ($processed/$total)';
  }

  @override
  String get librarySyncStagePreparing => 'Preparing';

  @override
  String get librarySyncStageArtists => 'Fetching artists';

  @override
  String get librarySyncStageAlbums => 'Fetching albums';

  @override
  String get librarySyncStagePersisting => 'Persisting metadata';

  @override
  String get librarySyncStageSongs => 'Scanning songs';

  @override
  String get librarySyncStageStarred => 'Updating liked items';

  @override
  String get librarySyncStagePlaylists => 'Updating playlists';

  @override
  String get librarySyncStageFinalizing => 'Finalizing';

  @override
  String get librarySyncFailureFallback => 'Library sync failed.';

  @override
  String librarySyncScanningSongIndex(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString songs found',
      one: '1 song found',
    );
    return 'Metadata ready. Scanning song index ($_temp0)';
  }

  @override
  String get librarySyncHydratingUnknown =>
      'Metadata ready. Fetching remaining album details...';

  @override
  String librarySyncHydratingProgress(int processed, int total, int pending) {
    return 'Metadata ready. Fetching remaining album details ($processed/$total, $pending remaining)';
  }

  @override
  String librarySyncHydratingProgressWithRate(
    int processed,
    int total,
    int pending,
    Object rate,
  ) {
    return 'Metadata ready. Fetching remaining album details ($processed/$total, $pending remaining, $rate albums/s)';
  }

  @override
  String get libraryArtistsEmptyTitle => 'No Artists Found';

  @override
  String get libraryArtistsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryArtistsErrorTitle => 'Could Not Load Artists';

  @override
  String get libraryLikedArtistsSectionTitle => 'Liked Artists';

  @override
  String get libraryLikedAlbumsSectionTitle => 'Liked Albums';

  @override
  String get libraryLikedAlbumsSeeAll => 'See all';

  @override
  String get libraryLikedAlbumsAllTitle => 'Liked Albums';

  @override
  String get libraryLikedSongsSectionTitle => 'Liked Songs';

  @override
  String get libraryLikedEmptyTitle => 'Nothing Liked Yet';

  @override
  String get libraryLikedEmptySubtitle =>
      'Like albums or songs to see them here.';

  @override
  String get libraryLikedOnlyFilter => 'Liked';

  @override
  String get libraryLikedOnlyEmptyTitle => 'No Liked Matches';

  @override
  String get libraryNoPagesEnabledTitle => 'No Library Pages Enabled';

  @override
  String get libraryNoPagesEnabledSubtitle =>
      'Enable a page in Appearance settings to browse your library.';

  @override
  String get libraryNoPagesEnabledAction => 'Open Appearance Settings';

  @override
  String get libraryLikedOnlyEmptySubtitle =>
      'Try turning off the liked filter or like more content.';

  @override
  String get libraryAlbumsEmptyTitle => 'No Albums Found';

  @override
  String get libraryAlbumsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryAlbumsErrorTitle => 'Could Not Load Albums';

  @override
  String get libraryAlbumsByYearEmptyTitle => 'No Albums with Year Data';

  @override
  String get libraryAlbumsByYearEmptySubtitle =>
      'Sync more metadata or change filters to browse by year.';

  @override
  String get libraryAlbumsSortLabel => 'Sort Albums By';

  @override
  String libraryAlbumsPagingProgress(int loaded, int total) {
    final intl.NumberFormat loadedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String loadedString = loadedNumberFormat.format(loaded);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString albums',
      one: '1 album',
    );
    return 'Loaded $loadedString of $_temp0';
  }

  @override
  String get librarySortRecentlyAdded => 'Recently Added';

  @override
  String get librarySortNewest => 'Newest (Year)';

  @override
  String get librarySortByYear => 'By Year';

  @override
  String get librarySortName => 'Name';

  @override
  String get librarySortArtist => 'Artist';

  @override
  String get libraryArtistMenuOpen => 'Open artist';

  @override
  String get libraryAlbumMenuOpen => 'Open album';

  @override
  String get librarySongMenuPlayNow => 'Play now';

  @override
  String get librarySongMenuAddToQueue => 'Add to Queue';

  @override
  String get librarySongMenuPlayNext => 'Play next';

  @override
  String get librarySongMenuOpenAlbum => 'Open album';

  @override
  String get librarySongMenuOpenArtist => 'Open artist';

  @override
  String librarySongAddedToQueue(Object title) {
    return '\"$title\" added to queue.';
  }

  @override
  String librarySongPlayNextQueued(Object title) {
    return '\"$title\" added to play next.';
  }

  @override
  String artistCardAlbumCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count albums',
      one: '1 album',
    );
    return '$_temp0';
  }

  @override
  String get artistDetailTitle => 'Artist';

  @override
  String get artistDetailNotFoundTitle => 'Artist Not Found';

  @override
  String get artistDetailNotFoundSubtitle =>
      'This artist is not available in local data.';

  @override
  String artistDetailAlbumCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString albums',
      one: '1 album',
    );
    return '$_temp0';
  }

  @override
  String get artistDetailAlbumsEmptyTitle => 'No Albums for This Artist';

  @override
  String get artistDetailAlbumsEmptySubtitle =>
      'Sync your library to load artist albums.';

  @override
  String get artistDetailAlbumsSection => 'Albums';

  @override
  String get artistDetailFeaturedSection => 'Featured In';

  @override
  String get artistDetailBioSection => 'Biography';

  @override
  String get artistDetailSimilarSection => 'Similar Artists';

  @override
  String get artistDetailFansAlsoLikeSection => 'Fans Also Like';

  @override
  String get artistDetailMissingAlbumsSection => 'Missing Albums';

  @override
  String artistDetailFanCount(int count) {
    final intl.NumberFormat countNumberFormat = intl.NumberFormat.compact(
      locale: localeName,
    );
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString fans on Deezer',
      one: '1 fan on Deezer',
    );
    return '$_temp0';
  }

  @override
  String get sourceFromDeezer => 'From Deezer';

  @override
  String get sourceFromLastFm => 'From Last.fm';

  @override
  String get sourceFromDeezerAndLastFm => 'From Deezer and Last.fm';

  @override
  String get deezerReleaseTypeAlbum => 'Album';

  @override
  String get deezerReleaseTypeEp => 'EP';

  @override
  String get deezerReleaseTypeSingle => 'Single';

  @override
  String get deezerReleaseTypeCompilation => 'Compilation';

  @override
  String get artistDetailAlbumsErrorTitle => 'Could Not Load Artist Albums';

  @override
  String get artistDetailLoadErrorTitle => 'Could Not Load Artist Details';

  @override
  String get artistDetailLoadingLabel => 'Loading Artist Details';

  @override
  String get artistDetailLoadingRemote => 'Loading Remote Artist…';

  @override
  String get artistDetailLoadingServer => 'Loading Artist…';

  @override
  String get artistDetailLoadFailedTitle => 'Could Not Load This Artist';

  @override
  String get artistDetailRefreshError =>
      'Could not refresh this artist. Check your connection and try again.';

  @override
  String get detailLoadFailedMessage =>
      'Your server could not provide it right now.';

  @override
  String detailSearchFor(String name) {
    return 'Search for $name';
  }

  @override
  String get detailRefreshAction => 'Refresh';

  @override
  String get artistTopTracksSection => 'Top Tracks';

  @override
  String get artistTopTracksShowMore => 'Show more';

  @override
  String get artistTopTracksShowLess => 'Show less';

  @override
  String artistTopTracksListeners(String count) {
    return '$count listeners';
  }

  @override
  String get artistTopTracksNotAvailable =>
      'Track not available in your library.';

  @override
  String get artistTopTracksPlayError => 'Could not play track. Try again.';

  @override
  String artistTopTracksPlaylistTitle(String artist) {
    return 'This Is $artist';
  }

  @override
  String get artistTopTracksPlaylistEmptyTitle => 'No Top Tracks';

  @override
  String get artistTopTracksPlaylistEmptySubtitle =>
      'No top songs are available for this artist.';

  @override
  String get artistTopTracksPlaylistErrorTitle => 'Failed to Load Top Tracks';

  @override
  String get albumDetailTitle => 'Album';

  @override
  String get albumDetailUnknownArtist => 'Unknown artist';

  @override
  String get albumDetailTracksEmptyTitle => 'No Tracks for This Album';

  @override
  String get albumDetailTracksEmptySubtitle =>
      'Sync your library to load album tracks.';

  @override
  String get albumDetailLikedTracksEmptyTitle =>
      'No Liked Tracks in This Album';

  @override
  String get albumDetailLikedTracksEmptySubtitle =>
      'None of the tracks in this album have been liked yet.';

  @override
  String get albumDetailShowAllTracksAction => 'Show All Tracks';

  @override
  String get albumDetailFilterLabel => 'Filters';

  @override
  String get albumDetailRefreshError =>
      'Could not refresh this album. Check your connection and try again.';

  @override
  String get albumDetailLoadingRemote => 'Loading Remote Album…';

  @override
  String get albumDetailLoadingServer => 'Loading Album…';

  @override
  String get albumDetailLoadFailedTitle => 'Could Not Load This Album';

  @override
  String get albumDetailPlayAction => 'Play';

  @override
  String get albumDetailShuffleAction => 'Shuffle';

  @override
  String get albumDetailStarAction => 'Like';

  @override
  String get albumDetailDownloadAction => 'Download Album';

  @override
  String get albumDetailStarFailure => 'Could not update like status.';

  @override
  String get albumDetailAboutSection => 'About This Album';

  @override
  String get albumDetailMenuShowAlbumArt => 'Show album art';

  @override
  String get albumDetailTitleCopied => 'Copied to clipboard';

  @override
  String get albumDetailLastFm => 'Last.fm';

  @override
  String get albumDetailMusicBrainz => 'MusicBrainz';

  @override
  String albumDetailDiscHeader(int number) {
    return 'Disc $number';
  }

  @override
  String get miniPlayerUnknownTrack => 'Unknown track';

  @override
  String get miniPlayerUnknownArtist => 'Unknown artist';

  @override
  String get miniPlayerPlay => 'Play';

  @override
  String get miniPlayerPause => 'Pause';

  @override
  String get miniPlayerSkipNext => 'Skip to next';

  @override
  String get playbackBootstrapLoadingTitle => 'Preparing Playback';

  @override
  String get playbackBootstrapLoadingSubtitle =>
      'Restoring your listening session…';

  @override
  String get playbackBootstrapRecoveryTitle =>
      'Playback Is Taking Longer Than Usual';

  @override
  String get playbackBootstrapRecoverySubtitle =>
      'You can restart Navis, recover local playback data, or continue without playback.';

  @override
  String get playbackBootstrapContinueToSignIn => 'Continue to sign in';

  @override
  String get playbackRecoveryRestart => 'Restart Navis';

  @override
  String get startupCopyDetails => 'Copy details';

  @override
  String get startupDetailsCopied => 'Startup details copied';

  @override
  String get playbackRecoveryRetry => 'Retry playback';

  @override
  String get playbackRecoveryResetCache => 'Reset library cache and retry';

  @override
  String get playbackRecoveryResetConfirmTitle => 'Reset Library Cache?';

  @override
  String get playbackRecoveryResetConfirmBody =>
      'This permanently deletes your streaming cache, cover art cache, and local library metadata. Downloaded music and your sign-in will be kept.';

  @override
  String get playbackRecoveryResetConfirmAction => 'Reset Cache';

  @override
  String get playbackRecoveryWipeConfirmTitle =>
      'Sign Out and Clear Local Data?';

  @override
  String get playbackRecoveryWipeConfirmBody =>
      'This permanently deletes your sign-in, downloaded music, caches, library metadata, and history from this device, including playlists and radio stations saved on this device.';

  @override
  String get playbackRecoveryWipeConfirmAction => 'Clear Local Data';

  @override
  String get playbackRecoveryActionFailed =>
      'Could not complete playback recovery. Try again.';

  @override
  String get playbackRecoverySheetTitle => 'Playback Unavailable';

  @override
  String get playbackRecoverySheetSubtitle =>
      'You can keep browsing Navis. Choose a recovery action before trying playback again.';

  @override
  String get playbackUnavailableInitializing =>
      'Playback is still initializing. Try again in a moment.';

  @override
  String get playbackUnavailableStartupFailed =>
      'Playback is restarting. Try again in a moment.';

  @override
  String get playbackUnavailableSource =>
      'Could not resolve an audio source. Check server session and connection.';

  @override
  String get playbackUnavailableGeneric => 'Playback is unavailable right now.';

  @override
  String get playbackActionFailed =>
      'Playback action failed. Please try again.';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get queueTitle => 'Queue';

  @override
  String get queueUnknownTrack => 'Unknown track';

  @override
  String get queueUnavailableTrackDescription =>
      'This track is no longer available in your library.';

  @override
  String get queueUnknownArtist => 'Unknown artist';

  @override
  String get queueTrackLoadError => 'Error loading track';

  @override
  String get queueTrackLoadErrorDescription =>
      'This track couldn\'t be loaded. You can remove it from the queue or try again later.';

  @override
  String get queueClearAction => 'Clear Queue';

  @override
  String get queueClearConfirmTitle => 'Clear Queue?';

  @override
  String get queueClearConfirmMessage =>
      'This will remove all tracks from the queue.';

  @override
  String get queueEmptyTitle => 'Queue Is Empty';

  @override
  String get queueEmptySubtitle => 'Add tracks to start playing.';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get nowPlayingTitle => 'Now Playing';

  @override
  String get nowPlayingUnknownTrack => 'Unknown track';

  @override
  String get nowPlayingUnknownArtist => 'Unknown artist';

  @override
  String get nowPlayingUnknownAlbum => 'Unknown album';

  @override
  String get nowPlayingShuffle => 'Shuffle';

  @override
  String get nowPlayingShuffleOff => 'Shuffle off';

  @override
  String queueShuffleOnStatus(String queue) {
    return '$queue, shuffle on';
  }

  @override
  String get nowPlayingPrevious => 'Previous';

  @override
  String get nowPlayingRestartCurrent => 'Restarting current track';

  @override
  String get nowPlayingPlay => 'Play';

  @override
  String get nowPlayingPause => 'Pause';

  @override
  String get nowPlayingNext => 'Next';

  @override
  String get nowPlayingNoNextTrack => 'No next track';

  @override
  String get nowPlayingRepeatOff => 'Repeat off';

  @override
  String get nowPlayingRepeatAll => 'Repeat all';

  @override
  String get nowPlayingRepeatOne => 'Repeat one';

  @override
  String get nowPlayingLyrics => 'Lyrics';

  @override
  String get nowPlayingQueue => 'Queue';

  @override
  String nowPlayingQueuePosition(int current, int total) {
    return 'Playing $current of $total';
  }

  @override
  String get nowPlayingInstantMix => 'Start Instant Mix';

  @override
  String get nowPlayingInstantMixLabel => 'Instant Mix';

  @override
  String nowPlayingInstantMixStarted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Instant Mix started — $count similar tracks queued.',
      one: 'Instant Mix started — 1 similar track queued.',
      zero: 'No similar tracks found.',
    );
    return '$_temp0';
  }

  @override
  String get nowPlayingInstantMixUnsupported =>
      'Your server doesn\'t support Instant Mix.';

  @override
  String get nowPlayingInstantMixError => 'Couldn\'t start Instant Mix.';

  @override
  String get nowPlayingSameVibesLabel => 'Same Vibes';

  @override
  String nowPlayingSameVibesStarted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Same Vibes started — $count similar tracks from Last.fm queued.',
      one: 'Same Vibes started — 1 similar track from Last.fm queued.',
      zero: 'No similar tracks found.',
    );
    return '$_temp0';
  }

  @override
  String get nowPlayingSameVibesUnsupported =>
      'Your server doesn\'t support similar-track lookups.';

  @override
  String get nowPlayingSameVibesError => 'Couldn\'t start Same Vibes.';

  @override
  String get nowPlayingSameVibesStopped => 'Same Vibes stopped.';

  @override
  String get nowPlayingMore => 'More options';

  @override
  String get nowPlayingGoToAlbum => 'Go to album';

  @override
  String get nowPlayingGoToArtist => 'Go to artist';

  @override
  String get nowPlayingAudioQuality => 'Audio quality';

  @override
  String get nowPlayingTranscodedPlayback => 'Transcoded playback';

  @override
  String get nowPlayingReleaseDate => 'Release date';

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get lyricsNoneAvailable => 'No Lyrics Available';

  @override
  String get lyricsError => 'Could not load lyrics. Check your connection.';

  @override
  String get lyricsUnsupported => 'Lyrics not supported by this server.';

  @override
  String get lyricsSourceServerSynced => 'Lyrics source: Server (synced)';

  @override
  String get lyricsSourceServerPlain => 'Lyrics source: Server';

  @override
  String get lyricsSourceLrclibSynced => 'Lyrics source: LRCLIB (synced)';

  @override
  String get lyricsSourceLrclibPlain => 'Lyrics source: LRCLIB';

  @override
  String get lyricsAttributionLrclib => 'Lyrics provided by LRCLIB';

  @override
  String get ratingTitle => 'Rating';

  @override
  String get ratingHint => 'Tap a star to set or clear';

  @override
  String get ratingNoValue => 'No Rating';

  @override
  String get ratingNotLiked => 'Not liked';

  @override
  String get ratingActionLabel => 'Rate';

  @override
  String ratingValueShort(int rating) {
    return '$rating/5';
  }

  @override
  String get ratingUpdateFailed => 'Could not update rating.';

  @override
  String get queueSaveAsPlaylist => 'Save as playlist';

  @override
  String get searchHint => 'Search artists, albums, songs...';

  @override
  String get quickSearchHint => 'Search library...';

  @override
  String get quickSearchSubmitTooltip => 'Search';

  @override
  String get quickSearchEverything => 'Search Everything';

  @override
  String get instantRadioAction => 'Instant Radio';

  @override
  String get instantRadioLoading => 'Starting radio…';

  @override
  String get instantRadioStop => 'Stop radio';

  @override
  String get instantRadioEmpty => 'No playable songs match these filters.';

  @override
  String get instantRadioError =>
      'Couldn’t start radio. Check your connection or try again.';

  @override
  String get instantRadioFallback => 'Radio is using music from your library.';

  @override
  String get instantRadioRetry => 'Retry radio';

  @override
  String get sameVibesInvalidKey =>
      'Last.fm rejected the API key. Update it in Settings and retry.';

  @override
  String get sameVibesRateLimited =>
      'Last.fm is limiting requests. Try again later.';

  @override
  String get searchRecentTitle => 'Recent Searches';

  @override
  String get searchClearRecent => 'Clear';

  @override
  String get searchClearQuery => 'Clear search';

  @override
  String searchNoResultsForQuery(String query) {
    return 'No results for \"$query\"';
  }

  @override
  String get searchNoResultsSubtitle => 'Try a different search term.';

  @override
  String get searchLoadError => 'Could Not Load Search Results';

  @override
  String get searchArtistsSection => 'Artists';

  @override
  String get searchAlbumsSection => 'Albums';

  @override
  String get searchSongsSection => 'Songs';

  @override
  String get searchShowAll => 'Show all';

  @override
  String get searchShowLess => 'Show less';

  @override
  String searchAlbumCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString albums',
      one: '1 album',
    );
    return '$_temp0';
  }

  @override
  String get searchPlayNext => 'Play next';

  @override
  String get searchAddToQueue => 'Add to Queue';

  @override
  String get searchFilterAll => 'All';

  @override
  String get searchLocalOfflineBanner => 'Searching local library (offline)';

  @override
  String get playlistsEmpty => 'No Playlists Yet';

  @override
  String get playlistsEmptySubtitle => 'Create a playlist to get started.';

  @override
  String get playlistsLoadError => 'Failed to load playlists';

  @override
  String entityTotalDurationMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String entityTotalDurationHours(int hours, int minutes) {
    return '$hours hr $minutes min';
  }

  @override
  String playlistsSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$_temp0';
  }

  @override
  String get playlistsCreateAction => 'New Playlist';

  @override
  String get playlistsCreateTitle => 'Create Playlist';

  @override
  String get playlistsCreateNameLabel => 'Playlist Name';

  @override
  String get playlistsCreateSuccess => 'Playlist created';

  @override
  String get playlistsCreateFailed => 'Failed to create playlist';

  @override
  String get playlistsDeleteConfirmTitle => 'Delete Playlist?';

  @override
  String playlistsDeleteConfirmMessage(String name) {
    return 'This will permanently delete \"$name\".';
  }

  @override
  String playlistsDeleteLocalConfirmMessage(String name) {
    return 'This will permanently delete \"$name\" from this device. It is not saved on your server.';
  }

  @override
  String get playlistsOnDevice => 'On this device';

  @override
  String get playlistsSaveToServerLabel => 'Save to server';

  @override
  String get playlistsSaveToServerSubtitle =>
      'Off keeps this playlist on this device only';

  @override
  String get playlistsSaveToServerOfflineSubtitle =>
      'Unavailable offline. The playlist stays on this device';

  @override
  String get playlistsRenameTitle => 'Rename Playlist';

  @override
  String get playlistsRenameFailed => 'Failed to rename playlist';

  @override
  String get playlistsDeleteFailed => 'Failed to delete playlist';

  @override
  String get playlistsFilterHint => 'Search playlists...';

  @override
  String get playlistsSectionYours => 'Your playlists';

  @override
  String get playlistsSectionMadeForYou => 'Made for you';

  @override
  String get playlistsSectionOther => 'Other playlists';

  @override
  String get playlistDetailTitle => 'Playlist';

  @override
  String playlistDetailMeta(String owner, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$owner · $_temp0';
  }

  @override
  String get playlistDetailNotFound => 'Playlist not found';

  @override
  String get playlistDetailNotFoundSubtitle => 'It may have been deleted.';

  @override
  String get playlistDetailLoadError => 'Failed to load playlist';

  @override
  String get playlistDetailEmptyTitle => 'No Tracks';

  @override
  String get playlistDetailEmptySubtitle => 'Add songs from the library.';

  @override
  String get playlistDetailRemoveTrack => 'Remove from playlist';

  @override
  String get playlistDetailTrackRemoved => 'Track removed';

  @override
  String get playlistDetailTrackRemoveFailed => 'Failed to remove track';

  @override
  String get playlistDetailReorderFailed => 'Failed to reorder tracks';

  @override
  String get addToPlaylistTitle => 'Add to Playlist';

  @override
  String addToPlaylistSuccess(String name) {
    return 'Added to \"$name\"';
  }

  @override
  String addToPlaylistPartial(String name, int skipped) {
    String _temp0 = intl.Intl.pluralLogic(
      skipped,
      locale: localeName,
      other: '$skipped songs were',
      one: '1 song was',
    );
    return 'Added to \"$name\"; $_temp0 skipped';
  }

  @override
  String get addToPlaylistNewPlaylist => 'New playlist';

  @override
  String get addToPlaylistFailed => 'Failed to add to playlist';

  @override
  String get librarySongMenuAddToPlaylist => 'Add to playlist';

  @override
  String get cacheSettingsTitle => 'Cache & Storage';

  @override
  String get cacheSettingsRollingSection => 'Streaming Cache';

  @override
  String get cacheSettingsRollingDescription =>
      'Recently streamed tracks are cached automatically. Oldest tracks are evicted when the budget is exceeded.';

  @override
  String get cacheSettingsRollingBudgetLabel => 'Cache Budget';

  @override
  String cacheSettingsRollingCurrentSize(String used, String budget) {
    return '$used / $budget';
  }

  @override
  String cacheSettingsRollingTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cached tracks',
      one: '1 cached track',
      zero: 'No cached tracks',
    );
    return '$_temp0';
  }

  @override
  String get cacheSettingsRollingCaching => 'Caching current track…';

  @override
  String cacheSettingsRollingCachingProgress(int percent) {
    return 'Caching current track… $percent%';
  }

  @override
  String get cacheSettingsClearRolling => 'Clear streaming cache';

  @override
  String get cacheSettingsClearRollingConfirm =>
      'Clear all cached streaming audio? This cannot be undone.';

  @override
  String cacheSettingsPermanentTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloaded tracks',
      one: '1 downloaded track',
      zero: 'No downloaded tracks',
    );
    return '$_temp0';
  }

  @override
  String get cacheSettingsClearPermanent => 'Remove all downloads';

  @override
  String get cacheSettingsClearPermanentConfirm =>
      'Remove all downloaded tracks? This cannot be undone.';

  @override
  String get cacheSettingsClearCoverArt => 'Clear cover art cache';

  @override
  String get cacheSettingsClearCoverArtConfirm =>
      'Clear all cached cover art images?';

  @override
  String get cacheSettingsClearSuccess => 'Cache cleared.';

  @override
  String get cacheSettingsBudgetSaved => 'Cache budget updated.';

  @override
  String cacheSettingsBudgetGb(String gb) {
    return '$gb GB';
  }

  @override
  String get downloadQualityTitle => 'Download Quality';

  @override
  String get downloadQualityOriginal => 'Original quality';

  @override
  String get downloadQualityOriginalSub => 'Lossless / as stored on server';

  @override
  String downloadQualityTranscoded(int kbps, String format) {
    return '$kbps kbps $format';
  }

  @override
  String downloadQualityAlwaysTitle(String quality) {
    return 'Always download in $quality?';
  }

  @override
  String get downloadQualityAlwaysBody =>
      'Navis will stop asking and download everything in this quality. You can change this anytime in Downloads settings.';

  @override
  String get downloadQualityAlwaysAsk => 'Ask every time';

  @override
  String get downloadQualityAlwaysUse => 'Always use';

  @override
  String downloadQueuedWithQuality(String message, String quality) {
    return '$message · $quality';
  }

  @override
  String get downloadsSettingsQualitySection => 'Quality';

  @override
  String get downloadsSettingsQualityLabel => 'Download quality';

  @override
  String get downloadsSettingsQualityAsk => 'Ask every time';

  @override
  String get downloadsSettingsFormatLabel => 'Transcode format';

  @override
  String get downloadsSettingsFormatHelper =>
      'Used for downloads below original quality';

  @override
  String get downloadsSettingsConcurrentTitle => 'Concurrent downloads';

  @override
  String downloadsSettingsConcurrentValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloads at a time',
      one: '1 download at a time',
    );
    return '$_temp0';
  }

  @override
  String downloadsSettingsConcurrentCellular(String value) {
    return '$value · 1 on mobile data';
  }

  @override
  String get downloadsPauseAll => 'Pause';

  @override
  String get downloadsResumeAll => 'Resume';

  @override
  String get downloadsPausedBanner =>
      'Downloads are paused. Resume to continue the queue.';

  @override
  String get downloadAction => 'Download';

  @override
  String get downloadSongQueued => 'Download queued.';

  @override
  String downloadAlbumQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks queued for download',
      one: '1 track queued for download',
      zero: 'All tracks already downloaded',
    );
    return '$_temp0';
  }

  @override
  String downloadPlaylistQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks queued for download',
      one: '1 track queued for download',
      zero: 'All tracks already downloaded',
    );
    return '$_temp0';
  }

  @override
  String get downloadsTitle => 'Downloads';

  @override
  String get downloadsTabSettings => 'Settings';

  @override
  String get downloadsTabQueue => 'Queue';

  @override
  String get downloadsTabDownloaded => 'Downloaded';

  @override
  String get downloadsQueueEmpty => 'No Pending Downloads';

  @override
  String get downloadsQueueEmptySubtitle =>
      'Download tracks from albums or playlists for offline listening.';

  @override
  String get downloadsDownloadedEmpty => 'No Downloaded Tracks';

  @override
  String get downloadsDownloadedEmptySubtitle =>
      'Downloaded tracks will appear here.';

  @override
  String get downloadsRemoveAction => 'Remove Download';

  @override
  String get downloadsOpenFolderAction => 'Open Downloaded Folder';

  @override
  String get downloadsOpenFolderError =>
      'Could not open the downloaded folder.';

  @override
  String get downloadsRedownloadQueued => 'Queued for re-download';

  @override
  String get downloadsChangeQuality => 'Change Download Quality';

  @override
  String downloadsChangeQualityCurrent(String quality) {
    return 'Current: $quality';
  }

  @override
  String get downloadsCancelAction => 'Cancel Download';

  @override
  String get downloadsRetryFailed => 'Retry failed';

  @override
  String get downloadsStatusFailed => 'Failed';

  @override
  String get downloadsRetryAllFailed => 'Retry all failed';

  @override
  String get downloadsErrorLoadingQueue => 'Could Not Load Download Queue.';

  @override
  String get downloadsClearQueue => 'Clear Queue';

  @override
  String get downloadsClearQueueConfirm =>
      'Remove all queued downloads? Active downloads will be cancelled.';

  @override
  String get downloadsQueueSearchHint => 'Search queue...';

  @override
  String get downloadsSearchHint => 'Search downloads...';

  @override
  String get downloadsCustomFolderTitle => 'Custom Folder';

  @override
  String get downloadsCustomFolderSubtitle =>
      'Store permanent downloads in a folder you choose. Navis moves its downloads there into artist folders; files already in the folder keep their names.';

  @override
  String get downloadsCustomFolderUnsupported =>
      'Custom download folders are not available on this platform.';

  @override
  String get downloadsCustomFolderChooseAction => 'Choose Folder';

  @override
  String get downloadsCustomFolderSaved => 'Download folder updated.';

  @override
  String get downloadsCustomFolderDisabled =>
      'Custom download folder disabled.';

  @override
  String get downloadsCustomFolderDisableTitle => 'Turn Off Custom Folder?';

  @override
  String get downloadsCustomFolderDisableConfirm =>
      'Files in this folder stay where they are, and Navis stops listing them as downloads. Turn the folder back on to pick them up again. New downloads are stored by Navis.';

  @override
  String get downloadsCustomFolderDisableAction => 'Turn Off';

  @override
  String get downloadsCustomFolderUpdating => 'Moving downloaded tracks...';

  @override
  String get downloadsScanError => 'Could not scan the downloads folder.';

  @override
  String get downloadsRescanTitle => 'Rescan Existing Downloads';

  @override
  String get downloadsRescanSubtitle => 'Import tracks already in this folder';

  @override
  String get downloadsManualMatchingTitle => 'Manual Matching';

  @override
  String downloadsManualMatchingPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs from the last scan need to be matched by hand.',
      one: '1 song from the last scan needs to be matched by hand.',
    );
    return '$_temp0';
  }

  @override
  String get downloadsManualMatchingNone =>
      'No songs need manual matching from the most recent scan.';

  @override
  String get downloadsCustomFolderSelected => 'Selected folder';

  @override
  String downloadsRescanImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count existing downloads imported.',
      one: '1 existing download imported.',
      zero: 'No existing downloads imported.',
    );
    return '$_temp0';
  }

  @override
  String downloadsManualImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matched downloads imported.',
      one: '1 matched download imported.',
      zero: 'No matched downloads imported.',
    );
    return '$_temp0';
  }

  @override
  String downloadsCustomFolderError(String message) {
    return 'Could not update download folder: $message';
  }

  @override
  String downloadsSearchNoResults(String query) {
    return 'No results for \"$query\"';
  }

  @override
  String get libraryDownloadedOnlyFilter => 'Downloaded';

  @override
  String get libraryDownloadedOnlyEmpty => 'No Downloaded Content';

  @override
  String get libraryDownloadedOnlyEmptySubtitle =>
      'Download albums or tracks to see them here.';

  @override
  String get libraryClearFiltersAction => 'Show All';

  @override
  String get libraryUnknownYear => 'Unknown year';

  @override
  String get cacheSettingsWifiOnlyDownloads => 'Download on Wi-Fi only';

  @override
  String get cacheSettingsWifiOnlyDownloadsSub =>
      'Pause downloads when not connected to Wi-Fi.';

  @override
  String get cacheSettingsAutoDownloadStarred => 'Auto-download liked';

  @override
  String get cacheSettingsAutoDownloadStarredSub =>
      'Queue liked albums and songs for download automatically.';

  @override
  String get cacheSettingsAutoDownloadCellularWarningTitle =>
      'Allow Liked Downloads on Mobile Data?';

  @override
  String get cacheSettingsAutoDownloadCellularWarning =>
      'Your liked library can use a large amount of storage and mobile data when Wi-Fi-only downloads are off.';

  @override
  String get cacheSettingsAutoDownloadCellularWarningContinue => 'Continue';

  @override
  String get externalSourceBadgeLabel =>
      'Remote source — not in your server library.';

  @override
  String get remoteSourceLabel => 'Remote';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceThemeModeLabel => 'Theme Mode';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceThemeOled => 'OLED';

  @override
  String get appearanceThemeSystem => 'Auto';

  @override
  String get appearanceColorStyleLabel => 'Color Style';

  @override
  String get appearanceColorStyleNeutral => 'Neutral';

  @override
  String get appearanceColorStylePastel => 'Pastel';

  @override
  String get appearanceColorStyleImmersive => 'Immersive';

  @override
  String get appearanceColorStyleNight => 'Night';

  @override
  String get appearanceColorStyleNeutralSub =>
      'Neutral backgrounds. Color comes from your accent and album art.';

  @override
  String get appearanceColorStylePastelSub =>
      'Soft pastel accents on gently tinted backgrounds.';

  @override
  String get appearanceColorStyleImmersiveSub =>
      'Your accent color fills the backgrounds in deep, rich tones.';

  @override
  String get appearanceColorStyleNightSub =>
      'Warm colors with less blue light, for evening listening.';

  @override
  String get appearanceColorTuningLabel => 'Fine-Tune Colors';

  @override
  String get appearanceColorTuningColor => 'Intensity';

  @override
  String get appearanceColorTuningBrightness => 'Brightness';

  @override
  String get appearanceColorTuningMuted => 'Muted';

  @override
  String get appearanceColorTuningVivid => 'Vivid';

  @override
  String get appearanceColorTuningLighter => 'Lighter';

  @override
  String get appearanceColorTuningDeeper => 'Deeper';

  @override
  String get appearanceColorTuningDefault => 'Default';

  @override
  String get appearanceColorTuningMoreMuted => 'Make colors more muted';

  @override
  String get appearanceColorTuningMoreVivid => 'Make colors more vivid';

  @override
  String get appearanceColorTuningLighterBackgrounds =>
      'Make backgrounds lighter';

  @override
  String get appearanceColorTuningDeeperBackgrounds =>
      'Make backgrounds deeper';

  @override
  String get appearanceColorTuningReset => 'Reset';

  @override
  String appearanceColorTuningSummaryIntensity(String value) {
    return 'Intensity $value';
  }

  @override
  String appearanceColorTuningSummaryBrightness(String value) {
    return 'Brightness $value';
  }

  @override
  String appearanceColorTuningSummaryModeBrightness(String mode, String value) {
    return '$mode Brightness $value';
  }

  @override
  String get appearanceColorTuningAppliesLight => 'Applies in Light mode';

  @override
  String get appearanceColorTuningAppliesDark => 'Applies in Dark and OLED';

  @override
  String get appearanceColorTuningLooksHint =>
      'Save this as part of a Look in Appearance.';

  @override
  String get appearanceColorTuningHintNoAccent =>
      'Pick an accent color to see Intensity.';

  @override
  String get appearanceColorTuningHintMaxed =>
      'This style is already close to its most colorful here.';

  @override
  String get appearanceColorTuningBackgrounds => 'Backgrounds';

  @override
  String get appearanceColorTuningTint => 'Tint';

  @override
  String get appearanceColorTuningNone => 'None';

  @override
  String get appearanceColorTuningFull => 'Full';

  @override
  String get appearanceColorTuningLessTint => 'Use less tint';

  @override
  String get appearanceColorTuningMoreTint => 'Use more tint';

  @override
  String get appearanceColorTuningTintOled =>
      'OLED keeps pure black, so Tint only colors the panels.';

  @override
  String get appearanceColorTuningControls => 'Controls';

  @override
  String get appearanceColorTuningControlsAccent => 'Accent';

  @override
  String get appearanceColorTuningControlsWhite => 'White';

  @override
  String get appearanceColorTuningControlsHint =>
      'White fills Play, sliders and selected controls instead of the accent color.';

  @override
  String appearanceColorTuningSummaryTint(String value) {
    return 'Tint $value';
  }

  @override
  String appearanceColorTuningSummaryModeTint(String mode, String value) {
    return '$mode Tint $value';
  }

  @override
  String get appearanceColorTuningSummaryWhiteControls => 'White controls';

  @override
  String get appearanceLooksLabel => 'Looks';

  @override
  String get appearanceLooksSub => 'Save and switch your colours and style.';

  @override
  String get appearanceLooksSubEmpty =>
      'Save your colours and style from the menu, then switch back any time.';

  @override
  String get appearanceLooksPicker => 'Look';

  @override
  String get appearanceLooksActions => 'Look actions';

  @override
  String get appearanceLooksSaveNew => 'Save Current as New Look';

  @override
  String get appearanceLooksName => 'Look name';

  @override
  String get appearanceLooksMissing => 'That Look no longer exists.';

  @override
  String appearanceLooksApplied(String name) {
    return 'Applied $name';
  }

  @override
  String appearanceLooksCustomEdited(String name) {
    return 'Custom · edited from $name';
  }

  @override
  String get appearancePresetCustom => 'Custom';

  @override
  String appearancePresetUpdateNamed(String name) {
    return 'Update “$name”';
  }

  @override
  String appearancePresetRenameNamed(String name) {
    return 'Rename “$name”…';
  }

  @override
  String appearancePresetDeleteNamed(String name) {
    return 'Delete “$name”';
  }

  @override
  String appearancePresetDeleteConfirm(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get appearancePresetNameEmpty => 'Enter a name.';

  @override
  String get appearancePresetNameTaken => 'That name is already in use.';

  @override
  String get appearancePresetNameReserved =>
      'Default is reserved. Choose another name.';

  @override
  String get appearancePresetMissing => 'That preset no longer exists.';

  @override
  String get appearancePresetSaveFailure =>
      'Could not save your changes. Try again.';

  @override
  String get appearanceLanguageLabel => 'Language';

  @override
  String get appearanceLanguageSystemDefault => 'System default';

  @override
  String get appearanceLanguageUnavailable =>
      'Language switching is disabled in this build.';

  @override
  String get appearanceLanguageEnglish => 'English';

  @override
  String get appearanceColorSchemeLabel => 'Accent Color';

  @override
  String get appearanceColorSchemeSub =>
      'Choose the accent color your color style is built from.';

  @override
  String get appearanceColorSchemeDynamicSub =>
      'Dynamic Album Color is on: album art replaces your accent when a cover has one.';

  @override
  String get appearanceColorDefault => 'Default';

  @override
  String get appearanceColorCustom => 'Custom';

  @override
  String appearanceColorCustomSemantics(Object label) {
    return '$label, custom color';
  }

  @override
  String get appearanceColorPickerTitle => 'Pick a Custom Color';

  @override
  String get appearanceColorPickerHexLabel => 'Hex';

  @override
  String get appearanceColorPickerSave => 'Save as preset';

  @override
  String get appearanceColorPickerApply => 'Apply';

  @override
  String get appearanceColorPresetSaved => 'Custom preset saved';

  @override
  String get appearanceColorPresetDeleted => 'Custom preset deleted';

  @override
  String get appearanceColorDeletePreset => 'Delete preset';

  @override
  String get appearanceColorDeletePresetConfirm =>
      'Delete this custom color preset?';

  @override
  String appearanceLongPressHint(Object label) {
    return '$label (long-press to delete)';
  }

  @override
  String get appearanceNowPlayingBackgroundLabel => 'Now Playing Background';

  @override
  String get appearanceNowPlayingBackgroundTinted => 'Art-Tinted';

  @override
  String get appearanceNowPlayingBackgroundArtwork => 'Artwork';

  @override
  String get appearanceNowPlayingBackgroundPlain => 'Plain';

  @override
  String get appearanceNowPlayingBackgroundTintedSub =>
      'A soft gradient in the album art color, or one solid color when Flat Surfaces is on.';

  @override
  String get appearanceNowPlayingBackgroundArtworkSub =>
      'The album art, blurred and veiled so text stays easy to read. Flat Surfaces uses one solid color instead.';

  @override
  String get appearanceNowPlayingBackgroundOledFlatNote =>
      'With OLED and Flat Surfaces, Now Playing stays black.';

  @override
  String get appearanceNowPlayingBackgroundPlainSub =>
      'The plain background of your theme, with no album color.';

  @override
  String get appearanceOledForAutoLabel => 'Use OLED When Dark';

  @override
  String get appearanceOledForAutoSub =>
      'In Auto, use pure black instead of Dark when your device is in dark mode.';

  @override
  String get appearanceNightScheduleLabel => 'Night Schedule';

  @override
  String appearanceNightScheduleSub(Object start, Object end) {
    return 'Switches the color style to Night from $start to $end. Theme mode stays as set.';
  }

  @override
  String appearanceNightScheduleStartsAt(Object time) {
    return 'Starts at $time';
  }

  @override
  String appearanceNightScheduleEndsAt(Object time) {
    return 'Ends at $time';
  }

  @override
  String appearanceNightScheduleActiveNote(Object time) {
    return 'Night is on until $time.';
  }

  @override
  String get appearanceNightScheduleAlreadyNight =>
      'Your color style is already Night.';

  @override
  String get appearanceNightScheduleSameTimes =>
      'Pick different start and end times.';

  @override
  String get appearanceFlatSurfacesLabel => 'Flat Surfaces';

  @override
  String get appearanceFlatSurfacesSub =>
      'Solid colors without glows, gradients, shadows or blur. Now Playing Artwork becomes a solid color.';

  @override
  String get appearanceFlatAreaSurfacesLabel => 'Panels and Shadows';

  @override
  String get appearanceFlatAreaSurfacesSub =>
      'Solid panels and washes with no shadows, gradients or blur.';

  @override
  String get appearanceFlatAreaNowPlayingLabel => 'Now Playing';

  @override
  String get appearanceFlatAreaNowPlayingSub =>
      'A solid Now Playing screen and mini player.';

  @override
  String get appearanceFlatAreaArtworkTextLabel => 'Text Over Artwork';

  @override
  String get appearanceFlatAreaArtworkTextSub =>
      'Keep album art clear, with titles below the cover.';

  @override
  String get appearanceCornerStyleLabel => 'Corner Style';

  @override
  String get appearanceCornerStyleRounded => 'Pill';

  @override
  String get appearanceCornerStyleSoft => 'Soft';

  @override
  String get appearanceCornerStyleSquare => 'Square';

  @override
  String get appearanceCornerStyleRoundedSub =>
      'Pill-shaped buttons, chips and tags; gently rounded cards.';

  @override
  String get appearanceCornerStyleSoftSub =>
      'Larger, softer corners on cards, buttons and sheets.';

  @override
  String get appearanceCornerStyleSquareSub =>
      'Crisp corners on cards, buttons and chips.';

  @override
  String get appearanceCornerStyleArtworkNote =>
      'Artwork follows Artwork Shape.';

  @override
  String get appearanceDynamicAlbumColorLabel => 'Dynamic Album Color';

  @override
  String get appearanceDynamicAlbumColorSub =>
      'Album art replaces your accent when a cover has one.';

  @override
  String get appearanceAlbumArtShadeLabel => 'Album Art Shade';

  @override
  String get appearanceAlbumArtShadeSub =>
      'A solid shade behind album titles for easier reading.';

  @override
  String get appearanceAlbumArtShadeFlatNote =>
      'Album titles sit below the art while Flat text over artwork is on.';

  @override
  String get appearanceAlbumArtCoverColorLabel => 'Use Cover Color';

  @override
  String get appearanceAlbumArtCoverColorSub =>
      'Tint the shade with a color from each cover.';

  @override
  String get cacheSettingsCoverArtSection => 'Cover Art Cache';

  @override
  String get cacheSettingsCoverArtDescription =>
      'Cached album artwork images. Larger limits reduce network requests but use more storage.';

  @override
  String get cacheSettingsCoverArtMaxLabel => 'Maximum Images';

  @override
  String cacheSettingsCoverArtMaxValue(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString images',
      one: '1 image',
    );
    return '$_temp0';
  }

  @override
  String get cacheSettingsCoverArtMaxSaved => 'Cover art cache limit updated.';

  @override
  String get cacheSettingsCoverArtRestart =>
      'Changes take effect after restarting the app.';

  @override
  String get cacheSettingsCoverArtUnlimitedLabel => 'No Limit';

  @override
  String get cacheSettingsCoverArtUnlimitedSubtitle =>
      'Store all cover art on disk without restriction.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutChangelog => 'Changelog';

  @override
  String get aboutChangelogSub => 'See every version\'s changes and bug fixes.';

  @override
  String get aboutWebsite => 'Website';

  @override
  String get aboutPrivacyPolicy => 'Privacy policy';

  @override
  String get aboutPrivacyPolicySub => 'The full policy on the Navis website.';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutLicenseSub => 'GNU GPL v3.0 or later';

  @override
  String get aboutSourceCode => 'Source code';

  @override
  String get aboutReportBug => 'Report a bug';

  @override
  String get aboutContact => 'Contact support';

  @override
  String aboutLinkOpenFailed(String target) {
    return 'Couldn\'t open $target.';
  }

  @override
  String get changelogSpecialThanks => 'Special Thanks';

  @override
  String get changelogDiscoveryDismiss => 'Dismiss update notes';

  @override
  String changelogDiscoverySemanticLabel(String version) {
    return 'What’s new in version $version';
  }

  @override
  String changelogDiscoveryCheckOut(String version) {
    return 'Check out $version';
  }

  @override
  String changelogDiscoveryCheckOutNamed(String version, String codename) {
    return 'Check out $version “$codename”';
  }

  @override
  String changelogDiscoveryUpdatedTo(String version) {
    return 'Updated to $version';
  }

  @override
  String get changelogEmpty => 'No Changelog Entries Yet.';

  @override
  String get changelogEntryTypeNew => 'New';

  @override
  String get changelogEntryTypeImproved => 'Improved';

  @override
  String get changelogEntryTypeFixed => 'Fixed';

  @override
  String get changelogFilterAll => 'All';

  @override
  String changelogChangeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes',
      one: '1 change',
    );
    return '$_temp0';
  }

  @override
  String changelogShowAllFixes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show $count more fixes',
      one: 'Show 1 more fix',
    );
    return '$_temp0';
  }

  @override
  String get changelogShowFewerFixes => 'Show fewer fixes';

  @override
  String get changelogEarlierReleases => 'Earlier releases';

  @override
  String get changelogReleases => 'Releases';

  @override
  String changelogPartOf(String version) {
    return 'Part of $version';
  }

  @override
  String changelogPartOfNamed(String version, String codename) {
    return 'Part of $version “$codename”';
  }

  @override
  String get changelogHighlights => 'Highlights';

  @override
  String get changelogAllChanges => 'All changes';

  @override
  String changelogDiscoveryAndMore(String list, int count) {
    return '$list and $count more';
  }

  @override
  String get aboutLicenses => 'Open-source licenses';

  @override
  String get aboutLicensesSub => 'View third-party software licenses.';

  @override
  String get privacyTitle => 'Privacy';

  @override
  String get privacySub =>
      'How Navis handles your data and which online services it uses.';

  @override
  String get aboutDataUsageTitle => 'Data Usage';

  @override
  String get aboutDataUsageSubtitle =>
      'Local network usage estimates by feature and network type.';

  @override
  String get aboutDataUsageToday => 'Today';

  @override
  String get aboutDataUsageSevenDays => 'Last 7 days';

  @override
  String get aboutDataUsageThirtyDays => 'Last 30 days';

  @override
  String get aboutDataUsageBreakdown => 'Last 7 days by feature';

  @override
  String get aboutDataUsageEmpty => 'No Usage Recorded Yet.';

  @override
  String get aboutDataUsageLoading => 'Loading usage stats...';

  @override
  String get aboutDataUsageUnavailable => 'Usage stats unavailable.';

  @override
  String aboutDataUsageRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count requests',
      one: '1 request',
      zero: 'No requests',
    );
    return '$_temp0';
  }

  @override
  String get aboutDataUsageReset => 'Reset usage stats';

  @override
  String get aboutDataUsageResetConfirmTitle => 'Reset Usage Stats?';

  @override
  String get aboutDataUsageResetConfirmMessage =>
      'This clears local network usage totals on this device.';

  @override
  String get aboutDataUsageResetCancel => 'Cancel';

  @override
  String get aboutDataUsageResetConfirmAction => 'Reset';

  @override
  String get aboutDataUsageResetComplete => 'Usage stats reset.';

  @override
  String get aboutDataUsageResetFailed => 'Could not reset usage stats.';

  @override
  String get aboutDataUsageNetworkWifi => 'Wi-Fi';

  @override
  String get aboutDataUsageNetworkMobile => 'Mobile';

  @override
  String get aboutDataUsageNetworkOffline => 'Offline';

  @override
  String get aboutDataUsageNetworkOther => 'Other network';

  @override
  String get aboutDataUsageCategoryAudioStreaming => 'Audio streaming';

  @override
  String get aboutDataUsageCategoryDownloads => 'Downloads';

  @override
  String get aboutDataUsageCategoryCoverArt => 'Cover art';

  @override
  String get aboutDataUsageCategoryLibrarySync => 'Library sync';

  @override
  String get aboutDataUsageCategoryLyrics => 'Lyrics';

  @override
  String get aboutDataUsageCategoryScrobbling => 'Scrobbling';

  @override
  String get aboutDataUsageCategoryRecommendations => 'Recommendations';

  @override
  String get aboutDataUsageCategoryUpdates => 'Updates';

  @override
  String get aboutDataUsageCategoryOtherApi => 'Other API';

  @override
  String get updateCheckTitle => 'Check for Updates';

  @override
  String updateCheckSub(String version) {
    return 'Currently on $version. Tap to check now.';
  }

  @override
  String get updateAvailableTitle => 'Update Available';

  @override
  String updateAvailableBody(String version) {
    return '$version is ready to download.';
  }

  @override
  String updateReadyTitle(String version) {
    return 'Navis $version is ready';
  }

  @override
  String get updateReadyBodyInstall => 'Installs in a minute.';

  @override
  String get updateReadyBodyDownload => 'Opens the download page.';

  @override
  String get updateDownload => 'Download';

  @override
  String get updateDismiss => 'Dismiss';

  @override
  String get updateAvailableNotice => 'Update available';

  @override
  String get updateView => 'View';

  @override
  String get updateUpToDate => 'Navis is up to date.';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateRetry => 'Retry';

  @override
  String get updateReleaseNotes => 'Release notes';

  @override
  String updateDownloading(String version) {
    return 'Downloading $version…';
  }

  @override
  String get updateReadyToInstall => 'Download complete. Ready to install.';

  @override
  String get updateDownloadFailed => 'Download failed. Please try again.';

  @override
  String get updateDownloadDamaged =>
      'The update download was damaged. Try again.';

  @override
  String get updateApplyFailed => 'Could not apply the update automatically.';

  @override
  String get updateReadyToRestart =>
      'Download complete. Restart the app to apply the update.';

  @override
  String get updateRestartAndUpdate => 'Restart & Update';

  @override
  String get updateApplying => 'Applying update…';

  @override
  String get updateNoWriteAccess =>
      'Navis cannot update itself from this location. Please download manually.';

  @override
  String get updateSignatureMismatch =>
      'This update is signed with a different key than your installed version. Uninstall Navis, then install the new version manually.';

  @override
  String get updateDownloadManually => 'Download Manually';

  @override
  String get updatePlayStoreTitle => 'Update on Google Play';

  @override
  String updatePlayStoreBody(String version) {
    return '$version is available on Google Play. Update there to get the latest release.';
  }

  @override
  String get updateOpenPlayStore => 'Open in Play Store';

  @override
  String get updatePlayStoreFallbackNotice =>
      'Could not open Google Play. Opening the release page instead.';

  @override
  String get updatesSettingsSectionLabel => 'Updates';

  @override
  String get appearancePagesSectionLabel => 'Page Visibility';

  @override
  String get appearanceShowRadioPageSubtitle =>
      'Show the Radio tab in the Library screen.';

  @override
  String get appearanceShowPlaylistsPageSubtitle =>
      'Show the Playlists tab in the Library screen.';

  @override
  String get appearanceShowArtistsPageSubtitle =>
      'Show the Artists tab in the Library screen.';

  @override
  String get appearanceShowLikedPageSubtitle =>
      'Show the Liked tab in the Library screen.';

  @override
  String get appearanceGridDensityAuto => 'Auto';

  @override
  String get appearanceCoverArtShapeLabel => 'Artwork Shape';

  @override
  String get appearanceCoverArtShapeNote =>
      'Cards and buttons follow Corner Style.';

  @override
  String get appearanceCoverArtShapeSubLabel => 'Library & Carousel Art';

  @override
  String get appearanceNpArtShapeLabel => 'Now Playing Art';

  @override
  String get appearanceArtistCardShapeLabel => 'Artist Card Art';

  @override
  String get shapeSquare => 'Square';

  @override
  String get shapeRounded => 'Rounded';

  @override
  String get shapeCircle => 'Circle';

  @override
  String get appearanceArtistViewModeLabel => 'Artist View Mode';

  @override
  String get appearanceArtistViewModeGrid => 'Grid';

  @override
  String get appearanceArtistViewModeList => 'List';

  @override
  String get appearanceHomeSectionsLabel => 'Home Sections';

  @override
  String get appearanceDensityLabel => 'Density';

  @override
  String get appearanceDensitySub =>
      'Spacing for Home, track lists, playlists and artist lists.';

  @override
  String get appearanceDensityComfortable => 'Comfortable';

  @override
  String get appearanceDensityCompact => 'Compact';

  @override
  String get desktopNavbarSectionLabel => 'Desktop Navigation';

  @override
  String get desktopNavbarStyleLabel => 'Navigation Style';

  @override
  String get desktopNavbarStyleWide => 'Wide';

  @override
  String get desktopNavbarStyleNarrow => 'Narrow';

  @override
  String get desktopNavbarStyleIcons => 'Icons';

  @override
  String get desktopNavbarAutohideLabel => 'Collapse Sidebar';

  @override
  String get desktopNavbarAutohideSub =>
      'When inactive, the sidebar collapses to icons. Hover it to expand.';

  @override
  String get desktopNavbarLockTooltip => 'Keep Sidebar Expanded';

  @override
  String get desktopNavbarUnlockTooltip => 'Collapse Sidebar When Inactive';

  @override
  String get homeSectionRecentlyLikedAlbums => 'Recently Liked Albums';

  @override
  String get homeSectionLikedTracks => 'Liked Tracks';

  @override
  String get homeSectionRecentlyAdded => 'Recently Added';

  @override
  String get homeSectionRecentlyPlayed => 'Recently Played';

  @override
  String get homeSectionRandomAlbums => 'You Might Like';

  @override
  String get homeSectionMostPlayed => 'Most Played';

  @override
  String get homeSectionRecentlyPlayedTracks => 'Recently Played Tracks';

  @override
  String get homeSectionFrequentAlbums => 'Frequent Albums';

  @override
  String get homeSectionNewReleases => 'New Releases';

  @override
  String get homeSectionQuickActions => 'Quick Actions';

  @override
  String cacheSettingsCoverArtSizeLabel(String size) {
    return 'Storage used: $size';
  }

  @override
  String get cacheSettingsPrecacheTitle => 'Pre-Cache All Album Art';

  @override
  String get cacheSettingsPrecacheSubtitle =>
      'Download artwork for every album to the device now. Only available when cover art cache has no limit.';

  @override
  String cacheSettingsPrecachingProgress(int done, int total) {
    return 'Caching $done of $total...';
  }

  @override
  String cacheSettingsPrecacheSuccess(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString album art images',
      one: '1 album art image',
    );
    return 'Done — cached $_temp0.';
  }

  @override
  String get serverSettingsSignOutConfirmTitle => 'Sign Out';

  @override
  String get serverSettingsSignOutConfirmMessage =>
      'How would you like to handle your local library data? Clearing local data permanently deletes your downloads, caches, library metadata, and history, including playlists and radio stations saved on this device.';

  @override
  String get songStatusQueued => 'Queued for download';

  @override
  String get songStatusDownloading => 'Downloading…';

  @override
  String get songStatusCachedTooltip => 'Cached — tap to download';

  @override
  String get downloadsRemoveConfirmTitle => 'Remove Download?';

  @override
  String get downloadsRemoveConfirmContent =>
      'The downloaded file will be permanently deleted.';

  @override
  String get deleteDownloadAction => 'Delete Download';

  @override
  String get libraryAlbumMenuPlay => 'Play album';

  @override
  String get libraryAlbumMenuAddToQueue => 'Add to Queue';

  @override
  String get libraryAlbumMenuDownload => 'Download album';

  @override
  String get libraryAlbumAddedToQueue => 'Album added to queue';

  @override
  String get actionLike => 'Like';

  @override
  String get actionLiked => 'Liked';

  @override
  String get actionMore => 'More';

  @override
  String get remoteSourceActionUnavailable =>
      'Not available for remote tracks.';

  @override
  String get remoteSourceInstantMixUnavailable =>
      'Instant Mix requires a locally scanned track.';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonRename => 'Rename';

  @override
  String get commonRemove => 'Remove';

  @override
  String get commonReorder => 'Reorder';

  @override
  String get matchFlowTitle => 'Match Flow';

  @override
  String get matchFlowPlaybackSettingsSubtitle =>
      'Expand a selected master song into a saved local playback flow.';

  @override
  String get matchFlowManageTitle => 'Manage Match Flows';

  @override
  String get matchFlowCreateAction => 'New Flow';

  @override
  String get matchFlowEmptyTitle => 'No Match Flows Yet';

  @override
  String get matchFlowEmptySubtitle =>
      'Create a flow, choose a master song, then add the songs that should follow it.';

  @override
  String get matchFlowLoadError => 'Could Not Load Match Flow';

  @override
  String get matchFlowSaveError => 'Could not save Match Flow. Try again.';

  @override
  String get matchFlowSongAlreadyInFlow => 'This song is already in the flow.';

  @override
  String get matchFlowMissing => 'Match Flow no longer exists.';

  @override
  String get matchFlowMasterSongInAnotherFlow =>
      'This song is already the master song in another flow.';

  @override
  String matchFlowSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$_temp0';
  }

  @override
  String get matchFlowContentsTitle => 'Flow Contents';

  @override
  String get matchFlowExpandContents => 'Expand Flow Contents';

  @override
  String get matchFlowCollapseContents => 'Collapse Flow Contents';

  @override
  String get matchFlowNoSongs => 'Add a song to set the master.';

  @override
  String get matchFlowAddSongAction => 'Add Song';

  @override
  String get matchFlowAddSongTitle => 'Add Song';

  @override
  String get matchFlowSearchHint => 'Search songs';

  @override
  String get matchFlowNoSearchResults => 'No Songs Found';

  @override
  String get matchFlowRenameTitle => 'Rename Flow';

  @override
  String get matchFlowNameLabel => 'Flow Name';

  @override
  String get matchFlowDeleteTitle => 'Delete Flow?';

  @override
  String matchFlowDeleteMessage(String name) {
    return 'Delete “$name” and its song order?';
  }

  @override
  String get matchFlowMasterLabel => 'Master';

  @override
  String matchFlowUnresolvedSong(String songId) {
    return 'Unresolved song $songId';
  }

  @override
  String matchFlowSongAdded(String title) {
    return 'Added $title.';
  }

  @override
  String get desktopWindowTitle => 'Desktop Window';

  @override
  String get desktopViewTitle => 'Desktop View';

  @override
  String get desktopWindowSubtitle =>
      'Choose how Navis behaves as a full or compact desktop window.';

  @override
  String get desktopWindowUnavailable =>
      'Desktop window controls are only available in the desktop app.';

  @override
  String get desktopMiniPlayerTitle => 'Mini Player';

  @override
  String get desktopMiniPlayerDescription =>
      'Use a compact, playback-focused Navis window.';

  @override
  String get desktopMiniPlayerOpen => 'Open Mini Player';

  @override
  String get desktopReturnToView => 'Return to Desktop View';

  @override
  String get desktopMiniPlayerKeepOnTop => 'Keep Mini Player on top';

  @override
  String get desktopMiniPlayerStopOnTop => 'Stop keeping Mini Player on top';

  @override
  String get desktopMiniPlayerKeepOnTopDescription =>
      'Keep the compact player above other windows. This only applies in Mini Player.';

  @override
  String get desktopMiniPlayerKeepOnTopUnavailable =>
      'Always-on-top is unavailable in this Linux Wayland session. Your desktop compositor controls window stacking.';

  @override
  String get desktopMiniPlayerTooSmallTitle => 'Mini Player Is Too Small';

  @override
  String get desktopMiniPlayerTooSmallDescription =>
      'Mini Player needs at least 560 by 360 logical pixels. Restoring its last valid size.';

  @override
  String get desktopNothingPlaying => 'Nothing playing';

  @override
  String get desktopChooseSomething => 'Choose something to play';

  @override
  String get desktopNothingPlayingPrompt =>
      'Return to Desktop View to choose something to play.';

  @override
  String get desktopPlaybackUnavailableTooltip =>
      'Unavailable Until Something Is Playing';

  @override
  String get desktopFavoriteUnavailableForRadio =>
      'Favorite is unavailable for radio';

  @override
  String get desktopLyricsUnavailableForRadio =>
      'Lyrics are unavailable for radio';

  @override
  String get desktopQueueUnavailableForRadio =>
      'Queue is unavailable for radio';

  @override
  String get desktopWindowTooSmallTitle =>
      'This Window Is Too Small for Desktop View';

  @override
  String get desktopWindowMinimumDescription =>
      'Desktop View needs at least 800 by 600 logical pixels.';

  @override
  String get desktopReturnQuestion => 'Return to Desktop View?';

  @override
  String get desktopReturnDescription =>
      'The window is now large enough for the full desktop interface.';

  @override
  String get desktopSwitchToMiniPlayer => 'Switch to Mini Player';

  @override
  String get desktopRestoreSize => 'Restore Desktop Size';

  @override
  String get desktopKeepMiniPlayer => 'Keep Mini Player';

  @override
  String get desktopViewUnavailableOnDisplay =>
      'This display cannot fit Desktop View. Mini Player is available until Navis moves to a larger display.';

  @override
  String get unavailableReviewTitle => 'Unavailable Items';

  @override
  String get unavailableReviewEmpty =>
      'No unavailable items are waiting for review.';

  @override
  String get unavailableReviewLoadError => 'Could not load the review list.';

  @override
  String get unavailableReviewUnknownTitle => 'Unknown Item';

  @override
  String get unavailableReviewReasonMissing =>
      'No longer on the server. Favorites, ratings, history, and downloads are kept until you decide.';

  @override
  String get unavailableReviewReasonAmbiguous =>
      'Several possible replacements were found. Decide which one is correct before anything is relinked.';

  @override
  String get unavailableReviewReasonConflicting =>
      'Conflicting identifiers were found in the catalog. Review before anything is relinked.';

  @override
  String get unavailableReviewTypeSong => 'Song';

  @override
  String get unavailableReviewTypeAlbum => 'Album';

  @override
  String get unavailableReviewTypeArtist => 'Artist';

  @override
  String get unavailableReviewFindMatch => 'Find match';

  @override
  String get unavailableReviewKeepForLater => 'Keep for later';

  @override
  String get unavailableReviewRemoveFromLiked => 'Remove from Liked';

  @override
  String get unavailableReviewNoMatchFound =>
      'No matching item found in the current library.';

  @override
  String get unavailableReviewRelinkTitle => 'Relink Item';

  @override
  String get unavailableReviewRelinkOld => 'Unavailable item';

  @override
  String get unavailableReviewRelinkNew => 'Selected replacement';

  @override
  String get unavailableReviewReferences => 'References carried over';

  @override
  String get unavailableReviewRelinkApply => 'Relink';

  @override
  String get unavailableReviewRelinkDismiss => 'Cancel';

  @override
  String get unavailableReviewPossibleReplacements => 'Possible replacements';

  @override
  String get unavailableReviewStaleSelection =>
      'This selection is no longer current. Nothing was changed; the list was refreshed.';

  @override
  String get unavailableReviewAlreadyResolved =>
      'This entry was already resolved.';

  @override
  String unavailableReviewRefCopies(int count) {
    return 'Downloads and cached copies: $count';
  }

  @override
  String unavailableReviewRefPlaylists(int count) {
    return 'Playlist entries: $count';
  }

  @override
  String unavailableReviewRefHistory(int count) {
    return 'Played before: $count';
  }

  @override
  String unavailableReviewRefQueue(int count) {
    return 'Play queue entries: $count';
  }

  @override
  String unavailableReviewRefLikes(int count) {
    return 'Pending like or rating actions: $count';
  }

  @override
  String unavailableReviewRefSongs(int count) {
    return 'Songs that follow this item: $count';
  }

  @override
  String get unavailableReviewRefNone => 'No local references to carry over.';

  @override
  String get unavailableReviewEntry => 'Unavailable items';

  @override
  String unavailableReviewEntryWithCount(Object count) {
    return 'Unavailable items ($count)';
  }

  @override
  String get appearanceArtworkSizeLabel => 'Artwork Size';

  @override
  String get appearanceArtworkSizeSub =>
      'Controls artwork size in album and artist grids. Columns adjust to the available space.';

  @override
  String get appearanceArtworkSizeSmall => 'Small';

  @override
  String get appearanceArtworkSizeMedium => 'Medium';

  @override
  String get appearanceArtworkSizeLarge => 'Large';

  @override
  String get appearanceRecommendationsAutoAdvance =>
      'Automatically advance recommendations';

  @override
  String get appearanceRecommendationsAutoAdvanceSub =>
      'Move through You Might Like automatically. You can always swipe manually.';

  @override
  String get contentShelfPrevious => 'Previous items';

  @override
  String get contentShelfNext => 'Next items';

  @override
  String get trackColumnTitle => 'Title';

  @override
  String get trackColumnNumber => '#';

  @override
  String get trackColumnNumberDescription => 'Track number';

  @override
  String get trackColumnArtist => 'Artist';

  @override
  String get trackColumnAlbum => 'Album';

  @override
  String get trackColumnDuration => 'Time';

  @override
  String get playbackSpeedPitchTitle => 'Speed & Pitch';

  @override
  String get playbackPitchLabel => 'Pitch';

  @override
  String get playbackPresetLabel => 'Preset';

  @override
  String get playbackPresetNone => 'Normal';

  @override
  String get playbackPresetCustom => 'Custom';

  @override
  String get playbackPresetSaveNew => 'Save as New';

  @override
  String get playbackPresetName => 'Preset name';

  @override
  String get playbackPresetRename => 'Rename';

  @override
  String get playbackPresetDelete => 'Delete';

  @override
  String get playbackPresetNameInvalid =>
      'Choose a unique name. Normal is reserved.';

  @override
  String get playbackPitchUnavailable =>
      'Pitch control is unavailable on this audio backend.';

  @override
  String get playbackAdjustmentUnsupported =>
      'This adjustment is outside the audio backend’s supported range.';

  @override
  String get playbackAdjustmentApplyFailure =>
      'Could not apply the adjustment. The previous values have been restored.';

  @override
  String get playbackAdjustmentSaveFailure =>
      'Could not save your changes. Retry to keep them after restart.';

  @override
  String get playbackAdjustmentLoadFailure =>
      'Could not load playback adjustments.';

  @override
  String get playbackAdjustmentRetry => 'Retry';

  @override
  String get playbackAdjustmentResetBoth => 'Reset Speed & Pitch';

  @override
  String get playbackAdjustmentCancel => 'Cancel';

  @override
  String get playbackAdjustmentApply => 'Apply';

  @override
  String get playbackAdjustmentSave => 'Save';

  @override
  String playbackPitchSemitonesValue(String value) {
    return '$value semitones';
  }

  @override
  String get playbackAdjustmentReset => 'Reset';

  @override
  String get playbackAdjustmentInvalidNumber =>
      'Enter a finite decimal number.';

  @override
  String playbackSpeedMultiplierValue(String value) {
    return '$value×';
  }

  @override
  String get playbackPitchLock => 'Pitch Lock';

  @override
  String get playbackPitchLockSubtitle => 'Match pitch to speed.';

  @override
  String get playbackPitchFollowsSpeed => 'Follows playback speed';

  @override
  String get playbackPitchLockUnsupportedRange =>
      'Pitch cannot follow this speed on this audio backend. Choose a speed within the supported linked range.';

  @override
  String get playbackAdjustmentPrecision =>
      'Enter a number with no more than two decimal places.';

  @override
  String get playbackPresetUnsupported => 'Unavailable on this audio backend';

  @override
  String get playbackPresetActions => 'Preset actions';

  @override
  String playbackPresetUpdateNamed(String name) {
    return 'Update “$name”';
  }

  @override
  String playbackPresetRenameNamed(String name) {
    return 'Rename “$name”…';
  }

  @override
  String playbackPresetDeleteNamed(String name) {
    return 'Delete “$name”';
  }

  @override
  String playbackPresetDeleteConfirm(String name) {
    return 'Delete “$name”?';
  }

  @override
  String playbackAdjustmentRange(String minimum, String maximum) {
    return 'Available range: $minimum to $maximum';
  }

  @override
  String playbackAdjustmentMinimum(String value) {
    return 'Minimum: $value';
  }

  @override
  String playbackAdjustmentMaximum(String value) {
    return 'Maximum: $value';
  }

  @override
  String get playbackSpeedMinimumReached => 'Minimum supported speed reached';

  @override
  String get playbackSpeedMaximumReached => 'Maximum supported speed reached';

  @override
  String get playbackPitchMinimumReached => 'Minimum supported pitch reached';

  @override
  String get playbackPitchMaximumReached => 'Maximum supported pitch reached';

  @override
  String playbackAdjustmentIncreaseBy(String step) {
    return 'Increase by $step';
  }

  @override
  String playbackAdjustmentDecreaseBy(String step) {
    return 'Decrease by $step';
  }

  @override
  String playbackQuickAdjustmentsTooltip(String summary) {
    return 'Speed & Pitch: $summary';
  }

  @override
  String playbackQuickEqualizerTooltip(String preset) {
    return 'Equalizer: $preset';
  }

  @override
  String get playbackQuickEqualizerOff => 'Equalizer: Off';

  @override
  String playbackSpeedChangedNotice(String value) {
    return 'Playback speed $value';
  }

  @override
  String get desktopMiniPlayerSpeedPitchAction => 'Speed & Pitch…';

  @override
  String get eqQuickOpen => 'Open Equalizer';

  @override
  String get eqQuickClose => 'Close Equalizer';

  @override
  String get eqQuickEditHint => 'Open Equalizer to edit';

  @override
  String get nowPlayingSoundSection => 'Sound';

  @override
  String get eqTitle => 'Equalizer';

  @override
  String get eqSubtitle => 'Shape your sound and save headphone profiles';

  @override
  String get eqUnavailable =>
      'Equalizer is unavailable with this audio engine.';

  @override
  String get eqEnable => 'Enable equalizer';

  @override
  String get eqCustom => 'Custom';

  @override
  String get eqSimple => 'Simple · 5 bands';

  @override
  String get eqTenBand => '10 bands';

  @override
  String get eqAdvanced => 'Advanced';

  @override
  String get eqImportedFixed => 'Imported fixed bands';

  @override
  String get eqMode => 'Editing mode';

  @override
  String get eqPresets => 'Presets';

  @override
  String get eqBuiltIn => 'Built in';

  @override
  String get eqSaveAs => 'Save as New';

  @override
  String get eqRename => 'Rename';

  @override
  String get eqDuplicate => 'Duplicate';

  @override
  String get eqDelete => 'Delete';

  @override
  String get eqExport => 'Export';

  @override
  String get eqImport => 'Import';

  @override
  String get eqImportFile => 'From file';

  @override
  String get eqImportPaste => 'Paste settings';

  @override
  String get eqAutoEq => 'Find headphones in AutoEQ';

  @override
  String get eqName => 'Preset name';

  @override
  String get eqSave => 'Save';

  @override
  String get eqSaveEnable => 'Save and enable';

  @override
  String get eqCancel => 'Cancel';

  @override
  String get eqUndo => 'Undo';

  @override
  String get eqRedo => 'Redo';

  @override
  String get eqReset => 'Reset to flat';

  @override
  String get eqPreamp => 'Preamp';

  @override
  String get eqAutoHeadroom => 'Automatic headroom';

  @override
  String get eqAutoHeadroomDescription =>
      'Reduce gain when the combined curve would exceed 0 dB. The authored preamp stays unchanged.';

  @override
  String get eqClippingRisk =>
      'Positive gain may clip. Lower preamp or enable automatic headroom.';

  @override
  String get eqResponse => 'Configured frequency response';

  @override
  String get eqApplied => 'Applied';

  @override
  String get eqBypassed => 'Bypassed';

  @override
  String get eqPending => 'Waiting for audio';

  @override
  String get eqApplying => 'Applying…';

  @override
  String get eqLegacyReset =>
      'The experimental equalizer and loudness booster have been replaced. Equalizer starts disabled with a flat curve; please create or import your new profiles.';

  @override
  String get eqDismiss => 'Dismiss';

  @override
  String get eqFrequency => 'Frequency';

  @override
  String get eqGain => 'Gain';

  @override
  String get eqQ => 'Q';

  @override
  String get eqType => 'Filter type';

  @override
  String get eqPeaking => 'Peaking';

  @override
  String get eqLowShelf => 'Low shelf';

  @override
  String get eqHighShelf => 'High shelf';

  @override
  String get eqLowPass => 'Low pass';

  @override
  String get eqHighPass => 'High pass';

  @override
  String get eqNotch => 'Notch';

  @override
  String get eqImportText =>
      'AutoEQ ParametricEQ / FixedBandEQ text, or Navis preset JSON';

  @override
  String get eqFixedImport => 'This is a FixedBandEQ profile';

  @override
  String get eqImportPreview => 'Preview preset';

  @override
  String get eqPreviewDescription =>
      'Review before saving. Importing does not change playback until you choose Save and enable.';

  @override
  String get eqSource => 'Source';

  @override
  String get eqTarget => 'Target';

  @override
  String get eqOriginalSource =>
      'Original source settings are retained with this preset. Your edits do not change its source attribution.';

  @override
  String get eqSearch => 'Search headphones';

  @override
  String get eqRecommendedOnly => 'Recommended results only';

  @override
  String get eqRefreshCatalogue => 'Refresh catalogue';

  @override
  String get eqCatalogueOffline =>
      'Search is available offline. Downloading a new profile requires a connection. Saved presets always work offline.';

  @override
  String get eqAttribution =>
      'AutoEQ by Jaakko Pasanen and contributors · MIT licence';

  @override
  String get eqNoResults =>
      'No matching headphones. Try the full index or import a profile.';

  @override
  String get eqDownloadError =>
      'Could not download this profile. Check your connection and try again.';

  @override
  String get eqAutoEqOnlineOff =>
      'Refreshing and downloading are turned off in Integrations settings. Search still works from the built-in catalogue.';

  @override
  String get eqRefreshError =>
      'Could not refresh. The existing catalogue is still available.';

  @override
  String get eqImportDefaultName => 'Imported profile';

  @override
  String get eqImportErrorTooLarge => 'EQ files must be smaller than 1 MB.';

  @override
  String get eqImportErrorEmpty => 'The EQ file is empty.';

  @override
  String get eqImportErrorUnreadable =>
      'The text in this file could not be read.';

  @override
  String get eqImportErrorNavisPreset =>
      'This Navis preset is damaged or from a newer version.';

  @override
  String get eqImportErrorUnsupportedJson =>
      'This JSON file is not an EQ format Navis can import.';

  @override
  String eqImportErrorLine(int line) {
    return 'Line $line is not an EQ setting Navis understands.';
  }

  @override
  String eqImportErrorValue(int line) {
    return 'Line $line has a value outside the supported range.';
  }

  @override
  String get eqImportErrorValueNoLine =>
      'A value is outside the supported range.';

  @override
  String eqImportErrorTooMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'EQ profiles can have at most $count filters.',
      one: 'EQ profiles can have at most 1 filter.',
    );
    return '$_temp0';
  }

  @override
  String get eqImportErrorNoFilters => 'No EQ filters were found in this file.';

  @override
  String get eqImportErrorPreamp =>
      'The preamp is outside the supported range.';

  @override
  String get eqImportErrorFixedBand =>
      'Fixed-band profiles can only contain peaking filters.';

  @override
  String get eqImportErrorGraphic =>
      'A GraphicEQ curve needs at least two points.';

  @override
  String get eqImportWarningsTitle => 'Notes';

  @override
  String get eqImportWarningPreampSummed =>
      'Several preamp lines were added together.';

  @override
  String get eqImportWarningPreampMissing =>
      'No preamp was set; automatic headroom prevents clipping.';

  @override
  String eqImportWarningIgnored(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count settings that do not affect the curve were ignored.',
      one: '1 setting that does not affect the curve was ignored.',
    );
    return '$_temp0';
  }

  @override
  String eqImportWarningDropped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count filters of unsupported types were left out.',
      one: '1 filter of an unsupported type was left out.',
    );
    return '$_temp0';
  }

  @override
  String get eqImportWarningChannels =>
      'Only the first channel’s settings were imported.';

  @override
  String get eqImportWarningSplitChannels =>
      'Left and right differ; the left channel was imported.';

  @override
  String eqImportWarningGraphic(int count, String rms) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The curve was matched with $count filters (average difference $rms dB).',
      one: 'The curve was matched with 1 filter (average difference $rms dB).',
    );
    return '$_temp0';
  }

  @override
  String get eqImportError => 'Could not read the preset file.';

  @override
  String get eqExportError => 'Could not export the preset.';

  @override
  String get eqNameInvalid => 'Enter a name of 1–120 characters.';

  @override
  String get eqNumberInvalid => 'Enter a finite number in the supported range.';

  @override
  String eqFilterCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString filters',
      one: '1 filter',
    );
    return '$_temp0';
  }

  @override
  String eqCatalogueRevision(String revision) {
    return 'Catalogue revision: $revision';
  }

  @override
  String eqRange(String min, String max) {
    return 'Supported range: $min to $max';
  }

  @override
  String get eqDraftSaved => 'Draft saved on this device';

  @override
  String get eqDraftSaving => 'Saving draft…';

  @override
  String get eqSaveChanges => 'Save changes';

  @override
  String get eqDiscardChanges => 'Discard changes';

  @override
  String get eqDiscardDescription =>
      'Discard all mode drafts for this preset and restore its saved settings?';

  @override
  String get eqDiscardDelete => 'Discard and Delete';

  @override
  String get eqDeleteDraftDescription =>
      'This preset has drafts. Save them as a new preset or discard them before deleting.';

  @override
  String get eqEditAdvanced => 'Edit in Advanced';

  @override
  String eqBand(int number) {
    return 'Band $number';
  }

  @override
  String get eqDraftNotSaved => 'Draft could not be saved';

  @override
  String get artistPlaybackPreparing => 'Loading artist queue';

  @override
  String artistPlaybackProgress(int completed, int total) {
    final intl.NumberFormat completedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String completedString = completedNumberFormat.format(completed);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString albums',
      one: '1 album',
    );
    return 'Loaded $completedString of $_temp0';
  }

  @override
  String get queueTrackUnavailable => 'Unavailable · skipped automatically';

  @override
  String get eqChooseBand => 'Select band';

  @override
  String get eqFilterResponse => 'Filter response';

  @override
  String get eqFitResponse => 'Fit response';

  @override
  String get eqOutputResponse => 'Output response';

  @override
  String get eqWider => 'Wider';

  @override
  String get eqNarrower => 'Narrower';

  @override
  String get eqCalculatingOutput => 'Calculating output response…';

  @override
  String get eqAttenuation => 'Automatic attenuation';

  @override
  String get eqEffectiveOutput => 'Effective output gain';

  @override
  String get eqOutputSettings => 'Output settings';

  @override
  String get eqNumericPreview =>
      'Live preview. Choose Done to keep this value or Cancel to restore it.';

  @override
  String get eqNotApplicable => 'Not applicable';

  @override
  String get eqFixed => 'Fixed';

  @override
  String get eqBandEnabled => 'Band enabled';

  @override
  String get eqNoBands => 'Add a band to start shaping your sound.';

  @override
  String get eqAddBand => 'Add band';

  @override
  String get eqDeleteBand => 'Delete band';

  @override
  String get eqGraphDescription =>
      'Drag a band on the graph, or tap a value to enter it exactly. The graph is a calculated filter response, not a measurement of your headphones.';

  @override
  String get eqDone => 'Done';

  @override
  String get eqAdvancedDraftExists =>
      'This preset already has an Advanced draft. Resume it or create a new preset from the current curve to keep both.';

  @override
  String get eqResumeAdvanced => 'Resume Advanced draft';

  @override
  String get eqCreateCurvePreset => 'Create a new preset from this curve';

  @override
  String get eqPreampDrag =>
      'Drag up or down to adjust preamp, or tap to enter a value';

  @override
  String get eqIncrease => 'Increase value';

  @override
  String get eqDecrease => 'Decrease value';

  @override
  String get eqBandOff => 'Band off';

  @override
  String get eqSimpleShort => 'Simple';

  @override
  String get eqTenBandShort => '10-band';

  @override
  String get eqImportedShort => 'Imported';

  @override
  String get eqEnterExact => 'Tap to enter an exact value';

  @override
  String get eqFixedInMode =>
      'Fixed in this mode. Use Edit in Advanced to change it.';

  @override
  String get eqBandwidth => 'Bandwidth';

  @override
  String get eqBands => 'Bands';

  @override
  String get eqDiscard => 'Discard';

  @override
  String get eqYourPresets => 'Your presets';

  @override
  String get eqBuiltInPresets => 'Built in';

  @override
  String get eqUnsavedWork => 'Unsaved work';

  @override
  String get eqAutoEqHint =>
      'Search measured headphone corrections. Works offline.';

  @override
  String get eqRecommended => 'Recommended';

  @override
  String eqResultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count results',
      one: '1 result',
    );
    return '$_temp0';
  }

  @override
  String get eqAuthoredPreamp => 'Preamp you set';

  @override
  String get eqOutputExplanation =>
      'Output gain combines your preamp with any automatic attenuation. The band curve on the graph does not include it.';

  @override
  String get eqFilterOn => 'On';

  @override
  String get eqFilterOffShort => 'Off';

  @override
  String eqEditingValue(String band, String parameter) {
    return '$band · $parameter';
  }

  @override
  String get eqCloseLibrary => 'Close presets';

  @override
  String get onboardingSaveFailed => 'Could not save setup. Try again.';

  @override
  String get onboardingSkipDialogTitle => 'Skip Customization?';

  @override
  String get onboardingSkipDialogMessage =>
      'Your current settings will be kept. You can reopen this from Settings at any time.';

  @override
  String get onboardingSkipToIntegrationsDialogMessage =>
      'Your current settings will be kept. Before you start, choose which online services Navis may use. You can reopen setup from Settings at any time.';

  @override
  String get onboardingKeepCustomizing => 'Keep customizing';

  @override
  String get onboardingSkipSetup => 'Skip setup';

  @override
  String get onboardingTitle => 'Make Navis Yours';

  @override
  String get onboardingReviewTitle => 'Customize Navis';

  @override
  String onboardingStepProgress(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String onboardingStepProgressSemantics(int current, int total) {
    return 'Customization step $current of $total';
  }

  @override
  String get onboardingBack => 'Back';

  @override
  String get onboardingContinue => 'Continue';

  @override
  String get onboardingFinish => 'Finish';

  @override
  String get onboardingScrollForMore => 'Scroll for more options';

  @override
  String get onboardingAppearanceTitle => 'Choose Your Look';

  @override
  String get onboardingAppearanceDescription =>
      'Choose your theme, style, accent and layout. You can change them later in Appearance settings.';

  @override
  String get onboardingMoreAppearanceOptions => 'More appearance options';

  @override
  String get onboardingAccentColor => 'Accent Color';

  @override
  String get onboardingAppearanceColorPickerHint =>
      'This is the full color picker from Appearance settings. You can revisit it there at any time.';

  @override
  String get onboardingListeningTitle => 'Tune Your Listening';

  @override
  String get onboardingListeningDescription =>
      'Choose stream quality, formats, local playback priority, and track transitions.';

  @override
  String get onboardingWifiQuality => 'Wi-Fi quality';

  @override
  String get onboardingWifiFormat => 'Wi-Fi format';

  @override
  String get onboardingMobileQuality => 'Mobile quality';

  @override
  String get onboardingMobileFormat => 'Mobile format';

  @override
  String get onboardingPreferLocalTitle => 'Play cached copies at any quality';

  @override
  String get onboardingPreferLocalSubtitle =>
      'Use a song already cached on this device even if its quality differs from your streaming setting. Downloads always play from your device.';

  @override
  String get onboardingScrobbleTitle => 'Scrobble to Your Music Server';

  @override
  String get onboardingScrobbleSubtitle =>
      'Report now-playing and completed plays to your Subsonic server.';

  @override
  String get onboardingGaplessTitle => 'Gapless Playback';

  @override
  String get onboardingGaplessSubtitle =>
      'Move between tracks without an added pause.';

  @override
  String get onboardingCrossfadeTitle => 'Crossfade';

  @override
  String get onboardingCrossfadeSubtitle =>
      'Blend the end of a track into the next one.';

  @override
  String onboardingCrossfadeDuration(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: 'Crossfade duration: $seconds seconds',
      one: 'Crossfade duration: 1 second',
    );
    return '$_temp0';
  }

  @override
  String onboardingCrossfadeSecondsShort(int seconds) {
    return '${seconds}s';
  }

  @override
  String get onboardingCrossfadeType => 'Crossfade type';

  @override
  String get onboardingCrossfadeTypeSmart =>
      'Smart — only between different albums';

  @override
  String get onboardingCrossfadeSmartDescription =>
      'Smart avoids blending tracks from the same album.';

  @override
  String get onboardingCrossfadeNormalDescription =>
      'Normal blends every eligible track transition.';

  @override
  String get onboardingQueueTitle => 'Queue and Downloads';

  @override
  String get onboardingQueueDescription =>
      'Control what happens when you play a track and when downloads can run.';

  @override
  String get onboardingAlbumQueueTitle => 'Queue Whole Albums';

  @override
  String get onboardingAlbumQueueSubtitle =>
      'Playing a track from an album queues the album from that track.';

  @override
  String get onboardingLikedQueueTitle => 'Queue All Liked Songs';

  @override
  String get onboardingLikedQueueSubtitle =>
      'On the Liked page, start from the selected song.';

  @override
  String get onboardingLikedQueueDisabledSubtitle =>
      'Enable album queueing to use this option.';

  @override
  String get onboardingWifiOnlyDownloadsTitle => 'Download Only on Wi-Fi';

  @override
  String get onboardingWifiOnlyDownloadsSubtitle =>
      'Avoid downloading music over a metered connection.';

  @override
  String get onboardingIntegrationsTitle => 'Integrations';

  @override
  String get onboardingIntegrationsDescription =>
      'Navis can use these online services as well as your server. Turn off any you don\'t want.';

  @override
  String get onboardingIntegrationsFineTune =>
      'Fine-tune per feature in Settings › Integrations.';

  @override
  String get onboardingIntegrationsStoredOff =>
      'Online services are off on this device. Finish setup with them on, then connect in Settings › Integrations.';

  @override
  String get onboardingValidating => 'Validating…';

  @override
  String get onboardingListenBrainzValidate => 'Validate and connect';

  @override
  String get onboardingLastFmValidateKey => 'Validate key';

  @override
  String get routeNotFoundTitle => 'Page not found';

  @override
  String get routeNotFoundMessage => 'This page is no longer available.';

  @override
  String get routeNotFoundGoHome => 'Go to Home';

  @override
  String get navigationBackTooltip => 'Back';

  @override
  String get navigationForwardTooltip => 'Forward';

  @override
  String get desktopShortcutsNavigateBackTitle => 'Go back';

  @override
  String get desktopShortcutsNavigateBackDescription =>
      'Return to the previous page; the mouse Back button does the same';

  @override
  String get desktopShortcutsNavigateForwardTitle => 'Go forward';

  @override
  String get desktopShortcutsNavigateForwardDescription =>
      'Go to the next page after going back; the mouse Forward button does the same';

  @override
  String get radioPlaybackBlockedOnlineServicesOff =>
      'Online services are off. Turn them on in Integrations to play stations outside your server.';

  @override
  String get integrationsListenBrainzDisconnectFailed =>
      'Couldn\'t remove the ListenBrainz token. Try again.';

  @override
  String get notificationLibraryScanChannelName => 'Library Scan';

  @override
  String get notificationLibraryScanChannelDescription =>
      'Library scan progress and completion updates';

  @override
  String get notificationLibraryScanProgressTitle => 'Scanning library';

  @override
  String notificationLibraryScanProgressBody(
    Object stage,
    int processed,
    int total,
  ) {
    return '$stage • $processed/$total';
  }

  @override
  String get notificationLibraryScanCompleteTitle => 'Library scan complete';

  @override
  String notificationLibraryScanCompleteHydrated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count albums',
      one: '1 album',
    );
    return 'Updated metadata and hydrated $_temp0.';
  }

  @override
  String get notificationLibraryScanCompleteRefreshed =>
      'Metadata refresh finished successfully.';

  @override
  String get notificationLibraryScanCompleteUpToDate =>
      'Library is already up to date.';

  @override
  String get notificationLibraryScanFailedTitle => 'Library scan failed';

  @override
  String get notificationLibraryScanFailedBody =>
      'The scan could not finish. Open Navis to try again.';

  @override
  String get notificationLibraryScanCancelledTitle => 'Library scan cancelled';

  @override
  String get notificationLibraryScanCancelledBody =>
      'The scan stopped before it finished. Open Navis to try again.';

  @override
  String get notificationLibraryScanStagePreparing => 'Preparing scan';

  @override
  String get notificationLibraryScanStageFetchingArtists =>
      'Refreshing artists';

  @override
  String get notificationLibraryScanStageFetchingAlbums => 'Refreshing albums';

  @override
  String get notificationLibraryScanStagePersistingMetadata =>
      'Saving metadata';

  @override
  String get notificationLibraryScanStageFetchingSongs => 'Hydrating songs';

  @override
  String get notificationLibraryScanStageFetchingStarred =>
      'Updating liked items';

  @override
  String get notificationLibraryScanStageFetchingPlaylists =>
      'Updating playlists';

  @override
  String get notificationLibraryScanStageCollectingCandidate =>
      'Building catalog update';

  @override
  String get notificationLibraryScanStageValidatingCandidate =>
      'Validating catalog update';

  @override
  String get notificationLibraryScanStageApplyingCandidate =>
      'Applying catalog update';

  @override
  String get notificationLibraryScanStageCleaningCandidate =>
      'Cleaning up catalog update';

  @override
  String get notificationLibraryScanStageFinalizing => 'Finalizing scan';

  @override
  String get notificationLibraryScanStageCompleted => 'Scan complete';

  @override
  String get notificationLibraryScanStageIdle => 'Waiting to scan';

  @override
  String get notificationDownloadsChannelName => 'Downloads';

  @override
  String get notificationDownloadsChannelDescription =>
      'Download queue and progress updates';

  @override
  String get notificationDownloadFailedTitle => 'Download failed';

  @override
  String notificationDownloadCompleteTitle(Object title) {
    return 'Downloaded: $title';
  }

  @override
  String notificationDownloadProgressMultiple(int count) {
    return 'Downloading $count songs';
  }

  @override
  String notificationDownloadProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get cacheSettingsResetSection => 'Reset';

  @override
  String get cacheSettingsDeleteAllPresets => 'Delete all presets';

  @override
  String get cacheSettingsDeleteAllPresetsDescription =>
      'Remove all saved Looks and Speed & Pitch presets.';

  @override
  String get cacheSettingsDeleteAllPresetsConfirmTitle => 'Delete all presets?';

  @override
  String get cacheSettingsDeleteAllPresetsConfirmBody =>
      'This permanently deletes every saved appearance Look and Speed & Pitch preset, their selections, and any older Fine-Tune color presets. Your current speed, pitch and appearance values stay as they are.';

  @override
  String get cacheSettingsDeleteAllPresetsSuccess =>
      'All presets deleted. Your current values are unchanged.';

  @override
  String get cacheSettingsDeleteAllPresetsFailure =>
      'Could not delete presets. Try again.';

  @override
  String get playbackPresetDeleteFailure =>
      'Could not delete the preset. It may have changed or could not be saved. Try again.';

  @override
  String get configurationListenBrainzOnlineServicesOff =>
      'Online services is switched off. Turn it on before connecting to ListenBrainz.';

  @override
  String get configurationListenBrainzRateLimited =>
      'ListenBrainz is limiting requests right now. Your token was not rejected. Try again later.';

  @override
  String configurationListenBrainzUnavailableHttp(int status) {
    return 'ListenBrainz isn\'t accepting connections right now (HTTP $status). This is on their side; your token wasn\'t rejected. Try again later.';
  }

  @override
  String get downloadsFolderHoldUnset =>
      'Downloads are queued. Choose a custom folder or use app storage to continue.';

  @override
  String get downloadsFolderHoldMissing =>
      'Downloads are queued because the custom folder is missing. Reconnect the storage, choose a folder or use app storage.';

  @override
  String get downloadsFolderHoldInaccessible =>
      'Downloads are queued because Navis cannot write to the download folder. Choose an accessible folder or use app storage.';

  @override
  String get downloadsFolderHoldChoose => 'Choose folder';

  @override
  String get downloadsFolderHoldUseAppStorage => 'Use app storage';

  @override
  String get downloadsFailureNotFound =>
      'This song is no longer available on the server.';

  @override
  String get downloadsFailureServerError =>
      'The server could not send this song. Try again later.';

  @override
  String get downloadsFailureNetwork =>
      'The connection was lost. Check your network and try again.';

  @override
  String get downloadsFailureTimeout =>
      'The server took too long to respond. Try again.';

  @override
  String get downloadsFailureNotAudio =>
      'The server sent a page or error message instead of audio.';

  @override
  String get downloadsFailureTruncated =>
      'The download was cut short. Try again.';

  @override
  String get downloadsFailureNoSpace =>
      'There is not enough free space for this download.';

  @override
  String get downloadsFailureFolderUnavailable =>
      'The download folder is unavailable. Reconnect it or choose another folder.';

  @override
  String get downloadsFailurePermission =>
      'Navis does not have permission to save this download.';

  @override
  String get downloadsFailureUnknown =>
      'The download could not be completed. Try again.';

  @override
  String get downloadsFolderHoldNoSpace =>
      'Downloads are queued because storage is full. Free some space or choose another folder to continue.';

  @override
  String get notificationDownloadHeldTitle =>
      'Downloads waiting for storage or access';
}
