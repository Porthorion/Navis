import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/local_radio_stations_table.dart';
import 'package:uuid/uuid.dart';

part 'local_radio_station_dao.g.dart';

@DriftAccessor(tables: [LocalRadioStationsTable])
class LocalRadioStationDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$LocalRadioStationDaoMixin {
  new(super.attachedDatabase);

  Stream<List<LocalRadioStationsTableData>> watchAll() {
    return (select(localRadioStationsTable)..orderBy([
          (table) => OrderingTerm.asc(table.name.collate(Collate.noCase)),
        ]))
        .watch();
  }

  Future<String> upsert({
    String? id,
    required String name,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    final stationId = id ?? 'local:${const Uuid().v4()}';
    await into(localRadioStationsTable).insertOnConflictUpdate(
      LocalRadioStationsTableCompanion.insert(
        id: stationId,
        name: name,
        streamUrl: streamUrl,
        homePageUrl: Value(homePageUrl),
      ),
    );
    return stationId;
  }

  Future<void> deleteStation(String id) async {
    await (delete(
      localRadioStationsTable,
    )..where((table) => table.id.equals(id))).go();
  }
}
