import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  test(
    'v1 schema opens with expected user_version',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final pragmaRow = await database
          .customSelect('PRAGMA user_version;')
          .getSingle();

      expect(database.schemaVersion, 1);
      expect(pragmaRow.read<int>('user_version'), 1);
    },
    skip: !_sqliteAvailable,
  );
}
