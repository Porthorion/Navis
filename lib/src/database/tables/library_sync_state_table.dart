import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

class LibrarySyncStateTable extends Table {
  @override
  String get tableName => 'library_sync_state';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  IntColumn get plannerVersion => integer().withDefault(const Constant(2))();

  TextColumn get providerFingerprint => text().nullable()();

  TextColumn get conditionalIndexesMode =>
      text().withDefault(const Constant('unknown'))();

  TextColumn get bulkSearchMode =>
      text().withDefault(const Constant('unknown'))();

  TextColumn get bulkSearchQuery => text().nullable()();

  IntColumn get safePageSize => integer().withDefault(const Constant(500))();

  IntColumn get detailConcurrency => integer().withDefault(const Constant(2))();

  IntColumn get averageLatencyMs => integer().nullable()();

  TextColumn get endpointFailureJson => text().nullable()();

  DateTimeColumn get catalogCursor => dateTime().nullable()();

  TextColumn get catalogFingerprint => text().nullable()();

  IntColumn get currentGeneration => integer().withDefault(const Constant(0))();

  IntColumn get candidateGeneration => integer().nullable()();

  TextColumn get candidateStatus => text().nullable()();

  DateTimeColumn get candidateStartedAt => dateTime().nullable()();

  IntColumn get candidateCarriedForwardCount =>
      integer().withDefault(const Constant(0))();

  IntColumn get lastApplyDurationMs => integer().nullable()();

  TextColumn get lastPromotionDiagnosticsJson => text().nullable()();

  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  DateTimeColumn get lastCatalogSyncedAt => dateTime().nullable()();

  /// First setup may leave a safely promoted catalog with only incomplete
  /// server album details pending. This is readiness, not full freshness.
  DateTimeColumn get initialCatalogUsableAt => dateTime().nullable()();

  DateTimeColumn get lastAuxiliarySyncedAt => dateTime().nullable()();

  DateTimeColumn get lastAuditAt => dateTime().nullable()();

  IntColumn get auditOffset => integer().withDefault(const Constant(0))();

  IntColumn get failureStreak => integer().withDefault(const Constant(0))();

  DateTimeColumn get nextEligibleAt => dateTime().nullable()();

  /// The next time an automatic catalog check may start for this server.
  ///
  /// This is deliberately separate from [nextEligibleAt], which is the
  /// endpoint-circuit cooldown. Lifecycle and timer events must use this
  /// durable schedule instead of each starting a process-local interval.
  DateTimeColumn get nextAutomaticCheckAt => dateTime().nullable()();

  /// Android-only WorkManager capability gate. It is intentionally durable so
  /// an internal rollout cannot be enabled merely by restarting the process.
  BoolColumn get androidBackgroundSyncEnabled =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get androidScheduleReconciledAt => dateTime().nullable()();

  IntColumn get androidRequestedIntervalMinutes => integer().nullable()();

  TextColumn get androidWorkId => text().nullable()();

  TextColumn get androidWorkState => text().nullable()();

  IntColumn get androidWorkAttemptCount => integer().withDefault(
    const Constant(0),
  )();

  DateTimeColumn get androidWorkerStartedAt => dateTime().nullable()();

  DateTimeColumn get androidWorkerCompletedAt => dateTime().nullable()();

  IntColumn get androidWorkerDurationMs => integer().nullable()();

  /// A bounded redacted category, never an exception string or server detail.
  TextColumn get androidWorkerResult => text().nullable()();

  /// Safe WorkManager stop category when the platform exposes one.
  TextColumn get androidWorkerStopReason => text().nullable()();

  TextColumn get lastPlanKind => text().nullable()();

  TextColumn get lastPlanReason => text().nullable()();

  IntColumn get lastRunBytes => integer().withDefault(const Constant(0))();

  IntColumn get lastRunRequests => integer().withDefault(const Constant(0))();

  TextColumn get deletionCandidateFingerprint => text().nullable()();

  IntColumn get deletionCandidateCount =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {serverId};
}
