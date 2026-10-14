import 'dart:async';

import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/utils/connectivity.dart';

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

/// A repository over [database] with the standard `alice@example.com` session
/// already saved.
Future<ServerConfigRepository> seedSyncSession(
  NavisDatabase database, {
  DateTime? lastSynced,
}) async {
  final repository = ServerConfigRepository(
    database,
    credentials: FakeSyncCredentialStore(),
  );
  await repository.save(
    ServerConfigModel(
      url: 'https://example.com',
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
      lastSynced: lastSynced,
    ),
  );
  return repository;
}

/// A Drift engine with single-lane album concurrency and tiny write chunks,
/// so sync ordering is deterministic.
DriftLibrarySyncEngine serialDriftEngine({
  required LibrarySyncApi api,
  required NavisDatabase database,
  required ServerConfigRepository repository,
  NetworkType networkType = NetworkType.other,
  Duration scanSettlePollInterval = const Duration(seconds: 5),
  int scanSettleMaxPolls = 12,
  int fastPathPageSize = 500,
  int bulkSearchPageSize = 1000,
  int writeChunkSize = 4,
  Future<void> Function(Map<String, String> aliases)? onBeforeSongIdentityRemap,
  String? Function()? readActiveSongId,
  Set<String> Function()? readProtectedSongIds,
}) => DriftLibrarySyncEngine(
  api: api,
  database: database,
  serverConfigRepository: repository,
  networkType: networkType,
  scanSettlePollInterval: scanSettlePollInterval,
  scanSettleMaxPolls: scanSettleMaxPolls,
  fastPathPageSize: fastPathPageSize,
  bulkSearchPageSize: bulkSearchPageSize,
  fallbackArtistConcurrency: 1,
  wifiAlbumConcurrency: 1,
  cellularAlbumConcurrency: 1,
  otherAlbumConcurrency: 1,
  writeChunkSize: writeChunkSize,
  onBeforeSongIdentityRemap: onBeforeSongIdentityRemap,
  readActiveSongId: readActiveSongId,
  readProtectedSongIds: readProtectedSongIds,
);

/// A Drift engine on a metered cellular connection that still allows
/// interactive hydration.
DriftLibrarySyncEngine meteredDriftEngine({
  required LibrarySyncApi api,
  required NavisDatabase database,
  required ServerConfigRepository repository,
}) => DriftLibrarySyncEngine(
  api: api,
  database: database,
  serverConfigRepository: repository,
  networkType: NetworkType.cellular,
  readSyncNetworkPolicy: () => const SyncNetworkPolicy(
    networkType: NetworkType.cellular,
    isMetered: true,
    allowsBackgroundSync: false,
    allowsHardProbe: true,
    allowsInteractiveHydration: true,
  ),
  fallbackArtistConcurrency: 1,
  cellularAlbumConcurrency: 1,
  writeChunkSize: 4,
);

class FakeLibrarySyncApi implements LibrarySyncApi {
  static final DateTime defaultIndexesCursor = DateTime.utc(2026, 1, 1);
  final List<String> calls = <String>[];
  final List<DateTime?> requestedIndexesCursors = <DateTime?>[];
  final List<Artist> artists = <Artist>[];
  final Map<String, Artist> artistDetails = <String, Artist>{};
  final Map<String, Album> albumDetails = <String, Album>{};
  final Map<String, Playlist> playlistDetails = <String, Playlist>{};
  final Map<int, List<Album>> fastPathPages = <int, List<Album>>{};

  /// Pages of the server's `newest` list by offset. When empty, the newest
  /// list repeats [fastPathPages].
  final Map<int, List<Album>> newestPages = <int, List<Album>>{};
  final Map<int, Object> fastPathErrors = <int, Object>{};
  final Map<int, List<Song>> bulkSongPages = <int, List<Song>>{};
  StarredContent starredContent = const StarredContent();
  List<Playlist> playlists = <Playlist>[];
  Indexes indexes = const Indexes();
  ScanStatus? scanStatus;

  /// Consumed one entry per `getScanStatusOrNull` call so tests can vary the
  /// observation between collection time and promotion time. Falls back to
  /// [scanStatus] when empty. [onGetScanStatus] takes precedence over both.
  final List<ScanStatus?> scanStatusQueue = <ScanStatus?>[];
  Future<ScanStatus?> Function()? onGetScanStatus;
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

  /// Awaited right after the call is recorded, so a test can pause a sync at
  /// that album-list page offset or album detail request.
  final Map<int, Completer<void>> pageGates = <int, Completer<void>>{};
  final Map<String, Completer<void>> albumGates = <String, Completer<void>>{};
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
      completer.completeError(const SubsonicConnectionException('cancelled'));
    }
  }

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) async {
    calls.add('getAlbum:$id');
    await albumGates[id]?.future;
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
      Error.throwWithStackTrace(albumError, StackTrace.current);
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
    final onCall = onGetScanStatus;
    if (onCall != null) {
      return await onCall();
    }
    if (scanStatusQueue.isNotEmpty) {
      return scanStatusQueue.removeAt(0);
    }
    return scanStatus;
  }

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('getAlbumListPage:$offset:$size');
    await pageGates[offset]?.future;
    final pageError = fastPathErrors[offset];
    if (pageError != null) {
      Error.throwWithStackTrace(pageError, StackTrace.current);
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
  }) async {
    if (newestPages.isEmpty) {
      return await getAlbumListPage(size: size, offset: offset);
    }
    calls.add('getNewestAlbumListPage:$offset:$size');
    return newestPages[offset] ?? const <Album>[];
  }

  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) async {
    calls.add('getArtist:$id');
    if (notFoundArtistIds.contains(id)) {
      throw const SubsonicNotFoundException(message: 'Artist not found');
    }
    final artistError = artistErrors[id];
    if (artistError != null) {
      Error.throwWithStackTrace(artistError, StackTrace.current);
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
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    final completer = artistsCompleter;
    if (completer != null) {
      return await completer.future;
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
