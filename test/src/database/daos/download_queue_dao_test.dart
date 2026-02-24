import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import '../../../helpers/test_database.dart';

void main() {
  group('DownloadQueueDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'enqueue inserts a download queue item',
      () async {
        // Insert a song first (FK requirement).
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        final dao = database.downloadQueueDao;
        final id = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        expect(id, greaterThan(0));

        final items = await dao.watchQueue().first;
        expect(items, hasLength(1));
        expect(items.first.songId, 'song-1');
        expect(items.first.status, DownloadStatus.queued);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'findBySongId returns the item if present',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        final dao = database.downloadQueueDao;
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        final found = await dao.findBySongId('song-1');
        expect(found, isNotNull);
        expect(found!.songId, 'song-1');

        final notFound = await dao.findBySongId('does-not-exist');
        expect(notFound, isNull);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'getQueuedItems returns only items with queued status',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
          SongsTableCompanion.insert(id: 'song-3', title: 'Song 3'),
        ]);

        final dao = database.downloadQueueDao;
        final id1 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-2'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 2),
          ),
        );
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-3'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 3),
          ),
        );

        // Mark song-1 as downloading.
        await dao.updateStatus(id1, DownloadStatus.downloading);

        final queued = await dao.getQueuedItems();
        expect(queued, hasLength(2));
        expect(queued.map((i) => i.songId), containsAll(['song-2', 'song-3']));
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'requeueStuckDownloads resets downloading items to queued',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
        ]);

        final dao = database.downloadQueueDao;
        final id1 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        final id2 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-2'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 2),
          ),
        );

        // Simulate app kill — both stuck in downloading.
        await dao.updateStatus(id1, DownloadStatus.downloading);
        await dao.updateStatus(id2, DownloadStatus.downloading);
        await dao.updateProgress(id1, 0.5);

        // Recover.
        await dao.requeueStuckDownloads();

        final items = await dao.watchQueue().first;
        for (final item in items) {
          expect(item.status, DownloadStatus.queued);
          expect(item.progress, 0);
        }
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'retryAllFailed resets failed items to queued',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
        ]);

        final dao = database.downloadQueueDao;
        final id1 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        final id2 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-2'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 2),
          ),
        );

        await dao.updateStatus(id1, DownloadStatus.failed);
        await dao.updateStatus(id2, DownloadStatus.failed);

        await dao.retryAllFailed();

        final items = await dao.watchQueue().first;
        for (final item in items) {
          expect(item.status, DownloadStatus.queued);
          expect(item.progress, 0);
        }
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'updateProgress updates the progress value',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        final dao = database.downloadQueueDao;
        final id = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await dao.updateProgress(id, 0.75);

        final items = await dao.watchQueue().first;
        expect(items.first.progress, closeTo(0.75, 0.001));
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'remove deletes a single queue item',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
        ]);

        final dao = database.downloadQueueDao;
        final id1 = await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-2'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 2),
          ),
        );

        await dao.remove(id1);

        final items = await dao.watchQueue().first;
        expect(items, hasLength(1));
        expect(items.first.songId, 'song-2');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'clearQueue removes all items',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
        ]);

        final dao = database.downloadQueueDao;
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        await dao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-2'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 2),
          ),
        );

        await dao.clearQueue();

        final items = await dao.watchQueue().first;
        expect(items, isEmpty);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );
  });
}
