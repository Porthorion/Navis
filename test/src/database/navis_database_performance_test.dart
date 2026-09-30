import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'file databases use the performance PRAGMAs and reverse indexes',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-db-perf-');
      final database = NavisDatabase.atPath(
        p.join(directory.path, 'navis.sqlite'),
      );
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });

      Future<Object?> pragma(String name) async =>
          (await database.customSelect('PRAGMA $name').getSingle())
              .data
              .values
              .first;

      expect(await pragma('journal_mode'), 'wal');
      // 1 = NORMAL.
      expect(await pragma('synchronous'), 1);
      expect(await pragma('cache_size'), -8192);
      // 2 = MEMORY.
      expect(await pragma('temp_store'), 2);

      final indexes =
          (await database
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'index'",
                  )
                  .get())
              .map((row) => row.read<String>('name'))
              .toSet();
      expect(
        indexes,
        containsAll(<String>[
          'idx_songs_artist',
          'idx_songs_starred',
          'idx_play_queue_items_song',
          'idx_playlist_songs_song',
        ]),
      );

      await database.runDeferredMaintenance();
    },
  );
}
