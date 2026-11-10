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

  // The process dies while the rename of [hangOn] is pending: everything
  // renamed before it has moved, nothing rolls back.
  for (final hangOn in ['-wal', '-shm', '']) {
    test('a kill while renaming "$hangOn" keeps the WAL with the database the '
        'next launch opens', () async {
      for (final suffix in ['', '-wal', '-shm']) {
        await oldFile(suffix).writeAsString('fixture$suffix');
      }
      final reached = Completer<void>();
      unawaited(
        resolve(
          rename: (source, destination) {
            if (source.path.endsWith('sqlite$hangOn')) {
              reached.complete();
              return Completer<File>().future;
            }
            return source.rename(destination);
          },
        ),
      );
      await reached.future;

      final selected = await resolve();
      expect(selected.path, newFile('').path);
      for (final suffix in ['', '-wal', '-shm']) {
        expect(await newFile(suffix).readAsString(), 'fixture$suffix');
        expect(oldFile(suffix).existsSync(), isFalse);
      }
    });
  }

  test('stranded legacy sidecars from a main-first kill are set aside, never '
      'attached to the target', () async {
    await support.create();
    await newFile('').writeAsString('current');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      await oldFile(suffix).writeAsString('stale$suffix');
    }
    final selected = await resolve();
    expect(selected.path, newFile('').path);
    expect(await newFile('').readAsString(), 'current');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      expect(newFile(suffix).existsSync(), isFalse);
      expect(oldFile(suffix).existsSync(), isFalse);
      expect(
        await File('${oldFile(suffix).path}.orphaned').readAsString(),
        'stale$suffix',
      );
    }
  });

  test(
    'a stranded legacy -wal never touches an existing target -wal',
    () async {
      await support.create();
      await newFile('').writeAsString('fixture');
      await newFile('-wal').writeAsString('current');
      await oldFile('-wal').writeAsString('legacy');
      expect((await resolve()).path, newFile('').path);
      expect(await newFile('-wal').readAsString(), 'current');
      expect(
        await File('${oldFile('-wal').path}.orphaned').readAsString(),
        'legacy',
      );
    },
  );

  test('a legacy -wal beside a legacy main never joins an existing target '
      'database', () async {
    await support.create();
    await newFile('').writeAsString('current');
    await oldFile('').writeAsString('legacy');
    await oldFile('-wal').writeAsString('legacy-wal');
    await resolve();
    expect(newFile('-wal').existsSync(), isFalse);
    expect(await oldFile('-wal').readAsString(), 'legacy-wal');
  });

  test('a kill after the sidecar rename but before the main rename resumes '
      'and opens the target with its -wal', () async {
    await support.create();
    await oldFile('').writeAsString('fixture');
    await newFile('-wal').writeAsString('wal');
    final selected = await resolve();
    expect(selected.path, newFile('').path);
    expect(await newFile('').readAsString(), 'fixture');
    expect(await newFile('-wal').readAsString(), 'wal');
    expect(oldFile('').existsSync(), isFalse);
  });

  test('a conflicting -wal at both locations falls back to legacy', () async {
    await support.create();
    await oldFile('').writeAsString('fixture');
    await oldFile('-wal').writeAsString('legacy');
    await newFile('-wal').writeAsString('other');
    expect((await resolve()).path, oldFile('').path);
    expect(await newFile('-wal').readAsString(), 'other');
    expect(await oldFile('-wal').readAsString(), 'legacy');
  });

  test('a failed main move rolls back a sidecar moved by an earlier '
      'launch', () async {
    await support.create();
    await oldFile('').writeAsString('fixture');
    await newFile('-wal').writeAsString('wal');
    final selected = await resolve(
      rename: (_, _) async => throw const FileSystemException('cross-device'),
      copy: (source, destination) async {
        if (source.path == oldFile('').path) {
          throw const FileSystemException('copy failed');
        }
        return source.copy(destination);
      },
    );
    expect(selected.path, oldFile('').path);
    expect(await oldFile('-wal').readAsString(), 'wal');
    expect(newFile('-wal').existsSync(), isFalse);
    expect(newFile('').existsSync(), isFalse);
  });

  const crossDevice = FileSystemException('cross-device');
  Future<File> Function(File, String) failRename() =>
      (_, _) async => throw crossDevice;
  List<String> partFiles() => [
    for (final dir in [documents, support])
      if (dir.existsSync())
        for (final f in dir.listSync())
          if (f.path.endsWith('.navis-part')) f.path,
  ];

  // The process dies while the copy of [hangOn] is pending, after writing a
  // truncated part file; the next launch must finish the move from intact
  // originals and never open a truncated target.
  for (final hangOn in ['', '-wal', '-shm']) {
    test('copy mode: a kill mid-copy of "$hangOn" never exposes a truncated '
        'target and the next launch finishes the move', () async {
      for (final suffix in ['', '-wal', '-shm']) {
        await oldFile(suffix).writeAsString('fixture$suffix');
      }
      final reached = Completer<void>();
      unawaited(
        resolve(
          rename: failRename(),
          copy: (source, destination) async {
            if (source.path.endsWith('sqlite$hangOn')) {
              await File(destination).writeAsString('fix');
              reached.complete();
              return Completer<File>().future;
            }
            return source.copy(destination);
          },
        ),
      );
      await reached.future;
      // The main file is never opened truncated at its final name.
      expect(newFile('').existsSync(), isFalse);

      final selected = await resolve(rename: failRename());
      expect(selected.path, newFile('').path);
      for (final suffix in ['', '-wal', '-shm']) {
        expect(await newFile(suffix).readAsString(), 'fixture$suffix');
        expect(oldFile(suffix).existsSync(), isFalse);
      }
      expect(partFiles(), isEmpty);
    });
  }

  test('stale part files in both directories are deleted at launch', () async {
    await support.create();
    await oldFile('').writeAsString('fixture');
    await File('${oldFile('-wal').path}.navis-part').writeAsString('x');
    await File('${newFile('').path}.navis-part').writeAsString('x');
    expect((await resolve()).path, newFile('').path);
    expect(partFiles(), isEmpty);
  });

  test('copy mode: a size mismatch leaves no part file', () async {
    await oldFile('').writeAsString('database');
    await resolve(
      rename: failRename(),
      copy: (_, destination) => File(destination).writeAsString('x'),
    );
    expect(partFiles(), isEmpty);
  });

  test('rollback renames a moved sidecar back instead of copying it', () async {
    await oldFile('').writeAsString('database');
    await oldFile('-wal').writeAsString('wal');
    final renames = <String>[];
    final selected = await resolve(
      rename: (source, destination) {
        renames.add(destination);
        if (source.path == oldFile('').path) throw crossDevice;
        return source.rename(destination);
      },
      copy: (_, _) async => throw const FileSystemException('copy failed'),
    );
    expect(selected.path, oldFile('').path);
    expect(renames, contains(oldFile('-wal').path));
    expect(await oldFile('-wal').readAsString(), 'wal');
    expect(newFile('-wal').existsSync(), isFalse);
  });

  test('a kill mid cross-device rollback never leaves a truncated legacy '
      '-wal and the next launch finishes the move', () async {
    await oldFile('').writeAsString('database');
    await oldFile('-wal').writeAsString('wal');
    final reached = Completer<void>();
    unawaited(
      resolve(
        rename: (source, destination) {
          if (source.path == oldFile('').path ||
              source.path == newFile('-wal').path) {
            throw crossDevice;
          }
          return source.rename(destination);
        },
        copy: (source, destination) async {
          if (source.path == oldFile('').path) {
            throw const FileSystemException('copy failed');
          }
          await File(destination).writeAsString('w');
          reached.complete();
          return Completer<File>().future;
        },
      ),
    );
    await reached.future.timeout(const Duration(seconds: 2));
    expect(oldFile('-wal').existsSync(), isFalse);

    final selected = await resolve();
    expect(selected.path, newFile('').path);
    expect(await newFile('').readAsString(), 'database');
    expect(await newFile('-wal').readAsString(), 'wal');
    expect(partFiles(), isEmpty);
  });

  test(
    'a failing rollback escapes and keeps the only remaining copy',
    () async {
      await support.create();
      await oldFile('').writeAsString('database');
      await newFile('-wal').writeAsString('wal');
      await expectLater(
        resolve(
          rename: failRename(),
          copy: (_, _) async => throw const FileSystemException('copy failed'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await newFile('-wal').readAsString(), 'wal');
      expect(partFiles(), isEmpty);
    },
  );
}
