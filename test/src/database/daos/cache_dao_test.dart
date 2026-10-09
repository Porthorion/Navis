import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  CachedTracksTableCompanion entry(CacheType type) =>
      CachedTracksTableCompanion.insert(
        songId: 'song',
        filePath: '/cache/${type.name}.mp3',
        storageKind: Value(type == CacheType.permanent ? 'androidSaf' : 'file'),
        fileSize: type == CacheType.permanent ? 100 : 10,
        format: 'mp3',
        bitRate: Value(type == CacheType.permanent ? 320 : 192),
        cacheType: type,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime(2026),
      );

  test(
    'rolling registration cannot overwrite an interleaved permanent write',
    () async {
      // The rolling read starts first; the permanent write is queued before
      // the rolling registration can resume from that read and write its row.
      final rolling = database.cacheDao.upsertRollingCachedTrack(
        entry(CacheType.rolling),
      );
      final permanent = database.cacheDao.upsertCachedTrack(
        entry(CacheType.permanent),
      );
      await Future.wait([rolling, permanent]);

      final cached = (await database.cacheDao.getCachedTrack('song'))!;
      expect(cached.cacheType, CacheType.permanent);
      expect(cached.filePath, '/cache/permanent.mp3');
      expect(cached.storageKind, 'androidSaf');
      expect(cached.fileSize, 100);
      expect(cached.bitRate, 320);
    },
  );

  test(
    'rolling registration touches but preserves an existing permanent row',
    () async {
      await database.cacheDao.upsertCachedTrack(entry(CacheType.permanent));
      await database.cacheDao.upsertRollingCachedTrack(
        entry(CacheType.rolling),
      );
      final cached = (await database.cacheDao.getCachedTrack('song'))!;
      expect(cached.cacheType, CacheType.permanent);
      expect(cached.fileSize, 100);
      expect(cached.lastAccessedAt.isAfter(DateTime(2026)), isTrue);
    },
  );

  test('rolling registration replaces a rolling row', () async {
    await database.cacheDao.upsertRollingCachedTrack(entry(CacheType.rolling));
    await database.cacheDao.upsertRollingCachedTrack(
      entry(CacheType.rolling).copyWith(fileSize: const Value(20)),
    );
    final cached = (await database.cacheDao.getCachedTrack('song'))!;
    expect(cached.cacheType, CacheType.rolling);
    expect(cached.fileSize, 20);
  });
}
