import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/database_location.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_database.dart';

const _oldUuid = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
const _newUuid = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';

void main() {
  late Directory root;
  late String oldHome;
  late String newHome;
  late NavisDatabase database;

  String containers(String uuid) =>
      p.join(root.path, 'Containers', 'Data', 'Application', uuid);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('navis_rebase_');
    oldHome = containers(_oldUuid);
    newHome = containers(_newUuid);
    // The old container is gone; the new one holds the moved files.
    for (final relative in ['Documents/Downloads/a.mp3', 'tmp/r.mp3']) {
      final file = File(p.join(newHome, relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(128, 7));
    }
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<void> seed(String songId, String path, CacheType type) =>
      database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: songId,
          filePath: path,
          fileSize: 128,
          format: 'mp3',
          cacheType: type,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime(2026),
        ),
      );

  Future<String> pathOf(String songId) async =>
      (await database.cacheDao.getCachedTrack(songId))!.filePath;

  test(
    'rows under an old container are rebased and survive both prunes',
    () async {
      await seed(
        'perm',
        p.join(oldHome, 'Documents/Downloads/a.mp3'),
        CacheType.permanent,
      );
      await seed('roll', p.join(oldHome, 'tmp/r.mp3'), CacheType.rolling);
      await seed(
        'current',
        p.join(newHome, 'Documents/Downloads/a.mp3'),
        CacheType.permanent,
      );
      await seed('plain', '/not/a/container/x.mp3', CacheType.permanent);

      expect(await database.cacheDao.rebaseContainerPaths(newHome), 2);

      expect(
        await pathOf('perm'),
        p.join(newHome, 'Documents/Downloads/a.mp3'),
      );
      expect(await pathOf('roll'), p.join(newHome, 'tmp/r.mp3'));
      expect(
        await pathOf('current'),
        p.join(newHome, 'Documents/Downloads/a.mp3'),
      );
      expect(await pathOf('plain'), '/not/a/container/x.mp3');

      final manager = RollingCacheManager(cacheDao: database.cacheDao);
      await manager.pruneMissingFiles();
      await manager.pruneMissingPermanentFiles();
      expect(await database.cacheDao.getCachedTrack('perm'), isNotNull);
      expect(await database.cacheDao.getCachedTrack('roll'), isNotNull);
      expect(await database.cacheDao.getCachedTrack('current'), isNotNull);
      // Unrelated stale rows are still pruned as before.
      expect(await database.cacheDao.getCachedTrack('plain'), isNull);

      // Nothing differs now: a second pass changes nothing.
      expect(await database.cacheDao.rebaseContainerPaths(newHome), 0);
    },
  );

  test('download queue finish journals are rebased too', () async {
    final journal = jsonEncode({
      'phase': 'finishing',
      'path': p.join(oldHome, 'Documents/Downloads/a.mp3'),
      'partPath': p.join(oldHome, 'Documents/Downloads/a.mp3.navis-part'),
      'size': 128,
    });
    final transferring = jsonEncode({
      'phase': 'transferring',
      'partPath': '/not/a/container/a.navis-part',
    });
    final queue = database.downloadQueueDao;
    for (final entry in {
      's1': journal,
      's2': transferring,
      's3': null,
    }.entries) {
      await queue.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: Value(entry.key),
          status: DownloadStatus.queued,
          addedAt: DateTime(2026),
          finishJournal: Value(entry.value),
        ),
      );
    }

    await database.cacheDao.rebaseContainerPaths(newHome);

    final items = {
      for (final item in await queue.watchQueue().first) item.songId: item,
    };
    final rebased =
        jsonDecode(items['s1']!.finishJournal!) as Map<String, dynamic>;
    expect(rebased['path'], p.join(newHome, 'Documents/Downloads/a.mp3'));
    expect(
      rebased['partPath'],
      p.join(newHome, 'Documents/Downloads/a.mp3.navis-part'),
    );
    expect(rebased['phase'], 'finishing');
    expect(rebased['size'], 128);
    expect(items['s2']!.finishJournal, transferring);
    expect(items['s3']!.finishJournal, isNull);
  });

  test('a home that is not an app container changes nothing', () async {
    await seed(
      'perm',
      p.join(oldHome, 'Documents/Downloads/a.mp3'),
      CacheType.permanent,
    );
    expect(
      await database.cacheDao.rebaseContainerPaths('/tmp/diagnostics-root'),
      0,
    );
    expect(await pathOf('perm'), p.join(oldHome, 'Documents/Downloads/a.mp3'));
  });

  test('opening the database rebases before any consumer reads', () async {
    final file = File(p.join(root.path, 'navis.sqlite'));
    final first = createTestDatabase(file: file);
    await first.cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: 'perm',
        filePath: p.join(oldHome, 'Documents/Downloads/a.mp3'),
        fileSize: 128,
        format: 'mp3',
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime(2026),
      ),
    );
    await first.close();

    final previous = NavisDatabase.containerHomeReader;
    NavisDatabase.containerHomeReader = () async => newHome;
    addTearDown(() => NavisDatabase.containerHomeReader = previous);
    final reopened = createTestDatabase(file: file);
    addTearDown(reopened.close);
    // The very first query already sees the rebased path.
    expect(
      (await reopened.cacheDao.getCachedTrack('perm'))!.filePath,
      p.join(newHome, 'Documents/Downloads/a.mp3'),
    );
  });

  test('iosContainerHome is the parent of Documents on iOS only', () async {
    Future<Directory> documents() async =>
        Directory(p.join(newHome, 'Documents'));
    expect(
      await iosContainerHome(isIOS: true, readDocuments: documents),
      newHome,
    );
    expect(
      await iosContainerHome(isIOS: false, readDocuments: documents),
      isNull,
    );
  });
}
