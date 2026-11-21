import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../helpers/test_database.dart';

void main() {
  for (final nested in [false, true]) {
    test(
      'transaction completes in fake microtasks (nested: $nested)',
      () async {
        final database = createTestDatabase();
        final clock = FakeAsync();
        addTearDown(() async {
          // Also clean up a broken implementation whose cancellation escapes
          // to the real queue before scheduling more fake microtasks.
          await Future<void>.delayed(Duration.zero);
          clock.flushMicrotasks();
          await database.close();
        });
        await database.customSelect('SELECT 1').get();
        final updates = <Set<TableUpdate>>[];
        var completed = false;
        clock.run((_) {
          final subscription = database.tableUpdates().listen(updates.add);
          unawaited(
            database
                .transaction(() async {
                  Future<void> write() async {
                    await database
                        .into(database.artistsTable)
                        .insert(
                          ArtistsTableCompanion.insert(
                            id: 'artist',
                            name: 'Artist',
                          ),
                        );
                  }

                  if (nested) {
                    await database.transaction(write, requireNew: true);
                  } else {
                    await write();
                  }
                })
                .then((_) {
                  completed = true;
                }),
          );
          clock.flushMicrotasks();
          unawaited(subscription.cancel());
        });

        expect(completed, isTrue, reason: 'commit stays in the fake queue');
        expect(
          updates.where((set) => set.any((u) => u.table == 'artists')),
          hasLength(1),
        );
        expect(await database.libraryDao.getArtistById('artist'), isNotNull);
      },
      skip: !sqliteAvailable,
    );
  }

  test('rollback completes in fake microtasks', () async {
    final database = createTestDatabase();
    final clock = FakeAsync();
    addTearDown(() async {
      await Future<void>.delayed(Duration.zero);
      clock.flushMicrotasks();
      await database.close();
    });
    await database.customSelect('SELECT 1').get();
    final error = StateError('rollback sentinel');
    Object? caught;
    final updates = <Set<TableUpdate>>[];
    clock.run((_) {
      final subscription = database.tableUpdates().listen(updates.add);
      unawaited(
        database
            .transaction(() async {
              await database
                  .into(database.artistsTable)
                  .insert(
                    ArtistsTableCompanion.insert(
                      id: 'discard',
                      name: 'Discard',
                    ),
                  );
              throw error;
            })
            .then<void>(
              (_) => fail('Transaction must roll back'),
              onError: (Object failure, StackTrace _) {
                caught = failure;
              },
            ),
      );
      clock.flushMicrotasks();
      unawaited(subscription.cancel());
    });

    expect(caught, same(error));
    expect(await database.libraryDao.getArtistById('discard'), isNull);
  }, skip: !sqliteAvailable);
}
