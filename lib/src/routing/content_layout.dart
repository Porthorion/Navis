import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:navis/src/routing/desktop_layout.dart';

enum GridArtworkSize {
  auto,
  small,
  medium,
  large;

  static GridArtworkSize parse(String value) =>
      values.firstWhere((size) => size.name == value, orElse: () => auto);
}

enum TrackRowMode { compact, medium, wide }

/// Geometry resolved from the content pane, after navigation and padding.
@immutable
class ContentGridGeometry {
  const new({required this.columns, required this.extent, required this.gap});

  factory bounded({
    required double width,
    required double minimum,
    required double maximum,
    required double gap,
  }) {
    assert(width.isFinite && width >= 0, 'Pane width must be finite.');
    final columns = math.max(1, ((width + gap) / (minimum + gap)).floor());
    return ContentGridGeometry(
      columns: columns,
      extent: math.min(maximum, (width - (columns - 1) * gap) / columns),
      gap: gap,
    );
  }
  final int columns;
  final double extent;
  final double gap;

  double get occupiedWidth => columns * extent + (columns - 1) * gap;
}

class ContentLayout {
  const new _();

  static double padding(double width) => width < kAdaptiveMediumWidth ? 12 : 24;
  static double gap(double width) => width < kAdaptiveMediumWidth ? 8 : 12;

  static ContentGridGeometry albums(double width, GridArtworkSize size) {
    final narrow = width < kAdaptiveMediumWidth;
    final bounds = switch (size) {
      GridArtworkSize.small => narrow ? (120.0, 152.0) : (152.0, 184.0),
      GridArtworkSize.auto ||
      GridArtworkSize.medium => narrow ? (148.0, 184.0) : (180.0, 220.0),
      GridArtworkSize.large => narrow ? (172.0, 216.0) : (220.0, 268.0),
    };
    return ContentGridGeometry.bounded(
      width: width,
      minimum: bounds.$1,
      maximum: bounds.$2,
      gap: gap(width),
    );
  }

  static ContentGridGeometry artists(double width, GridArtworkSize size) {
    final narrow = width < kAdaptiveMediumWidth;
    final bounds = switch (size) {
      GridArtworkSize.small => narrow ? (104.0, 128.0) : (120.0, 152.0),
      GridArtworkSize.auto ||
      GridArtworkSize.medium => narrow ? (120.0, 152.0) : (144.0, 176.0),
      GridArtworkSize.large => narrow ? (144.0, 176.0) : (176.0, 216.0),
    };
    return ContentGridGeometry.bounded(
      width: width,
      minimum: bounds.$1,
      maximum: bounds.$2,
      gap: gap(width),
    );
  }

  /// The square card size of a horizontal album shelf: Home's album
  /// carousels and an artist page's Missing Albums. [compact] is Home's
  /// compact section density.
  static double shelfCardExtent(double width, {bool compact = false}) {
    if (width < kAdaptiveMediumWidth) return compact ? 138 : 150;
    return compact ? 152 : 164;
  }

  static int shelfLimit(double width, double extent) =>
      math.max(1, ((width + gap(width)) / (extent + gap(width))).ceil()) * 2;

  static TrackRowMode trackMode(double width, TextScaler scaler) {
    final effectiveWidth = width / math.max(1, scaler.scale(14) / 14);
    if (effectiveWidth >= 960) return TrackRowMode.wide;
    if (effectiveWidth >= 720) return TrackRowMode.medium;
    return TrackRowMode.compact;
  }

  static ContentGridGeometry radio(double width) => width < kAdaptiveMediumWidth
      ? ContentGridGeometry(columns: 1, extent: width, gap: 12)
      : ContentGridGeometry.bounded(
          width: width,
          minimum: 280,
          maximum: 360,
          gap: 12,
        );
}
