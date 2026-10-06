import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('every Navis DAO routes transactions through the database', () {
    final files = Directory('lib/src/database/daos')
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              p.extension(file.path) == '.dart' &&
              !file.path.endsWith('.g.dart'),
        );
    final accessors = RegExp(
      r'class\s+\w+\s+extends\s+DatabaseAccessor<NavisDatabase>\s+with\s+([^\{]+)\{',
    );
    var count = 0;
    for (final file in files) {
      for (final declaration in accessors.allMatches(file.readAsStringSync())) {
        count++;
        expect(
          declaration.group(1),
          contains('NavisDaoTransactions'),
          reason: file.path,
        );
      }
    }
    expect(count, 18);
  });
}
