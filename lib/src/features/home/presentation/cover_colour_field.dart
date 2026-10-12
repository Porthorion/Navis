import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/utils/bounded_lru_map.dart';

export 'package:navis/src/features/home/presentation/cover_colour_sampler.dart'
    show backgroundCoverColourFieldProvider, coverColourFieldProvider;

/// Side of the colour grid sampled from a cover.
const int kCoverColourGrid = 3;

/// A [kCoverColourGrid]×[kCoverColourGrid] grid of a cover's average
/// colours, row-major from the top-left.
@immutable
class CoverColourField {
  const new(this.colors, {this.revision = 0})
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

  /// Artwork revision sampled into this field. Retained with cached colours
  /// so a visible caller can refresh lazily without losing the old field.
  final int revision;

  /// Average of the bottom row of the grid: the colour under a caption drawn
  /// along the cover's lower edge.
  Color get bottomRowAverage =>
      _averageColors(colors.skip((kCoverColourGrid - 1) * kCoverColourGrid))!;

  /// Opaque average of usable cells, or null for an entirely transparent field.
  Color? get average => _averageColors(colors.where((color) => color.a > 0));

  static Color? _averageColors(Iterable<Color> colors) {
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    var count = 0;
    for (final color in colors) {
      r += color.r;
      g += color.g;
      b += color.b;
      count++;
    }
    if (count == 0) return null;
    return Color.from(
      alpha: 1,
      red: r / count,
      green: g / count,
      blue: b / count,
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

/// Fields kept in memory. Each is nine colours, so a few hundred cost
/// kilobytes; the size covers a long grid plus its rails.
const int kCoverColourFieldCacheCapacity = 512;

/// Small least-recently-used cache so revisiting a cover reuses its field.
class CoverColourFieldCache {
  new({this.capacity = kCoverColourFieldCacheCapacity})
    : _entries = BoundedLruMap(capacity: capacity);

  final int capacity;
  final BoundedLruMap<String, CoverColourField> _entries;

  CoverColourField? get(String key) => _entries.get(key);

  void put(String key, CoverColourField value) => _entries.put(key, value);

  /// The cached value without marking it recently used.
  CoverColourField? peek(String key) =>
      _entries.get(key, refreshRecency: false);

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
