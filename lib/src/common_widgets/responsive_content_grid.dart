import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SliverConstraints;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';

double artistTileHeight(BuildContext context, double extent) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'Ag\nAg',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 2,
  )..layout(maxWidth: extent.clamp(1, double.infinity));
  final height = extent + 6 + painter.height;
  painter.dispose();
  return height;
}

/// Remembers which grid item leads the viewport, so a geometry change (fold,
/// rotation, resize, text scale) can put that item back in the first row.
///
/// A `PageStorageKey` restores a pixel offset, which lands on a different item
/// once the column count or the tile size changes. The owner State keeps one
/// anchor per scroll view (it survives the layout class rebuild) and passes it
/// to every grid sliver in that view. It is a plain object written during
/// layout, so nothing here notifies or calls `setState`.
class GridScrollAnchor {
  /// Skips tracking and correction, for example while the alphabet rail is
  /// scrubbed.
  bool paused = false;

  // The grid section holding the leading item; null until one is claimed.
  Object? _owner;
  // Leading item inside the owner, last stride, and where the owner starts.
  int _index = 0;
  double _stride = 0;
  double _ownerStart = 0;
  int _columns = 1;
  int _itemCount = 0;
  bool _jumpPending = false;

  /// Forgets the owner when [gone] says its section no longer exists.
  void releaseWhere(bool Function(Object owner) gone) {
    final owner = _owner;
    if (owner != null && !_jumpPending && gone(owner)) {
      _owner = null;
    }
  }

  void _track(
    BuildContext context,
    Object id,
    SliverConstraints constraints, {
    required int itemCount,
    required int columns,
    required double stride,
    required double gap,
    required double bottomPadding,
  }) {
    if (paused) {
      return;
    }
    final mine = _owner == id;
    final start = constraints.precedingScrollExtent;
    if (_jumpPending) {
      if (mine) {
        _ownerStart = start;
        _columns = columns;
        _itemCount = itemCount;
      }
      return;
    }
    if (_owner != null && (_stride != stride || _columns != columns)) {
      // The geometry (row height or column count) changed under a restored
      // pixel offset, which now points at another item: only the owner moves
      // the view back to its item.
      if (!mine) {
        return;
      }
      _ownerStart = start;
      _columns = columns;
      _itemCount = itemCount;
      _stride = stride;
      _jumpPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpPending = false;
        final position = context.mounted
            ? Scrollable.maybeOf(context)?.position
            : null;
        if (position == null || !position.hasPixels) {
          return;
        }
        final row = math.min(_index, _itemCount - 1) ~/ _columns;
        final target = (_ownerStart + row * _stride).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() > 0.5) {
          position.jumpTo(target);
        }
      });
      return;
    }
    _stride = stride;
    final rows = (itemCount + columns - 1) ~/ columns;
    final scrolledPast =
        constraints.scrollOffset >= rows * stride - gap + bottomPadding - 0.5;
    if (scrolledPast) {
      if (mine) {
        _owner = null;
      }
      return;
    }
    // The topmost section not scrolled past owns the anchor; sections lay out
    // top to bottom, so the first claimant of a pass has the smallest start.
    if (_owner == null || mine || start < _ownerStart) {
      // First row with any part below the top edge: an offset inside the gap
      // under a row leads with the next row. The gap also absorbs float error
      // right after a jump to a row top.
      final row = (constraints.scrollOffset + gap) ~/ stride;
      // Keep the exact item while its row leads: refolding then returns to
      // the item the reader started from, not to the first item of a row.
      if (!mine || row != _index ~/ columns) {
        _index = math.min(row * columns, itemCount - 1);
      }
      _owner = id;
      _ownerStart = start;
      _columns = columns;
      _itemCount = itemCount;
    }
  }
}

/// A lazy collection grid whose cards remain bounded as its pane grows.
///
/// With an [anchor], the item leading the viewport stays in the first row
/// when the geometry changes. [anchorId] tells the sections of one scroll view
/// apart.
class ResponsiveContentSliverGrid extends ConsumerWidget {
  const new({
    required this.itemCount,
    required this.itemBuilder,
    this.artists = false,
    this.trailingInset = 0,
    this.anchor,
    this.anchorId = '',
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool artists;
  final double trailingInset;
  final GridScrollAnchor? anchor;
  final Object anchorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(gridArtworkSizeProvider);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final padding = ContentLayout.padding(constraints.crossAxisExtent);
        final width =
            (constraints.crossAxisExtent - padding * 2 - trailingInset).clamp(
              0.0,
              double.infinity,
            );
        if (width <= 0 || itemCount == 0) {
          anchor?.releaseWhere((owner) => owner == anchorId);
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final grid = artists
            ? ContentLayout.artists(width, size)
            : ContentLayout.albums(width, size);
        final remainder = (width - grid.occupiedWidth) / 2;
        final mainAxisExtent = artists
            ? artistTileHeight(context, grid.extent)
            // Flat text over artwork puts the album caption under the
            // square cover, so the album cell grows by its height.
            : grid.extent + albumCardExtraHeight(context);
        anchor?._track(
          context,
          anchorId,
          constraints,
          itemCount: itemCount,
          columns: grid.columns,
          stride: mainAxisExtent + grid.gap,
          gap: grid.gap,
          bottomPadding: padding,
        );
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            padding + remainder,
            0,
            padding + remainder + trailingInset,
            padding,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: grid.columns,
              mainAxisExtent: mainAxisExtent,
              crossAxisSpacing: grid.gap,
              mainAxisSpacing: grid.gap,
            ),
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: itemCount,
            ),
          ),
        );
      },
    );
  }
}
