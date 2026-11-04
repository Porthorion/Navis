import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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
  // flutter_test_config.dart installs the FFI factory on macOS only; Linux and
  // Windows use the JSON repository, so the sqflite store is not exercised.
  final skip = Platform.isMacOS ? null : 'sqflite store runs on macOS tests';
  late Directory support;
  var seq = 0;
  late String name;

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

  NavisCacheObjectProvider repo() =>
      NavisCacheObjectProvider(databaseName: name);
  File dbFile() => File(p.join(support.path, '$name.db'));

  group('D1 failed open', skip: skip, () {
    test('a corrupt index is replaced and the open succeeds', () async {
      await dbFile().writeAsString('this is not a sqlite database' * 50);
      final r = repo();
      await r.open().timeout(_bound);
      addTearDown(r.close);
      await r.insert(_object('a')).timeout(_bound);
      expect((await r.get('a').timeout(_bound))?.key, 'a');
    });

    test(
      'an unrecoverable open errors instead of hanging, then retries',
      () async {
        // A directory where the database file belongs cannot be deleted as a file.
        await Directory(dbFile().path).create();
        final r = repo();
        await expectLater(
          r.open().timeout(_bound),
          throwsA(isNot(isA<TimeoutException>())),
        );
        // Later callers get the error too, not a never-completing future.
        await expectLater(
          r.open().timeout(_bound),
          throwsA(isNot(isA<TimeoutException>())),
        );
        await Directory(dbFile().path).delete();
        await r.open().timeout(_bound);
        addTearDown(r.close);
        await r.insert(_object('a')).timeout(_bound);
        expect((await r.get('a').timeout(_bound))?.key, 'a');
      },
    );

    test('emptyCache on a manager whose open failed completes', () async {
      await Directory(dbFile().path).create();
      final manager = CacheManager(Config(name, repo: repo()));
      // The store's own open error is consumed here, never left unhandled.
      await expectLater(
        manager.emptyCache().timeout(_bound),
        throwsA(isNot(isA<TimeoutException>())),
      );
      await manager.dispose().timeout(_bound);
    });
  });

  group('D2 close before open completes', skip: skip, () {
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

  group('D3 shared database', skip: skip, () {
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
