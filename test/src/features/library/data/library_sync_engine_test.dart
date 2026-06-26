import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';
import '../../../../helpers/test_database.dart';

class _FakeCredentialStore implements SecureCredentialStore {
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

class _FakeLibrarySyncApi implements LibrarySyncApi {
  final List<String> calls = <String>[];
  final List<Artist> artists = <Artist>[];
  final Map<String, Artist> artistDetails = <String, Artist>{};
  final Map<String, Album> albumDetails = <String, Album>{};
  final Map<int, List<Album>> fastPathPages = <int, List<Album>>{};
  final Map<int, List<Song>> bulkSongPages = <int, List<Song>>{};
  StarredContent starredContent = const StarredContent();
  List<Genre> genres = <Genre>[];
  List<Playlist> playlists = <Playlist>[];
  Indexes indexes = const Indexes();
  Completer<List<Artist>>? artistsCompleter;

  Exception? throwOnFastPath;
  Exception? throwOnIndexes;
  Exception? throwOnSongSearch;
  Exception? throwOnGenres;
  final Set<String> notFoundAlbumIds = <String>{};
  final Set<String> notFoundArtistIds = <String>{};
  final Set<String> permanentTransientAlbumIds = <String>{};
  final Map<String, int> transientAlbumFailures = <String, int>{};
  Duration albumDelay = Duration.zero;
  int currentAlbumRequests = 0;
  int maxConcurrentAlbumRequests = 0;

  @override
  Future<Album> getAlbum(String id) async {
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
    if (albumDelay > Duration.zero) {
      await Future<void>.delayed(albumDelay);
    }
    final album = albumDetails[id];
    currentAlbumRequests--;
    if (album == null) {
      throw StateError('Missing fake album for id: $id');
    }
    return album;
  }

  @override
  Future<StarredContent> getStarredContent() async => starredContent;

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('getAlbumListPage:$offset:$size');
    final error = throwOnFastPath;
    if (error != null) {
      throw error;
    }
    return fastPathPages[offset] ?? const <Album>[];
  }

  @override
  Future<Artist> getArtist(String id) async {
    calls.add('getArtist:$id');
    if (notFoundArtistIds.contains(id)) {
      throw const SubsonicNotFoundException(message: 'Artist not found');
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
    final completer = artistsCompleter;
    if (completer != null) {
      return completer.future;
    }
    return artists;
  }

  @override
  Future<List<Genre>> getGenres() async {
    calls.add('getGenres');
    final error = throwOnGenres;
    if (error != null) {
      throw error;
    }
    return genres;
  }

  @override
  Future<Indexes> getIndexes({DateTime? ifModifiedSince}) async {
    calls.add('getIndexes');
    final error = throwOnIndexes;
    if (error != null) {
      throw error;
    }
    return indexes;
  }

  @override
  Future<List<Playlist>> getPlaylists() async {
    calls.add('getPlaylists');
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

void main() {
  group('DriftLibrarySyncEngine', () {
    late NavisDatabase database;
    late ServerConfigRepository serverConfigRepository;
    late _FakeCredentialStore credentials;
    late _FakeLibrarySyncApi api;
    late DriftLibrarySyncEngine engine;

    Future<void> saveSession({
      DateTime? lastSynced,
      DateTime? lastFullSyncedAt,
      String? capabilitiesJson,
    }) {
      return serverConfigRepository.save(
        ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
          capabilitiesJson: capabilitiesJson,
          lastSynced: lastSynced,
          lastFullSyncedAt: lastFullSyncedAt,
        ),
      );
    }

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      credentials = _FakeCredentialStore();
      serverConfigRepository = ServerConfigRepository(
        database,
        credentials: credentials,
      );
      api = _FakeLibrarySyncApi();
      engine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
        isolateThreshold: 1000,
      );
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'full sync writes metadata and songs using album-list fast path',
      () async {
        await saveSession();
        api.artists.addAll(const <Artist>[
          Artist(id: 'artist-1', name: 'Artist 1'),
          Artist(id: 'artist-2', name: 'Artist 2'),
        ]);
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 2',
            artistId: 'artist-2',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song 1',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          songs: <Song>[
            Song(
              id: 'song-2',
              title: 'Song 2',
              albumId: 'album-2',
              artistId: 'artist-2',
            ),
          ],
        );
        api.genres = const <Genre>[
          Genre(name: 'Rock', albumCount: 2, songCount: 2),
        ];
        api.playlists = const <Playlist>[
          Playlist(id: 'playlist-1', name: 'Favorites', songCount: 2),
        ];

        final state = await engine.syncNow(forceFull: true);

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.forceFull);
        expect(api.calls, contains('getAlbumListPage:0:500'));
        expect(
          api.calls.where((call) => call.startsWith('getArtist:')),
          isEmpty,
        );

        final artistRows = await database.select(database.artistsTable).get();
        final albumRows = await database.select(database.albumsTable).get();
        final songRows = await database.select(database.songsTable).get();
        final genreRows = await database.select(database.genresTable).get();
        final playlistRows = await database
            .select(database.playlistsTable)
            .get();
        final serverConfig = await serverConfigRepository.getActiveServer();

        expect(artistRows.length, 2);
        expect(albumRows.length, 2);
        expect(songRows.length, 2);
        expect(genreRows.length, 1);
        expect(playlistRows.length, 1);
        expect(serverConfig?.lastSynced, isNotNull);
        expect(serverConfig?.lastFullSyncedAt, isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'album detail hydration binds child songs to the fetched album id',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song 1',
              albumId: 'missing-album-id',
              artistId: 'artist-1',
            ),
          ],
        );

        final state = await engine.syncNow(forceFull: true);
        final songRows = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(songRows.single.albumId, 'album-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'fast-path metadata sync emits incremental album discovery progress',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.fastPathPages[2] = const <Album>[
          Album(
            id: 'album-3',
            name: 'Album 3',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );
        api.albumDetails['album-3'] = const Album(
          id: 'album-3',
          name: 'Album 3',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );

        final localEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          fastPathPageSize: 2,
          writeChunkSize: 4,
          isolateThreshold: 1000,
        );

        final progress = <LibrarySyncState>[];
        await localEngine.syncNow(
          forceFull: true,
          onProgress: progress.add,
        );

        final albumStageProgress = progress
            .where((state) => state.stage == LibrarySyncStage.fetchingAlbums)
            .where((state) => state.processed != null && state.total != null)
            .toList(growable: false);

        expect(albumStageProgress.length, greaterThanOrEqualTo(2));
        expect(albumStageProgress.first.processed, 2);
        expect(albumStageProgress.last.processed, 3);
        expect(albumStageProgress.last.total, 3);
      },
      skip: !sqliteAvailable,
    );

    test(
      'fast-path fallback uses per-artist expansion when endpoint is unsupported',
      () async {
        await saveSession();
        api.throwOnFastPath = const SubsonicNotFoundException(
          message: 'missing',
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(
              id: 'album-1',
              name: 'Album 1',
              artist: 'Artist 1',
              artistId: 'artist-1',
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.syncNow(forceFull: true);

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getArtist:artist-1'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path hydrates songs without per-album requests when compatible',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          9,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
          ),
        );

        final state = await engine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:1'));
        expect(api.calls, contains('searchSongsPage::0:1000'));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs.length, 9);
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path emits incremental hydration progress updates',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
          ),
        );
        api.bulkSongPages[3] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 4}',
            title: 'Song ${index + 4}',
            albumId: 'album-${index + 4}',
            artistId: 'artist-1',
          ),
        );
        api.bulkSongPages[6] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 7}',
            title: 'Song ${index + 7}',
            albumId: 'album-${index + 7}',
            artistId: 'artist-1',
          ),
        );

        final bulkEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          bulkSearchPageSize: 3,
          writeChunkSize: 4,
          isolateThreshold: 1000,
        );

        final progress = <LibrarySyncState>[];
        await bulkEngine.syncNow(
          forceFull: true,
          onProgress: progress.add,
        );

        final hydrationProgress = progress
            .where((state) => state.stage == LibrarySyncStage.fetchingSongs)
            .where((state) => state.processed != null)
            .map((state) => state.processed!)
            .toList(growable: false);

        expect(hydrationProgress, isNotEmpty);
        expect(hydrationProgress.any((count) => count > 0), isTrue);
        expect(hydrationProgress.last, greaterThanOrEqualTo(9));
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path with isolate parsing does not crash',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          9,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
          ),
        );

        final isolateEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 4,
          isolateThreshold: 1,
        );

        final state = await isolateEngine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs.length, 9);
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path with replay gain keeps fast-path hydration active',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          9,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
            replayGain: const ReplayGain(
              trackGain: -4.5,
              albumGain: -3,
              trackPeak: 0.92,
              albumPeak: 0.95,
            ),
          ),
        );

        final isolateEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 4,
          isolateThreshold: 1,
        );

        final state = await isolateEngine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs.length, 9);
        expect(songs.first.replayGainTrackGain, -4.5);
        expect(songs.first.replayGainAlbumGain, -3.0);
        expect(songs.first.replayGainTrackPeak, 0.92);
        expect(songs.first.replayGainAlbumPeak, 0.95);
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path gracefully falls back to per-album hydration',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        api.throwOnSongSearch = const SubsonicGenericException(
          message: 'search unavailable',
        );
        for (var index = 0; index < 9; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }

        final state = await engine.syncNow(forceFull: true);

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')).length,
          greaterThan(0),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'stored bulk-song query is reused for small pending hydration batches',
      () async {
        await saveSession(
          capabilitiesJson: jsonEncode(<String, Object?>{
            'navis': <String, Object?>{
              'bulkSongSearchWildcardQuery': '',
            },
          }),
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-1',
            title: 'Song 1',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ];

        final state = await engine.syncNow(forceFull: true);

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:1'));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path hydrates complete albums and falls back for partial albums',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            songCount: 2,
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artistId: 'artist-1',
            songCount: 2,
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-1a',
            title: 'Song 1a',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
          Song(
            id: 'song-2a',
            title: 'Song 2a',
            albumId: 'album-2',
            artistId: 'artist-1',
          ),
          Song(
            id: 'song-2b',
            title: 'Song 2b',
            albumId: 'album-2',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1a',
              title: 'Song 1a',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
            Song(
              id: 'song-1b',
              title: 'Song 1b',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );

        final bulkEnabledEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 1,
          isolateThreshold: 1000,
        );

        final state = await bulkEnabledEngine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbum:album-1'));
        expect(api.calls, isNot(contains('getAlbum:album-2')));
        expect(
          songs.map((song) => song.id).toSet(),
          containsAll(<String>{'song-1a', 'song-1b', 'song-2a', 'song-2b'}),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path reconciles complete album song sets',
      () async {
        await saveSession(
          capabilitiesJson: jsonEncode(<String, Object?>{
            'navis': <String, Object?>{
              'bulkSongSearchWildcardQuery': '',
            },
          }),
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            artistId: const Value('artist-1'),
            songCount: const Value(2),
            songsHydrated: const Value(true),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-empty',
            name: 'Album Empty',
            artistId: const Value('artist-1'),
            songCount: const Value(1),
            songsHydrated: const Value(true),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-old',
            title: 'Old Song',
            albumId: const Value('album-1'),
          ),
          SongsTableCompanion.insert(
            id: 'song-empty-old',
            title: 'Empty Old Song',
            albumId: const Value('album-empty'),
          ),
        ]);
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            songCount: 1,
          ),
          Album(
            id: 'album-empty',
            name: 'Album Empty',
            artistId: 'artist-1',
            songCount: 0,
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-new',
            title: 'New Song',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ];

        final state = await engine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:1000'));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs.map((song) => song.id).toSet(), <String>{'song-new'});
      },
      skip: !sqliteAvailable,
    );

    test(
      'song hydration tolerates unknown artist ids by storing null artistId',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-unknown-artist',
            title: 'Song Unknown Artist',
            albumId: 'album-1',
            artistId: 'artist-missing',
            artist: 'Missing Artist',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-unknown-artist',
              title: 'Song Unknown Artist',
              albumId: 'album-1',
              artistId: 'artist-missing',
              artist: 'Missing Artist',
            ),
          ],
        );

        final state = await engine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(songs, hasLength(1));
        expect(songs.single.id, 'song-unknown-artist');
        expect(songs.single.artistId, isNull);
        expect(songs.single.artistName, 'Missing Artist');
      },
      skip: !sqliteAvailable,
    );

    test('staleness gate skips sync when session is fresh', () async {
      await saveSession(
        lastSynced: DateTime.now(),
        lastFullSyncedAt: DateTime.now(),
      );

      final state = await engine.syncIfStale();

      expect(state.status, LibrarySyncStatus.skipped);
      expect(api.calls, isEmpty);
    }, skip: !sqliteAvailable);

    test(
      'incremental sync only requests changed artists/albums',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'artist-old', name: 'Artist Old'),
          ],
        );
        api.indexes = const Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              name: 'A',
              artists: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
            ),
          ],
        );
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(
              id: 'album-1',
              name: 'Album 1',
              artist: 'Artist 1',
              artistId: 'artist-1',
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );

        final state = await engine.syncIfStale();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.incremental);
        expect(api.calls, contains('getIndexes'));
        expect(api.calls, contains('getArtist:artist-1'));
        expect(api.calls, isNot(contains('getArtist:artist-old')));
        expect(api.calls, contains('getAlbum:album-1'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental sync persists play-count-only album metadata changes',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
          ],
        );
        await database.libraryDao.upsertAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              artistId: const Value('artist-1'),
              artistName: const Value('Artist 1'),
              playCount: const Value(1),
              songsHydrated: const Value(true),
            ),
          ],
        );
        api.indexes = const Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              name: 'A',
              artists: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
            ),
          ],
        );
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(
              id: 'album-1',
              name: 'Album 1',
              artist: 'Artist 1',
              artistId: 'artist-1',
              playCount: 2,
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
          playCount: 2,
          songs: <Song>[],
        );

        final state = await engine.syncNow();
        final albums = await database.select(database.albumsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(albums.single.playCount, 2);
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental mode falls back to rebaseline when indexes unsupported',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now(),
        );
        api.throwOnIndexes = const SubsonicNotFoundException(
          message: 'missing',
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.syncIfStale();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.rebaselineFull);
        expect(api.calls, contains('getArtists'));
        expect(api.calls, contains('getAlbumListPage:0:500'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental mode falls back to rebaseline when changed artist fanout is too large',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 2)),
        );
        api.indexes = Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              name: 'A',
              artists: List<Artist>.generate(
                49,
                (index) => Artist(
                  id: 'artist-${index + 1}',
                  name: 'Artist ${index + 1}',
                ),
              ),
            ),
          ],
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.syncIfStale();
        final config = await serverConfigRepository.getActiveServer();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.rebaselineFull);
        expect(api.calls, contains('getIndexes'));
        expect(api.calls, contains('getArtists'));
        expect(api.calls, contains('getAlbumListPage:0:500'));
        expect(
          api.calls.where((call) => call.startsWith('getArtist:')),
          isEmpty,
        );
        expect(config?.lastFullSyncedAt, isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental sync marks run skipped after exhausted transient index failures',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now(),
        );
        api.throwOnIndexes = const SubsonicGenericException(
          code: 530,
          message: 'origin unavailable',
        );

        final state = await engine.syncIfStale();

        expect(state.status, LibrarySyncStatus.skipped);
        expect(state.mode, LibrarySyncMode.incremental);
        expect(state.stage, LibrarySyncStage.completed);
        expect(
          state.errorMessage,
          'Server temporarily unavailable. Sync will retry later.',
        );
        expect(
          api.calls.where((call) => call == 'getIndexes').length,
          4,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'daily rebaseline mode triggers full sync after interval',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 30)),
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.syncIfStale();
        final config = await serverConfigRepository.getActiveServer();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.rebaselineFull);
        expect(config?.lastFullSyncedAt, isNotNull);
        expect(
          config!.lastFullSyncedAt!.isAfter(
            DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'rebaseline avoids rehydrating unchanged albums',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 30)),
        );
        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
          ],
        );
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              artistId: const Value('artist-1'),
              artistName: const Value('Artist 1'),
              songsHydrated: const Value(true),
            ),
          ],
        );
        await database.libraryDao.replaceSongs(
          <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-1'),
            ),
          ],
        );

        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
          ),
        ];

        final state = await engine.syncIfStale();
        final pending = await database.libraryDao.countPendingHydrationAlbums();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.rebaselineFull);
        expect(api.calls, isNot(contains('getAlbum:album-1')));
        expect(pending, 0);
        expect(songs.map((song) => song.id), contains('song-1'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'adaptive hydration ramps concurrency on healthy latency',
      () async {
        await saveSession();
        api.albumDelay = const Duration(milliseconds: 2);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          18,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        for (var index = 0; index < 18; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }

        final adaptiveEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          fallbackArtistConcurrency: 2,
          wifiAlbumConcurrency: 2,
          wifiMaxAlbumConcurrency: 8,
          cellularAlbumConcurrency: 1,
          cellularMaxAlbumConcurrency: 2,
          otherAlbumConcurrency: 2,
          otherMaxAlbumConcurrency: 4,
          writeChunkSize: 18,
          isolateThreshold: 1000,
        );

        final state = await adaptiveEngine.syncNow(forceFull: true);

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.maxConcurrentAlbumRequests, greaterThan(2));
      },
      skip: !sqliteAvailable,
    );

    test('transient album failures are retried with backoff', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = const <Album>[
        Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
      );
      api.transientAlbumFailures['album-1'] = 2;

      final state = await engine.syncNow(forceFull: true);

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(
        api.calls.where((call) => call == 'getAlbum:album-1').length,
        greaterThanOrEqualTo(3),
      );
    }, skip: !sqliteAvailable);

    test(
      'fresh session resumes pending song hydration without metadata fetch',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              songsHydrated: const Value(false),
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );

        final state = await engine.syncIfStale();
        final albums = await database.select(database.albumsTable).get();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbum:album-1'));
        expect(api.calls, isNot(contains('getArtists')));
        expect(albums.single.songsHydrated, isTrue);
        expect(songs.single.id, 'song-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync failure does not wipe existing songs table',
      () async {
        await saveSession();
        await database
            .into(database.songsTable)
            .insert(
              SongsTableCompanion.insert(
                id: 'existing-song',
                title: 'Existing Song',
              ),
            );

        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        // Intentionally omit api.albumDetails['album-1'] so hydration fails.

        final state = await engine.syncNow(forceFull: true);
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.failed);
        expect(songs.any((song) => song.id == 'existing-song'), isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      '404 on one getAlbum during hydration succeeds and removes stale album',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              songsHydrated: const Value(false),
            ),
            AlbumsTableCompanion.insert(
              id: 'album-stale',
              name: 'Stale Album',
              songsHydrated: const Value(false),
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.notFoundAlbumIds.add('album-stale');

        final state = await engine.syncIfStale();
        final albums = await database.select(database.albumsTable).get();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(albums.map((album) => album.id), contains('album-1'));
        expect(albums.map((album) => album.id), isNot(contains('album-stale')));
        expect(songs.single.id, 'song-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'transient album failure in batch leaves album pending but sync succeeds',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              songsHydrated: const Value(false),
            ),
            AlbumsTableCompanion.insert(
              id: 'album-2',
              name: 'Album 2',
              songsHydrated: const Value(false),
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.permanentTransientAlbumIds.add('album-2');

        final state = await engine.syncIfStale();
        final pending = await database.libraryDao.countPendingHydrationAlbums();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(songs.single.id, 'song-1');
        expect(pending, 1);
      },
      skip: !sqliteAvailable,
    );

    test(
      'genre fetch failure after hydration still completes sync',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now(),
        );
        api.indexes = const Indexes(
          shortcut: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
        );
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[],
        );
        api.genres = <Genre>[const Genre(name: 'Rock', songCount: 1)];
        api.throwOnGenres = const SubsonicConnectionException('genres down');

        final state = await engine.syncIfStale();
        final config = await serverConfigRepository.getActiveServer();
        final storedGenres = await database.select(database.genresTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(config?.lastSynced, isNotNull);
        expect(storedGenres, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync artist fanout removes artists missing from getArtist',
      () async {
        await saveSession();
        api.artists.addAll(const <Artist>[
          Artist(id: 'artist-1', name: 'Artist 1'),
          Artist(id: 'artist-2', name: 'Artist 2'),
        ]);
        api.throwOnFastPath = const SubsonicNotFoundException(
          message: 'Album list unsupported',
        );
        api.notFoundArtistIds.add('artist-1');
        api.artistDetails['artist-2'] = const Artist(
          id: 'artist-2',
          name: 'Artist 2',
          albums: <Album>[
            Album(id: 'album-2', name: 'Album 2', artistId: 'artist-2'),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          songs: <Song>[
            Song(id: 'song-2', title: 'Song 2', albumId: 'album-2'),
          ],
        );
        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
          ],
        );

        final state = await engine.syncNow(forceFull: true);
        final artists = await database.select(database.artistsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(artists.map((artist) => artist.id), contains('artist-2'));
        expect(artists.map((artist) => artist.id), isNot(contains('artist-1')));
      },
      skip: !sqliteAvailable,
    );

    test(
      'sync lock returns same in-flight future for concurrent calls',
      () async {
        await saveSession();
        final completer = Completer<List<Artist>>();
        api.artistsCompleter = completer;

        final first = engine.syncNow(forceFull: true);
        final second = engine.syncNow(forceFull: true);

        completer.complete(const <Artist>[]);
        final firstState = await first;
        final secondState = await second;

        expect(firstState.status, LibrarySyncStatus.succeeded);
        expect(secondState.status, LibrarySyncStatus.succeeded);
        expect(api.calls.where((call) => call == 'getArtists').length, 1);
      },
      skip: !sqliteAvailable,
    );
  });
}
