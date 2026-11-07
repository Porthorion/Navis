import 'dart:async';
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
    bool useSupportDirectory = true,
    Future<File> Function(File, String)? rename,
    Future<File> Function(File, String)? copy,
    Future<void> Function(File)? delete,
  }) => resolveDatabaseFile(
    useSupportDirectory: useSupportDirectory,
    readApplicationDocumentsDirectory: () async => documents,
    readApplicationSupportDirectory: () async => support,
    renameFile: rename,
    copyFile: copy,
    deleteFile: delete,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('navis-db-location-');
    documents = await Directory(p.join(root.path, 'documents')).create();
    support = Directory(p.join(root.path, 'support'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('fresh install selects support and creates its directory', () async {
    expect((await resolve()).path, newFile('').path);
    expect(support.existsSync(), isTrue);
    expect(newFile('').existsSync(), isFalse);
  });
  test('only Android keeps the database in documents by default', () {
    expect(databaseUsesSupportDirectory('ios'), isTrue);
    expect(databaseUsesSupportDirectory('macos'), isTrue);
    expect(databaseUsesSupportDirectory('linux'), isTrue);
    expect(databaseUsesSupportDirectory('windows'), isTrue);
    expect(databaseUsesSupportDirectory('android'), isFalse);
  });
  test('a missing documents directory still selects support', () async {
    documents.deleteSync();
    expect((await resolve()).path, newFile('').path);
    expect(support.existsSync(), isTrue);
  });
  test('android retains documents without reading support', () async {
    final file = await resolveDatabaseFile(
      useSupportDirectory: false,
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
    'sidecars stranded by a crash after the main file moved are adopted',
    () async {
      await support.create();
      await newFile('').writeAsString('moved main');
      await oldFile('-wal').writeAsString('stranded wal');
      await oldFile('-shm').writeAsString('stranded shm');
      await newFile('-shm').writeAsString('current shm');
      final selected = await resolve();
      expect(selected.path, newFile('').path);
      expect(await newFile('-wal').readAsString(), 'stranded wal');
      expect(oldFile('-wal').existsSync(), isFalse);
      // A sidecar whose destination exists is never overwritten.
      expect(await newFile('-shm').readAsString(), 'current shm');
      expect(await oldFile('-shm').readAsString(), 'stranded shm');
    },
  );
  test('stranded sidecars are only renamed, never copied', () async {
    await support.create();
    await newFile('').writeAsString('moved main');
    await oldFile('-wal').writeAsString('stranded wal');
    await resolve(
      rename: (_, _) async => throw const FileSystemException('cross-device'),
      copy: (_, _) async => fail('a stranded sidecar must not be copied'),
    );
    expect(newFile('-wal').existsSync(), isFalse);
    expect(await oldFile('-wal').readAsString(), 'stranded wal');
  });
  test('a copy-fallback move that dies mid-cleanup never lets a stale wal roll '
      'the database back', () async {
    await oldFile('').writeAsString('v1 main');
    await oldFile('-wal').writeAsString('v1 wal');
    // Launch 1: every rename fails (cross-volume), so the family is copied;
    // the process then dies (the future never completes) while deleting the
    // originals, after the first delete.
    var deletes = 0;
    unawaited(
      resolve(
        rename: (_, _) async => throw const FileSystemException('cross-device'),
        delete: (file) {
          if (deletes++ > 0) return Completer<void>().future;
          return file.delete();
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(newFile('').existsSync(), isTrue);
    expect(newFile('-wal').existsSync(), isTrue);
    // Launch 2: the target exists; the app runs, writes and closes cleanly,
    // which checkpoints the WAL and deletes it.
    await resolve();
    await newFile('').writeAsString('v2 main');
    await newFile('-wal').delete();
    // Launch 3 must not adopt a stale legacy wal beside the newer main.
    await resolve();
    expect(newFile('-wal').existsSync(), isFalse);
    expect(await newFile('').readAsString(), 'v2 main');
  });
  test(
    'legacy sidecars stay when the legacy main file is still there',
    () async {
      await support.create();
      await newFile('').writeAsString('current');
      await oldFile('').writeAsString('legacy');
      await oldFile('-wal').writeAsString('legacy wal');
      await resolve();
      expect(newFile('-wal').existsSync(), isFalse);
      expect(await oldFile('-wal').readAsString(), 'legacy wal');
    },
  );
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
