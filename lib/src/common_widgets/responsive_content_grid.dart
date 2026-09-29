import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  )..layout(maxWidth: (extent - 16).clamp(1, double.infinity));
  final height = extent + 6 + painter.height;
  painter.dispose();
  return height;
}

/// A lazy collection grid whose cards remain bounded as its pane grows.
class ResponsiveContentSliverGrid extends ConsumerWidget {
  const ResponsiveContentSliverGrid({
    required this.itemCount,
    required this.itemBuilder,
    this.artists = false,
    this.trailingInset = 0,
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool artists;
  final double trailingInset;

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
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final grid = artists
            ? ContentLayout.artists(width, size)
            : ContentLayout.albums(width, size);
        final remainder = (width - grid.occupiedWidth) / 2;
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
              mainAxisExtent: artists
                  ? artistTileHeight(context, grid.extent)
                  : grid.extent,
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
