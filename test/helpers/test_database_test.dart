import 'package:flutter_test/flutter_test.dart';

import 'test_database.dart';

void main() {
  void missingSqlite() => throw Exception('libsqlite3.so not found');

  test('missing SQLite skips quietly unless it is required', () {
    expect(checkSqliteAvailable(missingSqlite, require: false), isFalse);
    expect(checkSqliteAvailable(() {}, require: false), isTrue);
  });

  test('missing SQLite fails when NAVIS_REQUIRE_SQLITE is set', () {
    expect(
      () => checkSqliteAvailable(missingSqlite, require: true),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('NAVIS_REQUIRE_SQLITE=1'),
        ),
      ),
    );
    expect(checkSqliteAvailable(() {}, require: true), isTrue);
  });
}
