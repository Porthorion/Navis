import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sqlite3/sqlite3.dart';

NavisDatabase createTestDatabase({File? file}) {
  // Close query streams as soon as their last listener leaves. Otherwise
  // drift keeps them for one event-loop turn with a timer, which widget tests
  // report as pending when auto-disposed providers release a stream while the
  // widget tree is torn down.
  return NavisDatabase(
    DatabaseConnection(
      file == null ? NativeDatabase.memory() : NativeDatabase(file),
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
/// library is not bundled (e.g. some CI runners).
bool get sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.close();
    return true;
  } on Object {
    return false;
  }
}
