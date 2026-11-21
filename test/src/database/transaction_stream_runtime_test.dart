import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;

class _Watch<T> {
  new(Stream<T> stream) {
    _subscription = stream.listen(values.add);
    addTearDown(() => _subscription.cancel());
  }

  final values = <T>[];
  late final StreamSubscription<T> _subscription;

  Future<void> until(bool Function(T) condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (values.isEmpty || !condition(values.last)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Stream did not emit the committed value; received $values');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

// Drift >= 2.35.1 hands a nested transaction's table updates to the enclosing
// transaction, so subscribers hear of them once, after the outermost COMMIT.
// Returns the root announcements; the listener is created outside any
// transaction.
List<Set<TableUpdate>> _rootUpdates(NavisDatabase database) {
  final updates = <Set<TableUpdate>>[];
  final subscription = database.tableUpdates().listen(updates.add);
  addTearDown(subscription.cancel);
  return updates;
}

Future<void> _expectNoAnnouncement(List<Set<TableUpdate>> updates) async {
  // The root store delivers through Stream.multi: drain it before asserting.
  await Future<void>.delayed(Duration.zero);
  expect(updates, isEmpty, reason: 'announced inside the open transaction');
}

// Adds only a commit barrier; the executor is still NavisDatabase.atPath's
// production WAL connection with both reader isolates.
class _CommitBarrierDatabase extends NavisDatabase {
  new atPath(super.databasePath) : super.atPath();

  Future<void> Function()? beforeCommit;
  final _barrierZoneKey = Object();

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) {
    if (beforeCommit == null || Zone.current[_barrierZoneKey] != null) {
      return super.transaction(action, requireNew: requireNew);
    }
    return runZoned(
      () => super.transaction(() async {
        final result = await action();
        await beforeCommit?.call();
        return result;
      }, requireNew: requireNew),
      zoneValues: {_barrierZoneKey: true},
    );
  }
}

void main() {
  late Directory directory;
  late _CommitBarrierDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis_wal_updates_');
    database = _CommitBarrierDatabase.atPath(
      p.join(directory.path, 'navis.sqlite'),
    );
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 'old', title: 'Old'),
      SongsTableCompanion.insert(id: 'canonical', title: 'Canonical'),
    ]);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('plain outermost write announces each table exactly once', () async {
    final updates = <Set<TableUpdate>>[];
    final subscription = database.tableUpdates().listen(updates.add);
    addTearDown(subscription.cancel);

    await database.playQueueDao.saveQueue(songIds: ['old']);
    await Future<void>.delayed(Duration.zero);

    expect(updates, hasLength(1));
    expect(updates.single.map((update) => update.table).toSet(), {
      'play_queue',
      'play_queue_items',
    });
  });

  for (final nested in [false, true]) {
    test(
      'queued transaction does not repeat preceding commit (nested: $nested)',
      () async {
        final updates = <Set<TableUpdate>>[];
        final subscription = database.tableUpdates().listen(updates.add);
        addTearDown(subscription.cancel);
        final firstLocked = Completer<void>();
        final releaseFirst = Completer<void>();
        final secondLocked = Completer<void>();
        final releaseSecond = Completer<void>();
        addTearDown(() {
          if (!releaseFirst.isCompleted) releaseFirst.complete();
          if (!releaseSecond.isCompleted) releaseSecond.complete();
        });

        final first = database.transaction(() async {
          Future<void> write() async {
            await database
                .into(database.artistsTable)
                .insert(
                  ArtistsTableCompanion.insert(id: 'first', name: 'First'),
                );
          }

          if (nested) {
            await database.transaction(write, requireNew: true);
          } else {
            await write();
          }
          firstLocked.complete();
          await releaseFirst.future;
        });
        await firstLocked.future;
        final second = database.transaction(() async {
          secondLocked.complete();
          await releaseSecond.future;
          await database
              .into(database.albumsTable)
              .insert(
                AlbumsTableCompanion.insert(id: 'second', name: 'Second'),
              );
        });
        // Give the second call time to request the writer lock, while the first
        // transaction is deliberately still holding it.
        await Future<void>.delayed(Duration.zero);
        expect(secondLocked.isCompleted, isFalse);
        releaseFirst.complete();
        await first;
        await secondLocked.future;
        await Future<void>.delayed(Duration.zero);
        final beforeSecondCommit = updates.length;
        releaseSecond.complete();
        await second;
        await Future<void>.delayed(Duration.zero);

        expect(
          updates
              .skip(beforeSecondCommit)
              .expand((set) => set)
              .map((u) => u.table),
          isNot(contains('artists')),
        );
        expect(
          updates.where((set) => set.any((u) => u.table == 'artists')),
          hasLength(1),
        );
      },
    );
  }

  test('nested announcement arrives once, after the outer commit', () async {
    final updates = _rootUpdates(database);
    await database.transaction(() async {
      await database.transaction(() async {
        await database
            .into(database.artistsTable)
            .insert(ArtistsTableCompanion.insert(id: 'last', name: 'Last'));
      }, requireNew: true);
      await _expectNoAnnouncement(updates);
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      updates.where((set) => set.any((u) => u.table == 'artists')),
      hasLength(1),
    );
    expect(await database.libraryDao.getArtistById('last'), isNotNull);
  });

  test(
    'nested and requireNew writes reach a pooled reader after commit',
    () async {
      final watch = _Watch(database.select(database.artistsTable).watch());
      await watch.until((rows) => rows.isEmpty);
      final updates = _rootUpdates(database);
      await database.transaction(() async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'nested', name: 'Nested'),
        ]);
        await database.transaction(() async {
          await database
              .into(database.artistsTable)
              .insert(
                ArtistsTableCompanion.insert(id: 'savepoint', name: 'SP'),
              );
        }, requireNew: true);
        await _expectNoAnnouncement(updates);
        expect(watch.values.last, isEmpty);
      });
      await watch.until((rows) => rows.length == 2);
      expect(
        updates.where((set) => set.any((u) => u.table == 'artists')),
        hasLength(1),
      );
    },
  );

  test('caught inner savepoint rollback announces once after commit', () async {
    final watch = _Watch(database.select(database.artistsTable).watch());
    await watch.until((rows) => rows.isEmpty);
    final updates = _rootUpdates(database);
    await database.transaction(() async {
      try {
        await database.transaction(() async {
          await database
              .into(database.artistsTable)
              .insert(ArtistsTableCompanion.insert(id: 'gone', name: 'Gone'));
          throw Exception('inner');
        }, requireNew: true);
      } on Exception {
        // The savepoint is undone; the outer transaction continues.
      }
      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'kept', name: 'Kept'));
      await _expectNoAnnouncement(updates);
    });
    await watch.until((rows) => rows.any((row) => row.id == 'kept'));
    expect(watch.values.last.map((row) => row.id), ['kept']);
    expect(updates, hasLength(1));
  });

  for (final operation in [
    'like',
    'rating',
    'server star',
    'server unstar',
    'artwork',
  ]) {
    test('$operation does not invalidate playlist membership', () async {
      await database
          .into(database.playlistsTable)
          .insert(
            PlaylistsTableCompanion.insert(id: 'playlist', name: 'Playlist'),
          );
      await database
          .into(database.playlistSongsTable)
          .insert(
            PlaylistSongsTableCompanion.insert(
              playlistId: 'playlist',
              songId: 'old',
              sortOrder: 0,
            ),
          );
      if (operation == 'server unstar') {
        await database.libraryDao.setEntityStarred(
          'song',
          'old',
          DateTime.now(),
        );
      }
      final membership = _Watch(
        database.select(database.playlistSongsTable).watch(),
      );
      await membership.until((rows) => rows.length == 1);
      final updates = <Set<TableUpdate>>[];
      final subscription = database.tableUpdates().listen(updates.add);
      addTearDown(subscription.cancel);

      switch (operation) {
        case 'like':
          await database.starSyncDao.setStarred(
            itemId: 'old',
            itemType: 'song',
            liked: true,
          );
        case 'rating':
          await database.starSyncDao.setRating(
            itemId: 'old',
            itemType: 'song',
            rating: 4,
          );
        case 'server star':
          await database.libraryDao.batchReconcileStarred('song', {
            'old': DateTime.now(),
          });
        case 'server unstar':
          await database.libraryDao.batchReconcileStarred(
            'song',
            {},
            confirmedAbsentIds: {'old'},
          );
        case 'artwork':
          await database.libraryDao.bumpCoverArtRevisions(songIds: ['old']);
      }
      await Future<void>.delayed(Duration.zero);
      final announced = updates.expand((set) => set).toList();
      expect(announced.where((update) => update.table == 'songs'), isNotEmpty);
      expect(
        announced.map((update) => update.table),
        isNot(contains('playlist_songs')),
      );
      expect(membership.values, hasLength(1));
      expect(
        await database.select(database.playlistSongsTable).get(),
        hasLength(1),
      );
    });
  }

  test('DAO setStarred publishes liked songs after outer commit', () async {
    final watch = _Watch(database.libraryDao.watchAllStarredSongs());
    await watch.until((rows) => rows.isEmpty);
    final updates = _rootUpdates(database);
    await database.starSyncDao.transaction(() async {
      await database.starSyncDao.setStarred(
        itemId: 'old',
        itemType: 'song',
        liked: true,
      );
      await _expectNoAnnouncement(updates);
      expect(watch.values.last, isEmpty);
    });
    await watch.until((rows) => rows.any((row) => row.id == 'old'));
  });

  test('DAO setRating publishes rating after outer commit', () async {
    final watch = _Watch(database.libraryDao.watchSongRating('old'));
    await watch.until((rating) => rating == null);
    final updates = _rootUpdates(database);
    await database.starSyncDao.transaction(() async {
      await database.starSyncDao.setRating(
        itemId: 'old',
        itemType: 'song',
        rating: 4,
      );
      await _expectNoAnnouncement(updates);
      expect(watch.values.last, isNull);
    });
    await watch.until((rating) => rating == 4);
  });

  test('playlist replacement publishes songs after outer commit', () async {
    final watch = _Watch(database.playlistDao.watchPlaylistSongs('playlist'));
    final updates = _rootUpdates(database);
    await watch.until((rows) => rows.isEmpty);
    await database.transaction(() async {
      await database.playlistDao.replaceHydratedPlaylist(
        PlaylistsTableCompanion.insert(id: 'playlist', name: 'Playlist'),
        [SongsTableCompanion.insert(id: 'old', title: 'Old')],
        [
          PlaylistSongsTableCompanion.insert(
            playlistId: 'playlist',
            songId: 'old',
            sortOrder: 0,
          ),
        ],
      );
      await _expectNoAnnouncement(updates);
      expect(watch.values.last, isEmpty);
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      updates.expand((set) => set).map((update) => update.table),
      contains('playlist_songs'),
    );
    await watch.until((rows) => rows.any((row) => row.id == 'old'));
  });

  test('nested upsertArtists publishes artists after outer commit', () async {
    final watch = _Watch(database.libraryDao.watchArtists());
    await watch.until((rows) => rows.isEmpty);
    final updates = _rootUpdates(database);
    await database.transaction(() async {
      await database.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'artist', name: 'Artist'),
      ]);
      await _expectNoAnnouncement(updates);
      expect(watch.values.last, isEmpty);
    });
    await watch.until((rows) => rows.any((row) => row.id == 'artist'));
  });

  test('all-external upsertArtists alone announces after commit', () async {
    // watchArtists intentionally excludes provisional references.
    final watch = _Watch(database.select(database.artistsTable).watch());
    await watch.until((rows) => rows.isEmpty);
    final updates = _rootUpdates(database);
    database.beforeCommit = () async {
      await _expectNoAnnouncement(updates);
      expect(watch.values.last, isEmpty);
    };
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(id: 'ext-deezer-artist-1', name: 'Remote'),
    ]);
    database.beforeCommit = null;
    await watch.until(
      (rows) => rows.any((row) => row.id == 'ext-deezer-artist-1'),
    );
  });

  test('song remap announces raw queue and playlist references', () async {
    await database.playQueueDao.saveQueue(songIds: ['old']);
    await database.playlistDao.replaceHydratedPlaylist(
      PlaylistsTableCompanion.insert(id: 'playlist', name: 'Playlist'),
      [],
      [
        PlaylistSongsTableCompanion.insert(
          playlistId: 'playlist',
          songId: 'old',
          sortOrder: 0,
        ),
      ],
    );
    final queue = _Watch(database.select(database.playQueueItemsTable).watch());
    final playlist = _Watch(
      database.select(database.playlistSongsTable).watch(),
    );
    final joinedQueue = _Watch(database.playQueueDao.watchQueueItems());
    final joinedPlaylist = _Watch(
      database.playlistDao.watchPlaylistSongs('playlist'),
    );
    await queue.until((rows) => rows.single.songId == 'old');
    await playlist.until((rows) => rows.single.songId == 'old');
    await joinedQueue.until((rows) => rows.single.id == 'old');
    await joinedPlaylist.until((rows) => rows.single.id == 'old');
    final rewrittenTables = <String>{};
    final subscription = database.tableUpdates().listen((updates) {
      rewrittenTables.addAll(
        updates
            .where((update) => update.kind != UpdateKind.delete)
            .map((update) => update.table),
      );
    });
    addTearDown(subscription.cancel);
    await database.songIdentityDao.remapSongIdentity(
      oldSongId: 'old',
      canonicalSongId: 'canonical',
      matchReason: 'test',
    );
    await Future<void>.delayed(Duration.zero);
    // A song deletion's FK cascade happens to invalidate these streams today.
    // The SQL reference rewrites must also announce their own updates.
    expect(
      rewrittenTables,
      containsAll([
        'play_queue_items',
        'playlist_songs',
        'download_queue',
        'play_history',
        'match_flow_songs',
      ]),
    );
    await queue.until((rows) => rows.single.songId == 'canonical');
    await playlist.until((rows) => rows.single.songId == 'canonical');
    await joinedQueue.until((rows) => rows.single.id == 'canonical');
    await joinedPlaylist.until((rows) => rows.single.id == 'canonical');
  });

  for (final type in ['album', 'artist']) {
    test('$type remap refreshes pending annotation references', () async {
      await database.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'old-artist', name: 'Old artist'),
        ArtistsTableCompanion.insert(id: 'new-artist', name: 'New artist'),
      ]);
      await database.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(id: 'old-album', name: 'Old album'),
        AlbumsTableCompanion.insert(id: 'new-album', name: 'New album'),
      ]);
      await database.starSyncDao.queueStarAction(
        itemId: 'old-$type',
        itemType: type,
        action: 'star',
      );
      final watch = _Watch(database.starSyncDao.watchPendingActions());
      await watch.until((rows) => rows.single.itemId == 'old-$type');
      if (type == 'album') {
        await database.songIdentityDao.remapAlbumIdentity(
          oldAlbumId: 'old-album',
          canonicalAlbumId: 'new-album',
          matchReason: 'test',
        );
      } else {
        await database.songIdentityDao.remapArtistIdentity(
          oldArtistId: 'old-artist',
          canonicalArtistId: 'new-artist',
          matchReason: 'test',
        );
      }
      await watch.until((rows) => rows.single.itemId == 'new-$type');
    });
  }

  test('rollback never shows the row and a later commit updates', () async {
    final watch = _Watch(database.libraryDao.watchArtists());
    await watch.until((rows) => rows.isEmpty);
    final updates = _rootUpdates(database);
    final error = StateError('rollback sentinel');
    await expectLater(
      database.transaction(() async {
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(id: 'rolled-back', name: 'Discard'),
        ]);
        await _expectNoAnnouncement(updates);
        throw error;
      }),
      throwsA(same(error)),
    );
    expect(await database.libraryDao.getArtistById('rolled-back'), isNull);
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(id: 'committed', name: 'Keep'),
    ]);
    await watch.until((rows) => rows.any((row) => row.id == 'committed'));
    expect(
      watch.values.expand((rows) => rows).map((row) => row.id),
      isNot(contains('rolled-back')),
    );
  });
}
