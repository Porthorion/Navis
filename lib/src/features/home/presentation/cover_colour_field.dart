import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Side of the colour grid sampled from a cover.
const int kCoverColourGrid = 3;

/// Decode size used for sampling; small enough to read instantly.
const int _kSampleSize = 24;

/// A [kCoverColourGrid]×[kCoverColourGrid] grid of a cover's average
/// colours, row-major from the top-left.
@immutable
class CoverColourField {
  const CoverColourField(this.colors)
    : assert(
        colors.length == kCoverColourGrid * kCoverColourGrid,
        'A colour field needs one colour per grid cell.',
      );

  /// Every cell the same colour; used when a cover has no usable art.
  factory CoverColourField.uniform(Color color) => CoverColourField(
    List<Color>.filled(kCoverColourGrid * kCoverColourGrid, color),
  );

  /// The field between [a] and [b] at [t], cell by cell.
  factory CoverColourField.lerp(
    CoverColourField a,
    CoverColourField b,
    double t,
  ) {
    return CoverColourField(<Color>[
      for (var i = 0; i < a.colors.length; i++)
        Color.lerp(a.colors[i], b.colors[i], t)!,
    ]);
  }

  final List<Color> colors;

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
@visibleForTesting
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

/// Small least-recently-used cache so revisiting a cover reuses its field.
@visibleForTesting
class CoverColourFieldCache {
  CoverColourFieldCache({this.capacity = 64});

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

  int get length => _entries.length;
}

final CoverColourFieldCache _fieldCache = CoverColourFieldCache();

/// Colour field for a cover, sampled from the already-cached 600 px artwork.
///
/// Uses the same URL and cache key as the album cards, so it never makes a
/// new request; only a 24 px decode is read.
final coverColourFieldProvider = FutureProvider.autoDispose
    .family<CoverColourField?, String>((ref, coverId) async {
      final cached = _fieldCache.get(coverId);
      if (cached != null) return cached;
      final api = ref.watch(subsonicApiProvider);
      if (api == null) return null;
      final cacheManager = ref.watch(coverArtCacheManagerProvider);
      final provider = ResizeImage(
        CachedNetworkImageProvider(
          api
              .getCoverArtUrl(id: coverId, size: kCoverArtStandardSize)
              .toString(),
          cacheKey: coverArtImageCacheKey(coverId, kCoverArtStandardSize),
          cacheManager: cacheManager,
        ),
        width: _kSampleSize,
        height: _kSampleSize,
      );
      final info = await _resolveImage(provider);
      if (info == null) return null;
      try {
        final bytes = await info.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (bytes == null) return null;
        final colors = averageColourGrid(
          bytes,
          info.image.width,
          info.image.height,
        );
        if (colors.any((color) => color.a == 0)) return null;
        final field = CoverColourField(colors);
        _fieldCache.put(coverId, field);
        return field;
      } finally {
        info.dispose();
      }
    });

Future<ImageInfo?> _resolveImage(ImageProvider provider) {
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
  const CoverColourFieldPainter(this.field);

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
