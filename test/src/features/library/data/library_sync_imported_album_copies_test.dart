import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

/// #707: remote copies moved onto a library album by the album remap must be
/// cleaned up once the library album gains its songs.
void main() {
  const remoteAlbumId = 'ext-deezer-album-1';
  const titles = ['One', 'Two', 'Three'];

  late NavisDatabase database;
  late FakeLibrarySyncApi api;
  late DriftLibrarySyncEngine engine;

  Song librarySong(int n) => Song(
    id: 'lib-song-$n',
    title: titles[n - 1],
    album: 'Album',
    albumId: 'lib-album',
    artist: 'Artist',
    artistId: 'artist',
    track: n,
    duration: 100 + n,
  );

  // The header keeps reporting the full song count, as a server whose album
  // row was written before the remaining songs were imported does.
  void serve(List<Song> songs, {int? songCount}) {
    final album = Album(
      id: 'lib-album',
      name: 'Album',
      artist: 'Artist',
      artistId: 'artist',
      songCount: songCount ?? songs.length,
      songs: songs,
    );
    api.artists
      ..clear()
      ..add(const Artist(id: 'artist', name: 'Artist'));
    api.fastPathPages
      ..clear()
      ..[0] = <Album>[album];
    api.albumDetails
      ..clear()
      ..['lib-album'] = album;
  }

  Future<void> seedRemoteCopies({int from = 1}) async {
    await database.libraryDao.upsertProvisionalAlbums([
      AlbumsTableCompanion.insert(
        id: remoteAlbumId,
        name: 'Album',
        artistName: const Value('Artist'),
        isExternal: const Value(true),
        isProvisional: const Value(true),
      ),
    ]);
    await database.libraryDao.upsertProvisionalSongs([
      for (var n = from; n <= 3; n++)
        SongsTableCompanion.insert(
          id: 'ext-deezer-song-$n',
          title: titles[n - 1],
          albumId: const Value(remoteAlbumId),
          artistName: const Value('Artist'),
          albumName: const Value('Album'),
          track: Value(n),
          duration: Value(100 + n),
          isExternal: const Value(true),
          isProvisional: const Value(true),
        ),
    ]);
  }

  /// A second library album whose song carries the same title, artist,
  /// album name and length as library song 3, so both claim remote copy 3.
  Song rivalSong() => const Song(
    id: 'rival-song-3',
    title: 'Three',
    album: 'Album',
    albumId: 'rival-album',
    artist: 'Artist',
    artistId: 'artist',
    track: 3,
    duration: 103,
  );

  void serveWithRival() {
    serve([librarySong(1), librarySong(2), librarySong(3)]);
    final rival = Album(
      id: 'rival-album',
      name: 'Album',
      artist: 'Artist',
      artistId: 'artist',
      songCount: 1,
      songs: [rivalSong()],
    );
    api.fastPathPages[0] = [...api.fastPathPages[0]!, rival];
    api.albumDetails['rival-album'] = rival;
  }

  Future<void> sync() async {
    final result = await engine.executeSyncPlan(
      await repairPlanAfterDialog(database),
    );
    expect(result.status, LibrarySyncStatus.succeeded);
  }

  /// The follow-up run the coordinator schedules while albums are pending.
  Future<void> drainPending() async {
    final result = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.targetedHydration),
    );
    expect(result.status, LibrarySyncStatus.succeeded);
  }

  /// A like stored on the song row only, with no star_sync_queue entry.
  Future<void> like(String id) => database.customStatement(
    "UPDATE songs SET starred = 1767225600 WHERE id = ?",
    [id],
  );

  /// A finished permanent download, so the provisional garbage collection
  /// cannot delete the copy and only the hydration pass can remove it.
  Future<File> download(String songId) async {
    final files = await Directory.systemTemp.createTemp('navis_707d_');
    addTearDown(() => files.delete(recursive: true));
    final file = File('${files.path}/$songId.mp3')..writeAsBytesSync([1, 2, 3]);
    await database.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: songId,
        filePath: file.path,
        fileSize: 3,
        format: 'mp3',
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime.utc(2026),
      ),
    );
    return file;
  }

  Future<List<String>> listedIds() async => [
    for (final song
        in await database.libraryDao.watchSongsByAlbum('lib-album').first)
      song.id,
  ];

  setUp(() async {
    database = NavisDatabase(NativeDatabase.memory());
    api = FakeLibrarySyncApi();
    engine = serialDriftEngine(
      api: api,
      database: database,
      repository: await seedSyncSession(database),
    );
  });

  tearDown(() => database.close());

  test('a later full sync with every library song present drops '
      'the remote copies', () async {
    await seedRemoteCopies();
    serve([librarySong(1)]);
    await sync();
    expect(await database.libraryDao.getAlbumById(remoteAlbumId), isNull);
    expect(
      await listedIds(),
      unorderedEquals(['lib-song-1', 'ext-deezer-song-2', 'ext-deezer-song-3']),
    );

    serve([librarySong(1), librarySong(2), librarySong(3)]);
    await sync();
    expect(await listedIds(), ['lib-song-1', 'lib-song-2', 'lib-song-3']);
  }, skip: !sqliteAvailable);

  test('a copy contested by a song of another album is removed '
      'from the imported album', () async {
    await seedRemoteCopies();
    final file = await download('ext-deezer-song-3');
    serveWithRival();
    await sync();
    await drainPending();
    expect(await listedIds(), ['lib-song-1', 'lib-song-2', 'lib-song-3']);
    expect(await database.libraryDao.getSongById('ext-deezer-song-3'), isNull);
    expect(
      (await database.cacheDao.getCachedTrack('lib-song-3'))?.filePath,
      file.path,
    );
    expect(file.existsSync(), isTrue);
  }, skip: !sqliteAvailable);

  test('a second full sync before the drain keeps the album pending so the '
      'contested copy is still removed', () async {
    await seedRemoteCopies();
    await download('ext-deezer-song-3');
    serveWithRival();
    await sync();
    await sync();
    await drainPending();
    expect(await listedIds(), ['lib-song-1', 'lib-song-2', 'lib-song-3']);
  }, skip: !sqliteAvailable);

  test('control: a manual refresh of the album removes the contested '
      'copy', () async {
    await seedRemoteCopies();
    serveWithRival();
    await sync();
    await engine.hydrateAlbum('lib-album');
    expect(await listedIds(), ['lib-song-1', 'lib-song-2', 'lib-song-3']);
  }, skip: !sqliteAvailable);

  test('partial promotion lists library and remote songs once each and '
      'marks the album for hydration', () async {
    await seedRemoteCopies();
    serve([librarySong(1)]);
    await sync();
    final ids = await listedIds();
    expect(ids.toSet().length, ids.length);
    expect(ids.where((id) => id.startsWith('ext-')).length, 2);
    expect(await database.libraryDao.getAlbumById(remoteAlbumId), isNull);
    expect(
      await database.libraryDao.getPendingHydrationAlbumIds(),
      contains('lib-album'),
    );
  }, skip: !sqliteAvailable);

  test(
    'completion keeps downloads, queues and history of a copy on '
    'the library id and deletes the losing cache file after commit',
    () async {
      final files = await Directory.systemTemp.createTemp('navis_707_');
      addTearDown(() => files.delete(recursive: true));
      await seedRemoteCopies();
      serve([librarySong(1)]);
      await sync();

      const copy = 'ext-deezer-song-2';
      final file = File('${files.path}/copy.mp3')..writeAsBytesSync([1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: copy,
          filePath: file.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.utc(2026),
        ),
      );
      await database
          .into(database.downloadQueueTable)
          .insert(
            DownloadQueueTableCompanion.insert(
              songId: const Value(copy),
              status: DownloadStatus.queued,
              addedAt: DateTime.utc(2026),
            ),
          );
      await database
          .into(database.playQueueTable)
          .insert(
            PlayQueueTableCompanion.insert(
              id: const Value(1),
              updatedAt: DateTime.utc(2026),
            ),
          );
      await database
          .into(database.playQueueItemsTable)
          .insert(
            PlayQueueItemsTableCompanion.insert(
              queueId: 1,
              songId: copy,
              sortOrder: 0,
            ),
          );
      await database
          .into(database.playHistoryTable)
          .insert(
            PlayHistoryTableCompanion.insert(
              songId: copy,
              playedAt: DateTime.utc(2026),
            ),
          );

      serve([librarySong(1), librarySong(2), librarySong(3)]);
      await sync();
      await drainPending();
      expect(await listedIds(), ['lib-song-1', 'lib-song-2', 'lib-song-3']);
      expect(await database.libraryDao.getSongById(copy), isNull);
      expect(
        (await database.cacheDao.getCachedTrack('lib-song-2'))?.filePath,
        file.path,
      );
      expect(file.existsSync(), isTrue);
      for (final table in [
        'download_queue',
        'play_queue_items',
        'play_history',
      ]) {
        final rows = await database
            .customSelect("SELECT 1 FROM $table WHERE song_id = 'lib-song-2'")
            .get();
        expect(rows, hasLength(1), reason: table);
      }
    },
    skip: !sqliteAvailable,
  );

  test('a never-matched liked copy survives repeated syncs and garbage '
      'collection, listed once, without extra fetches', () async {
    await seedRemoteCopies();
    serve([librarySong(1)]);
    await sync();
    const copy = 'ext-deezer-song-3';
    await like(copy);
    await sync();
    await drainPending();
    await database.songIdentityDao
        .garbageCollectUnreferencedProvisionalMetadata();
    final before = api.calls.where((c) => c == 'getAlbum:lib-album').length;
    await sync();
    await drainPending();
    await database.songIdentityDao
        .garbageCollectUnreferencedProvisionalMetadata();
    expect((await listedIds()).where((id) => id == copy), hasLength(1));
    expect(await database.libraryDao.getSongStarred(copy), isNotNull);
    // The album holds a copy, so the full sync re-fetches it once; the drain
    // finds nothing pending, so no second fetch.
    expect(
      api.calls.where((c) => c == 'getAlbum:lib-album').length - before,
      1,
    );
  }, skip: !sqliteAvailable);

  test(
    'a remote-only album without aliases is not marked for hydration',
    () async {
      await seedRemoteCopies();
      await database.songIdentityDao.markAlbumPendingIfRemoteCopies(
        remoteAlbumId,
      );
      expect(await database.libraryDao.getPendingHydrationAlbumIds(), isEmpty);
    },
    skip: !sqliteAvailable,
  );
}
