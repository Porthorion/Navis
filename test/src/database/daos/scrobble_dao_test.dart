import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('ScrobbleDao', () {
    late NavisDatabase database;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
      ]);
    });

    tearDown(() async {
      await database.close();
    });

    test('enqueue deduplicates by song/submission/session key', () async {
      final now = DateTime.now();
      await database.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'subsonic',
        submission: false,
        sessionKey: 'session-1',
        createdAt: now,
        nextAttemptAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      await database.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'subsonic',
        submission: false,
        sessionKey: 'session-1',
        createdAt: now,
        nextAttemptAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
      );

      final rows = await database.select(database.scrobbleQueueTable).get();
      expect(rows.length, 1);
    }, skip: !sqliteAvailable);

    test('getDueEntries returns only due non-expired rows', () async {
      final now = DateTime.now();
      await database.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'subsonic',
        submission: false,
        sessionKey: 'due',
        createdAt: now.subtract(const Duration(minutes: 2)),
        nextAttemptAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(minutes: 30)),
      );
      await database.scrobbleDao.enqueue(
        songId: 'song-2',
        provider: 'subsonic',
        submission: true,
        sessionKey: 'future',
        createdAt: now,
        nextAttemptAt: now.add(const Duration(minutes: 10)),
        expiresAt: now.add(const Duration(hours: 1)),
      );

      final due = await database.scrobbleDao.getDueEntries(now);
      expect(due.length, 1);
      expect(due.single.sessionKey, 'due');
    }, skip: !sqliteAvailable);

    test('reschedule and pruneExpired update queue correctly', () async {
      final now = DateTime.now();
      await database.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'subsonic',
        submission: true,
        sessionKey: 'retry-me',
        createdAt: now.subtract(const Duration(minutes: 5)),
        nextAttemptAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(minutes: 20)),
      );
      await database.scrobbleDao.enqueue(
        songId: 'song-2',
        provider: 'subsonic',
        submission: false,
        sessionKey: 'expire-me',
        createdAt: now.subtract(const Duration(hours: 3)),
        nextAttemptAt: now.subtract(const Duration(hours: 2)),
        expiresAt: now.subtract(const Duration(minutes: 1)),
      );

      final before = await database.select(database.scrobbleQueueTable).get();
      final retryId = before
          .singleWhere((row) => row.sessionKey == 'retry-me')
          .id;
      await database.scrobbleDao.reschedule(
        id: retryId,
        attempts: 3,
        nextAttemptAt: now.add(const Duration(minutes: 5)),
        lastError: 'timeout',
      );

      await database.scrobbleDao.pruneExpired(now);

      final after = await database.select(database.scrobbleQueueTable).get();
      expect(after.length, 1);
      expect(after.single.sessionKey, 'retry-me');
      expect(after.single.attempts, 3);
      expect(after.single.lastError, 'timeout');
    }, skip: !sqliteAvailable);
  });
}
