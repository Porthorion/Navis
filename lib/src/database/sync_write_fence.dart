import 'dart:async';

import 'package:drift/drift.dart';

class SyncLeaseLostException implements Exception {
  const new();
}

/// Opaque lease ownership carried only by a sync execution's async work.
/// Ordinary playback, UI edits, and database migrations remain outside it.
class SyncWriteFence {
  const new({
    required this.serverId,
    required this.ownerToken,
    required this.now,
    this.renewalTtl,
  });

  final int serverId;
  final String ownerToken;
  final DateTime Function() now;

  /// When set, the first write of a transaction renews the lease to
  /// `now + renewalTtl` under the write lock it already holds. A transaction
  /// longer than the lease TTL otherwise expires its own lease and fails at
  /// commit even though the owner never lost it: heartbeats cannot run inside
  /// the open transaction, and takeover cannot happen either because the
  /// writer lock is held for the whole transaction.
  final Duration? renewalTtl;

  static final _zoneKey = Object();
  static SyncWriteFence? get current =>
      Zone.current[_zoneKey] as SyncWriteFence?;

  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});

  Future<void> lockAndCheck(QueryExecutor executor) async {
    // The no-op update acquires SQLite's writer lock before validating the
    // token. Another connection cannot replace the owner until this commit.
    // A renewal TTL extends the lease under the same lock so a long
    // transaction cannot expire out from under its live owner.
    final renewTo = renewalTtl == null
        ? null
        : now().add(renewalTtl!).millisecondsSinceEpoch ~/ 1000;
    final matched = await executor.runUpdate(
      'UPDATE library_sync_execution_lease '
      'SET owner_token = owner_token, '
      '    expires_at = CASE WHEN ? IS NULL THEN expires_at ELSE ? END '
      'WHERE server_id = ? AND owner_token = ? AND expires_at > ?',
      [
        renewTo,
        renewTo,
        serverId,
        ownerToken,
        now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
    if (matched != 1) throw const SyncLeaseLostException();
  }

  Future<void> checkBeforeCommit(QueryExecutor executor) async {
    // Ownership, not expiry: a takeover cannot have happened while this
    // transaction held the writer lock, so the owner token matching is the
    // exact liveness condition at commit. Requiring unexpired leases here
    // would fail transactions that outlive the TTL despite uninterrupted
    // ownership.
    final rows = await executor.runSelect(
      'SELECT 1 FROM library_sync_execution_lease '
      'WHERE server_id = ? AND owner_token = ?',
      [serverId, ownerToken],
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
