import 'package:drift/native.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;
import 'package:sqlite3/sqlite3.dart';

NavisDatabase createTestDatabase() {
  return NavisDatabase(NativeDatabase.memory());
}

List<Override> withTestDatabase(
  NavisDatabase database, {
  List<Override> overrides = const <Override>[],
}) {
  return <Override>[
    navisDatabaseProvider.overrideWithValue(database),
    ...overrides,
  ];
}

/// Whether the native SQLite3 library is available on this machine.
///
/// Use this to skip database-dependent tests in environments where the native
/// library is not bundled (e.g. some CI runners).
bool get sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}
