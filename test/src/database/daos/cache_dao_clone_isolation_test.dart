import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<void> cache(String songId, String filePath, CacheType type) =>
      database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: songId,
          filePath: filePath,
          fileSize: 1,
          format: 'flac',
          cacheType: type,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime(2026),
        ),
      );

  test('forgets only tracks whose files lie outside the clone root', () async {
    const root = '/work/build/diagnostics/run';
    await cache(
      'real-download',
      '/home/me/Downloads/Navis/A/b.flac',
      CacheType.permanent,
    );
    await cache(
      'real-rolling',
      '/home/me/.cache/navis/rolling/c.opus',
      CacheType.rolling,
    );
    await cache(
      'sibling-run',
      '/work/build/diagnostics/run-2/d.flac',
      CacheType.permanent,
    );
    await cache('clone-copy', '$root/cache/e.flac', CacheType.permanent);
    await cache(
      'clone-support',
      '$root/support/audio/permanent/F/g.flac',
      CacheType.permanent,
    );
    await cache(
      'android-tree',
      'content://com.android.externalstorage.documents/tree/x',
      CacheType.permanent,
    );

    final forgotten = await database.cacheDao.forgetEntriesOutside(root);

    expect(forgotten, 3);
    final kept = (await database.select(database.cachedTracksTable).get())
        .map((row) => row.songId)
        .toSet();
    expect(kept, {'clone-copy', 'clone-support', 'android-tree'});
  });

  test('nothing to forget leaves the table unchanged', () async {
    await cache('clone-copy', '/run/cache/e.flac', CacheType.permanent);
    expect(await database.cacheDao.forgetEntriesOutside('/run'), 0);
    expect(
      await database.select(database.cachedTracksTable).get(),
      hasLength(1),
    );
  });
}
