import 'dart:io';

import 'package:collection/collection.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves the database file, moving a legacy desktop database before opening.
/// Directory readers use path_provider so diagnostics profile overrides apply.
Future<File> resolveDatabaseFile({
  bool? desktop,
  Future<Directory> Function()? readApplicationSupportDirectory,
  Future<Directory> Function()? readApplicationDocumentsDirectory,
  Future<File> Function(File source, String destination)? renameFile,
  Future<File> Function(File source, String destination)? copyFile,
}) async {
  final isDesktop =
      desktop ?? (Platform.isLinux || Platform.isWindows || Platform.isMacOS);
  final readDocuments =
      readApplicationDocumentsDirectory ?? getApplicationDocumentsDirectory;
  if (!isDesktop) {
    return File(p.join((await readDocuments()).path, 'navis.sqlite.sqlite'));
  }
  final legacy = File(
    p.join((await readDocuments()).path, 'navis.sqlite.sqlite'),
  );
  final rename = renameFile ?? _rename;
  final copy = copyFile ?? _copy;
  final entries = <({File source, File destination})>[];
  final transferred = <({File source, File destination})>[];
  final copied = <({File source, File destination})>[];
  try {
    final support =
        await (readApplicationSupportDirectory ??
            getApplicationSupportDirectory)();
    final target = File(p.join(support.path, 'navis.sqlite.sqlite'));
    await _deleteStaleParts(legacy, target);
    if (await _exists(target)) {
      // The target main file marks a finished move. With the legacy main file
      // gone, legacy sidecars are leftovers of a build that moved the main
      // file first. Their WAL may predate changes made to the target since,
      // so they are never attached: set them aside.
      if (!await _exists(legacy)) await _orphanLegacySidecars(legacy);
      return target;
    }
    await support.create(recursive: true);
    if (!await _exists(legacy)) return target;
    for (final suffix in _suffixes) {
      final source = File('${legacy.path}$suffix');
      final destination = File('${target.path}$suffix');
      final sourceExists = await _exists(source);
      if (await _exists(destination)) {
        // A sidecar whose source is gone was moved before an interrupted
        // earlier launch. With both present the destination is not ours.
        final entry = (source: source, destination: destination);
        if (!sourceExists) {
          transferred.add(entry);
        } else if (await _sameContent(source, destination)) {
          // A copy finished before a kill, its original not yet deleted.
          transferred.add(entry);
          copied.add(entry);
        } else {
          throw const FileSystemException(
            'Migration destination already exists',
          );
        }
        continue;
      }
      if (sourceExists) entries.add((source: source, destination: destination));
    }
    for (final entry in entries) {
      final copiedFile = await _moveFile(
        entry.source,
        entry.destination,
        rename,
        copy,
        onCopyStart: () => transferred.add(entry),
      );
      if (copiedFile) {
        copied.add(entry);
      } else {
        transferred.add(entry);
      }
    }
    for (final entry in copied) {
      await entry.source.delete();
    }
    return target;
  } on Object catch (error) {
    // Restore renamed files and any originals already deleted before a later
    // failure. Never remove the only remaining copy if rollback itself fails.
    for (final entry in transferred.reversed) {
      if (!await _exists(entry.destination)) continue;
      // Rename back; only a cross-device failure copies (via a part file).
      if (!await _exists(entry.source)) {
        await _moveFile(entry.destination, entry.source, rename, copy);
      }
      if (await _exists(entry.destination)) await entry.destination.delete();
    }
    AppLogger.warning(
      'Desktop database migration failed; using legacy location: '
      '${error.runtimeType}',
    );
    return legacy;
  }
}

Future<bool> _exists(File file) async =>
    // Keep filesystem probing asynchronous during startup migration.
    // ignore: avoid_slow_async_io
    await FileSystemEntity.type(file.path) != FileSystemEntityType.notFound;

Future<File> _rename(File source, String destination) =>
    source.rename(destination);
Future<File> _copy(File source, String destination) => source.copy(destination);

const _suffixes = ['-wal', '-shm', '-journal', ''];
const _partSuffix = '.navis-part';

/// Renames [source] to [destination]. When the rename fails (cross-device),
/// copies it to `<destination>.navis-part`, verifies the size and renames the
/// part file into place, so the final name never holds a partial copy.
/// Calls [onCopyStart] first so a failed copy is rolled back. Returns true
/// when the original is still in place.
Future<bool> _moveFile(
  File source,
  File destination,
  Future<File> Function(File, String) rename,
  Future<File> Function(File, String) copy, {
  void Function()? onCopyStart,
}) async {
  try {
    await rename(source, destination.path);
    return false;
  } on FileSystemException {
    onCopyStart?.call();
    final part = File('${destination.path}$_partSuffix');
    try {
      await copy(source, part.path);
      if (await source.length() != await part.length()) {
        throw const FileSystemException(
          'Database migration copy size mismatch',
        );
      }
      await part.rename(destination.path);
    } on Object {
      await _deleteQuietly(part);
      rethrow;
    }
    return true;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await _exists(file)) await file.delete();
  } on Object catch (error) {
    AppLogger.warning('Could not delete ${p.basename(file.path)}: $error');
  }
}

/// Part files are never complete copies, so a kill mid-copy leaves only
/// garbage that is dropped before the next move.
Future<void> _deleteStaleParts(File legacy, File target) async {
  for (final base in [legacy, target]) {
    for (final suffix in _suffixes) {
      await _deleteQuietly(File('${base.path}$suffix$_partSuffix'));
    }
  }
}

Future<void> _orphanLegacySidecars(File legacy) async {
  var orphaned = 0;
  for (final suffix in _suffixes.where((s) => s.isNotEmpty)) {
    final source = File('${legacy.path}$suffix');
    if (!await _exists(source)) continue;
    try {
      // Never replace an earlier set-aside copy: each one may hold the only
      // bytes of transactions a shipped build stranded.
      var name = '${source.path}.orphaned';
      for (var n = 1; await _exists(File(name)); n++) {
        name = '${source.path}.orphaned.$n';
      }
      await source.rename(name);
      orphaned++;
    } on Object catch (error) {
      AppLogger.warning(
        'Could not set aside legacy database sidecar $suffix: '
        '${error.runtimeType}',
      );
    }
  }
  if (orphaned > 0) {
    AppLogger.warning(
      'Legacy database sidecars without a main file were set aside as '
      '.orphaned: $orphaned',
    );
  }
}

/// Compares in chunks so a large WAL is never held in memory twice.
Future<bool> _sameContent(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final ra = await a.open();
  final rb = await b.open();
  try {
    const chunk = 1 << 20;
    while (true) {
      final x = await ra.read(chunk);
      final y = await rb.read(chunk);
      if (!const ListEquality<int>().equals(x, y)) return false;
      if (x.isEmpty) return true;
    }
  } finally {
    await ra.close();
    await rb.close();
  }
}
