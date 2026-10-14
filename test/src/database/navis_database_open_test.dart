import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
// ignore: experimental_member_use, reason: DriftRemoteException is how drift's isolates report a SQLite error.
import 'package:drift/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'background engines defer while the app has not migrated the schema',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-open-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(p.join(directory.path, 'navis.sqlite'));

      expect(
        NavisDatabase.schemaUpgradePending(file),
        isTrue,
        reason: 'missing',
      );
      expect(file.existsSync(), isFalse, reason: 'the gate never creates it');

      final database = NavisDatabase.atPath(file.path);
      await database.customSelect('SELECT 1').get();
      await database.close();
      expect(NavisDatabase.schemaUpgradePending(file), isFalse);

      final raw = sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 102');
      raw.close();
      expect(NavisDatabase.schemaUpgradePending(file), isTrue, reason: 'older');

      final check = sqlite3.open(file.path);
      addTearDown(check.close);
      expect(check.userVersion, 102, reason: 'the gate never migrates');

      check.execute(
        'PRAGMA user_version = ${NavisDatabase.currentSchemaVersion + 1}',
      );
      expect(NavisDatabase.schemaUpgradePending(file), isTrue, reason: 'newer');

      file.writeAsBytesSync(List.filled(64, 7));
      expect(
        NavisDatabase.schemaUpgradePending(file),
        isTrue,
        reason: 'unreadable',
      );
    },
  );

  Future<String> createCurrentDatabase() async {
    final directory = await Directory.systemTemp.createTemp('navis-open-');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'navis.sqlite');
    final database = NavisDatabase.atPath(path);
    await database.customSelect('SELECT 1').get();
    await database.close();
    return path;
  }

  // Holds the writer lock past the 5 s busy bound of the first open attempt,
  // then releases it while the retry is waiting.
  Database holdWriterLock(String path, {required String before}) {
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    raw.execute(before);
    raw.execute('BEGIN IMMEDIATE');
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 7),
        () => raw.execute('ROLLBACK'),
      ),
    );
    return raw;
  }

  test(
    'a lock held past the busy deadline during open recovers without restart',
    () async {
      final path = await createCurrentDatabase();
      final raw = holdWriterLock(path, before: 'DROP INDEX idx_artists_name');

      final database = NavisDatabase.atPath(path);
      addTearDown(database.close);
      await database.customSelect('SELECT 1').get();
      // A fix that only works once would rethrow the cached error here.
      await database.customSelect('SELECT 1').get();

      expect(
        raw.select(
          "SELECT 1 FROM sqlite_master WHERE name = 'idx_artists_name'",
        ),
        hasLength(1),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('an upgrade interrupted by a lock reruns safely', () async {
    final path = await createCurrentDatabase();
    final raw = holdWriterLock(
      path,
      before:
          "INSERT INTO songs (id, title) VALUES ('kept', 'Kept'); "
          'PRAGMA user_version = 102;',
    );

    final database = NavisDatabase.atPath(path);
    addTearDown(database.close);
    await database.customSelect('SELECT 1').get();

    expect(raw.userVersion, NavisDatabase.currentSchemaVersion);
    expect(
      raw.select("SELECT title FROM songs WHERE id = 'kept'"),
      hasLength(1),
      reason: 'the pre-release reset path must not run',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('only SQLite lock errors count as lock timeouts', () async {
    final path = await createCurrentDatabase();
    final database = NavisDatabase(
      NativeDatabase.createInBackground(File(path)),
    );
    addTearDown(database.close);
    // No busy timeout: the write fails at once, wrapped by the drift isolate.
    await database.customStatement('PRAGMA busy_timeout = 0');
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    raw.execute('BEGIN IMMEDIATE');
    final remote = await database
        .customStatement("INSERT INTO songs (id, title) VALUES ('a', 'A')")
        .then<Object?>((_) => null, onError: (Object error) => error);
    raw.execute('ROLLBACK');

    expect(remote, isA<DriftRemoteException>());
    expect(isDatabaseLockTimeout(remote!), isTrue);
    expect((unwrapRemote(remote) as SqliteException).resultCode, 5);
    expect(
      isDatabaseLockTimeout(
        SqliteException(extendedResultCode: 5, message: 'busy'),
      ),
      isTrue,
    );
    expect(
      isDatabaseLockTimeout(
        SqliteException(extendedResultCode: 6, message: 'locked'),
      ),
      isTrue,
    );
    expect(
      isDatabaseLockTimeout(
        SqliteException(extendedResultCode: 1, message: ''),
      ),
      isFalse,
    );
    expect(isDatabaseLockTimeout(StateError('closed')), isFalse);
  });

  Future<(NavisDatabase, Database)> openWithRawLock() async {
    final path = await createCurrentDatabase();
    final database = NavisDatabase.atPath(path);
    addTearDown(database.close);
    await database.customSelect('SELECT 1').get();
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    raw.execute('BEGIN IMMEDIATE');
    return (database, raw);
  }

  Future<void> insertSong(NavisDatabase database) => database.customStatement(
    "INSERT INTO songs (id, title) VALUES ('waited', 'Waited')",
  );

  test('a write waits while another connection holds the lock', () async {
    final (database, raw) = await openWithRawLock();
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 1),
        () => raw.execute('ROLLBACK'),
      ),
    );
    final stopwatch = Stopwatch()..start();

    await insertSong(database);

    expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 900)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a lock held past the busy bound fails within it', () async {
    final (database, raw) = await openWithRawLock();
    addTearDown(() => raw.execute('ROLLBACK'));
    final stopwatch = Stopwatch()..start();

    final error = await insertSong(database)
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(isDatabaseLockTimeout(error!), isTrue);
    expect(stopwatch.elapsed, greaterThan(const Duration(seconds: 4)));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  // Drops an index so every open attempt must take the write lock (a no-op
  // CREATE INDEX IF NOT EXISTS never would), then holds it for the whole test.
  Database holdWriterLockForever(String path) {
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    raw.execute('DROP INDEX idx_artists_name');
    raw.execute('BEGIN IMMEDIATE');
    return raw;
  }

  Future<Object?> selectOne(NavisDatabase database) => database
      .customSelect('SELECT 1')
      .get()
      .then<Object?>((rows) => rows, onError: (Object error) => error);

  test('a query after close throws and opens no new connection', () async {
    final directory = await Directory.systemTemp.createTemp('navis-open-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(p.join(directory.path, 'navis.sqlite'));

    final database = NavisDatabase.atPath(file.path);
    await database.close();

    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(isA<StateError>()),
    );
    expect(file.existsSync(), isFalse, reason: 'no new connection was opened');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('concurrent queries during the retry delay share one open', () async {
    final path = await createCurrentDatabase();
    holdWriterLockForever(path);

    final database = NavisDatabase.atPath(path);
    addTearDown(database.close);
    final first = selectOne(database);
    // Attempt 1 fails at the 5 s busy bound and the chain sleeps 1 s before
    // its retry; a query issued now must join that same open, not start one.
    await Future<void>.delayed(const Duration(milliseconds: 5600));
    final second = selectOne(database);
    final results = await Future.wait([first, second]);

    expect(isDatabaseLockTimeout(results[0]!), isTrue);
    expect(isDatabaseLockTimeout(results[1]!), isTrue);
    // Both awaiters saw the same open chain fail.
    expect(results[0], same(results[1]));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('closing during the retry delay stops further attempts', () async {
    final path = await createCurrentDatabase();
    holdWriterLockForever(path);

    final database = NavisDatabase.atPath(path);
    final stopwatch = Stopwatch()..start();
    final pending = selectOne(database);
    // Attempt 1 fails at the 5 s busy bound; close inside the 1 s delay.
    await Future<void>.delayed(const Duration(milliseconds: 5600));
    await database.close();

    final error = await pending;

    expect(isDatabaseLockTimeout(error!), isTrue);
    // Attempts 2 and 3 (a 5 s busy bound plus delay each) would run past
    // 18 s; the closed guard rethrows out of the delay instead.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 12)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a non-lock error during migration surfaces and is not retried',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-open-');
      addTearDown(() => directory.delete(recursive: true));
      final valid = await createCurrentDatabase();
      final path = p.join(directory.path, 'navis.sqlite');
      File(path).writeAsBytesSync(List.filled(64, 7));

      final database = NavisDatabase.atPath(path);
      addTearDown(database.close);
      final error = await selectOne(database);

      final cause = unwrapRemote(error!);
      expect(cause, isA<SqliteException>());
      expect((cause as SqliteException).resultCode, 26);
      expect(isDatabaseLockTimeout(error), isFalse);

      // A non-lock failure keeps the delegate, so Drift's cached migration
      // error replays instead of opening the valid database now at the path.
      File(valid).copySync(path);
      final replayed = unwrapRemote((await selectOne(database))!);
      expect((replayed as SqliteException).resultCode, 26);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Object unwrapRemote(Object error) {
  var cause = error;
  while (cause is DriftRemoteException) {
    cause = cause.remoteCause;
  }
  return cause;
}
