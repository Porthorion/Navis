part of 'navis_audio_handler.dart';

extension _NavisAndroidAuto on NavisAudioHandler {
  Future<List<SongsTableData>> _loadAutoCollection(
    AutoMediaContextType? context,
  ) async => switch (context) {
    AutoMediaContextType.downloads => await _libraryDao.getSongsSorted(
      SongSortOrder.newest,
      onlyIds: await _rollingCacheManager.getPermanentlyCachedSongIds(),
    ),
    AutoMediaContextType.liked =>
      await _libraryDao.watchAllStarredSongs().first,
    AutoMediaContextType.recent =>
      await _historyDao.watchRecentlyPlayedSongs(limit: 50).first,
    _ => const <SongsTableData>[],
  };

  Future<bool> _loadAutoRows(
    List<SongsTableData> songs, {
    required bool autoPlay,
    int startIndex = 0,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) async {
    if (songs.isEmpty) return false;
    await replaceQueueWithData(
      songs,
      startIndex: startIndex,
      autoPlay: autoPlay,
      expandMatchFlows: expandMatchFlows,
      originalOrder: originalOrder,
    );
    return _queueItems.isNotEmpty;
  }

  Future<bool> _loadFromMediaId(
    String mediaId, {
    required bool autoPlay,
  }) async {
    // Handle special root-level playable/browsable nodes by raw ID.
    switch (mediaId) {
      case AutoMediaRoot.shuffleLiked:
        final songs = await _libraryDao.watchAllStarredSongs().first;
        if (songs.isEmpty) return false;
        final shuffled = List<SongsTableData>.of(songs)
          ..shuffle(_shuffleRandom);
        return await _loadAutoRows(
          shuffled,
          originalOrder: songs.map((song) => song.id).toList(growable: false),
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
      case AutoMediaRoot.instantMix:
        if (autoPlay) {
          return _playInstantMixFromCurrentSong();
        }
        return _startInstantRadio(autoPlay: false);
      case AutoMediaRoot.instantRadio:
        return _startInstantRadio(autoPlay: autoPlay);
      case AutoMediaRoot.likedSongs:
      case AutoMediaRoot.downloads:
      case AutoMediaRoot.recent:
        return await _loadAutoRows(
          await _loadAutoCollection(switch (mediaId) {
            AutoMediaRoot.likedSongs => AutoMediaContextType.liked,
            AutoMediaRoot.downloads => AutoMediaContextType.downloads,
            _ => AutoMediaContextType.recent,
          }),
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
      case AutoMediaRoot.likedAlbums:
        final albums = await _libraryDao.watchLikedAlbums().first;
        final allSongs = <SongsTableData>[];
        for (final album in albums) {
          allSongs.addAll(await _libraryDao.watchSongsByAlbum(album.id).first);
        }
        return await _loadAutoRows(allSongs, autoPlay: autoPlay);
      case AutoMediaRoot.resumeQueue:
        await _restoreQueueFromDisk();
        if (_queueItems.isEmpty) return false;
        if (autoPlay) {
          await play();
        }
        return true;
    }

    // Handle entity media IDs (artist/album/playlist/song).
    final parsed = AutoMediaId.parse(mediaId);
    if (parsed == null) {
      final rawSongId = AutoMediaId.songIdFrom(mediaId);
      if (rawSongId == null) {
        AppLogger.debug('Android Auto mediaId ignored: $mediaId');
        return false;
      }
      final songs = await _libraryDao.getSongsByIds([rawSongId]);
      if (songs.isEmpty) {
        AppLogger.debug('Android Auto raw song mediaId not found: $mediaId');
        return false;
      }
      return await _loadAutoRows(songs, autoPlay: autoPlay);
    }
    if (parsed.entityId == null) return false;

    switch (parsed.type) {
      case AutoMediaIdType.song:
        final songs = await _libraryDao.getSongsByIds([parsed.entityId!]);
        if (songs.isEmpty) return false;
        final song = songs.first;
        final contextualSongs = await _loadAutoCollection(parsed.contextType);
        if (contextualSongs.isNotEmpty) {
          final startIndex = contextualSongs.indexWhere(
            (item) => item.id == parsed.entityId,
          );
          if (startIndex >= 0) {
            return await _loadAutoRows(
              contextualSongs,
              startIndex: startIndex,
              autoPlay: autoPlay,
              expandMatchFlows: false,
            );
          }
        }
        if (parsed.contextType == AutoMediaContextType.playlist &&
            parsed.contextId != null) {
          final playlistSongs = await _playlistDao
              .watchPlaylistSongs(parsed.contextId!)
              .first;
          final startIndex = playlistSongs.indexWhere(
            (item) => item.id == parsed.entityId,
          );
          if (startIndex >= 0) {
            return await _loadAutoRows(
              playlistSongs,
              startIndex: startIndex,
              autoPlay: autoPlay,
            );
          }
        }

        // Album browse context is explicit when available. The phone setting
        // still decides whether an album leaf builds the album queue.
        final albumId = parsed.contextType == AutoMediaContextType.album
            ? parsed.contextId
            : song.albumId;
        if (albumId != null && _readRuntimeSettings().albumQueueEnabled) {
          final albumSongs = await _libraryDao.watchSongsByAlbum(albumId).first;
          if (albumSongs.isNotEmpty) {
            final startIndex = albumSongs.indexWhere(
              (s) => s.id == parsed.entityId,
            );
            return await _loadAutoRows(
              albumSongs,
              startIndex: startIndex < 0 ? 0 : startIndex,
              autoPlay: autoPlay,
            );
          }
        }
        await replaceQueue([parsed.entityId!], autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaIdType.album:
        final songs = await _libraryDao
            .watchSongsByAlbum(parsed.entityId!)
            .first;
        return await _loadAutoRows(songs, autoPlay: autoPlay);
      case AutoMediaIdType.playlist:
        final songs = await _playlistDao
            .watchPlaylistSongs(parsed.entityId!)
            .first;
        return await _loadAutoRows(songs, autoPlay: autoPlay);
      case AutoMediaIdType.artist:
        final albums = await _libraryDao
            .watchAlbumsByArtist(parsed.entityId!)
            .first;
        final allSongs = <SongsTableData>[];
        for (final album in albums) {
          allSongs.addAll(await _libraryDao.watchSongsByAlbum(album.id).first);
        }
        return await _loadAutoRows(allSongs, autoPlay: autoPlay);
      case AutoMediaIdType.root:
      case AutoMediaIdType.rootCategory:
      case AutoMediaIdType.likedSubcategory:
        return false;
    }
  }

  Future<bool> _loadFromSearch(
    String query,
    Map<String, dynamic>? extras, {
    required bool autoPlay,
  }) async {
    final request = navisAndroidAutoSearchRequest(query, extras);
    if (request.type == NavisAndroidAutoSearchType.empty) {
      return _startInstantRadio(autoPlay: autoPlay);
    }

    switch (request.type) {
      case NavisAndroidAutoSearchType.artist:
        final artists = await _libraryDao.searchArtistsLocal(
          request.term,
          limit: 1,
        );
        if (artists.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.artist(artists.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.album:
        final albums = await _libraryDao.searchAlbumsLocal(
          request.term,
          limit: 1,
        );
        if (albums.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.album(albums.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.playlist:
        final playlists = await _playlistDao.watchPlaylists().first;
        final matches = playlists.where(
          (playlist) => _containsIgnoreCase(playlist.name, request.term),
        );
        if (matches.isNotEmpty) {
          final exactMatches = matches.where(
            (playlist) => _equalsIgnoreCase(playlist.name, request.term),
          );
          return _loadFromMediaId(
            AutoMediaId.playlist(
              exactMatches.isNotEmpty
                  ? exactMatches.first.id
                  : matches.first.id,
            ),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.title:
        final songs = await _libraryDao.searchSongsLocal(
          request.term,
          limit: 1,
        );
        if (songs.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.song(songs.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.general:
        final songs = await _libraryDao.searchSongsLocal(
          request.term,
          limit: 20,
        );
        final exactSongs = songs.where(
          (song) => _equalsIgnoreCase(song.title, request.term),
        );
        if (exactSongs.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.song(exactSongs.first.id),
            autoPlay: autoPlay,
          );
        }
        final playlists = await _playlistDao.watchPlaylists().first;
        final exactPlaylists = playlists.where(
          (playlist) => _equalsIgnoreCase(playlist.name, request.term),
        );
        if (exactPlaylists.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.playlist(exactPlaylists.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.empty:
        break;
    }

    final results = await search(request.term, extras);
    final playable = results.where((item) => item.playable == true);
    final browsable = results.where(
      (item) => item.extras?[AndroidAutoConstants.isBrowsableKey] == true,
    );
    if (playable.isEmpty && browsable.isEmpty) return false;

    final target = playable.isNotEmpty ? playable.first : browsable.first;
    return _loadFromMediaId(target.id, autoPlay: autoPlay);
  }

  void _broadcastAndroidAutoPlaybackError(String message) {
    AppLogger.warning('Android Auto playback request failed: $message');
    playbackState.add(
      navisAndroidAutoPlaybackErrorState(playbackState.value, message),
    );
  }

  Future<void> _runAndroidAutoLoad(
    Future<bool> Function() load, {
    required String failureMessage,
  }) async {
    try {
      if (await load()) {
        return;
      }
    } on Object catch (error) {
      AppLogger.warning(
        'Android Auto playback request raised ${error.runtimeType}.',
      );
    }
    _broadcastAndroidAutoPlaybackError(failureMessage);
  }

  Future<void> _notifyAndroidAutoBrowseRefresh() async {
    _androidAutoBrowseNotifier.notifyParentsChanged();
    AppLogger.info('Android Auto browse roots refresh requested.');
  }
}
