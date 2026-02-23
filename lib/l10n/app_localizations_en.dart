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
  String get settingsSyncTitle => 'Sync';

  @override
  String get settingsSyncSubtitle =>
      'Sync progress, history, and manual controls.';

  @override
  String get settingsPlaybackTitle => 'Playback';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get syncSettingsTitle => 'Sync Settings';

  @override
  String get syncSettingsStatusLabel => 'Current sync status';

  @override
  String get syncSettingsLastSyncedLabel => 'Server last synced';

  @override
  String get syncSettingsNeverSynced => 'Never synced';

  @override
  String get syncSettingsStatusIdle => 'Idle';

  @override
  String get syncSettingsStatusSucceeded => 'Last sync succeeded';

  @override
  String get syncSettingsStatusFailed => 'Last sync failed';

  @override
  String playbackSettingsLoadError(Object message) {
    return 'Could not load playback settings: $message';
  }

  @override
  String get playbackSettingsWifiSectionTitle => 'Wi-Fi streaming';

  @override
  String get playbackSettingsWifiQualityLabel => 'Max bitrate';

  @override
  String get playbackSettingsWifiFormatLabel => 'Preferred format';

  @override
  String get playbackSettingsCellularSectionTitle => 'Cellular streaming';

  @override
  String get playbackSettingsCellularQualityLabel => 'Max bitrate';

  @override
  String get playbackSettingsCellularFormatLabel => 'Preferred format';

  @override
  String get playbackSettingsScrobbleTitle => 'Enable scrobbling';

  @override
  String get playbackSettingsScrobbleSubtitle =>
      'Send now-playing and listened-track updates to the server.';

  @override
  String get playbackSettingsGaplessTitle => 'Enable gapless playback';

  @override
  String get playbackSettingsGaplessSubtitle =>
      'Preload tracks to reduce gaps between songs.';

  @override
  String get playbackSettingsShowRadioPageTitle => 'Show Radio page';

  @override
  String get playbackSettingsShowRadioPageSubtitle =>
      'Display the Radio tab in bottom navigation.';

  @override
  String get playbackSettingsAndroidDspSectionTitle => 'Android audio effects';

  @override
  String get playbackSettingsEqualizerTitle => 'Enable equalizer';

  @override
  String get playbackSettingsEqualizerSubtitle =>
      'Adjust frequency bands for Android playback.';

  @override
  String playbackSettingsEqualizerBandLabel(int index) {
    return 'Band $index';
  }

  @override
  String get playbackSettingsLoudnessTitle => 'Enable loudness enhancer';

  @override
  String get playbackSettingsLoudnessSubtitle =>
      'Apply target gain in dB on Android playback.';

  @override
  String get playbackSettingsSkipSilenceTitle => 'Skip silence when possible';

  @override
  String get playbackSettingsSkipSilenceSubtitle =>
      'Automatically skip silent segments on supported platforms.';

  @override
  String get playbackSettingsSaveAction => 'Save';

  @override
  String get playbackSettingsResetAction => 'Reset defaults';

  @override
  String get playbackSettingsQualityOriginal => 'Original quality';

  @override
  String playbackSettingsQualityKbps(int kbps) {
    return '$kbps kbps';
  }

  @override
  String get playbackSettingsFormatOriginal => 'Server default';

  @override
  String get playbackSettingsSaveSuccess => 'Playback settings saved.';

  @override
  String playbackSettingsSaveFailure(Object message) {
    return 'Could not save playback settings: $message';
  }

  @override
  String get playbackSettingsResetSuccess =>
      'Playback settings reset to defaults.';

  @override
  String playbackSettingsResetFailure(Object message) {
    return 'Could not reset playback settings: $message';
  }

  @override
  String get homeTitle => 'Home';

  @override
  String get homeLoadErrorTitle => 'Could not load section';

  @override
  String get homeRecentlyPlayedTitle => 'Recently played';

  @override
  String get homeRecentlyPlayedEmptyTitle => 'No recent plays yet';

  @override
  String get homeRecentlyPlayedEmptySubtitle =>
      'Start playback to populate this section.';

  @override
  String get homeRecentlyAddedTitle => 'Recently added';

  @override
  String get homeRecentlyAddedEmptyTitle => 'No recently added albums';

  @override
  String get homeRecentlyAddedEmptySubtitle =>
      'Pull to refresh to fetch newly added albums.';

  @override
  String get homeFrequentTitle => 'Most played';

  @override
  String get homeFrequentEmptyTitle => 'No frequent albums yet';

  @override
  String get homeFrequentEmptySubtitle =>
      'Play more tracks to build listening history.';

  @override
  String get homeRandomTitle => 'Random picks';

  @override
  String get homeRandomEmptyTitle => 'No random picks available';

  @override
  String get homeRandomEmptySubtitle =>
      'Pull to refresh to fetch random albums.';

  @override
  String get homeStarredTitle => 'Liked tracks';

  @override
  String get homeStarredEmptyTitle => 'No liked tracks';

  @override
  String get homeStarredEmptySubtitle =>
      'Like tracks on your server to see them here.';

  @override
  String get radioTitle => 'Radio';

  @override
  String get radioEmptyTitle => 'No radio stations found';

  @override
  String get radioEmptySubtitle =>
      'Add internet radio stations on your server to see them here.';

  @override
  String get radioLoadErrorTitle => 'Could not load radio stations';

  @override
  String get radioUnsupportedMessage =>
      'This server does not expose internet radio station endpoints.';

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
  String get serverSettingsForceFullSync => 'Force Full Sync';

  @override
  String get serverSettingsForceFullSyncRunning => 'Sync in progress...';

  @override
  String get serverSettingsForceFullSyncSuccess =>
      'Full library sync completed.';

  @override
  String serverSettingsForceFullSyncFailure(Object message) {
    return 'Full sync failed: $message';
  }

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

  @override
  String get commonRetry => 'Retry';

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryTabArtists => 'Artists';

  @override
  String get libraryTabAlbums => 'Albums';

  @override
  String get libraryTabSongs => 'Songs';

  @override
  String get libraryTabGenres => 'Genres';

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
  String librarySyncLastSynced(Object timestamp) {
    return 'Last synced: $timestamp';
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
  String get librarySyncStageSongs => 'Hydrating songs';

  @override
  String get librarySyncStageGenres => 'Fetching genres';

  @override
  String get librarySyncStagePlaylists => 'Fetching playlists';

  @override
  String get librarySyncStageFinalizing => 'Finalizing';

  @override
  String get librarySyncFailureFallback => 'Library sync failed.';

  @override
  String get librarySyncHydratingUnknown =>
      'Metadata ready. Hydrating songs...';

  @override
  String librarySyncHydratingProgress(int processed, int total, int pending) {
    return 'Metadata ready. Hydrating songs ($processed/$total, $pending remaining)';
  }

  @override
  String librarySyncHydratingProgressWithRate(
    int processed,
    int total,
    int pending,
    Object rate,
  ) {
    return 'Metadata ready. Hydrating songs ($processed/$total, $pending remaining, $rate albums/s)';
  }

  @override
  String get libraryArtistsEmptyTitle => 'No artists found';

  @override
  String get libraryArtistsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryArtistsIndexAll => 'All';

  @override
  String get libraryArtistsErrorTitle => 'Could not load artists';

  @override
  String get libraryAlbumsEmptyTitle => 'No albums found';

  @override
  String get libraryAlbumsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryAlbumsErrorTitle => 'Could not load albums';

  @override
  String get libraryAlbumsSortLabel => 'Sort albums by';

  @override
  String libraryAlbumsPagingProgress(int loaded, int total) {
    return 'Loaded $loaded of $total albums';
  }

  @override
  String get librarySongsEmptyTitle => 'No songs found';

  @override
  String get librarySongsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get librarySongsErrorTitle => 'Could not load songs';

  @override
  String get librarySongsSortLabel => 'Sort songs by';

  @override
  String get libraryGenresEmptyTitle => 'No genres found';

  @override
  String get libraryGenresEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryGenresErrorTitle => 'Could not load genres';

  @override
  String libraryGenresCount(int albums, int songs) {
    return '$albums albums • $songs songs';
  }

  @override
  String get librarySortNewest => 'Newest';

  @override
  String get librarySortOldest => 'Oldest';

  @override
  String get librarySortName => 'Name';

  @override
  String get librarySortArtist => 'Artist';

  @override
  String get librarySortArtistAlbum => 'Artist / Album';

  @override
  String get librarySortTitle => 'Title';

  @override
  String get librarySortDuration => 'Duration';

  @override
  String get libraryArtistMenuOpen => 'Open artist';

  @override
  String get libraryAlbumMenuOpen => 'Open album';

  @override
  String get librarySongMenuPlayNow => 'Play now';

  @override
  String get librarySongMenuAddToQueue => 'Add to queue';

  @override
  String get librarySongMenuPlayNext => 'Play next';

  @override
  String get librarySongMenuOpenAlbum => 'Open album';

  @override
  String get librarySongMenuOpenArtist => 'Open artist';

  @override
  String librarySongPlayNowQueued(Object title) {
    return '\"$title\" queued to play now.';
  }

  @override
  String librarySongAddedToQueue(Object title) {
    return '\"$title\" added to queue.';
  }

  @override
  String librarySongPlayNextQueued(Object title) {
    return '\"$title\" added to play next.';
  }

  @override
  String libraryGenreDetailTitle(Object genre) {
    return '$genre';
  }

  @override
  String get libraryGenreAlbumsTab => 'Albums';

  @override
  String get libraryGenreSongsTab => 'Songs';

  @override
  String get libraryGenreAlbumsEmptyTitle => 'No albums in this genre';

  @override
  String get libraryGenreAlbumsEmptySubtitle => 'Sync to refresh genre albums.';

  @override
  String get libraryGenreSongsEmptyTitle => 'No songs in this genre';

  @override
  String get libraryGenreSongsEmptySubtitle => 'Sync to refresh genre songs.';

  @override
  String get libraryGenreLoadErrorTitle => 'Could not load genre';

  @override
  String artistCardAlbumCount(int count) {
    return '$count albums';
  }

  @override
  String get artistDetailTitle => 'Artist';

  @override
  String get artistDetailNotFoundTitle => 'Artist not found';

  @override
  String get artistDetailNotFoundSubtitle =>
      'This artist is not available in local data.';

  @override
  String artistDetailAlbumCount(int count) {
    return '$count albums';
  }

  @override
  String get artistDetailAlbumsEmptyTitle => 'No albums for this artist';

  @override
  String get artistDetailAlbumsEmptySubtitle =>
      'Sync your library to load artist albums.';

  @override
  String get artistDetailAlbumsSection => 'Albums';

  @override
  String get artistDetailUnknownYear => 'Unknown year';

  @override
  String get artistDetailBioSection => 'Biography';

  @override
  String get artistDetailSimilarSection => 'Similar artists';

  @override
  String get artistDetailAlbumsErrorTitle => 'Could not load artist albums';

  @override
  String get artistDetailLoadErrorTitle => 'Could not load artist details';

  @override
  String get albumDetailTitle => 'Album';

  @override
  String get albumDetailNotFoundTitle => 'Album not found';

  @override
  String get albumDetailNotFoundSubtitle =>
      'This album is not available in local data.';

  @override
  String get albumDetailUnknownArtist => 'Unknown artist';

  @override
  String albumDetailMeta(Object artist, Object year, int trackCount) {
    return '$artist • $year • $trackCount tracks';
  }

  @override
  String get albumDetailTracksEmptyTitle => 'No tracks for this album';

  @override
  String get albumDetailTracksEmptySubtitle =>
      'Sync your library to load album tracks.';

  @override
  String get albumDetailLoadErrorTitle => 'Could not load album details';

  @override
  String get albumDetailPlayAction => 'Play';

  @override
  String get albumDetailShuffleAction => 'Shuffle';

  @override
  String get albumDetailStarAction => 'Like';

  @override
  String get albumDetailDownloadAction => 'Download';

  @override
  String get albumDetailDownloadActionQueued => 'Album queued for download.';

  @override
  String get albumDetailPlayActionQueued => 'Album queued for playback.';

  @override
  String get albumDetailShuffleActionQueued => 'Album shuffled into queue.';

  @override
  String get albumDetailStarSuccess => 'Album liked.';

  @override
  String get albumDetailUnstarSuccess => 'Album unliked.';

  @override
  String get albumDetailStarFailure => 'Could not update like status.';

  @override
  String get cacheBadgeLabel => 'Cached';

  @override
  String get miniPlayerUnknownTrack => 'Unknown track';

  @override
  String get miniPlayerUnknownArtist => 'Unknown artist';

  @override
  String get miniPlayerPlay => 'Play';

  @override
  String get miniPlayerPause => 'Pause';

  @override
  String get playbackBootstrapLoadingTitle => 'Preparing playback';

  @override
  String get playbackBootstrapLoadingSubtitle =>
      'Initializing audio services...';

  @override
  String get playbackBootstrapFailedTitle => 'Playback initialization failed';

  @override
  String get playbackBootstrapFailedSubtitle =>
      'Could not initialize playback. Retry to continue.';

  @override
  String get playbackBootstrapRetryAction => 'Retry playback startup';

  @override
  String get playbackUnavailableInitializing =>
      'Playback is still initializing. Try again in a moment.';

  @override
  String get playbackUnavailableStartupFailed =>
      'Playback startup failed. Retry from the startup screen.';

  @override
  String get playbackUnavailableSource =>
      'Could not resolve an audio source. Check server session and connection.';

  @override
  String get playbackUnavailableGeneric => 'Playback is unavailable right now.';

  @override
  String get playbackActionFailed =>
      'Playback action failed. Please try again.';

  @override
  String get queueTitle => 'Queue';

  @override
  String get queueClearAction => 'Clear queue';

  @override
  String get queueClearConfirmTitle => 'Clear queue?';

  @override
  String get queueClearConfirmMessage =>
      'This will remove all tracks from the queue.';

  @override
  String get queueEmptyTitle => 'Queue is empty';

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
  String get nowPlayingPrevious => 'Previous';

  @override
  String get nowPlayingPlay => 'Play';

  @override
  String get nowPlayingPause => 'Pause';

  @override
  String get nowPlayingNext => 'Next';

  @override
  String get nowPlayingRepeatOff => 'Repeat off';

  @override
  String get nowPlayingRepeatAll => 'Repeat all';

  @override
  String get nowPlayingRepeatOne => 'Repeat one';

  @override
  String get nowPlayingStar => 'Like';

  @override
  String get nowPlayingLyrics => 'Lyrics';

  @override
  String get nowPlayingQueue => 'Queue';

  @override
  String get nowPlayingMore => 'More options';

  @override
  String get nowPlayingGoToAlbum => 'Go to album';

  @override
  String get nowPlayingGoToArtist => 'Go to artist';

  @override
  String get nowPlayingAudioQuality => 'Audio quality';

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get lyricsNoneAvailable => 'No lyrics available';

  @override
  String get queueSaveAsPlaylist => 'Save as playlist';

  @override
  String get queueSaveAsPlaylistName => 'Playlist name';

  @override
  String get queueSaveAsPlaylistSaved => 'Playlist saved';
}
