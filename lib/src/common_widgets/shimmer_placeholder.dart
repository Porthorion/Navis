import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/theme/navis_tokens.dart';

class ShimmerPlaceholder extends StatefulWidget {
  const new({
    super.key,
    this.height = 16,
    this.width = double.infinity,
    this.borderRadius = NavisRadius.smAll,
  });

  final double height;
  final double width;
  final BorderRadius borderRadius;

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    final highlight = Theme.of(context).colorScheme.surface;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment(-1 + (_controller.value * 2), 0),
              end: Alignment.centerRight,
              colors: <Color>[baseColor, highlight, baseColor],
              stops: const <double>[0.1, 0.5, 0.9],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable shimmer skeletons for lists of track / album / playlist items.
// ---------------------------------------------------------------------------

/// A skeleton that mimics a single list tile with a leading square thumbnail,
/// a title bar, and a subtitle bar — suitable for track, album, or playlist
/// loading states. With [songRows] it is as tall as a loaded song row
/// ([trackRowSkeletonHeight]), so the list does not jump when data arrives.
class ShimmerListTile extends StatelessWidget {
  const new({
    super.key,
    this.leadingSize = 48,
    this.songRows = false,
    this.songBadge = false,
  });

  final double leadingSize;
  final bool songRows;

  /// With [songRows]: the loaded rows have a badge line (Downloads).
  final bool songBadge;

  @override
  Widget build(BuildContext context) {
    if (!songRows) return _tile();
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = trackRowSkeletonHeight(
          context,
          constraints.maxWidth,
          badge: songBadge,
        );
        return height == null
            ? _tile()
            : SizedBox(
                height: height,
                child: Center(child: _tile()),
              );
      },
    );
  }

  Widget _tile() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          ShimmerPlaceholder(
            height: leadingSize,
            width: leadingSize,
            borderRadius: NavisRadius.xsAll,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                ShimmerPlaceholder(height: 14, width: double.infinity),
                SizedBox(height: 6),
                ShimmerPlaceholder(height: 12, width: 140),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A full-screen shimmer list page with [count] [ShimmerListTile] items.
/// Use this as the `loading:` fallback in `AsyncValue.when(...)`.
class ShimmerListPage extends StatelessWidget {
  const new({
    super.key,
    this.count = 10,
    this.leadingSize = 48,
    this.songRows = false,
    this.songBadge = false,
  });

  final int count;
  final double leadingSize;

  /// See [ShimmerListTile.songRows].
  final bool songRows;

  /// See [ShimmerListTile.songBadge].
  final bool songBadge;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      primary: false,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: count,
      itemBuilder: (_, _) => ShimmerListTile(
        leadingSize: leadingSize,
        songRows: songRows,
        songBadge: songBadge,
      ),
    );
  }
}
