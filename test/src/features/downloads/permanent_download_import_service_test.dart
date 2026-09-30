import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('PermanentDownloadImportService', () {
    late NavisDatabase database;
    late Directory root;

    setUp(() async {
      database = createTestDatabase();
      root = await Directory.systemTemp.createTemp('navis_import_');
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Hello Miss Johnson',
          artistName: const Value('Jack Harlow'),
          suffix: const Value('flac'),
        ),
      ]);
    });

    tearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    PermanentDownloadImportService service(String profile) {
      return PermanentDownloadImportService(
        cacheDao: database.cacheDao,
        libraryDao: database.libraryDao,
        readProfileIdentity: () => profile,
      );
    }

    test('reports inaccessible files separately from local-library misses', () {
      const preview = PermanentDownloadImportPreview(
        rootPath: 'content://example/tree/root',
        items: <PermanentDownloadImportItem>[
          PermanentDownloadImportItem(
            relativePath: 'missing.mp3',
            fileSize: 1,
            format: 'mp3',
            disposition: PermanentDownloadImportDisposition.unmatched,
          ),
          PermanentDownloadImportItem(
            relativePath: 'revoked.flac',
            fileSize: 1,
            format: 'flac',
            disposition: PermanentDownloadImportDisposition.inaccessible,
          ),
        ],
      );

      expect(preview.unmatchedCount, 1);
      expect(preview.inaccessibleCount, 1);
      expect(preview.skippedCount, 2);
    });

    test('adopting leaves files untouched and batches cache rows', () async {
      final bytes = <int>[
        ...'fLaC'.codeUnits,
        0x84,
        0,
        0,
        8,
        4,
        0,
        0,
        0,
        0x6e,
        0x61,
        0x76,
        0x69,
        0,
        0,
        0,
        0,
        1,
        2,
        3,
        4,
      ];
      final files = <File>[];
      final songs = <SongsTableCompanion>[];
      for (var i = 0; i < 30; i++) {
        songs.add(
          SongsTableCompanion.insert(
            id: 'batch-$i',
            title: 'Track $i',
            artistName: const Value('Batch Artist'),
            suffix: const Value('flac'),
          ),
        );
      }
      await database.libraryDao.upsertSongs(songs);
      final artist = Directory('${root.path}/Batch Artist')..createSync();
      for (var i = 0; i < 30; i++) {
        files.add(
          File('${artist.path}/Track $i.flac')..writeAsBytesSync(bytes),
        );
      }
      final notifications = <Set<TableUpdate>>[];
      final subscription = database
          .tableUpdates(TableUpdateQuery.onTable(database.cachedTracksTable))
          .listen(notifications.add);
      addTearDown(subscription.cancel);

      final preview = await service('https://example.test|navis').preview(root);
      expect(preview.recognizedCount, 30);
      await service('https://example.test|navis').commit(preview);
      await pumpEventQueue();

      // Adopted files are never rewritten; the folder index is the identity.
      for (final file in files) {
        expect(file.readAsBytesSync(), bytes);
      }
      expect(await database.cacheDao.getPermanentEntries(), hasLength(30));
      expect(notifications, hasLength(1));
    });

    test('matches file names in any script', () async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'arabic-1',
          title: 'حبيبي يا نور العين',
          artistName: const Value('عمرو دياب'),
          suffix: const Value('mp3'),
        ),
        SongsTableCompanion.insert(
          id: 'accented-1',
          title: 'Café del Mar',
          artistName: const Value('Energy 52'),
        ),
      ]);
      final arabic = Directory('${root.path}/عمرو دياب')..createSync();
      File('${arabic.path}/حبيبي يا نور العين.mp3').writeAsBytesSync(<int>[1]);
      final accented = Directory('${root.path}/Energy 52')..createSync();
      File('${accented.path}/Cafe del Mar.mp3').writeAsBytesSync(<int>[1]);

      final preview = await service('https://example.test|navis').preview(root);
      final matched = <String?>{
        for (final item in preview.items)
          if (item.disposition == PermanentDownloadImportDisposition.recognized)
            item.songId,
      };
      expect(matched, containsAll(<String>['arabic-1', 'accented-1']));
    });

    test('adopts a uniquely matched legacy artist/title file', () async {
      final artist = Directory('${root.path}/Jack Harlow')..createSync();
      final file = File('${artist.path}/Hello Miss Johnson.flac')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final preview = await service('https://example.test|navis').preview(root);

      expect(preview.recognizedCount, 1);
      expect(preview.items.single.songId, 'song-1');
      await service('https://example.test|navis').commit(preview);

      final track = await database.cacheDao.getCachedTrack('song-1');
      expect(track?.cacheType, CacheType.permanent);
      expect(track?.filePath, file.path);
      expect(track?.storageKind, 'filesystem');
      expect(
        File('${root.path}/$permanentDownloadManifestFileName').existsSync(),
        isTrue,
      );
    });

    test('preserves an unmatched file without registering it', () async {
      final file = File('${root.path}/Unknown/Elsewhere.flac')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);

      final preview = await service('profile').preview(root);
      final result = await service('profile').commit(preview);

      expect(preview.skippedCount, 1);
      expect(preview.unmatchedCount, 1);
      expect(result.importedCount, 0);
      expect(file.existsSync(), isTrue);
      expect(await database.cacheDao.getPermanentEntries(), isEmpty);
    });

    test('ignores an interrupted identity-tag rewrite copy', () async {
      File('${root.path}/Unknown/Elsewhere.flac.navis-writing')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);

      final preview = await service('profile').preview(root);

      expect(preview.items, isEmpty);
    });

    test('keeps duplicate legacy title and artist matches ambiguous', () async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-2',
          title: 'Hello Miss Johnson',
          artistName: const Value('Jack Harlow'),
          suffix: const Value('flac'),
        ),
      ]);
      final file = File('${root.path}/Jack Harlow/Hello Miss Johnson.flac')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final preview = await service('profile').preview(root);

      expect(
        preview.items.single.disposition,
        PermanentDownloadImportDisposition.ambiguous,
      );
      expect(
        preview.items.single.matchOrigin,
        PermanentDownloadMatchOrigin.ambiguous,
      );
      expect(file.existsSync(), isTrue);
    });

    test('manual-only commit does not re-import recognized items', () async {
      final file = File('${root.path}/Jack Harlow/Hello Miss Johnson.flac')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final preview = await service('profile').preview(root);

      final result = await service('profile').commit(
        preview,
        includeRecognized: false,
      );

      expect(result.importedCount, 0);
      expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      expect(file.existsSync(), isTrue);
    });

    test(
      'adopts an unmatched legacy file after an explicit local mapping',
      () async {
        final file = File('${root.path}/Unknown/Elsewhere.flac')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1, 2, 3]);

        final preview = await service('profile').preview(root);
        final result = await service('profile').commit(
          preview,
          manualSongIds: const <String, String>{
            'Unknown/Elsewhere.flac': 'song-1',
          },
        );

        expect(result.importedCount, 1);
        expect(file.existsSync(), isTrue);
        expect(
          (await database.cacheDao.getCachedTrack('song-1'))?.cacheType,
          CacheType.permanent,
        );
      },
    );

    test('rejects a sidecar record from another profile', () async {
      final artist = Directory('${root.path}/Jack Harlow')..createSync();
      final file = File('${artist.path}/Hello Miss Johnson.flac')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await service('profile-a').recordDownloaded(
        root: root,
        file: file,
        songId: 'song-1',
        format: 'flac',
      );

      final preview = await service('profile-b').preview(root);

      expect(
        preview.items.single.disposition,
        PermanentDownloadImportDisposition.profileMismatch,
      );
      expect(preview.profileMismatchCount, 1);
      expect(file.existsSync(), isTrue);
    });
  });
}
