import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/file.dart' as files;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_cache_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _SupportDirProvider extends PathProviderPlatform {
  new(this.support);

  final Directory support;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;

  @override
  Future<String?> getTemporaryPath() async => support.path;
}

class _FixedDirectory implements FileSystem {
  new(this.directory);

  final Directory directory;

  @override
  Future<files.File> createFile(String name) async =>
      const LocalFileSystem().file(p.join(directory.path, name));
}

const _bound = Duration(seconds: 5);

CacheObject _object(String key) => CacheObject(
  'https://example.test/$key',
  key: key,
  relativePath: '$key.jpg',
  validTill: DateTime.now().add(const Duration(days: 1)),
);

void main() {
  late Directory support;
  var seq = 0;
  late String name;

  setUpAll(() {
    // The class has no platform check; run it on whichever host runs the tests.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    support = await Directory.systemTemp.createTemp('cover-store-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _SupportDirProvider(support);
    name = 'store_${seq++}';
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await support.delete(recursive: true);
    });
  });

  NavisCacheObjectProvider repo({FileSystem? fileSystem}) =>
      NavisCacheObjectProvider(databaseName: name, fileSystem: fileSystem);
  File dbFile() => File(p.join(support.path, '$name.db'));
  Directory filesDir() => Directory(p.join(support.path, name));

  Future<void> roundTrip(NavisCacheObjectProvider r, [String key = 'a']) async {
    await r.insert(_object(key)).timeout(_bound);
    expect((await r.get(key).timeout(_bound))?.key, key);
  }

  Future<void> seedRow(String key) async {
    final r = repo();
    await r.open().timeout(_bound);
    await r.insert(_object(key)).timeout(_bound);
    await r.close().timeout(_bound);
  }

  Future<void> expectRowSurvives(String key) async {
    final r = repo();
    await r.open().timeout(_bound);
    addTearDown(r.close);
    expect((await r.get(key).timeout(_bound))?.key, key);
  }

  group('D1 failed open', () {
    test('a corrupt index is replaced and the open succeeds', () async {
      await dbFile().writeAsString('this is not a sqlite database' * 50);
      final r = repo();
      await r.open().timeout(_bound);
      addTearDown(r.close);
      await r.insert(_object('a')).timeout(_bound);
      expect((await r.get('a').timeout(_bound))?.key, 'a');
    });

    test('an unrecoverable open falls back to memory, then recovers', () async {
      // A directory where the database file belongs cannot be opened.
      await Directory(dbFile().path).create();
      final r = repo();
      await r.open().timeout(_bound);
      await roundTrip(r);
      await r.close().timeout(_bound);
      await Directory(dbFile().path).delete();
      await r.open().timeout(_bound);
      addTearDown(r.close);
      // The memory index was not persisted; the file index starts empty.
      expect(await r.get('a').timeout(_bound), isNull);
      await roundTrip(r);
    });

    test('lookups on a manager whose index cannot open complete', () async {
      await Directory(dbFile().path).create();
      final manager = CacheManager(Config(name, repo: repo()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await manager.getFileFromCache('k').timeout(_bound), isNull);
      await manager
          .putFile(
            'https://example.test/k',
            Uint8List.fromList([1, 2]),
            key: 'k',
          )
          .timeout(_bound);
      expect(await manager.getFileFromCache('k').timeout(_bound), isNotNull);
      await manager.emptyCache().timeout(_bound);
      expect(await manager.getFileFromCache('k').timeout(_bound), isNull);
      await manager.dispose().timeout(_bound);
    });

    test('a corrupt index on a manager is replaced for lookups', () async {
      await dbFile().writeAsString('this is not a sqlite database' * 50);
      final manager = CacheManager(Config(name, repo: repo()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await manager.getFileFromCache('k').timeout(_bound), isNull);
      await manager
          .putFile(
            'https://example.test/k',
            Uint8List.fromList([1, 2]),
            key: 'k',
          )
          .timeout(_bound);
      await manager.dispose().timeout(_bound);
      await expectRowSurvives('k');
    });

    test(
      'a locked index is left untouched and the next open sees its rows',
      () async {
        await seedRow('a');
        final locker = await databaseFactoryFfi.openDatabase(
          dbFile().path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await locker.execute('PRAGMA locking_mode=EXCLUSIVE');
        await locker.execute('BEGIN EXCLUSIVE');
        final r = repo();
        await r.open().timeout(_bound);
        expect(
          await r.get('a').timeout(_bound),
          isNull,
          reason: 'memory index',
        );
        await r.close().timeout(_bound);
        await locker.execute('ROLLBACK');
        await locker.close();
        await expectRowSurvives('a');
      },
    );

    test(
      'an unreadable index is left untouched and the next open sees its rows',
      () async {
        await seedRow('a');
        await Process.run('chmod', ['000', dbFile().path]);
        addTearDown(() => Process.run('chmod', ['600', dbFile().path]));
        try {
          dbFile().openSync().closeSync();
          markTestSkipped('permissions are not enforced for this user');
          return;
        } on FileSystemException {
          // Unreadable, as intended.
        }
        final r = repo();
        await r.open().timeout(_bound);
        await roundTrip(r, 'b');
        await r.close().timeout(_bound);
        await Process.run('chmod', ['600', dbFile().path]);
        await expectRowSurvives('a');
      },
    );

    test('a corrupt index also removes the orphaned image files', () async {
      final fileSystem = IOFileSystem(name);
      final image = await fileSystem.createFile('a.jpg');
      await image.writeAsBytes([1, 2, 3]);
      expect(image.existsSync(), isTrue);
      await dbFile().writeAsString('this is not a sqlite database' * 50);
      final r = repo(fileSystem: fileSystem);
      await r.open().timeout(_bound);
      addTearDown(r.close);
      expect(image.existsSync(), isFalse);
      expect(filesDir().existsSync(), isFalse);
      // The file system recreates its directory on demand.
      final again = await fileSystem.createFile('b.jpg');
      await again.writeAsBytes([4]);
      expect(again.existsSync(), isTrue);
    });

    test(
      'two repositories recovering one corrupt index share the new file',
      () async {
        await dbFile().writeAsString('this is not a sqlite database' * 50);
        final a = repo();
        final b = repo();
        await Future.wait([a.open(), b.open()]).timeout(_bound);
        addTearDown(a.close);
        addTearDown(b.close);
        await roundTrip(a);
        expect((await b.get('a').timeout(_bound))?.key, 'a');
      },
    );

    test('a transient failure keeps the image files', () async {
      await seedRow('a');
      final fileSystem = IOFileSystem(name);
      final image = await fileSystem.createFile('a.jpg');
      await image.writeAsBytes([1, 2, 3]);
      final locker = await databaseFactoryFfi.openDatabase(
        dbFile().path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await locker.execute('PRAGMA locking_mode=EXCLUSIVE');
      await locker.execute('BEGIN EXCLUSIVE');
      final r = repo(fileSystem: fileSystem);
      await r.open().timeout(_bound);
      await r.close().timeout(_bound);
      await locker.execute('ROLLBACK');
      await locker.close();
      expect(image.existsSync(), isTrue);
    });
  });

  group('D2 close before open completes', () {
    test(
      'open then immediate close does not throw and closes the database',
      () async {
        final r = repo();
        // Registered before close() waits on the same open, so it sees the db.
        final opened = r.open().then((_) => r.db);
        final closed = r.close();
        final database = await opened.timeout(_bound);
        expect(database, isNotNull);
        expect(await closed.timeout(_bound), isTrue);
        expect(database!.isOpen, isFalse);
      },
    );

    test('close twice and close without open are no-ops', () async {
      final r = repo();
      expect(await r.close().timeout(_bound), isFalse);
      await r.open().timeout(_bound);
      final database = r.db!;
      expect(await r.close().timeout(_bound), isTrue);
      expect(database.isOpen, isFalse);
      expect(await r.close().timeout(_bound), isFalse);
    });

    test('open, close, open yields a working database', () async {
      final r = repo();
      await r.open().timeout(_bound);
      await r.close().timeout(_bound);
      await r.open().timeout(_bound);
      addTearDown(r.close);
      await r.insert(_object('a')).timeout(_bound);
      expect((await r.get('a').timeout(_bound))?.key, 'a');
    });

    test('a close racing a re-open leaves the database usable', () async {
      final r = repo();
      await r.open().timeout(_bound);
      final closing = r.close();
      final reopened = r.open();
      await closing.timeout(_bound);
      await reopened.timeout(_bound);
      addTearDown(r.close);
      await r.insert(_object('a')).timeout(_bound);
      expect((await r.get('a').timeout(_bound))?.key, 'a');
    });

    test('two opens need two closes', () async {
      final r = repo();
      await Future.wait([r.open(), r.open()]).timeout(_bound);
      expect(await r.close().timeout(_bound), isFalse);
      await r.insert(_object('a')).timeout(_bound);
      expect(await r.close().timeout(_bound), isTrue);
    });
  });

  group('D3 shared database', () {
    test('A open in flight, B opens, A closes unawaited', () async {
      final a = repo();
      final aOpen = a.open();
      final b = repo();
      final bOpen = b.open();
      unawaited(a.close());
      await Future.wait([aOpen, bOpen]).timeout(_bound);
      addTearDown(b.close);
      await roundTrip(b);
    });

    test('same, with B fully open before A closes', () async {
      final a = repo();
      await a.open().timeout(_bound);
      final b = repo();
      await b.open().timeout(_bound);
      unawaited(a.close());
      addTearDown(b.close);
      await b.insert(_object('a')).timeout(_bound);
      expect((await b.get('a').timeout(_bound))?.key, 'a');
    });

    test(
      'a manager disposed right after creation does not break the next',
      () async {
        final first = repo();
        final firstOpen = first.open();
        unawaited(first.close());
        final second = repo();
        await second.open().timeout(_bound);
        await firstOpen.timeout(_bound);
        addTearDown(second.close);
        await second.insert(_object('a')).timeout(_bound);
        expect((await second.get('a').timeout(_bound))?.key, 'a');
      },
    );
  });

  group('query-time failures', () {
    Future<void> seedMany(int rows) async {
      final r = repo();
      await r.open().timeout(_bound);
      for (var i = 0; i < rows; i++) {
        await r.insert(_object('k$i' * 20)).timeout(_bound);
      }
      await r.close().timeout(_bound);
    }

    Future<void> overwriteAfterFirstPage() async {
      final file = await dbFile().open(mode: FileMode.append);
      final length = await file.length();
      expect(length, greaterThan(8192));
      await file.setPosition(4096);
      await file.writeFrom(List<int>.filled(length - 4096, 0xA5));
      await file.close();
    }

    test('corruption beyond the first page is found at open', () async {
      await seedMany(300);
      await overwriteAfterFirstPage();
      final manager = CacheManager(Config(name, repo: repo()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await manager.getFileFromCache('k').timeout(_bound), isNull);
      await manager
          .putFile('https://example.test/k', Uint8List.fromList([1]), key: 'k')
          .timeout(_bound);
      await manager.emptyCache().timeout(_bound);
      await manager.dispose().timeout(_bound);
    });

    test('corruption that appears while open switches to memory', () async {
      await seedMany(300);
      final r = repo();
      await r.open().timeout(_bound);
      await r.db!.rawQuery('PRAGMA cache_size=0');
      await overwriteAfterFirstPage();
      expect(await r.get('x').timeout(_bound), isNull);
      expect(await r.getAllObjects().timeout(_bound), isEmpty);
      expect(r.isFallback, isTrue);
      await roundTrip(r, 'fresh');
      await r.close().timeout(_bound);
      // The next open finds the damage and starts a new index.
      final again = repo();
      await again.open().timeout(_bound);
      addTearDown(again.close);
      expect(again.isFallback, isFalse);
      expect(await again.getAllObjects().timeout(_bound), isEmpty);
      await roundTrip(again);
    });

    test('lookups after dispose complete', () async {
      final manager = CacheManager(Config(name, repo: repo()));
      await manager
          .putFile('https://example.test/k', Uint8List.fromList([1]), key: 'k')
          .timeout(_bound);
      await manager.dispose().timeout(_bound);
      expect(await manager.getFileFromCache('missing').timeout(_bound), isNull);
      await manager.emptyCache().timeout(_bound);
    });

    test('every query is neutral on a closed repository', () async {
      final r = repo();
      await r.open().timeout(_bound);
      await r.close().timeout(_bound);
      expect(await r.get('a').timeout(_bound), isNull);
      expect(await r.getAllObjects().timeout(_bound), isEmpty);
      expect(await r.getOldObjects(Duration.zero).timeout(_bound), isEmpty);
      expect(await r.getObjectsOverCapacity(0).timeout(_bound), isEmpty);
      expect(await r.delete(1).timeout(_bound), 0);
      expect(await r.deleteAll([1, 2]).timeout(_bound), 0);
      expect(await r.update(_object('a')).timeout(_bound), 0);
      await r.insert(_object('a')).timeout(_bound);
      await r.updateOrInsert(_object('a')).timeout(_bound);
    });

    test(
      'fallback emptyCache also removes the earlier sessions images',
      () async {
        await seedRow('a');
        final fileSystem = IOFileSystem(name);
        final image = await fileSystem.createFile('old.jpg');
        await image.writeAsBytes([1, 2, 3]);
        final locker = await databaseFactoryFfi.openDatabase(
          dbFile().path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await locker.rawQuery('PRAGMA locking_mode=EXCLUSIVE');
        await locker.execute('BEGIN EXCLUSIVE');
        final manager = createCoverArtCacheManager(
          config: Config(
            name,
            repo: repo(fileSystem: fileSystem),
            fileSystem: fileSystem,
          ),
        );
        await manager.emptyCache().timeout(_bound);
        expect(image.existsSync(), isFalse);
        await manager.dispose().timeout(_bound);
        await locker.execute('ROLLBACK');
        await locker.close();
      },
    );

    test(
      'emptyCache removes an unindexed orphan file in a healthy index',
      () async {
        final fileSystem = IOFileSystem(name);
        final image = await fileSystem.createFile('orphan.jpg');
        await image.writeAsBytes([1, 2, 3]);
        final manager = createCoverArtCacheManager(
          config: Config(
            name,
            repo: repo(fileSystem: fileSystem),
            fileSystem: fileSystem,
          ),
        );
        await manager.emptyCache().timeout(_bound);
        expect(image.existsSync(), isFalse);
        await manager.dispose().timeout(_bound);
      },
    );

    test(
      'emptyCache removes the files when the index locks mid-session',
      () async {
        final fileSystem = IOFileSystem(name);
        final manager = createCoverArtCacheManager(
          config: Config(
            name,
            repo: repo(fileSystem: fileSystem),
            fileSystem: fileSystem,
          ),
        );
        await manager
            .putFile(
              'https://example.test/k',
              Uint8List.fromList([1]),
              key: 'k',
            )
            .timeout(_bound);
        final locker = await databaseFactoryFfi.openDatabase(
          dbFile().path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await locker.rawQuery('PRAGMA locking_mode=EXCLUSIVE');
        await locker.execute('BEGIN EXCLUSIVE');
        final files = (await fileSystem.createFile('x')).parent;
        expect(files.listSync(), isNotEmpty);
        await manager.emptyCache().timeout(_bound);
        expect(files.existsSync(), isFalse);
        await manager.dispose().timeout(_bound);
        await locker.execute('ROLLBACK');
        await locker.close();
      },
    );

    test(
      'a reopened repository that opens healthy is not in fallback',
      () async {
        await seedRow('a');
        final locker = await databaseFactoryFfi.openDatabase(
          dbFile().path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await locker.rawQuery('PRAGMA locking_mode=EXCLUSIVE');
        await locker.execute('BEGIN EXCLUSIVE');
        final r = repo();
        await r.open().timeout(_bound);
        expect(r.isFallback, isTrue);
        await r.close().timeout(_bound);
        await locker.execute('ROLLBACK');
        await locker.close();
        await r.open().timeout(_bound);
        addTearDown(r.close);
        expect(r.isFallback, isFalse);
        expect((await r.get('a').timeout(_bound))?.key, 'a');
      },
    );

    test(
      'image files are only deleted from a directory named for the index',
      () async {
        final other = Directory(p.join(support.path, 'elsewhere'))
          ..createSync();
        File(p.join(other.path, 'keep.jpg')).writeAsBytesSync([1]);
        final r = repo(fileSystem: _FixedDirectory(other));
        await r.deleteImageFiles();
        expect(File(p.join(other.path, 'keep.jpg')).existsSync(), isTrue);
      },
    );

    test('only the primary result code decides what is corruption', () {
      expect(NavisCacheObjectProvider.isCorruptResultCode(26), isTrue);
      expect(NavisCacheObjectProvider.isCorruptResultCode(11), isTrue);
      expect(NavisCacheObjectProvider.isCorruptResultCode(779), isTrue);
      expect(NavisCacheObjectProvider.isCorruptResultCode(523), isTrue);
      expect(NavisCacheObjectProvider.isCorruptResultCode(266), isFalse);
      expect(NavisCacheObjectProvider.isCorruptResultCode(14), isFalse);
      expect(NavisCacheObjectProvider.isCorruptResultCode(5), isFalse);
      expect(NavisCacheObjectProvider.isCorruptResultCode(null), isFalse);
    });

    test(
      'a file with a valid SQLite header is never deleted as not-a-db',
      () async {
        final bytes = [
          ...'SQLite format 3\u0000'.codeUnits,
          ...List<int>.filled(4096, 0),
        ];
        await dbFile().writeAsBytes(bytes);
        final r = repo();
        await r.open().timeout(_bound);
        addTearDown(r.close);
        expect(r.isFallback, isTrue);
        expect(dbFile().readAsBytesSync(), bytes);
      },
    );
  });
}
