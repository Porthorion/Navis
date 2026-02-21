import 'package:drift/native.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

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
