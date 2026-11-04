import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// Upstream's schema (CacheObjectProvider.open, v3) for the memory fallback.
const _schema =
    '''
  create table cacheObject (
    ${CacheObject.columnId} integer primary key,
    ${CacheObject.columnUrl} text,
    ${CacheObject.columnKey} text,
    ${CacheObject.columnPath} text,
    ${CacheObject.columnETag} text,
    ${CacheObject.columnValidTill} integer,
    ${CacheObject.columnTouched} integer,
    ${CacheObject.columnLength} integer
  );
  create unique index cacheObject${CacheObject.columnKey}
  ON cacheObject (${CacheObject.columnKey});
''';

/// The sqflite cover-art index (Android, iOS, macOS) without the open/close
/// defects of flutter_cache_manager 3.4.5's [CacheObjectProvider]:
///
/// * [open] never fails. `CacheStore` calls it once and caches the future, so
///   a failure would leave every lookup waiting forever. A corrupt index
///   (SQLite NOTADB or CORRUPT) is deleted with the image files it indexed and
///   reopened; any other error, or a second failure, leaves the file alone and
///   serves this session from an empty in-memory index (lookups miss and
///   refetch);
/// * a close that arrives while the open is still in flight waits for it;
/// * sqflite hands every opener of one path the same `Database`, so the
///   physical close happens only when the last repository of that name lets
///   go, and an open waits for a close of the same name that is in flight.
///
/// The database path is upstream's, so existing indexes keep working.
class NavisCacheObjectProvider extends CacheObjectProvider {
  /// `fileSystem` is the one the owning `Config` uses; its directory is
  /// removed together with a corrupt index, whose image files nothing else
  /// would ever evict.
  new({required String super.databaseName, this._fileSystem});

  // Repositories of one name that hold (or are about to hold) the index.
  static final Map<String, int> _holders = {};
  // The file Database of a name while any repository holds it.
  static final Map<String, Database> _sharedDbs = {};
  // The final close per name, so a later open never sees a closing Database.
  static final Map<String, Future<void>> _pendingCloses = {};
  // Serialises open-and-recover per name so repositories cannot delete each
  // other's freshly recreated file.
  static final Map<String, Future<void>> _recoveryLocks = {};

  final FileSystem? _fileSystem;

  String get _name => databaseName!;

  int _refs = 0;
  bool _opened = false;
  Database? _memory;
  Future<bool>? _opening;
  Future<void> _closing = Future<void>.value();

  @override
  Future<bool> open() {
    _refs++;
    var opening = _opening;
    if (opening == null) {
      _holders[_name] = (_holders[_name] ?? 0) + 1;
      // A close issued after this point must not be waited for: it waits for us.
      final started = opening = _opening = _openOnce(
        _closing,
        _pendingCloses[_name],
      );
      unawaited(
        started.then<void>(
          (_) {},
          onError: (_) {
            // Only reachable when even the memory fallback failed.
            if (!identical(_opening, started)) return;
            _opening = null;
            _refs = 0;
            if (_release()) {
              _track(_closeShared());
            }
          },
        ),
      );
    }
    return opening;
  }

  @override
  Future<bool> close() {
    if (_refs == 0) return Future.value(false);
    if (--_refs > 0) return Future.value(false);
    final opening = _opening;
    _opening = null;
    final last = _release();
    final closing = _closeAfter(_closing, opening, last: last);
    final done = closing.then<void>((_) {}, onError: (_) {});
    _closing = done;
    if (last) _track(done);
    return closing;
  }

  /// Drops this repository's hold; true when nobody holds the name any more.
  bool _release() {
    final left = (_holders[_name] ?? 1) - 1;
    if (left <= 0) {
      _holders.remove(_name);
      return true;
    }
    _holders[_name] = left;
    return false;
  }

  void _track(Future<void> closing) {
    final done = closing.then<void>((_) {}, onError: (_) {});
    _pendingCloses[_name] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_pendingCloses[_name], done)) {
          unawaited(_pendingCloses.remove(_name));
        }
      }),
    );
  }

  Future<void> _closeShared() async {
    await _sharedDbs.remove(_name)?.close();
  }

  Future<bool> _closeAfter(
    Future<void> previous,
    Future<bool>? opening, {
    required bool last,
  }) async {
    await previous;
    try {
      await opening;
    } on Object {
      // Nothing was opened.
    }
    if (!_opened) return false;
    _opened = false;
    openConnections = 0;
    openCompleter = null;
    db = null;
    final memory = _memory;
    _memory = null;
    await memory?.close();
    if (!last) return false;
    await _closeShared();
    return true;
  }

  Future<bool> _openOnce(Future<void> ownClose, Future<void>? nameClose) async {
    await ownClose;
    await nameClose;
    return await _locked(_load);
  }

  Future<T> _locked<T>(Future<T> Function() body) async {
    final before = _recoveryLocks[_name] ?? Future<void>.value();
    final released = Completer<void>();
    final mine = _recoveryLocks[_name] = released.future;
    await before;
    try {
      return await body();
    } finally {
      released.complete();
      if (identical(_recoveryLocks[_name], mine)) {
        unawaited(_recoveryLocks.remove(_name));
      }
    }
  }

  Future<bool> _load() async {
    try {
      return await _openFile();
    } on Object catch (error) {
      if (!_isCorrupt(error)) return await _useMemory(error);
      AppLogger.warning(
        'Cover art index $_name is corrupt (${_describe(error)}); recreating it',
      );
    }
    await _deleteIndex();
    try {
      return await _openFile();
    } on Object catch (error) {
      return await _useMemory(error);
    }
  }

  Future<bool> _openFile() async {
    try {
      final opened = await super.open();
      _sharedDbs[_name] = db!;
      _opened = true;
      return opened;
    } on Object {
      // Upstream leaves one connection counted and its completer pending.
      openConnections = 0;
      openCompleter = null;
      rethrow;
    }
  }

  Future<bool> _useMemory(Object error) async {
    AppLogger.warning(
      'Cover art index $_name cannot be opened (${_describe(error)}); '
      'using an empty in-memory index for this session',
    );
    final memory = await openDatabase(
      inMemoryDatabasePath,
      singleInstance: false,
      version: 3,
      onCreate: (db, version) => db.execute(_schema),
    );
    db = _memory = memory;
    _opened = true;
    return true;
  }

  // Never the message: it carries the file path.
  static String _describe(Object error) => error is DatabaseException
      ? 'sqlite result ${error.getResultCode()}'
      : error.runtimeType.toString();

  static bool _isCorrupt(Object error) {
    if (error is! DatabaseException) return false;
    final code = error.getResultCode();
    if (code != null) return code == 26 || code == 11;
    final message = error.toString().toLowerCase();
    return message.contains('not a database') || message.contains('malformed');
  }

  Future<void> _deleteIndex() async {
    try {
      final base = p.join(
        (await getApplicationSupportDirectory()).path,
        '$_name.db',
      );
      for (final suffix in const ['', '-journal', '-wal', '-shm']) {
        final file = File('$base$suffix');
        // ignore: avoid_slow_async_io, reason: Runs only after a failed open.
        if (await file.exists()) await file.delete();
      }
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art index $_name could not be deleted (${_describe(error)})',
      );
    }
    // Its image files are unreachable without the index; nothing else evicts them.
    final fileSystem = _fileSystem;
    if (fileSystem == null) return;
    try {
      final directory = (await fileSystem.createFile('.navis-reset')).parent;
      // ignore: avoid_slow_async_io, reason: Runs only after a corrupt index.
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art files of $_name could not be deleted (${_describe(error)})',
      );
    }
  }
}
