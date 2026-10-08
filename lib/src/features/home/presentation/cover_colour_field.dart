import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

export 'package:navis/src/features/home/presentation/cover_colour_sampler.dart'
    show coverColourFieldProvider;

/// Side of the colour grid sampled from a cover.
const int kCoverColourGrid = 3;

/// A [kCoverColourGrid]×[kCoverColourGrid] grid of a cover's average
/// colours, row-major from the top-left.
@immutable
class CoverColourField {
  const new(this.colors)
    : assert(
        colors.length == kCoverColourGrid * kCoverColourGrid,
        'A colour field needs one colour per grid cell.',
      );

  /// Every cell the same colour; used when a cover has no usable art.
  factory uniform(Color color) => CoverColourField(
    List<Color>.filled(kCoverColourGrid * kCoverColourGrid, color),
  );

  /// The field between [a] and [b] at [t], cell by cell.
  factory lerp(CoverColourField a, CoverColourField b, double t) {
    return CoverColourField(<Color>[
      for (var i = 0; i < a.colors.length; i++)
        Color.lerp(a.colors[i], b.colors[i], t)!,
    ]);
  }

  final List<Color> colors;

  /// Average of the bottom row of the grid: the colour under a caption drawn
  /// along the cover's lower edge.
  Color get bottomRowAverage {
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    for (var column = 0; column < kCoverColourGrid; column++) {
      final color = colors[(kCoverColourGrid - 1) * kCoverColourGrid + column];
      r += color.r;
      g += color.g;
      b += color.b;
    }
    return Color.from(
      alpha: 1,
      red: r / kCoverColourGrid,
      green: g / kCoverColourGrid,
      blue: b / kCoverColourGrid,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoverColourField && _listEquals(other.colors, colors);

  @override
  int get hashCode => Object.hashAll(colors);

  static bool _listEquals(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Averages an RGBA buffer into a [grid]×[grid] row-major colour grid.
///
/// Transparent pixels are ignored so letterboxed covers do not wash out.
List<Color> averageColourGrid(
  ByteData rgba,
  int width,
  int height, {
  int grid = kCoverColourGrid,
}) {
  final sums = List<List<int>>.generate(grid * grid, (_) => [0, 0, 0, 0]);
  for (var y = 0; y < height; y++) {
    final row = (y * grid ~/ height).clamp(0, grid - 1);
    for (var x = 0; x < width; x++) {
      final column = (x * grid ~/ width).clamp(0, grid - 1);
      final offset = (y * width + x) * 4;
      final alpha = rgba.getUint8(offset + 3);
      if (alpha == 0) continue;
      final cell = sums[row * grid + column];
      cell[0] += rgba.getUint8(offset);
      cell[1] += rgba.getUint8(offset + 1);
      cell[2] += rgba.getUint8(offset + 2);
      cell[3] += 1;
    }
  }
  return <Color>[
    for (final cell in sums)
      if (cell[3] == 0)
        Colors.transparent
      else
        Color.fromARGB(
          255,
          cell[0] ~/ cell[3],
          cell[1] ~/ cell[3],
          cell[2] ~/ cell[3],
        ),
  ];
}

/// Fields kept in memory. Each is nine colours, so a few hundred cost
/// kilobytes; the size covers a long grid plus its rails.
const int kCoverColourFieldCacheCapacity = 512;

/// Small least-recently-used cache so revisiting a cover reuses its field.
class CoverColourFieldCache {
  new({this.capacity = kCoverColourFieldCacheCapacity});

  final int capacity;
  final LinkedHashMap<String, CoverColourField> _entries =
      LinkedHashMap<String, CoverColourField>();

  CoverColourField? get(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(String key, CoverColourField value) {
    _entries
      ..remove(key)
      ..[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// The cached value without marking it recently used.
  CoverColourField? peek(String key) => _entries[key];

  void clear() => _entries.clear();

  int get length => _entries.length;
}

/// The cache behind [peekCoverColourField] and the app-wide sampler.
final CoverColourFieldCache sharedCoverColourFieldCache =
    CoverColourFieldCache();

/// The cached field for [coverId], if it was already sampled. Lets a card
/// paint its final colours on first build instead of flashing the fallback.
CoverColourField? peekCoverColourField(String coverId) =>
    sharedCoverColourFieldCache.get(coverId);

/// Resolves [provider] to its first decoded frame, or null on error.
Future<ImageInfo?> resolveImageInfo(ImageProvider provider) {
  final completer = Completer<ImageInfo?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(info);
    },
    onError: (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Paints [field] as a smoothly shaded mesh.
///
/// Each grid colour is a vertex and the GPU interpolates between them, so
/// the field stays smooth at any size, unlike an upscaled image, and costs a
/// single draw call. The mesh extends past the bounds so no edge is visible.
class CoverColourFieldPainter extends CustomPainter {
  const new(this.field);

  final CoverColourField field;

  @override
  void paint(Canvas canvas, Size size) {
    const grid = kCoverColourGrid;
    const overscan = 0.12;
    final positions = <Offset>[];
    for (var row = 0; row < grid; row++) {
      for (var column = 0; column < grid; column++) {
        final fx = -overscan + (1 + 2 * overscan) * column / (grid - 1);
        final fy = -overscan + (1 + 2 * overscan) * row / (grid - 1);
        positions.add(Offset(fx * size.width, fy * size.height));
      }
    }
    final indices = <int>[];
    for (var row = 0; row < grid - 1; row++) {
      for (var column = 0; column < grid - 1; column++) {
        final topLeft = row * grid + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + grid;
        final bottomRight = bottomLeft + 1;
        indices.addAll(<int>[
          topLeft,
          topRight,
          bottomLeft,
          topRight,
          bottomRight,
          bottomLeft,
        ]);
      }
    }
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      colors: field.colors,
      indices: indices,
    );
    // BlendMode.dst keeps the vertex colours as painted.
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }

  @override
  bool shouldRepaint(CoverColourFieldPainter oldDelegate) =>
      oldDelegate.field != field;
}
