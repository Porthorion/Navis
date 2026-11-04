import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The sqflite cover-art index (Android, iOS, macOS) without the open/close
/// defects of flutter_cache_manager 3.4.5's [CacheObjectProvider]:
///
/// * a failed open never leaves later callers waiting on a future that does
///   not complete: a corrupt index is deleted once and reopened, otherwise the
///   error reaches every waiting caller and the next open starts afresh;
/// * a close that arrives while the open is still in flight waits for it;
/// * sqflite hands every opener of one path the same `Database`, so the
///   physical close happens only when the last repository of that name lets
///   go, and an open waits for a close of the same name that is in flight.
///
/// The database path is upstream's, so existing indexes keep working.
class NavisCacheObjectProvider extends CacheObjectProvider {
  new({required String super.databaseName});

  // Repositories of one name that hold the shared Database right now.
  static final Map<String, int> _holders = {};
  // The final close per name, so a later open never sees a closing Database.
  static final Map<String, Future<void>> _pendingCloses = {};

  String get _name => databaseName!;

  int _refs = 0;
  bool _opened = false;
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
            // The failure also reaches the callers; later opens start afresh.
            if (!identical(_opening, started)) return;
            _opening = null;
            _refs = 0;
            _release();
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
    final previous = _closing;
    final closing = _closeAfter(previous, opening, last: last);
    final done = closing.then<void>((_) {}, onError: (_) {});
    _closing = done;
    if (last) {
      _pendingCloses[_name] = done;
      unawaited(
        done.whenComplete(() {
          if (identical(_pendingCloses[_name], done)) {
            _pendingCloses.remove(_name);
          }
        }),
      );
    }
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

  Future<bool> _closeAfter(
    Future<void> previous,
    Future<bool>? opening, {
    required bool last,
  }) async {
    await previous;
    try {
      await opening;
    } on Object {
      // The failed open already reset its own state; nothing to close.
    }
    if (!_opened) return false;
    _opened = false;
    if (last) return super.close();
    // Another repository still uses the shared Database; only forget it here.
    openConnections = 0;
    openCompleter = null;
    return false;
  }

  Future<bool> _openOnce(Future<void> ownClose, Future<void>? nameClose) async {
    await ownClose;
    await nameClose;
    try {
      return await _openUpstream();
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art index $_name failed to open ($error); recreating it',
      );
    }
    // The index only lists re-fetchable files, so a fresh one is safe.
    await _deleteIndex();
    return _openUpstream();
  }

  Future<bool> _openUpstream() async {
    try {
      final opened = await super.open();
      _opened = true;
      return opened;
    } on Object {
      // Upstream leaves one connection counted and its completer pending.
      openConnections = 0;
      openCompleter = null;
      rethrow;
    }
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
      AppLogger.warning('Cover art index $_name could not be deleted: $error');
    }
  }
}
