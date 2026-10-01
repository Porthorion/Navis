import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Genres are not a Navis concept (product decision 2026-09-30): no genre
/// page, route, Library section, Home shelf, search filter, Android Auto node,
/// sync/scan input, catalog-change signal, recommendation input or diagnostics
/// field without an explicit product decision. See AGENTS.md.
final RegExp _genre = RegExp('genre', caseSensitive: false);

/// The only application sources allowed to mention genres, and why.
final Map<String, String Function(String)> _allowed = {
  // Historical, user-visible release notes describe what shipped and when.
  'lib/src/features/changelog/changelog_data.dart': (_) => '',
  // The schema 89 migration must name the genre storage it drops. Mentions
  // anywhere else in the database class are still violations.
  'lib/src/database/navis_database.dart': _withoutGenreRemovalMigration,
};

String _withoutGenreRemovalMigration(String source) {
  final method = source.indexOf('  Future<void> from88To89(');
  if (method < 0) return source;
  var start = method;
  while (true) {
    final previousLineStart = source.lastIndexOf('\n', start - 2) + 1;
    if (!source
        .substring(previousLineStart, start)
        .trimLeft()
        .startsWith(
          '///',
        )) {
      break;
    }
    start = previousLineStart;
  }
  final end = source.indexOf('\n  }\n', method);
  if (end < 0) return source;
  return source.replaceRange(start, end + 4, '');
}

void main() {
  test('application source has no genre feature residue', () {
    final violations = <String>[];
    final files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => file.path.replaceAll(r'\', '/'))
            .where(
              (path) =>
                  path.endsWith('.dart') &&
                  !path.endsWith('.g.dart') &&
                  !path.endsWith('.freezed.dart'),
            )
            .toList()
          ..sort();
    expect(files, isNotEmpty);
    for (final path in files) {
      final source = File(path).readAsStringSync();
      final scanned = (_allowed[path] ?? (String text) => text)(source);
      final lines = scanned.split('\n');
      for (var index = 0; index < lines.length; index++) {
        if (_genre.hasMatch(lines[index])) {
          violations.add('$path: ${lines[index].trim()}');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Genres are not a Navis concept. Remove the genre reference or '
          'record an explicit product decision before allowlisting it.',
    );
  });

  test('the migration allowlist removes only the genre-removal step', () {
    final source = File('lib/src/database/navis_database.dart')
        .readAsStringSync();
    final stripped = _withoutGenreRemovalMigration(source);
    expect(stripped, isNot(contains('from88To89(Migrator')));
    expect(stripped, contains('await from88To89(migrator);'));
    // The neighbouring v87 and v88 steps are not genre code and stay scanned.
    expect(stripped, contains('Future<void> from86To87('));
    expect(stripped, contains('Future<void> from87To88('));
    expect(source.length - stripped.length, lessThan(3000));
  });
}
