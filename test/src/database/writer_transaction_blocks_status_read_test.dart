import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;

// Issue #373: on the production WAL executor (writer isolate plus two pooled
// readers), a plain read keeps moving while a long writer transaction is open,
// but getOrCreateState is itself a write transaction and queues behind it.
// /v1/sync/status calls it (via _androidBackgroundSyncJson), so the route
// waits for the whole catalog apply transaction; the read-only DB canary
// does not.
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
    await database.librarySyncDao.getOrCreateState(1);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('getOrCreateState waits for an open writer transaction; '
      'pooled reads do not', () async {
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

    final read = database.libraryDao.countArtists();
    var stateDone = false;
    final state = database.librarySyncDao
        .getOrCreateState(1)
        .whenComplete(() => stateDone = true);

    await read.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(stateDone, isFalse, reason: 'state read should be queued');

    release.complete();
    await longTransaction;
    await state.timeout(const Duration(seconds: 2));
    expect(stateDone, isTrue);
  });
}
