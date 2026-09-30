import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/file_utils.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('navis_prune_');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  group('pruneEmptyParentDirectories', () {
    test('removes empty folders up to, but not including, the root', () async {
      final root = Directory('${sandbox.path}/root')..createSync();
      final leaf = Directory('${root.path}/Artist/Album')
        ..createSync(recursive: true);

      await pruneEmptyParentDirectories(
        startDirectoryPath: leaf.path,
        stopAtDirectoryPath: root.path,
      );

      expect(root.existsSync(), isTrue);
      expect(Directory('${root.path}/Artist').existsSync(), isFalse);
    });

    test('never touches folders outside the root', () async {
      final root = Directory('${sandbox.path}/root')..createSync();
      final outside = Directory('${sandbox.path}/elsewhere/empty')
        ..createSync(recursive: true);

      await pruneEmptyParentDirectories(
        startDirectoryPath: outside.path,
        stopAtDirectoryPath: root.path,
      );

      expect(outside.existsSync(), isTrue);
      expect(sandbox.existsSync(), isTrue);
    });

    test('stops at the first folder that still has content', () async {
      final root = Directory('${sandbox.path}/root')..createSync();
      final artist = Directory('${root.path}/Artist')..createSync();
      File('${artist.path}/cover.jpg').writeAsBytesSync(<int>[1]);
      final album = Directory('${artist.path}/Album')..createSync();

      await pruneEmptyParentDirectories(
        startDirectoryPath: album.path,
        stopAtDirectoryPath: root.path,
      );

      expect(album.existsSync(), isFalse);
      expect(artist.existsSync(), isTrue);
    });

    test('a missing start folder is not an error', () async {
      final root = Directory('${sandbox.path}/root')..createSync();

      await pruneEmptyParentDirectories(
        startDirectoryPath: '${root.path}/gone/already',
        stopAtDirectoryPath: root.path,
      );

      expect(root.existsSync(), isTrue);
    });
  });
}
