import 'dart:io';

import 'package:drift/drift.dart';
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
