import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// A weekly playlist's cover, shaped by the Cover Art Shape setting:
/// ListenBrainz's own image when it has one, else [PlaylistCoverMosaic].
class ListenBrainzPlaylistArtwork extends ConsumerWidget {
  const new({required this.playlist, required this.size, super.key});

  final ListenBrainzDiscoverPlaylist playlist;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final borderRadius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: size,
    );
    final image = playlist.playlist.image;
    if (image != null && Uri.tryParse(image)?.hasAbsolutePath == true) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: ExternalArtworkImage(
          url: image,
          width: size,
          height: size,
          fit: BoxFit.cover,
          feature: IntegrationFeature.listenBrainzWeeklyPlaylists,
          fallbackBuilder: (_) => PlaylistCoverMosaic(
            coverArtIds: _coverArtIds(playlist),
            size: size,
          ),
        ),
      );
    }
    return PlaylistCoverMosaic(coverArtIds: _coverArtIds(playlist), size: size);
  }

  static List<String> _coverArtIds(ListenBrainzDiscoverPlaylist playlist) => [
    for (final recommendation in playlist.recommendations)
      ?(recommendation.song?.coverArt ?? recommendation.tableSong?.coverArt),
  ];
}

/// A virtual playlist's cover: up to four distinct song covers in a grid
/// (one fills it), shaped by the Cover Art Shape setting, or [fallbackIcon]
/// on the secondary container when there are none. Weekly playlists and
/// Trending Now share it.
class PlaylistCoverMosaic extends ConsumerWidget {
  const new({
    required this.coverArtIds,
    required this.size,
    this.fallbackIcon = Icons.auto_awesome_outlined,
    super.key,
  });

  final Iterable<String> coverArtIds;
  final double size;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final borderRadius = artworkBorderRadius(
      ref.watch(coverArtShapeProvider),
      extent: size,
    );
    final covers = coverArtIds
        .where((id) => id.trim().isNotEmpty)
        .toSet()
        .take(4)
        .toList(growable: false);
    final theme = Theme.of(context);
    if (covers.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: borderRadius,
        ),
        child: Icon(
          fallbackIcon,
          color: theme.colorScheme.onSecondaryContainer,
          size: size * 0.36,
        ),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius,
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
