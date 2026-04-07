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
/// [NavisAudioHandler].
class AutoMediaTreeService {
  AutoMediaTreeService({
    required LibraryDao libraryDao,
    required PlaylistDao playlistDao,
    required HistoryDao historyDao,
    required SubsonicApiClient? Function() readApiClient,
  }) : _libraryDao = libraryDao,
       _playlistDao = playlistDao,
       _historyDao = historyDao,
       _readApiClient = readApiClient;

  final LibraryDao _libraryDao;
  final PlaylistDao _playlistDao;
  final HistoryDao _historyDao;
  final SubsonicApiClient? Function() _readApiClient;

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
    } catch (error, stackTrace) {
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
      AutoMediaRoot.liked => _getLikedCategories(),
      AutoMediaRoot.recent => _getRecentlyPlayed(),
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
        id: AutoMediaRoot.playlists,
        title: 'Playlists',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.artists,
        title: 'Artists',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.albums,
        title: 'Albums',
        extras: AutoContentStyle.gridBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.liked,
        title: 'Liked Songs',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _browsableItem(
        id: AutoMediaRoot.recent,
        title: 'Recently Played',
        extras: AutoContentStyle.listBrowsableListPlayable,
      ),
      _playableItem(
        id: AutoMediaRoot.randomMix,
        title: 'Random Mix',
      ),
    ];

    _cachedRootChildren = children;
    _rootCacheTimestamp = now;
    return children;
  }

  Future<List<MediaItem>> _getPlaylists() async {
    final playlists = await _playlistDao.watchPlaylists().first;
    return playlists
        .take(_kMaxBrowseItems)
        .map((p) {
          return _browsableItem(
            id: AutoMediaId.playlist(p.id),
            title: p.name,
            artUri: _coverArtUri(p.coverArt),
            extras: AutoContentStyle.listBrowsableListPlayable,
          );
        })
        .toList(growable: false);
  }

  Future<List<MediaItem>> _getArtists() async {
    final artists = await _libraryDao.watchArtists().first;
    return artists
        .take(_kMaxBrowseItems)
        .map((a) {
          return _browsableItem(
            id: AutoMediaId.artist(a.id),
            title: a.name,
            artUri: _coverArtUri(a.coverArt),
            extras: AutoContentStyle.gridBrowsableListPlayable,
          );
        })
        .toList(growable: false);
  }

  Future<List<MediaItem>> _getAlbums() async {
    final albums = await _libraryDao.watchAllAlbums().first;
    return albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
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
    return songs
        .take(_kMaxBrowseItems)
        .map(_songToMediaItem)
        .toList(
          growable: false,
        );
  }

  Future<List<MediaItem>> _getLikedAlbums() async {
    final albums = await _libraryDao.watchLikedAlbums().first;
    return albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
  }

  Future<List<MediaItem>> _getRecentlyPlayed() async {
    final songs = await _historyDao.watchRecentlyPlayedSongs(limit: 50).first;
    return songs.map(_songToMediaItem).toList(growable: false);
  }

  Future<List<MediaItem>> _getEntityChildren(String parentMediaId) async {
    final parsed = AutoMediaId.parse(parentMediaId);
    if (parsed == null || parsed.entityId == null) return const [];

    return switch (parsed.type) {
      AutoMediaIdType.artist => _getArtistAlbums(parsed.entityId!),
      AutoMediaIdType.album => _getAlbumSongs(parsed.entityId!),
      AutoMediaIdType.playlist => _getPlaylistSongs(parsed.entityId!),
      _ => const <MediaItem>[],
    };
  }

  Future<List<MediaItem>> _getArtistAlbums(String artistId) async {
    final albums = await _libraryDao.watchAlbumsByArtist(artistId).first;
    return albums
        .take(_kMaxBrowseItems)
        .map(_albumToMediaItem)
        .toList(
          growable: false,
        );
  }

  Future<List<MediaItem>> _getAlbumSongs(String albumId) async {
    final songs = await _libraryDao.watchSongsByAlbum(albumId).first;
    return songs.map(_songToMediaItem).toList(growable: false);
  }

  Future<List<MediaItem>> _getPlaylistSongs(String playlistId) async {
    final songs = await _playlistDao.watchPlaylistSongs(playlistId).first;
    return songs.map(_songToMediaItem).toList(growable: false);
  }

  // ── getMediaItem ──────────────────────────────────────────────────────────

  /// Resolves a single [MediaItem] by its media ID.
  Future<MediaItem?> getMediaItem(String mediaId) async {
    try {
      return await _getMediaItemImpl(mediaId);
    } catch (error, stackTrace) {
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
    return _songToMediaItem(songs.first);
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
    return _browsableItem(
      id: AutoMediaId.artist(artist.id),
      title: artist.name,
      artUri: _coverArtUri(artist.coverArt),
    );
  }

  Future<MediaItem?> _getPlaylistMediaItem(String playlistId) async {
    final playlist = await _playlistDao.watchPlaylistById(playlistId).first;
    if (playlist == null) return null;
    return _browsableItem(
      id: AutoMediaId.playlist(playlist.id),
      title: playlist.name,
      artUri: _coverArtUri(playlist.coverArt),
    );
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
    } catch (error, stackTrace) {
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
    final api = _readApiClient();
    if (api != null) {
      return _searchViaApi(api, query, extras);
    }
    return _searchLocalDb(query);
  }

  Future<List<MediaItem>> _searchViaApi(
    SubsonicApiClient api,
    String query,
    Map<String, dynamic>? extras,
  ) async {
    try {
      final result = await api.search3(
        query: query,
        artistCount: 5,
        albumCount: 10,
        songCount: 20,
      );
      return _mapSearchResults(result.artists, result.albums, result.songs);
    } catch (_) {
      // Fall back to local search on API failure.
      return _searchLocalDb(query);
    }
  }

  Future<List<MediaItem>> _searchLocalDb(String query) async {
    final songs = await _libraryDao.searchSongsLocal(query, limit: 30);
    return songs.map(_songToMediaItem).toList(growable: false);
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
        ),
      );
    }

    return items;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  MediaItem _songToMediaItem(SongsTableData song) {
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
    );
  }

  MediaItem _albumToMediaItem(AlbumsTableData album) {
    return _browsableItem(
      id: AutoMediaId.album(album.id),
      title: album.name,
      artist: album.artistName,
      artUri: _coverArtUri(album.coverArt),
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
        'browsable': true,
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

  List<MediaItem> _errorItems(String message) {
    return [
      MediaItem(
        id: 'error/${DateTime.now().millisecondsSinceEpoch}',
        title: message,
        playable: false,
      ),
    ];
  }
}
