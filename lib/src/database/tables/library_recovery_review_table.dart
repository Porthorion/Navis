import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Items that identity recovery could not relink automatically and that a
/// user may review.
///
/// A row is created when catalog promotion detects a previously authoritative
/// item that disappeared without a proven replacement but still owns local
/// state (favorites, ratings, references, downloads, or pending mutations).
/// Rows survive restarts and are never auto-dismissed; only an explicit user
/// disposition or a proven replacement removes them.
class LibraryRecoveryReviewTable extends Table {
  @override
  String get tableName => 'library_recovery_review';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  /// 'song', 'album', or 'artist'.
  TextColumn get entityType => text()();

  TextColumn get oldId => text()();

  /// Saved metadata so the row stays presentable after the live row is gone.
  TextColumn get savedTitle => text().nullable()();
  TextColumn get savedSubtitle => text().nullable()();

  /// Catalog generation whose validated snapshot proved the absence.
  IntColumn get evidenceGeneration => integer().nullable()();

  /// Typed reason, e.g. 'missingFromCatalog', 'ambiguousMatch',
  /// 'conflictingMbid'.
  TextColumn get reason => text()();

  /// JSON-encoded replacement candidates for the review screen.
  TextColumn get candidateJson => text().nullable()();

  /// 'pending', 'relinked', 'keptForLater', or 'removedFromLiked'.
  TextColumn get disposition => text().withDefault(const Constant('pending'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {serverId, entityType, oldId},
  ];
}
