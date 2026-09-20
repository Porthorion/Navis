import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/sync_write_fence.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../helpers/test_database.dart';

void main() {
  late Directory directory;
  late NavisDatabase database;
  late Database otherConnection;
  late DateTime now;
  late SyncWriteFence fence;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-sync-fence-');
    final file = File('${directory.path}/fixture.sqlite');
    database = createTestDatabase(file: file);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    now = DateTime.utc(2026, 9, 19);
    await database.librarySyncDao.acquireExecutionLease(
      serverId: 1,
      ownerToken: 'first-owner',
      ownerKind: 'foreground',
      now: now,
      ttl: const Duration(minutes: 1),
    );
    otherConnection = sqlite3.open(file.path);
    fence = SyncWriteFence(
      serverId: 1,
      ownerToken: 'first-owner',
      now: () => now,
    );
  });

  tearDown(() async {
    otherConnection.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('owned standalone and batched writes commit', () async {
    await fence.run(() async {
      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'a', name: 'Artist'));
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's', title: 'Song'),
      ]);
    });
    expect((await database.libraryDao.getSongById('s'))?.title, 'Song');
  });

  test(
    'a replaced owner cannot write catalog, candidate, or checkpoint data',
    () async {
      otherConnection.execute(
        "UPDATE library_sync_execution_lease SET owner_token = 'second-owner'",
      );
      await expectLater(
        fence.run(
          () => database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 'stale', title: 'Stale'),
          ]),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      await expectLater(
        fence.run(
          () => database.customStatement(
            "INSERT INTO library_sync_candidate_artists (server_id, generation, id, name) VALUES (1, 2, 'stale', 'Stale')",
          ),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      await expectLater(
        fence.run(
          () => database.librarySyncDao.writeState(
            const LibrarySyncStateTableCompanion(
              serverId: Value(1),
              currentGeneration: Value(99),
            ),
          ),
        ),
        throwsA(isA<SyncLeaseLostException>()),
      );
      expect(await database.libraryDao.getSongById('stale'), isNull);
      expect(
        (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
        0,
      );
      expect(
        (await database.librarySyncDao.getExecutionLease(1))?.ownerToken,
        'second-owner',
      );
    },
  );

  test('expiry before outer commit rolls back nested writes', () async {
    await expectLater(
      fence.run(
        () => database.transaction(() async {
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(id: 's', title: 'Song'),
          ]);
          await database.librarySyncDao.writeState(
            const LibrarySyncStateTableCompanion(
              serverId: Value(1),
              currentGeneration: Value(2),
            ),
          );
          now = now.add(const Duration(minutes: 2));
        }),
      ),
      throwsA(isA<SyncLeaseLostException>()),
    );
    expect(await database.libraryDao.getSongById('s'), isNull);
    expect(
      (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
      0,
    );
  });

  test(
    'unrelated user edits remain available outside the sync scope',
    () async {
      otherConnection.execute(
        "UPDATE library_sync_execution_lease SET owner_token = 'second-owner'",
      );
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'local', title: 'Local edit'),
      ]);
      expect(
        (await database.libraryDao.getSongById('local'))?.title,
        'Local edit',
      );
    },
  );
}
