import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
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
        final opened = r.open();
        final closed = r.close();
        await opened.timeout(_bound);
        expect(await closed.timeout(_bound), isTrue);
        expect(r.db?.isOpen ?? false, isFalse);
      },
    );

    test('close twice and close without open are no-ops', () async {
      final r = repo();
      expect(await r.close().timeout(_bound), isFalse);
      await r.open().timeout(_bound);
      expect(await r.close().timeout(_bound), isTrue);
      expect(await r.close().timeout(_bound), isFalse);
      expect(r.db?.isOpen ?? false, isFalse);
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
    test('a new repository survives the old one closing unawaited', () async {
      final a = repo();
      await a.open().timeout(_bound);
      final b = repo();
      final opening = b.open();
      unawaited(a.close());
      await opening.timeout(_bound);
      addTearDown(b.close);
      await b.insert(_object('a')).timeout(_bound);
      expect((await b.get('a').timeout(_bound))?.key, 'a');
    });

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
}
