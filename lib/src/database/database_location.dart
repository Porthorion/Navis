import 'dart:io';

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
  final entries = <({File source, File destination})>[];
  final transferred = <({File source, File destination})>[];
  final copied = <({File source, File destination})>[];
  try {
    final support =
        await (readApplicationSupportDirectory ??
            getApplicationSupportDirectory)();
    final target = File(p.join(support.path, 'navis.sqlite.sqlite'));
    final rename = renameFile ?? _rename;
    final copy = copyFile ?? _copy;
    // Sidecars move first and the main file last, so the main file at the
    // target marks a finished move. A kill earlier leaves the main file in
    // the legacy location and the next launch resumes below.
    final suffixes = ['-wal', '-shm', '-journal', ''];
    if (await _exists(target)) {
      // A build that moved the main file first can be killed with the WAL
      // still at the legacy path. The legacy main file is gone then, so its
      // sidecars belong to the moved database and are finished here.
      if (!await _exists(legacy)) {
        for (final suffix in suffixes.where((s) => s.isNotEmpty)) {
          final source = File('${legacy.path}$suffix');
          final destination = File('${target.path}$suffix');
          if (!await _exists(source)) continue;
          if (await _exists(destination)) {
            AppLogger.warning(
              'Legacy database sidecar left in place; destination exists: '
              '$suffix',
            );
            continue;
          }
          try {
            if (await _moveFile(source, destination, rename, copy)) {
              await source.delete();
            }
          } on Object catch (error) {
            // The moved main file is the database now: never fall back to
            // legacy. Drop a partial copy so it is not opened as a WAL.
            if (await _exists(source) && await _exists(destination)) {
              await destination.delete();
            }
            AppLogger.warning(
              'Could not finish moving database sidecar $suffix: '
              '${error.runtimeType}',
            );
          }
        }
      }
      return target;
    }
    await support.create(recursive: true);
    if (!await _exists(legacy)) return target;
    for (final suffix in suffixes) {
      final source = File('${legacy.path}$suffix');
      final destination = File('${target.path}$suffix');
      final sourceExists = await _exists(source);
      if (await _exists(destination)) {
        // A sidecar whose source is gone was moved before an interrupted
        // earlier launch. With both present the destination is not ours.
        if (sourceExists) {
          throw const FileSystemException(
            'Migration destination already exists',
          );
        }
        transferred.add((source: source, destination: destination));
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
      if (!await _exists(entry.source)) {
        await entry.destination.copy(entry.source.path);
        if (await entry.source.length() != await entry.destination.length()) {
          throw const FileSystemException(
            'Database migration rollback size mismatch',
          );
        }
      }
      await entry.destination.delete();
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

/// Renames [source] to [destination]. When the rename fails (cross-device),
/// copies it and verifies the size, calling [onCopyStart] first so a failed
/// copy is rolled back. Returns true when the original is still in place.
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
    await copy(source, destination.path);
    if (await source.length() != await destination.length()) {
      throw const FileSystemException('Database migration copy size mismatch');
    }
    return true;
  }
}
