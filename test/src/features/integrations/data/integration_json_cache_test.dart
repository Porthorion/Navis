import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';

class _MockDirectory extends Mock implements Directory;

class _MockFile extends Mock implements File;

void main() {
  late Directory root;
  late DateTime now;
  late IntegrationJsonCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('integration_json_cache_');
    now = DateTime.utc(2026, 10, 5, 12);
    cache = IntegrationJsonCache(
      readRootDirectory: () async => root,
      now: () => now,
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('root initialization retries after a transient failure', () async {
    var attempts = 0;
    final retrying = IntegrationJsonCache(
      readRootDirectory: () async {
        if (++attempts == 1) throw const FileSystemException('unavailable');
        return root;
      },
    );
    await Future.wait([
      retrying.read('ns', 'first'),
      retrying.read('ns', 'second'),
    ]);
    expect(attempts, 1, reason: 'concurrent callers share initialization');
    await retrying.write('ns', 'key', 42, ttl: const Duration(days: 1));
    expect(attempts, 2);
    expect((await retrying.read('ns', 'key'))?.value, 42);
  });

  test('legacy sweep continues after an entry cannot be deleted', () async {
    final blocked = _MockFile();
    when(() => blocked.path)
        .thenReturn(p.join(root.path, 'lastfm_top_0000000000000000.json'));
    when(blocked.delete).thenThrow(const FileSystemException('delete refused'));
    final removable = File(
      p.join(root.path, 'lastfm_top_1111111111111111.json'),
    );
    await removable.writeAsString('{}');
    final directory = _MockDirectory();
    when(() => directory.path).thenReturn(root.path);
    when(directory.exists).thenAnswer((_) async => true);
    when(() => directory.list(followLinks: false)).thenAnswer(
      (_) => Stream<FileSystemEntity>.fromIterable([blocked, removable]),
    );
    final sweeping = IntegrationJsonCache(
      readRootDirectory: () async => directory,
    );
    await sweeping.read('ns', 'missing');
    verify(blocked.delete).called(1);
    expect(removable.existsSync(), isFalse);
    await sweeping.write('ns', 'key', 42, ttl: const Duration(days: 1));
    expect((await sweeping.read('ns', 'key'))?.value, 42);
  });

  test('sweeps only legacy root files once', () async {
    final legacy = File('${root.path}/lastfm_top_0123456789abcdef.json');
    await legacy.writeAsString('{}');
    final keep = [
      'lastfm_top_0123456789abcdeg.json',
      'lastfm_top_123.json',
      'lastfm_top_0123456789ABCDEF.json',
      'other.json',
    ];
    for (final name in keep) {
      await File('${root.path}/$name').writeAsString('{}');
    }
    final nested = Directory('${root.path}/nested');
    await nested.create();
    final nestedFile = File('${nested.path}/lastfm_top_0123456789abcdef.json');
    await nestedFile.writeAsString('{}');
    final matchingDirectory = Directory(
      '${root.path}/lastfm_top_fedcba9876543210.json',
    );
    await matchingDirectory.create();
    await cache.read('ns', 'missing');
    expect(legacy.existsSync(), isFalse);
    for (final name in keep) {
      expect(File('${root.path}/$name').existsSync(), isTrue);
    }
    expect(nestedFile.existsSync(), isTrue);
    expect(matchingDirectory.existsSync(), isTrue);
    await legacy.writeAsString('{}');
    await cache.read('ns', 'missing');
    expect(legacy.existsSync(), isTrue, reason: 'sweep runs once per cache');
  });

  test('a value reads back until its time to live ends', () async {
    await cache.write('deezer.artist-id', 'queen', <String, Object?>{
      'id': 412,
    }, ttl: const Duration(days: 30));

    now = now.add(const Duration(days: 29, hours: 23));
    final hit = await cache.read('deezer.artist-id', 'queen');
    expect(hit?.value, <String, Object?>{'id': 412});
    expect(hit?.storedAt, DateTime.utc(2026, 10, 5, 12));

    now = now.add(const Duration(hours: 1));
    expect(await cache.read('deezer.artist-id', 'queen'), isNull);
  });

  test('entries of one namespace keep their own lifetimes', () async {
    await cache.write('ns', 'found', 1, ttl: const Duration(days: 30));
    await cache.write('ns', 'missing', null, ttl: const Duration(days: 7));

    now = now.add(const Duration(days: 8));
    expect((await cache.read('ns', 'found'))?.value, 1);
    expect(await cache.read('ns', 'missing'), isNull);
  });

  test('a cached null is a hit, an absent key is not', () async {
    await cache.write('ns', 'not-found', null, ttl: const Duration(days: 7));

    final hit = await cache.read('ns', 'not-found');
    expect(hit, isNotNull);
    expect(hit!.value, isNull);
    expect(await cache.read('ns', 'other'), isNull);
  });

  test('namespaces are separate directories under the root', () async {
    await cache.write('a', 'key', 'from a', ttl: const Duration(hours: 1));
    await cache.write('b', 'key', 'from b', ttl: const Duration(hours: 1));

    expect((await cache.read('a', 'key'))?.value, 'from a');
    expect((await cache.read('b', 'key'))?.value, 'from b');
    expect(
      Directory('${root.path}/${IntegrationJsonCache.directoryName}/a')
          .existsSync(),
      isTrue,
    );

    await cache.clearNamespace('a');
    expect(await cache.read('a', 'key'), isNull);
    expect((await cache.read('b', 'key'))?.value, 'from b');
  });

  test('remove deletes one entry', () async {
    await cache.write('ns', 'one', 1, ttl: const Duration(hours: 1));
    await cache.write('ns', 'two', 2, ttl: const Duration(hours: 1));

    await cache.remove('ns', 'one');

    expect(await cache.read('ns', 'one'), isNull);
    expect((await cache.read('ns', 'two'))?.value, 2);
  });

  test('an entry stored under another key reads as a miss', () async {
    await cache.write('ns', 'key', 'value', ttl: const Duration(hours: 1));
    final file = Directory(
      '${root.path}/${IntegrationJsonCache.directoryName}/ns',
    ).listSync().whereType<File>().single;
    file.writeAsStringSync(
      file.readAsStringSync().replaceFirst('"key":"key"', '"key":"other"'),
    );

    expect(await cache.read('ns', 'key'), isNull);
  });

  test('an unreadable file reads as a miss and is replaced on write', () async {
    await cache.write('ns', 'key', 'value', ttl: const Duration(hours: 1));
    final file = Directory(
      '${root.path}/${IntegrationJsonCache.directoryName}/ns',
    ).listSync().whereType<File>().single;
    file.writeAsStringSync('{not json');

    expect(await cache.read('ns', 'key'), isNull);
    await cache.write('ns', 'key', 'fresh', ttl: const Duration(hours: 1));
    expect((await cache.read('ns', 'key'))?.value, 'fresh');
  });

  test('a namespace that could leave the cache directory is refused', () async {
    await cache.write(
      '../escape',
      'key',
      'value',
      ttl: const Duration(days: 1),
    );

    expect(await cache.read('../escape', 'key'), isNull);
    expect(Directory('${root.path}/escape').existsSync(), isFalse);
  });
}
