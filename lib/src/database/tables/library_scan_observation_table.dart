import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Per-profile observation of the server's library scan state.
///
/// A row exists once scan status has been probed for a server. `scanSupported`
/// is false when the server does not implement `getScanStatus`; unsupported
/// servers must not be re-probed on every sync. The observed token records the
/// newest completed scan identity seen, while the reconciled token records the
/// scan identity that a catalog snapshot has already been validated against.
class LibraryScanObservationTable extends Table {
  @override
  String get tableName => 'library_scan_observation';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  BoolColumn get scanSupported => boolean().withDefault(const Constant(true))();

  /// Provider-supplied scan identity, such as Navidrome's `lastScan` value.
  TextColumn get providerScanToken => text().nullable()();

  /// Scan identity whose changes have been observed but not yet reconciled.
  TextColumn get observedToken => text().nullable()();

  DateTimeColumn get observedAt => dateTime().nullable()();

  /// Scan identity that a successfully promoted catalog snapshot covered.
  TextColumn get reconciledToken => text().nullable()();

  DateTimeColumn get reconciledAt => dateTime().nullable()();

  BoolColumn get pendingReconciliation =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {serverId};
}
