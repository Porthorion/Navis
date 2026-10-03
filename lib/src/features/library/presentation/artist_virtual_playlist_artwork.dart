import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// Rotating cover art for an artist's virtual playlist, shaped by the Cover
/// Art Shape setting.
class ArtistVirtualPlaylistArtwork extends ConsumerStatefulWidget {
  const new({
    required this.coverArtIds,
    required this.size,
    this.imageUrl,
    super.key,
  });

  final List<String> coverArtIds;
  final String? imageUrl;
  final double size;

  @override
  ConsumerState<ArtistVirtualPlaylistArtwork> createState() =>
      _ArtistVirtualPlaylistArtworkState();
}

class _ArtistVirtualPlaylistArtworkState
    extends ConsumerState<ArtistVirtualPlaylistArtwork> {
  Timer? _timer;
  int _index = 0;

  List<String> get _distinctCoverArtIds {
    final seen = <String>{};
    return widget.coverArtIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && seen.add(id))
        .take(6)
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ArtistVirtualPlaylistArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverArtIds != widget.coverArtIds) {
      _index = 0;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final canAnimate = _distinctCoverArtIds.length >= 2;
    if (!canAnimate) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      final covers = _distinctCoverArtIds;
      if (covers.length < 2) return;
      setState(() => _index = (_index + 1) % covers.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final radius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: widget.size,
    );
    final covers = _distinctCoverArtIds;
    if (covers.length >= 2) {
      final coverArtId = covers[_index % covers.length];
      return ClipRRect(
        borderRadius: radius,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 1400),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final scale = Tween<double>(begin: 1.025, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: scale, child: child),
            );
          },
          child: CoverArtImage(
            key: ValueKey<String>(coverArtId),
            coverArtId: coverArtId,
            size: kCoverArtStandardSize,
            width: widget.size,
            height: widget.size,
            borderRadius: BorderRadius.zero,
            placeholderIcon: Icons.queue_music,
          ),
        ),
      );
    }

    final singleCover = covers.singleOrNull;
    if (singleCover != null) {
      return CoverArtImage(
        coverArtId: singleCover,
        size: kCoverArtStandardSize,
        width: widget.size,
        height: widget.size,
        borderRadius: radius,
        placeholderIcon: Icons.queue_music,
      );
    }

    final url = widget.imageUrl?.trim() ?? '';
    if (url.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: url,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) =>
              _ArtworkPlaceholder(size: widget.size, borderRadius: radius),
        ),
      );
    }

    return _ArtworkPlaceholder(size: widget.size, borderRadius: radius);
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const new({required this.size, required this.borderRadius});

  final double size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: borderRadius,
      ),
      child: Icon(
        Icons.queue_music,
        size: size * 0.34,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
