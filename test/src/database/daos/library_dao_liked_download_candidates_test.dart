import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  SongsTableCompanion song(String id, {String? albumId, bool liked = false}) =>
      SongsTableCompanion.insert(
        id: id,
        title: id,
        albumId: Value(albumId),
        starred: liked ? Value(DateTime(2026)) : const Value.absent(),
      );

  test('liked songs and liked-album songs count once; downloaded, queued and '
      'deleted songs are left out', () async {
    final dao = database.libraryDao;
    await dao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'liked-album',
        name: 'Liked',
        starred: Value(DateTime(2026)),
      ),
      AlbumsTableCompanion.insert(id: 'plain-album', name: 'Plain'),
    ]);
    await dao.upsertSongs(<SongsTableCompanion>[
      song('liked-only', liked: true),
      song('both', albumId: 'liked-album', liked: true),
      song('album-only', albumId: 'liked-album'),
      song('unrelated', albumId: 'plain-album'),
      song('downloaded', liked: true),
      song('queued', liked: true),
      song('failed-before', liked: true),
      song('deleted', liked: true),
      song('album-deleted', albumId: 'liked-album'),
    ]);
    // Upserts clear the marker, so set it directly.
    await (database.update(database.songsTable)
          ..where((t) => t.id.isIn(<String>['deleted', 'album-deleted'])))
        .write(SongsTableCompanion(serverDeletedAt: Value(DateTime(2026))));
    await database.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: 'downloaded',
        filePath: '/fake/downloaded.mp3',
        fileSize: 1,
        format: 'mp3',
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime(2026),
      ),
    );
    for (final (id, status) in <(String, DownloadStatus)>[
      ('queued', DownloadStatus.downloading),
      ('failed-before', DownloadStatus.failed),
    ]) {
      await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: Value(id),
          status: status,
          addedAt: DateTime(2026),
        ),
      );
    }

    final ids = (await dao.getLikedDownloadCandidates()).map((s) => s.id);
    // A failed row is retried by the dispatcher, so it still counts.
    expect(
      ids,
      unorderedEquals(<String>[
        'liked-only',
        'both',
        'album-only',
        'failed-before',
      ]),
    );
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');
}
