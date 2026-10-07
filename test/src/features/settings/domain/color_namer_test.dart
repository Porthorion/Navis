import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/color_name_table.g.dart';
import 'package:navis/src/features/settings/domain/color_namer.dart';

void main() {
  group('nameForColor', () {
    // Exact values from the pinned colour-name CSV, including a non-primary.
    for (final (name, rgb) in <(String, int)>[
      ('Black', 0x000000),
      ('White', 0xffffff),
      ('Red', 0xff0000),
      ('Blue', 0x0000ff),
      ('Snow', 0xfffafa),
      ('Lime', 0xaaff32),
    ]) {
      test('names exact $name', () {
        expect(nameForColor(Color(0xff000000 | rgb)), name);
      });
    }

    test('a slightly perturbed red keeps its name', () {
      expect(nameForColor(const Color(0xffff0100)), 'Red');
    });

    test('ignores alpha', () {
      expect(nameForColor(const Color(0x00ff0000)), 'Red');
      expect(nameForColor(const Color(0x80ff0000)), 'Red');
    });
  });

  test('table is non-empty, sorted by name, with unique RGB values', () {
    expect(kColorNameTable, isNotEmpty);
    final values = kColorNameTable.map((entry) => entry.$2);
    expect(values.toSet().length, kColorNameTable.length);
    final names = kColorNameTable.map((entry) => entry.$1).toList();
    expect(names, orderedEquals([...names]..sort()));
  });
}
