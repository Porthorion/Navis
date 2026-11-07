import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';

/// Resolves a sync request; the stub records it before calling this.
typedef SyncRequestHandler = Future<LibrarySyncState> Function(
  LibrarySyncRequest request, {
  LibrarySyncProgressCallback? onProgress,
});

/// A [LibrarySyncEngine] that logs every request and delegates the result to
/// a handler.
class StubLibrarySyncEngine extends LibrarySyncEngine {
  new(this._handler);

  /// Every request resolves to [state].
  new returning(LibrarySyncState state)
    : this((request, {onProgress}) async => state);

  final SyncRequestHandler _handler;

  final requests = <LibrarySyncRequest>[];

  Iterable<LibrarySyncRequest> get automaticRequests =>
      requests.where((request) => request.isAutomatic);

  Iterable<LibrarySyncRequest> get explicitCatalogRequests => requests.where(
    (request) =>
        !request.isAutomatic &&
        request.target.kind == LibrarySyncTargetKind.catalog,
  );

  Iterable<LibrarySyncRequest> requestsWithIntent(SyncRunIntent intent) =>
      requests.where((request) => request.intent == intent);

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    requests.add(request);
    return _handler(request, onProgress: onProgress);
  }
}

/// A [SyncPlanExecutor] that logs every executed plan and delegates the
/// result to a handler.
class StubSyncPlanExecutor implements SyncPlanExecutor {
  new(this._handler, {this.onObserveScan});

  final Future<LibrarySyncState> Function(
    SyncExecutionPlan plan, {
    LibrarySyncProgressCallback? onProgress,
  })
  _handler;

  /// Simulates the scan observation the real engine records; a test uses it
  /// to make the "server" report a new completed scan.
  final Future<void> Function()? onObserveScan;

  final plans = <SyncExecutionPlan>[];
  int cancelCalls = 0;
  int observeScanCalls = 0;

  @override
  void cancelSync() => cancelCalls++;

  @override
  Future<void> observeServerScan() async {
    observeScanCalls++;
    await onObserveScan?.call();
  }

  @override
  Future<LibrarySyncState> executeSyncPlan(
    SyncExecutionPlan plan, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    plans.add(plan);
    return _handler(plan, onProgress: onProgress);
  }
}
