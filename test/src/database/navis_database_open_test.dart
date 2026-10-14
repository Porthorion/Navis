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

  // Holds the writer lock until the first attempts have failed, then releases
  // it while a retry waits. The bundled SQLite gives up on busy_timeout almost
  // at once, so attempts run at about 0 s, 1 s and 3 s.
  Database holdWriterLock(String path, {required String before}) {
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    raw.execute(before);
    raw.execute('BEGIN IMMEDIATE');
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 2),
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
}
