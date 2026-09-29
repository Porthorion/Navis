import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/eq_tables.dart';

part 'eq_dao.g.dart';

@DriftAccessor(tables: [EqPresetsTable, EqStateTable])
class EqDao extends DatabaseAccessor<NavisDatabase> with _$EqDaoMixin {
  EqDao(super.attachedDatabase);

  Future<List<EqPresetsTableData>> getPresets() => (select(
    eqPresetsTable,
  )..orderBy([(t) => OrderingTerm.asc(t.normalizedName)])).get();

  Future<EqStateTableData?> getState() =>
      (select(eqStateTable)..where((t) => t.id.equals(1))).getSingleOrNull();

  Future<void> saveState({
    required String configurationJson,
    required String? selectedPresetId,
    required String? originPresetId,
    String? workspacesJson,
  }) async {
    await into(eqStateTable).insertOnConflictUpdate(
      EqStateTableCompanion.insert(
        id: const Value(1),
        configurationJson: Value(configurationJson),
        selectedPresetId: Value(selectedPresetId),
        originPresetId: Value(originPresetId),
        workspacesJson: workspacesJson == null
            ? const Value.absent()
            : Value(workspacesJson),
        // An ordinary save must not acknowledge an unread migration notice.
        legacyResetNotice: const Value.absent(),
      ),
    );
  }

  Future<void> savePreset({
    required String id,
    required String name,
    required String presetJson,
  }) async {
    await into(eqPresetsTable).insertOnConflictUpdate(
      EqPresetsTableCompanion.insert(
        id: id,
        name: name,
        normalizedName: name.trim().toLowerCase(),
        presetJson: presetJson,
      ),
    );
  }

  Future<void> deletePreset(String id) async {
    await (delete(eqPresetsTable)..where((t) => t.id.equals(id))).go();
  }

  Future<void> acknowledgeLegacyReset() async {
    await (update(eqStateTable)..where((t) => t.id.equals(1))).write(
      const EqStateTableCompanion(legacyResetNotice: Value(false)),
    );
  }
}
