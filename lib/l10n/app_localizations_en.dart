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
  String get settingsDownloadsSubtitle => 'Manage offline downloads and queue.';

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
  String get playbackSettingsCrossfadeSectionTitle => 'Cross-fade';

  @override
  String get playbackSettingsCrossfadeEnableTitle => 'Enable cross-fade';

  @override
  String get playbackSettingsCrossfadeEnableSubtitle =>
      'Smoothly blend the end of one track into the start of the next.';

  @override
  String playbackSettingsCrossfadeDurationLabel(int seconds) {
    return 'Duration: ${seconds}s';
  }

  @override
  String get playbackSettingsCrossfadeTypeLabel => 'Cross-fade mode';

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
  String get radioStopStation => 'Stop radio';

  @override
  String get radioPlaybackError => 'Could not play this radio station.';

  @override
  String get radioNowPlaying => 'Now playing on radio';

  @override
  String get radioLive => 'LIVE';

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

  @override
  String get searchHint => 'Search artists, albums, songs...';

  @override
  String get searchRecentTitle => 'Recent searches';

  @override
  String get searchClearRecent => 'Clear';

  @override
  String get searchNoResults => 'No results found';

  @override
  String get searchNoResultsSubtitle => 'Try a different search term.';

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
    return '$count albums';
  }

  @override
  String get searchPlayNext => 'Play next';

  @override
  String get searchAddToQueue => 'Add to queue';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get playlistsEmpty => 'No playlists yet';

  @override
  String get playlistsEmptySubtitle => 'Create a playlist to get started.';

  @override
  String get playlistsLoadError => 'Failed to load playlists';

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
  String get playlistsCreateAction => 'New playlist';

  @override
  String get playlistsCreateTitle => 'Create playlist';

  @override
  String get playlistsCreateNameLabel => 'Playlist name';

  @override
  String get playlistsCreateSuccess => 'Playlist created';

  @override
  String get playlistsCreateFailed => 'Failed to create playlist';

  @override
  String get playlistsDeleteConfirmTitle => 'Delete playlist?';

  @override
  String playlistsDeleteConfirmMessage(String name) {
    return 'This will permanently delete \"$name\".';
  }

  @override
  String get playlistsDeleteSuccess => 'Playlist deleted';

  @override
  String get playlistsDeleteFailed => 'Failed to delete playlist';

  @override
  String get playlistsRenameTitle => 'Rename playlist';

  @override
  String get playlistsRenameLabel => 'New name';

  @override
  String get playlistsRenameSuccess => 'Playlist renamed';

  @override
  String get playlistsRenameFailed => 'Failed to rename playlist';

  @override
  String get playlistDetailTitle => 'Playlist';

  @override
  String get playlistDetailPlayAction => 'Play';

  @override
  String get playlistDetailShuffleAction => 'Shuffle';

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
  String get playlistDetailEmptyTitle => 'No tracks';

  @override
  String get playlistDetailEmptySubtitle => 'Add songs from the library.';

  @override
  String get playlistDetailRemoveTrack => 'Remove from playlist';

  @override
  String get playlistDetailTrackRemoved => 'Track removed';

  @override
  String get playlistDetailTrackRemoveFailed => 'Failed to remove track';

  @override
  String get addToPlaylistTitle => 'Add to playlist';

  @override
  String addToPlaylistSuccess(String name) {
    return 'Added to \"$name\"';
  }

  @override
  String get addToPlaylistFailed => 'Failed to add to playlist';

  @override
  String get addToPlaylistNewPlaylist => 'New playlist';

  @override
  String get librarySongMenuAddToPlaylist => 'Add to playlist';

  @override
  String get cacheSettingsTitle => 'Cache & Storage';

  @override
  String get cacheSettingsRollingSection => 'Streaming cache';

  @override
  String get cacheSettingsRollingDescription =>
      'Recently streamed tracks are cached automatically. Oldest tracks are evicted when the budget is exceeded.';

  @override
  String get cacheSettingsRollingBudgetLabel => 'Cache budget';

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
  String get cacheSettingsClearRolling => 'Clear streaming cache';

  @override
  String get cacheSettingsClearRollingConfirm =>
      'Clear all cached streaming audio? This cannot be undone.';

  @override
  String get cacheSettingsPermanentSection => 'Downloaded tracks';

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
  String get cacheSettingsUnlimited => 'Unlimited';

  @override
  String get downloadQualityTitle => 'Download quality';

  @override
  String get downloadQualityOriginal => 'Original quality';

  @override
  String get downloadQualityOriginalSub => 'Lossless / as stored on server';

  @override
  String get downloadQuality320 => '320 kbps MP3';

  @override
  String get downloadQuality192 => '192 kbps MP3';

  @override
  String get downloadQuality128 => '128 kbps MP3';

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
  String get downloadsQueueEmpty => 'No pending downloads';

  @override
  String get downloadsQueueEmptySubtitle =>
      'Download tracks from albums or playlists for offline listening.';

  @override
  String get downloadsDownloadedEmpty => 'No downloaded tracks';

  @override
  String get downloadsDownloadedEmptySubtitle =>
      'Downloaded tracks will appear here.';

  @override
  String get downloadsRemoveAction => 'Remove download';

  @override
  String get downloadsRedownloadOriginal => 'Re-download in original quality';

  @override
  String get downloadsRedownloadOriginalSub =>
      'Replace with an untranscoded copy from server';

  @override
  String get downloadsRedownloadQueued =>
      'Queued for re-download in original quality';

  @override
  String get downloadsCancelAction => 'Cancel download';

  @override
  String get downloadsClearCompleted => 'Clear completed';

  @override
  String get downloadsRetryFailed => 'Retry failed';

  @override
  String get downloadsStatusFailed => 'Failed';

  @override
  String get downloadsRetryAllFailed => 'Retry all failed';

  @override
  String get downloadsErrorLoadingQueue => 'Could not load download queue.';

  @override
  String get libraryDownloadedOnlyFilter => 'Downloaded';

  @override
  String get libraryDownloadedOnlyEmpty => 'No downloaded content';

  @override
  String get libraryDownloadedOnlyEmptySubtitle =>
      'Download albums or tracks to see them here.';

  @override
  String get cacheSettingsWifiOnlyDownloads => 'Download on Wi-Fi only';

  @override
  String get cacheSettingsWifiOnlyDownloadsSub =>
      'Pause downloads when not connected to Wi-Fi.';

  @override
  String get cacheBadgeDownloaded => 'Downloaded';

  @override
  String get cacheBadgeCached => 'Cached';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceThemeModeLabel => 'Theme mode';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceThemeOled => 'OLED';

  @override
  String get appearanceThemeSystem => 'Auto';

  @override
  String get appearanceColorSchemeLabel => 'Color scheme';

  @override
  String get appearanceColorSchemeSub =>
      'Choose a seed color for the app\'s color palette.';

  @override
  String get appearanceColorDefault => 'Default';

  @override
  String get appearanceColorCustom => 'Custom';

  @override
  String get appearanceColorPickerTitle => 'Pick a custom color';

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
  String get appearanceArtTintedLabel => 'Art-tinted Now Playing';

  @override
  String get appearanceArtTintedSub =>
      'Tint the Now Playing background with colours from the album art.';

  @override
  String get cacheSettingsCoverArtSection => 'Cover art cache';

  @override
  String get cacheSettingsCoverArtDescription =>
      'Cached album artwork images. Larger limits reduce network requests but use more storage.';

  @override
  String get cacheSettingsCoverArtMaxLabel => 'Maximum images';

  @override
  String cacheSettingsCoverArtMaxValue(int count) {
    return '$count images';
  }

  @override
  String get cacheSettingsCoverArtMaxSaved => 'Cover art cache limit updated.';

  @override
  String get cacheSettingsCoverArtRestart =>
      'Changes take effect after restarting the app.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutLicenses => 'Open-source licenses';

  @override
  String get aboutLicensesSub => 'View third-party software licenses.';

  @override
  String get aboutSourceCode => 'Source code';

  @override
  String get aboutSourceCodeSub => 'View on Forgejo';
}
