import 'dart:async';

import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';

class FakeSyncCredentialStore implements SecureCredentialStore {
  String? _password;

  @override
  Future<void> clearPassword() async {
    _password = null;
  }

  @override
  Future<String?> readPassword() async => _password;

  @override
  Future<void> savePassword(String password) async {
    _password = password;
  }
}

class FakeLibrarySyncApi implements LibrarySyncApi {
  static final DateTime defaultIndexesCursor = DateTime.utc(2026, 1, 1);
  final List<String> calls = <String>[];
  final List<DateTime?> requestedIndexesCursors = <DateTime?>[];
  final List<Artist> artists = <Artist>[];
  final Map<String, Artist> artistDetails = <String, Artist>{};
  final Map<String, Album> albumDetails = <String, Album>{};
  final Map<String, Playlist> playlistDetails = <String, Playlist>{};
  final Map<int, List<Album>> fastPathPages = <int, List<Album>>{};
  final Map<int, Object> fastPathErrors = <int, Object>{};
  final Map<int, List<Song>> bulkSongPages = <int, List<Song>>{};
  StarredContent starredContent = const StarredContent();
  List<Playlist> playlists = <Playlist>[];
  Indexes indexes = const Indexes();
  ScanStatus? scanStatus;
  Completer<List<Artist>>? artistsCompleter;

  Exception? throwOnFastPath;
  Exception? throwOnIndexes;
  Exception? throwOnSongSearch;
  Exception? throwOnStarred;
  Exception? throwOnPlaylists;
  final Map<String, Object> albumErrors = <String, Object>{};
  final Map<String, Object> artistErrors = <String, Object>{};
  final Set<String> notFoundAlbumIds = <String>{};
  final Set<String> notFoundArtistIds = <String>{};
  final Set<String> permanentTransientAlbumIds = <String>{};
  Object? getArtistsError;
  final Map<String, int> transientAlbumFailures = <String, int>{};
  Duration albumDelay = Duration.zero;
  Completer<Album>? albumCompleter;
  bool activeRequestsCancelled = false;
  int currentAlbumRequests = 0;
  int maxConcurrentAlbumRequests = 0;

  @override
  void beginRun() {
    activeRequestsCancelled = false;
  }

  @override
  void cancelActiveRequests() {
    activeRequestsCancelled = true;
    final completer = albumCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const SubsonicConnectionException('cancelled'),
      );
    }
  }

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) async {
    calls.add('getAlbum:$id');
    currentAlbumRequests++;
    if (currentAlbumRequests > maxConcurrentAlbumRequests) {
      maxConcurrentAlbumRequests = currentAlbumRequests;
    }
    final transientFailures = transientAlbumFailures[id];
    if (transientFailures != null && transientFailures > 0) {
      transientAlbumFailures[id] = transientFailures - 1;
      currentAlbumRequests--;
      throw const SubsonicConnectionException('transient');
    }
    if (permanentTransientAlbumIds.contains(id)) {
      currentAlbumRequests--;
      throw const SubsonicConnectionException('transient');
    }
    if (notFoundAlbumIds.contains(id)) {
      currentAlbumRequests--;
      throw const SubsonicNotFoundException(message: 'Album not found');
    }
    final albumError = albumErrors[id];
    if (albumError != null) {
      currentAlbumRequests--;
      throw albumError;
    }
    if (albumDelay > Duration.zero) {
      await Future<void>.delayed(albumDelay);
    }
    final completer = albumCompleter;
    if (completer != null) {
      try {
        return await completer.future;
      } finally {
        currentAlbumRequests--;
      }
    }
    final album = albumDetails[id];
    currentAlbumRequests--;
    if (album == null) {
      throw StateError('Missing fake album for id: $id');
    }
    return album;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) async {
    calls.add('getPlaylist:$id');
    final playlist = playlistDetails[id];
    if (playlist == null) {
      throw StateError('Missing fake playlist for id: $id');
    }
    return playlist;
  }

  @override
  Future<StarredContent> getStarredContent() async {
    calls.add('getStarredContent');
    final error = throwOnStarred;
    if (error != null) {
      throw error;
    }
    return starredContent;
  }

  @override
  Future<ScanStatus?> getScanStatusOrNull() async {
    calls.add('getScanStatus');
    return scanStatus;
  }

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('getAlbumListPage:$offset:$size');
    final pageError = fastPathErrors[offset];
    if (pageError != null) {
      throw pageError;
    }
    final error = throwOnFastPath;
    if (error != null) {
      throw error;
    }
    return fastPathPages[offset] ?? const <Album>[];
  }

  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return getAlbumListPage(size: size, offset: offset);
  }

  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) async {
    calls.add('getArtist:$id');
    if (notFoundArtistIds.contains(id)) {
      throw const SubsonicNotFoundException(message: 'Artist not found');
    }
    final artistError = artistErrors[id];
    if (artistError != null) {
      throw artistError;
    }
    final artist = artistDetails[id];
    if (artist == null) {
      throw StateError('Missing fake artist for id: $id');
    }
    return artist;
  }

  @override
  Future<List<Artist>> getArtists() async {
    calls.add('getArtists');
    final error = getArtistsError;
    if (error != null) {
      throw error;
    }
    final completer = artistsCompleter;
    if (completer != null) {
      return completer.future;
    }
    return artists;
  }

  @override
  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  }) async {
    calls.add('getIndexes');
    requestedIndexesCursors.add(ifModifiedSince);
    final error = throwOnIndexes;
    if (error != null) {
      throw error;
    }
    return indexes.lastModified == null
        ? indexes.copyWith(lastModified: defaultIndexesCursor)
        : indexes;
  }

  @override
  Future<List<Playlist>> getPlaylists() async {
    calls.add('getPlaylists');
    final error = throwOnPlaylists;
    if (error != null) {
      throw error;
    }
    return playlists;
  }

  @override
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  }) async {
    calls.add('searchSongsPage:$query:$offset:$size');
    final error = throwOnSongSearch;
    if (error != null) {
      throw error;
    }
    return SearchResult3(songs: bulkSongPages[offset] ?? const <Song>[]);
  }
}
