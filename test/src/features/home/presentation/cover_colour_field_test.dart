import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';

ByteData _blocks(int size, List<Color> cells, {int transparentCell = -1}) {
  final bytes = ByteData(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final cell = (y * 3 ~/ size) * 3 + (x * 3 ~/ size);
      final color = cells[cell];
      final offset = (y * size + x) * 4;
      bytes
        ..setUint8(offset, (color.r * 255).round())
        ..setUint8(offset + 1, (color.g * 255).round())
        ..setUint8(offset + 2, (color.b * 255).round())
        ..setUint8(offset + 3, cell == transparentCell ? 0 : 255);
    }
  }
  return bytes;
}

void main() {
  const cells = <Color>[
    Color(0xFFFF0000),
    Color(0xFF00FF00),
    Color(0xFF0000FF),
    Color(0xFF101010),
    Color(0xFF808080),
    Color(0xFFF0F0F0),
    Color(0xFFFFFF00),
    Color(0xFF00FFFF),
    Color(0xFFFF00FF),
  ];

  test('averages each third of the cover into its grid cell', () {
    final colors = averageColourGrid(_blocks(24, cells), 24, 24);
    expect(colors, cells);
  });

  test('averages mixed pixels within a cell', () {
    final bytes = ByteData(3 * 3 * 4 * 4);
    // A 6x6 image: the top-left cell holds black and white pixels.
    const width = 6;
    for (var y = 0; y < width; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final value = (x < 2 && y < 2 && (x + y).isEven) ? 255 : 0;
        bytes
          ..setUint8(offset, value)
          ..setUint8(offset + 1, value)
          ..setUint8(offset + 2, value)
          ..setUint8(offset + 3, 255);
      }
    }
    final colors = averageColourGrid(bytes, width, width);
    expect(colors.first, const Color(0xFF7F7F7F));
    expect(colors[1], const Color(0xFF000000));
  });

  test('ignores transparent pixels', () {
    final colors = averageColourGrid(
      _blocks(24, cells, transparentCell: 4),
      24,
      24,
    );
    expect(colors[4].a, 0);
    expect(colors[0], cells[0]);
  });

  test('cache keeps the most recently used covers', () {
    final cache = CoverColourFieldCache(capacity: 2);
    final a = CoverColourField.uniform(const Color(0xFF111111));
    final b = CoverColourField.uniform(const Color(0xFF222222));
    final c = CoverColourField.uniform(const Color(0xFF333333));
    cache
      ..put('a', a)
      ..put('b', b);
    expect(cache.get('a'), a);
    cache.put('c', c);
    expect(cache.get('b'), isNull);
    expect(cache.get('a'), a);
    expect(cache.get('c'), c);
    expect(cache.length, 2);
  });

  test('fields interpolate cell by cell', () {
    final black = CoverColourField.uniform(const Color(0xFF000000));
    final white = CoverColourField.uniform(const Color(0xFFFFFFFF));
    final mid = CoverColourField.lerp(black, white, 0.5);
    expect(mid.colors.every((c) => (c.r - 0.5).abs() < 0.01), isTrue);
    expect(CoverColourField.lerp(black, white, 0), black);
  });

  test('painter repaints only when the colours change', () {
    final field = CoverColourField(cells);
    final same = CoverColourField(cells);
    final other = CoverColourField.uniform(const Color(0xFF000000));
    expect(
      CoverColourFieldPainter(field).shouldRepaint(
        CoverColourFieldPainter(same),
      ),
      isFalse,
    );
    expect(
      CoverColourFieldPainter(field).shouldRepaint(
        CoverColourFieldPainter(other),
      ),
      isTrue,
    );
  });

  testWidgets('paints a wide field without errors', (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 2000,
          height: 400,
          child: CustomPaint(
            painter: CoverColourFieldPainter(CoverColourField(cells)),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
