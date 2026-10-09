import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/database_location.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  File oldFile(String suffix) =>
      File(p.join(documents.path, 'navis.sqlite.sqlite$suffix'));
  File newFile(String suffix) =>
      File(p.join(support.path, 'navis.sqlite.sqlite$suffix'));
  Future<File> resolve({
    bool desktop = true,
    Future<File> Function(File, String)? rename,
    Future<File> Function(File, String)? copy,
  }) => resolveDatabaseFile(
    desktop: desktop,
    readApplicationDocumentsDirectory: () async => documents,
    readApplicationSupportDirectory: () async => support,
    renameFile: rename,
    copyFile: copy,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('navis-db-location-');
    documents = await Directory(p.join(root.path, 'documents')).create();
    support = Directory(p.join(root.path, 'support'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'fresh desktop install selects support and creates its directory',
    () async {
      expect((await resolve()).path, newFile('').path);
      expect(support.existsSync(), isTrue);
      expect(newFile('').existsSync(), isFalse);
    },
  );
  test('mobile retains documents without reading support', () async {
    final file = await resolveDatabaseFile(
      desktop: false,
      readApplicationDocumentsDirectory: () async => documents,
      readApplicationSupportDirectory: () async => throw StateError('unused'),
    );
    expect(file.path, oldFile('').path);
  });
  for (final copyFallback in [false, true]) {
    test(
      'migration preserves all sidecars copyFallback=$copyFallback',
      () async {
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          await oldFile(suffix).writeAsString('fixture$suffix');
        }
        final selected = await resolve(
          rename: copyFallback
              ? (_, _) async => throw const FileSystemException('cross-device')
              : null,
        );
        expect(selected.path, newFile('').path);
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          expect(await newFile(suffix).readAsString(), 'fixture$suffix');
          expect(oldFile(suffix).existsSync(), isFalse);
        }
      },
    );
  }
  test('existing support database leaves documents untouched', () async {
    await support.create();
    await newFile('').writeAsString('current');
    await oldFile('').writeAsString('legacy');
    expect((await resolve()).path, newFile('').path);
    expect(await oldFile('').readAsString(), 'legacy');
  });
  test(
    'partial move and copy failure roll back before legacy fallback',
    () async {
      await oldFile('').writeAsString('database');
      await oldFile('-wal').writeAsString('wal');
      final selected = await resolve(
        rename: (source, destination) async {
          if (source.path.endsWith('-wal')) {
            throw const FileSystemException('cross-device');
          }
          return await source.rename(destination);
        },
        copy: (source, destination) async {
          await File(destination).writeAsString('partial');
          throw const FileSystemException('copy failed');
        },
      );
      expect(selected.path, oldFile('').path);
      expect(await oldFile('').readAsString(), 'database');
      expect(await oldFile('-wal').readAsString(), 'wal');
      expect(newFile('').existsSync(), isFalse);
      expect(newFile('-wal').existsSync(), isFalse);
    },
  );
  test('size mismatch removes partial copies and retains originals', () async {
    await oldFile('').writeAsString('database');
    expect(
      (await resolve(
        rename: (_, _) async => throw const FileSystemException('cross-device'),
        copy: (_, destination) => File(destination).writeAsString('x'),
      )).path,
      oldFile('').path,
    );
    expect(await oldFile('').readAsString(), 'database');
    expect(newFile('').existsSync(), isFalse);
  });
  test('unavailable support directory falls back to legacy', () async {
    await File(support.path).writeAsString('obstruction');
    await oldFile('').writeAsString('database');
    expect((await resolve()).path, oldFile('').path);
    expect(await oldFile('').readAsString(), 'database');
  });
}
