import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
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
/// * `CacheStore` also chains its lookups without an error handler, so no
///   query or write ever throws: failures return an empty result and log once,
///   and a corrupt-coded one moves this repository to the in-memory index for
///   the rest of the session (the next open's `PRAGMA quick_check` deals with
///   the file);
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

  /// True while this repository serves an empty in-memory index because the
  /// file could not be used; image files of earlier sessions are unindexed.
  bool get isFallback => _fallback;

  /// Whether a SQLite result code, extended or primary, means a damaged file.
  @visibleForTesting
  static bool isCorruptResultCode(int? code) =>
      code != null && ((code & 0xff) == 26 || (code & 0xff) == 11);

  int _refs = 0;
  bool _opened = false;
  bool _fallback = false;
  bool _loggedQueryError = false;
  Database? _memory;
  Future<void>? _switching;
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
    try {
      await _sharedDbs.remove(_name)?.close();
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art index $_name did not close cleanly (${_describe(error)})',
      );
    }
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
    try {
      await _switching;
    } on Object {
      // Logged where it happened.
    }
    final memory = _memory;
    _memory = null;
    try {
      await memory?.close();
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art memory index $_name did not close cleanly (${_describe(error)})',
      );
    }
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
      if (!await _isDamaged(error)) return await _useMemory(error);
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
    final reused = _sharedDbs.containsKey(_name);
    try {
      final opened = await super.open();
      // Only a Database this repository opened itself can still be damaged.
      if (!reused) await _quickCheck(db!);
      _sharedDbs[_name] = db!;
      _opened = true;
      return opened;
    } on Object {
      // Upstream leaves one connection counted and its completer pending.
      openConnections = 0;
      openCompleter = null;
      final failed = db;
      db = null;
      if (!reused) {
        try {
          await failed?.close();
        } on Object {
          // The open already failed; the caller decides what happens next.
        }
      }
      rethrow;
    }
  }

  static Future<void> _quickCheck(Database database) async {
    final rows = await database.rawQuery('PRAGMA quick_check');
    if (rows.length != 1 || rows.first.values.first != 'ok') {
      throw const _QuickCheckFailed();
    }
  }

  Future<bool> _useMemory(Object error) async {
    AppLogger.warning(
      'Cover art index $_name cannot be opened (${_describe(error)}); '
      'using an empty in-memory index for this session',
    );
    _fallback = true;
    _opened = true;
    await _openMemory();
    return true;
  }

  Future<void> _openMemory() async {
    try {
      final memory = await openDatabase(
        inMemoryDatabasePath,
        singleInstance: false,
        version: 3,
        onCreate: (db, version) => db.execute(_schema),
      );
      if (!_opened) {
        await memory.close();
        return;
      }
      db = _memory = memory;
    } on Object catch (error) {
      // Every query now answers empty; open() itself must not fail.
      db = null;
      AppLogger.warning(
        'Cover art memory index $_name cannot be opened (${_describe(error)})',
      );
    }
  }

  // Never the message: it carries the file path.
  static String _describe(Object error) {
    if (error is DatabaseException) {
      return 'sqlite result ${error.getResultCode()}';
    }
    return error is _QuickCheckFailed
        ? 'quick_check failed'
        : error.runtimeType.toString();
  }

  static int? _primaryCode(Object error) {
    if (error is _QuickCheckFailed) return 11;
    if (error is! DatabaseException) return null;
    final code = error.getResultCode();
    if (code != null) return code & 0xff;
    final message = error.toString().toLowerCase();
    if (message.contains('not a database')) return 26;
    if (message.contains('malformed')) return 11;
    return null;
  }

  /// Whether [error] proves the index file is damaged and may be deleted.
  Future<bool> _isDamaged(Object error) async {
    final code = _primaryCode(error);
    if (code == 11) return true;
    if (code != 26) return false;
    // iOS data protection makes a healthy file unreadable before first unlock,
    // which can also surface as NOTADB: delete only a file that is readable
    // and does not carry the SQLite header.
    try {
      final file = await File(await _indexPath()).open();
      try {
        return !listEquals(await file.read(16), _sqliteHeader);
      } finally {
        await file.close();
      }
    } on Object {
      return false;
    }
  }

  static final List<int> _sqliteHeader = [...'SQLite format 3'.codeUnits, 0];

  Future<String> _indexPath() async =>
      p.join((await getApplicationSupportDirectory()).path, '$_name.db');

  // ---- Queries: CacheStore has no error handler, so none may throw. ----

  Future<T> _guard<T>(T neutral, Future<T> Function() query) async {
    if (db == null) {
      _logQueryError('repository is closed');
      return neutral;
    }
    try {
      return await query();
    } on Object catch (error) {
      _logQueryError(_describe(error));
      if (isCorruptResultCode(_primaryCode(error)) && !_fallback) {
        _fallback = true;
        try {
          await (_switching ??= _openMemory());
        } on Object {
          // Logged by _openMemory.
        }
      }
      return neutral;
    }
  }

  void _logQueryError(String what) {
    if (_loggedQueryError) return;
    _loggedQueryError = true;
    AppLogger.warning('Cover art index $_name query failed ($what)');
  }

  @override
  Future<CacheObject?> get(String key) =>
      _guard<CacheObject?>(null, () => super.get(key));

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) => _guard<CacheObject>(
    cacheObject,
    () => super.insert(cacheObject, setTouchedToNow: setTouchedToNow),
  );

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) =>
      _guard<int>(
        0,
        () => super.update(cacheObject, setTouchedToNow: setTouchedToNow),
      );

  @override
  Future<int> delete(int id) => _guard<int>(0, () => super.delete(id));

  @override
  Future<int> deleteAll(Iterable<int> ids) =>
      _guard<int>(0, () => super.deleteAll(ids));

  @override
  Future<List<CacheObject>> getAllObjects() =>
      _guard<List<CacheObject>>(const [], super.getAllObjects);

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) =>
      _guard<List<CacheObject>>(
        const [],
        () => super.getObjectsOverCapacity(capacity),
      );

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) =>
      _guard<List<CacheObject>>(const [], () => super.getOldObjects(maxAge));

  Future<void> _deleteIndex() async {
    try {
      final base = await _indexPath();
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
    await deleteImageFiles();
  }

  /// Removes the cache's image directory (the one the `Config`'s file system
  /// uses). Their index is gone or was never usable, so nothing else would
  /// ever evict them.
  Future<void> deleteImageFiles() async {
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

class _QuickCheckFailed implements Exception {
  const new();
}
