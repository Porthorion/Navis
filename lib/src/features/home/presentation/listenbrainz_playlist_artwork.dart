import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';

class ListenBrainzPlaylistArtwork extends StatelessWidget {
  const new({
    required this.playlist,
    required this.size,
    this.borderRadius = 8,
    super.key,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final image = playlist.playlist.image;
    if (image != null && Uri.tryParse(image)?.hasAbsolutePath == true) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.network(
          image,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _ListenBrainzArtworkMosaic(
            playlist: playlist,
            size: size,
            borderRadius: borderRadius,
          ),
        ),
      );
    }
    return _ListenBrainzArtworkMosaic(
      playlist: playlist,
      size: size,
      borderRadius: borderRadius,
    );
  }
}

class _ListenBrainzArtworkMosaic extends StatelessWidget {
  const new({
    required this.playlist,
    required this.size,
    required this.borderRadius,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final covers = playlist.recommendations
        .map(
          (recommendation) =>
              recommendation.song?.coverArt ??
              recommendation.tableSong?.coverArt,
        )
        .whereType<String>()
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .take(4)
        .toList(growable: false);
    final theme = Theme.of(context);
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(
        Icons.auto_awesome_outlined,
        color: theme.colorScheme.onSecondaryContainer,
        size: size * 0.36,
      ),
    );
    if (covers.isEmpty) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.square(
        dimension: size,
        child: GridView.count(
          crossAxisCount: covers.length == 1 ? 1 : 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: covers
              .map(
                (coverArt) => CoverArtImage(
                  coverArtId: coverArt,
                  size: size.round(),
                  borderRadius: BorderRadius.zero,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }
}
