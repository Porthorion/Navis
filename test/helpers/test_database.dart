import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

NavisDatabase createTestDatabase({File? file}) {
  // Close query streams as soon as their last listener leaves. Otherwise
  // drift keeps them for one event-loop turn with a timer, which widget tests
  // report as pending when auto-disposed providers release a stream while the
  // widget tree is torn down.
  return NavisDatabase(
    DatabaseConnection(
      file == null
          ? NativeDatabase.memory(setup: registerSearchFoldFunction)
          : NativeDatabase(file, setup: registerSearchFoldFunction),
      closeStreamsSynchronously: true,
    ),
  );
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
/// library is not bundled (e.g. some CI runners). With `NAVIS_REQUIRE_SQLITE=1`
/// (tool/check.sh and CI) a missing library throws instead, so the database
/// suites cannot pass with every test skipped.
bool get sqliteAvailable => checkSqliteAvailable(
  () => sqlite3.openInMemory().close(),
  require: Platform.environment['NAVIS_REQUIRE_SQLITE'] == '1',
);

@visibleForTesting
bool checkSqliteAvailable(void Function() open, {required bool require}) {
  try {
    open();
    return true;
  } on Object catch (error) {
    if (require) {
      throw StateError(
        'NAVIS_REQUIRE_SQLITE=1 but native SQLite3 is unavailable ($error); '
        'database tests would be silently skipped.',
      );
    }
    return false;
  }
}

Future<List<LibraryRecoveryReviewTableData>> pendingRecoveryReviews(
  NavisDatabase database,
  int serverId,
) =>
    (database.select(database.libraryRecoveryReviewTable)..where(
          (table) =>
              table.serverId.equals(serverId) &
              table.disposition.equals('pending'),
        ))
        .get();
