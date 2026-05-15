/// Android Auto browsable media tree service.
///
/// Builds a hierarchical [MediaItem] tree from the local Drift database so
/// that Android Auto can browse and play the user's music library without
/// any network round-trips during navigation.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:navis/src/api/models/album.dart' as api;
import 'package:navis/src/api/models/artist.dart' as api;
import 'package:navis/src/api/models/song.dart' as api;
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/auto/domain/auto_content_style.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Maximum number of items returned per browse level.
const int _kMaxBrowseItems = 500;

/// How long the root-node cache is considered fresh.
const Duration _kRootCacheTtl = Duration(seconds: 30);

/// Cover-art size used for browse-tree thumbnails (smaller than playback art).
const int _kBrowseArtSize = 256;

/// Service that builds the Android Auto browse tree from the local database.
///
/// This class is intentionally stateless with respect to playback — it only
/// reads library data.  Playback actions (`playFromMediaId`, etc.) remain in
/// `NavisAudioHandler`.
class AutoMediaTreeService {
  AutoMediaTreeService({
    required LibraryDao libraryDao,
    required PlaylistDao playlistDao,
    required HistoryDao historyDao,
    required SubsonicApiClient? Function() readApiClient,
    Future<Set<String>> Function()? readDownloadedSongIds,
  }) : _libraryDao = libraryDao,
       _playlistDao = playlistDao,
       _historyDao = historyDao,
       _readApiClient = readApiClient,
       _readDownloadedSongIds =
           readDownloadedSongIds ?? (() async => const <String>{});

  final LibraryDao _libraryDao;
  final PlaylistDao _playlistDao;
  final HistoryDao _historyDao;
  final SubsonicApiClient? Function() _readApiClient;
  final Future<Set<String>> Function() _readDownloadedSongIds;

  // ── Root cache ────────────────────────────────────────────────────────────

  List<MediaItem>? _cachedRootChildren;
  DateTime? _rootCacheTimestamp;

  // ── getChildren ───────────────────────────────────────────────────────────

  /// Returns the children of [parentMediaId] as a flat list of [MediaItem]s.
  ///
  /// Browsable items have `extras['browsable'] == true`; playable leaf items
  /// do not.
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    try {
      return await _getChildrenImpl(parentMediaId);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'AutoMediaTreeService.getChildren($parentMediaId) failed: '
        '$error\n$stackTrace',
      );
      return _errorItems('Unable to load content');
    }
  }

  Future<List<MediaItem>> _getChildrenImpl(String parentMediaId) async {
    return switch (parentMediaId) {
      AutoMediaRoot.root => _getRootChildren(),
      AutoMediaRoot.playlists => _getPlaylists(),
      AutoMediaRoot.artists => _getArtists(),
      AutoMediaRoot.albums => _getAlbums(),
      AutoMediaRoot.more => _getMoreChildren(),
      AutoMediaRoot.liked => _getLikedCategories(),
      // AudioService.recentRootId == 'recent' — the system-level RECENT_ROOT_ID
      // that AAOS uses for the home screen widget when no session is active.
      // AutoMediaRoot.recent == 'root/recent' is our own browseable node.
      AutoMediaRoot.recent || AudioService.recentRootId => _getRecentlyPlayed(
        parentMediaId,
      ),
      AutoMediaRoot.likedSongs => _getLikedSongs(),
      AutoMediaRoot.likedAlbums => _getLikedAlbums(),
      _ => _getEntityChildren(parentMediaId),
    };
  }

  Future<List<MediaItem>> _getRootChildren() async {
    final now = DateTime.now();
    if (_cachedRootChildren != null &&
        _rootCacheTimestamp != null &&
        now.difference(_rootCacheTimestamp!) < _kRootCacheTtl) {
      return _cachedRootChildren!;
    }

    final children = <MediaItem>[
      _browsableItem(
        id: AutoMediaRoot.albums,
        title: 'Albums',
        extras: AutoContentStyle.gridBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.recent,
        title: 'Recent',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.artists,
        title: 'Artists',
        extras: AutoContentStyle.gridBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.playlists,
        title: 'Playlists',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.more,
        title: 'More',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
    ];

    _cachedRootChildren = children;
    _rootCacheTimestamp = now;
    return children;
  }

  Future<List<MediaItem>> _getPlaylists() async {
    final playlists = await _playlistDao.watchPlaylists().first;
    final items = playlists
        .take(_kMaxBrowseItems)
        .map(_playlistToMediaItem)
        .toList(growable: false);
    return items.isEmpty
        ? _emptyItems(AutoMediaRoot.playlists, 'No playlists')
        : items;
  }

  Future<List<MediaItem>> _getArtists() async {
    final artists = await _libraryDao.watchArtists().first;
    final items = artists
        .take(_kMaxBrowseItems)
        .map(_artistToMediaItem)
        .toList(growable: false);
    return items.isEmpty
        ? _emptyItems(AutoMediaRoot.artists, 'No artists')
        : items;
  }

  Future<List<MediaItem>> _getAlbums() async {
    final albums = await _libraryDao.watchAllAlbums().first;
    final items = albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
    return items.isEmpty
        ? _emptyItems(AutoMediaRoot.albums, 'No albums')
        : items;
  }

  Future<List<MediaItem>> _getMoreChildren() async {
    return [
      _browsableItem(
        id: AutoMediaRoot.liked,
        title: 'Liked',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _playableItem(
        id: AutoMediaRoot.instantMix,
        title: 'Instant Mix',
      ),
      _playableItem(
        id: AutoMediaRoot.instantRadio,
        title: 'Instant Radio',
      ),
    ];
  }

  Future<List<MediaItem>> _getLikedCategories() async {
    return [
      _browsableItem(
        id: AutoMediaRoot.likedSongs,
        title: 'Songs',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.likedAlbums,
        title: 'Albums',
        extras: AutoContentStyle.gridBrowsableListPlayable,
      ),
    ];
  }

  Future<List<MediaItem>> _getLikedSongs() async {
    final songs = await _libraryDao.watchAllStarredSongs().first;
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    final items = songs
        .take(_kMaxBrowseItems)
        .map(
          (song) =>
              _songToMediaItem(song, downloadedSongIds: downloadedSongIds),
        )
        .toList(
          growable: false,
        );
    return items.isEmpty
        ? _emptyItems(AutoMediaRoot.likedSongs, 'No liked songs')
        : items;
  }

  Future<List<MediaItem>> _getLikedAlbums() async {
    final albums = await _libraryDao.watchLikedAlbums().first;
    final items = albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
    return items.isEmpty
        ? _emptyItems(AutoMediaRoot.likedAlbums, 'No liked albums')
        : items;
  }

  Future<List<MediaItem>> _getRecentlyPlayed(String parentId) async {
    final songs = await _historyDao.watchRecentlyPlayedSongs(limit: 50).first;
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    final items = songs
        .map(
          (song) =>
              _songToMediaItem(song, downloadedSongIds: downloadedSongIds),
        )
        .toList(growable: false);
    return items.isEmpty ? _emptyItems(parentId, 'No recent plays') : items;
  }

  Future<List<MediaItem>> _getEntityChildren(String parentMediaId) async {
    final parsed = AutoMediaId.parse(parentMediaId);
    if (parsed == null || parsed.entityId == null) {
      return _emptyItems(parentMediaId, 'No content');
    }

    return switch (parsed.type) {
      AutoMediaIdType.artist => _getArtistAlbums(parsed.entityId!),
      AutoMediaIdType.album => _getAlbumSongs(parsed.entityId!),
      AutoMediaIdType.playlist => _getPlaylistSongs(parsed.entityId!),
      _ => _emptyItems(parentMediaId, 'No content'),
    };
  }

  Future<List<MediaItem>> _getArtistAlbums(String artistId) async {
    final albums = await _libraryDao.watchAlbumsByArtist(artistId).first;
    final items = albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
    return items.isEmpty ? _emptyItems('artist/$artistId', 'No albums') : items;
  }

  Future<List<MediaItem>> _getAlbumSongs(String albumId) async {
    final songs = await _libraryDao.watchSongsByAlbum(albumId).first;
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    final items = songs
        .map(
          (song) =>
              _songToMediaItem(song, downloadedSongIds: downloadedSongIds),
        )
        .toList(growable: false);
    return items.isEmpty ? _emptyItems('album/$albumId', 'No songs') : items;
  }

  Future<List<MediaItem>> _getPlaylistSongs(String playlistId) async {
    final songs = await _playlistDao.watchPlaylistSongs(playlistId).first;
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    final items = songs
        .map(
          (song) =>
              _songToMediaItem(song, downloadedSongIds: downloadedSongIds),
        )
        .toList(growable: false);
    return items.isEmpty
        ? _emptyItems('playlist/$playlistId', 'No songs')
        : items;
  }

  // ── getMediaItem ──────────────────────────────────────────────────────────

  /// Resolves a single [MediaItem] by its media ID.
  Future<MediaItem?> getMediaItem(String mediaId) async {
    try {
      return await _getMediaItemImpl(mediaId);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'AutoMediaTreeService.getMediaItem($mediaId) failed: '
        '$error\n$stackTrace',
      );
      return null;
    }
  }

  Future<MediaItem?> _getMediaItemImpl(String mediaId) async {
    final parsed = AutoMediaId.parse(mediaId);
    if (parsed == null) return null;

    return switch (parsed.type) {
      AutoMediaIdType.song => _getSongMediaItem(parsed.entityId!),
      AutoMediaIdType.album => _getAlbumMediaItem(parsed.entityId!),
      AutoMediaIdType.artist => _getArtistMediaItem(parsed.entityId!),
      AutoMediaIdType.playlist => _getPlaylistMediaItem(parsed.entityId!),
      _ => null,
    };
  }

  Future<MediaItem?> _getSongMediaItem(String songId) async {
    final songs = await _libraryDao.getSongsByIds([songId]);
    if (songs.isEmpty) return null;
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    return _songToMediaItem(
      songs.first,
      downloadedSongIds: downloadedSongIds,
    );
  }

  Future<MediaItem?> _getAlbumMediaItem(String albumId) async {
    // Use watchAllAlbums and filter — lightweight for a single lookup since
    // the list is already cached by Drift's query cache in most scenarios.
    final albums = await _libraryDao.watchAllAlbums().first;
    final match = albums.where((a) => a.id == albumId);
    if (match.isEmpty) return null;
    return _albumToMediaItem(match.first);
  }

  Future<MediaItem?> _getArtistMediaItem(String artistId) async {
    final artists = await _libraryDao.watchArtists().first;
    final match = artists.where((a) => a.id == artistId);
    if (match.isEmpty) return null;
    final artist = match.first;
    return _artistToMediaItem(artist);
  }

  Future<MediaItem?> _getPlaylistMediaItem(String playlistId) async {
    final playlist = await _playlistDao.watchPlaylistById(playlistId).first;
    if (playlist == null) return null;
    return _playlistToMediaItem(playlist);
  }

  // ── search ────────────────────────────────────────────────────────────────

  /// Searches for media matching [query].
  ///
  /// Uses the Subsonic API when available (richer results, server-side
  /// matching) and falls back to a local LIKE search otherwise.
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) return const [];

    try {
      return await _searchImpl(query, extras);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'AutoMediaTreeService.search($query) failed: '
        '$error\n$stackTrace',
      );
      return const [];
    }
  }

  Future<List<MediaItem>> _searchImpl(
    String query,
    Map<String, dynamic>? extras,
  ) async {
    final focus = _SearchFocus.fromExtras(extras);
    final api = _readApiClient();
    if (api != null) {
      return _searchViaApi(api, query, focus);
    }
    return _searchLocalDb(query, focus);
  }

  Future<List<MediaItem>> _searchViaApi(
    SubsonicApiClient api,
    String query,
    _SearchFocus focus,
  ) async {
    try {
      final result = await api.search3(
        query: query,
        artistCount: focus.includeArtists ? 5 : 0,
        albumCount: focus.includeAlbums ? 10 : 0,
        songCount: focus.includeSongs ? 20 : 0,
      );
      return _mapSearchResults(result.artists, result.albums, result.songs);
    } on Object {
      // Fall back to local search on API failure.
      return _searchLocalDb(query, focus);
    }
  }

  Future<List<MediaItem>> _searchLocalDb(
    String query,
    _SearchFocus focus,
  ) async {
    final artists = focus.includeArtists
        ? await _libraryDao.searchArtistsLocal(query, limit: 5)
        : const <ArtistsTableData>[];
    final albums = focus.includeAlbums
        ? await _libraryDao.searchAlbumsLocal(query, limit: 10)
        : const <AlbumsTableData>[];
    final playlists = focus.includePlaylists
        ? (await _playlistDao.watchPlaylists().first)
              .where((playlist) => _containsIgnoreCase(playlist.name, query))
              .take(5)
              .toList(growable: false)
        : const <PlaylistsTableData>[];
    final songs = focus.includeSongs
        ? await _libraryDao.searchSongsLocal(query, limit: 20)
        : const <SongsTableData>[];
    final downloadedSongIds = await _readDownloadedSongIdsSafe();
    return _mapLocalSearchResults(
      artists,
      albums,
      playlists,
      songs,
      downloadedSongIds,
    );
  }

  List<MediaItem> _mapSearchResults(
    List<api.Artist> artists,
    List<api.Album> albums,
    List<api.Song> songs,
  ) {
    final items = <MediaItem>[];

    for (final a in artists) {
      items.add(
        _browsableItem(
          id: AutoMediaId.artist(a.id),
          title: a.name,
          artUri: _coverArtUri(a.coverArt),
          extras: _statusExtras(
            favorite: a.starred != null,
            groupTitle: 'Artists',
          ),
        ),
      );
    }

    for (final a in albums) {
      items.add(
        _browsableItem(
          id: AutoMediaId.album(a.id),
          title: a.name,
          artist: a.artist,
          artUri: _coverArtUri(a.coverArt),
          extras: _statusExtras(
            favorite: a.starred != null,
            groupTitle: 'Albums',
          ),
        ),
      );
    }

    for (final s in songs) {
      items.add(
        MediaItem(
          id: AutoMediaId.song(s.id),
          title: s.title,
          artist: s.artist,
          album: s.album,
          duration: s.duration != null
              ? Duration(seconds: math.max(0, s.duration!))
              : null,
          artUri: _coverArtUri(s.coverArt),
          playable: true,
          extras: _statusExtras(
            favorite: s.starred != null,
            groupTitle: 'Songs',
          ),
        ),
      );
    }

    return items;
  }

  List<MediaItem> _mapLocalSearchResults(
    List<ArtistsTableData> artists,
    List<AlbumsTableData> albums,
    List<PlaylistsTableData> playlists,
    List<SongsTableData> songs,
    Set<String> downloadedSongIds,
  ) {
    final items = <MediaItem>[
      for (final artist in artists)
        _artistToMediaItem(artist, groupTitle: 'Artists'),
      for (final album in albums)
        _albumToMediaItem(album, groupTitle: 'Albums'),
      for (final playlist in playlists)
        _playlistToMediaItem(playlist, groupTitle: 'Playlists'),
      for (final song in songs)
        _songToMediaItem(
          song,
          downloadedSongIds: downloadedSongIds,
          groupTitle: 'Songs',
        ),
    ];

    return items.isEmpty ? _emptyItems('search', 'No results') : items;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  MediaItem _songToMediaItem(
    SongsTableData song, {
    Set<String> downloadedSongIds = const <String>{},
    String? groupTitle,
  }) {
    return MediaItem(
      id: AutoMediaId.song(song.id),
      title: song.title,
      artist: song.artistName,
      album: song.albumName,
      duration: song.duration != null
          ? Duration(seconds: math.max(0, song.duration!))
          : null,
      artUri: _coverArtUri(song.coverArt),
      playable: true,
      extras: _statusExtras(
        favorite: song.starred != null,
        downloaded: downloadedSongIds.contains(song.id),
        groupTitle: groupTitle,
      ),
    );
  }

  MediaItem _albumToMediaItem(AlbumsTableData album, {String? groupTitle}) {
    return _browsableItem(
      id: AutoMediaId.album(album.id),
      title: album.name,
      artist: album.artistName,
      artUri: _coverArtUri(album.coverArt),
      extras: _statusExtras(
        favorite: album.starred != null,
        groupTitle: groupTitle,
      ),
    );
  }

  MediaItem _artistToMediaItem(ArtistsTableData artist, {String? groupTitle}) {
    return _browsableItem(
      id: AutoMediaId.artist(artist.id),
      title: artist.name,
      artUri: _coverArtUri(artist.coverArt),
      extras: <String, dynamic>{
        ...AutoContentStyle.gridBrowsableListPlayable,
        ..._statusExtras(
          favorite: artist.starred != null,
          groupTitle: groupTitle,
        ),
      },
    );
  }

  MediaItem _playlistToMediaItem(
    PlaylistsTableData playlist, {
    String? groupTitle,
  }) {
    return _browsableItem(
      id: AutoMediaId.playlist(playlist.id),
      title: playlist.name,
      artUri: _coverArtUri(playlist.coverArt),
      extras: <String, dynamic>{
        ...AutoContentStyle.listBrowsableListPlayable,
        ..._statusExtras(groupTitle: groupTitle),
      },
    );
  }

  MediaItem _browsableItem({
    required String id,
    required String title,
    String? artist,
    Uri? artUri,
    Map<String, dynamic>? extras,
  }) {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      artUri: artUri,
      playable: false,
      extras: <String, dynamic>{
        ...?extras,
        AndroidAutoConstants.isBrowsableKey: true,
      },
    );
  }

  MediaItem _playableItem({
    required String id,
    required String title,
    Uri? artUri,
  }) {
    return MediaItem(
      id: id,
      title: title,
      artUri: artUri,
      playable: true,
    );
  }

  Uri? _coverArtUri(String? coverArt) {
    if (coverArt == null || coverArt.trim().isEmpty) return null;
    final api = _readApiClient();
    if (api == null) return null;
    return api.getCoverArtUrl(id: coverArt, size: _kBrowseArtSize);
  }

  Future<Set<String>> _readDownloadedSongIdsSafe() async {
    try {
      return await _readDownloadedSongIds();
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'AutoMediaTreeService failed to read downloaded song IDs: '
        '$error\n$stackTrace',
      );
      return const <String>{};
    }
  }

  Map<String, dynamic> _statusExtras({
    bool favorite = false,
    bool? downloaded,
    String? groupTitle,
  }) {
    final extras = <String, dynamic>{};
    if (groupTitle != null) {
      extras[AndroidAutoConstants.contentStyleGroupTitleKey] = groupTitle;
    }
    if (favorite) {
      extras[AndroidAutoConstants.isFavoriteKey] = true;
    }
    if (downloaded != null) {
      extras[AndroidAutoConstants.downloadStatusKey] = downloaded
          ? AndroidAutoConstants.downloadStatusDownloaded
          : AndroidAutoConstants.downloadStatusNotDownloaded;
    }
    return extras;
  }

  List<MediaItem> _emptyItems(String parentId, String message) {
    return [
      MediaItem(
        id: 'empty/$parentId',
        title: message,
        playable: false,
        extras: const <String, dynamic>{
          AndroidAutoConstants.isBrowsableKey: false,
        },
      ),
    ];
  }

  List<MediaItem> _errorItems(String message) {
    return [
      MediaItem(
        id: 'error/content',
        title: message,
        playable: false,
        extras: const <String, dynamic>{
          AndroidAutoConstants.isBrowsableKey: false,
        },
      ),
    ];
  }

  bool _containsIgnoreCase(String value, String query) {
    return value.toLowerCase().contains(query.toLowerCase());
  }
}

class _SearchFocus {
  const _SearchFocus({
    this.includeArtists = true,
    this.includeAlbums = true,
    this.includePlaylists = true,
    this.includeSongs = true,
  });

  factory _SearchFocus.fromExtras(Map<String, dynamic>? extras) {
    final focus = extras?[AndroidAutoConstants.mediaFocusKey];
    return switch (focus) {
      AndroidAutoConstants.mediaFocusArtist => const _SearchFocus(
        includeAlbums: false,
        includePlaylists: false,
        includeSongs: false,
      ),
      AndroidAutoConstants.mediaFocusAlbum => const _SearchFocus(
        includeArtists: false,
        includePlaylists: false,
        includeSongs: false,
      ),
      AndroidAutoConstants.mediaFocusPlaylist => const _SearchFocus(
        includeArtists: false,
        includeAlbums: false,
        includeSongs: false,
      ),
      AndroidAutoConstants.mediaFocusSong => const _SearchFocus(
        includeArtists: false,
        includeAlbums: false,
        includePlaylists: false,
      ),
      _ => all,
    };
  }

  final bool includeArtists;
  final bool includeAlbums;
  final bool includePlaylists;
  final bool includeSongs;

  static const all = _SearchFocus();
}
