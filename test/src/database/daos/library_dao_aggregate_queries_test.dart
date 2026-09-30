import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() async {
    database = createTestDatabase();
    await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(id: 'a1', name: 'One'),
      AlbumsTableCompanion.insert(id: 'a2', name: 'Two'),
      AlbumsTableCompanion.insert(id: 'a3', name: 'Three'),
    ]);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (var i = 0; i < 4; i++)
        SongsTableCompanion.insert(
          id: 'a1-$i',
          title: 'a1 $i',
          albumId: const Value('a1'),
          starred: Value(i == 0 ? DateTime(2026) : null),
        ),
      for (var i = 0; i < 2; i++)
        SongsTableCompanion.insert(
          id: 'a2-$i',
          title: 'a2 $i',
          albumId: const Value('a2'),
        ),
      SongsTableCompanion.insert(
        id: 'a3-0',
        title: 'a3 0',
        albumId: const Value('a3'),
      ),
    ]);
  });

  tearDown(() => database.close());

  Future<void> cache(String songId, CacheType type) =>
      database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: songId,
          filePath: '/tmp/$songId',
          fileSize: 1,
          format: 'mp3',
          cacheType: type,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime(2026),
        ),
      );

  test('album download summaries cover only albums with activity', () async {
    await cache('a1-0', CacheType.permanent);
    await cache('a1-1', CacheType.permanent);
    await cache('a1-2', CacheType.rolling);
    await database
        .into(database.downloadQueueTable)
        .insert(
          DownloadQueueTableCompanion.insert(
            songId: const Value('a1-3'),
            status: DownloadStatus.downloading,
            progress: const Value(0.5),
            addedAt: DateTime(2026),
          ),
        );
    await cache('a2-0', CacheType.permanent);
    await cache('a2-1', CacheType.permanent);

    final states = {
      for (final summary
          in await database.libraryDao.watchAlbumDownloadSummaries().first)
        summary.albumId: albumTileDownloadStateFromSummary(summary),
    };

    expect(states.keys, unorderedEquals(<String>['a1', 'a2']));
    final a1 = states['a1']!;
    expect(a1.fullyDownloaded, isFalse);
    expect(a1.downloadedTrackCount, 2);
    expect(a1.totalTrackCount, 4);
    expect(a1.queued, isTrue);
    expect(a1.progress, closeTo(2.5 / 4, 1e-9));
    expect(states['a2']!.fullyDownloaded, isTrue);
  });

  test('radio availability follows liked and downloaded filters', () async {
    Future<bool> has({bool liked = false, bool downloaded = false}) => database
        .libraryDao
        .watchHasRadioCandidate(likedOnly: liked, downloadedOnly: downloaded)
        .first;

    expect(await has(), isTrue);
    expect(await has(liked: true), isTrue);
    expect(await has(downloaded: true), isFalse);

    await cache('a2-0', CacheType.permanent);
    expect(await has(downloaded: true), isTrue);
    expect(await has(liked: true, downloaded: true), isFalse);
  });
}
