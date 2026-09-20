import 'dart:async';

import 'package:drift/drift.dart';

class SyncLeaseLostException implements Exception {
  const SyncLeaseLostException();
}

/// Opaque lease ownership carried only by a sync execution's async work.
/// Ordinary playback, UI edits, and database migrations remain outside it.
class SyncWriteFence {
  const SyncWriteFence({
    required this.serverId,
    required this.ownerToken,
    required this.now,
  });

  final int serverId;
  final String ownerToken;
  final DateTime Function() now;
  static final _zoneKey = Object();
  static SyncWriteFence? get current =>
      Zone.current[_zoneKey] as SyncWriteFence?;

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});

  Future<void> lockAndCheck(QueryExecutor executor) async {
    // The no-op update acquires SQLite's writer lock before validating the
    // token. Another connection cannot replace the owner until this commit.
    final matched = await executor.runUpdate(
      'UPDATE library_sync_execution_lease SET owner_token = owner_token '
      'WHERE server_id = ? AND owner_token = ? AND expires_at > ?',
      [serverId, ownerToken, now().millisecondsSinceEpoch ~/ 1000],
    );
    if (matched != 1) throw const SyncLeaseLostException();
  }

  Future<void> checkBeforeCommit(QueryExecutor executor) async {
    final rows = await executor.runSelect(
      'SELECT 1 FROM library_sync_execution_lease '
      'WHERE server_id = ? AND owner_token = ? AND expires_at > ?',
      [serverId, ownerToken, now().millisecondsSinceEpoch ~/ 1000],
    );
    if (rows.isEmpty) throw const SyncLeaseLostException();
  }
}

/// Enforces ownership at the SQL boundary, including DAO batches, custom SQL,
/// hidden candidate writes and transaction commits. A heartbeat alone cannot
/// protect a request which returns after its lease has been replaced.
class SyncWriteFenceInterceptor extends QueryInterceptor {
  QueryExecutorUser? _user;
  final _fences = Expando<SyncWriteFence>();
  final _locked = Expando<bool>();

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final transaction = parent.beginTransaction();
    final fence = SyncWriteFence.current ?? _fences[parent];
    if (fence != null) _fences[transaction] = fence;
    return transaction;
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    _user = user;
    return executor.ensureOpen(user);
  }

  Future<T> _write<T>(
    QueryExecutor executor,
    Future<T> Function(QueryExecutor executor) action,
  ) async {
    final fence = SyncWriteFence.current;
    if (fence == null) return action(executor);
    if (executor is TransactionExecutor) {
      if (_fences[executor] != null && !identical(_fences[executor], fence)) {
        throw const SyncLeaseLostException();
      }
      if (_locked[executor] != true) {
        await fence.lockAndCheck(executor);
        _fences[executor] = fence;
        _locked[executor] = true;
      }
      return action(executor);
    }
    final transaction = executor.beginTransaction();
    await transaction.ensureOpen(_user!);
    try {
      await fence.lockAndCheck(transaction);
      final result = await action(transaction);
      await fence.checkBeforeCommit(transaction);
      await transaction.send();
      return result;
    } on Object {
      await transaction.rollback();
      rethrow;
    }
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final fence = _fences[inner];
    if (fence != null) await fence.checkBeforeCommit(inner);
    await inner.send();
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, (tx) => tx.runInsert(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, (tx) => tx.runUpdate(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, (tx) => tx.runDelete(statement, args));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, (tx) => tx.runCustom(statement, args));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _write(executor, (tx) => tx.runBatched(statements));

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    // Drift uses runSelect for INSERT/UPDATE/DELETE ... RETURNING too.
    if (!statement.trimLeft().toUpperCase().startsWith('SELECT')) {
      return _write(executor, (tx) => tx.runSelect(statement, args));
    }
    return executor.runSelect(statement, args);
  }
}
