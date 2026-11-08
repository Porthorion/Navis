import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;

// Issue #373: on the production WAL executor (writer isolate plus two pooled
// readers), getOrCreateState used to be a write transaction for every call, so
// /v1/sync/status (via _androidBackgroundSyncJson) queued behind the catalog
// apply transaction. An existing row must now be served by a pooled read.
void main() {
  late Directory directory;
  late NavisDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis-i373-');
    database = NavisDatabase.atPath(p.join(directory.path, 'navis.sqlite'));
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  /// Holds a writer transaction open until the returned release is called.
  Future<(Future<void>, void Function())> openWriterTransaction() async {
    final release = Completer<void>();
    final writerOpen = Completer<void>();
    final longTransaction = database.transaction(() async {
      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'a', name: 'Artist'));
      writerOpen.complete();
      await release.future;
    });
    await writerOpen.future;
    return (longTransaction, release.complete);
  }

  test(
    'an existing state row is read without waiting for the writer',
    () async {
      final created = await database.librarySyncDao.getOrCreateState(1);
      final (longTransaction, release) = await openWriterTransaction();

      final state = await database.librarySyncDao
          .getOrCreateState(1)
          .timeout(const Duration(seconds: 2));
      expect(state.serverId, created.serverId);

      release();
      await longTransaction;
    },
  );

  test('a missing state row is still created through the writer', () async {
    final (longTransaction, release) = await openWriterTransaction();

    var stateDone = false;
    final state = database.librarySyncDao
        .getOrCreateState(1)
        .whenComplete(() => stateDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(stateDone, isFalse, reason: 'creation is a write; it queues');

    release();
    await longTransaction;
    expect((await state.timeout(const Duration(seconds: 2))).serverId, 1);
  });

  test('a missing server still throws and creates no row', () async {
    await expectLater(
      database.librarySyncDao.getOrCreateState(99),
      throwsA(isA<StateError>()),
    );
    final rows = await database.select(database.librarySyncStateTable).get();
    expect(rows, isEmpty);
  });
}
