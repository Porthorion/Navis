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
    if (await _exists(target)) return target;
    await support.create(recursive: true);
    if (!await _exists(legacy)) return target;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final source = File('${legacy.path}$suffix');
      if (!await _exists(source)) continue;
      final destination = File('${target.path}$suffix');
      if (await _exists(destination)) {
        throw const FileSystemException('Migration destination already exists');
      }
      entries.add((source: source, destination: destination));
    }
    for (final entry in entries) {
      try {
        await (renameFile ?? _rename)(entry.source, entry.destination.path);
        transferred.add(entry);
      } on FileSystemException {
        // Cross-device moves need a verified copy. Keep every original until
        // the entire file family has transferred successfully.
        transferred.add(entry);
        await (copyFile ?? _copy)(entry.source, entry.destination.path);
        if (await entry.source.length() != await entry.destination.length()) {
          throw const FileSystemException(
            'Database migration copy size mismatch',
          );
        }
        copied.add(entry);
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
