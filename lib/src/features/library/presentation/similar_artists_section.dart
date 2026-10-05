import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/similar_artist_entry.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_tokens.dart';

export 'package:navis/src/features/library/domain/similar_artist_entry.dart';

/// A grid of related artists below an artist's albums ("Similar Artists",
/// "Fans Also Like"), at most two rows.
///
/// Library artists show their library art and open their artist page. Other
/// artists show their Deezer photo with the quiet "Remote" mark and open
/// search for their name, never a missing artist page.
class SimilarArtistsSection extends ConsumerWidget {
  const new({required this.title, required this.artists, super.key});

  final String title;
  final List<SimilarArtistEntry> artists;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (artists.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      // The same space above the title as the album sections' headers.
      padding: const EdgeInsets.fromLTRB(
        NavisSpace.sm,
        NavisSpace.xl,
        NavisSpace.sm,
        NavisSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NavisSpace.xxs),
            child: NavisSectionHeader(title: title),
          ),
          const SizedBox(height: NavisSpace.xs),
          LayoutBuilder(
            builder: (context, constraints) {
              final grid = ContentLayout.artists(
                constraints.maxWidth,
                ref.watch(gridArtworkSizeProvider),
              );
              final crossAxisCount = grid.columns;
              final inset = (constraints.maxWidth - grid.occupiedWidth) / 2;
              final maxVisible = crossAxisCount * 2;
              final visibleArtists = artists
                  .take(maxVisible)
                  .toList(growable: false);

              return GridView.builder(
                padding: EdgeInsets.symmetric(horizontal: inset),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visibleArtists.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisExtent: artistTileHeight(context, grid.extent),
                  crossAxisSpacing: grid.gap,
                  mainAxisSpacing: grid.gap,
                ),
                itemBuilder: (context, index) =>
                    _SimilarArtistCard(artist: visibleArtists[index]),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SimilarArtistCard extends ConsumerWidget {
  const new({required this.artist});

  final SimilarArtistEntry artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryArtistId = artist.libraryArtistId;
    return InkWell(
      borderRadius: NavisRadius.mdAll,
      onTap: () => libraryArtistId != null
          ? NavService.openArtistDetail(context, ref, libraryArtistId)
          : NavService.openSearch(
              context,
              ref,
              artist.name,
              filter: SearchResultType.artists,
            ),
      onLongPress: libraryArtistId == null
          ? null
          : () =>
                unawaited(showArtistContextMenu(context, ref, libraryArtistId)),
      onSecondaryTapDown: libraryArtistId == null
          ? null
          : (details) => unawaited(
              showArtistContextMenu(
                context,
                ref,
                libraryArtistId,
                anchor: details.globalPosition,
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.all(NavisSpace.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Expanded(
              // Centred so the artwork stays square, and a circle stays
              // round, when the tile is taller than it is wide.
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: libraryArtistId != null
                      ? CoverArtImage(
                          coverArtId: artist.coverArt,
                          size: kCoverArtStandardSize,
                          shape: ArtworkShapeRole.artist,
                          placeholderIcon: Icons.person_outline,
                        )
                      : _ExternalArtistPhoto(url: artist.imageUrl),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A Deezer photo in the user's artist shape, marked as not in the library.
class _ExternalArtistPhoto extends ConsumerWidget {
  const new({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget placeholder(BuildContext _) => const CoverArtImage(
      coverArtId: null,
      shape: ArtworkShapeRole.artist,
      placeholderIcon: Icons.person_outline,
    );
    final photoUrl = url;
    final photo = photoUrl == null
        ? placeholder(context)
        : _clip(
            ref.watch(artistCardShapeProvider),
            ExternalArtworkImage(
              url: photoUrl,
              feature: IntegrationFeature.deezerSimilarArtists,
              fit: BoxFit.cover,
              fallbackBuilder: placeholder,
            ),
          );
    return RemoteSourceArtworkOverlay(isRemote: true, child: photo);
  }

  static Widget _clip(String shape, Widget child) {
    if (shape == 'circle') return ClipOval(child: child);
    return ClipRRect(
      borderRadius: artworkBorderRadius(shape, extent: double.infinity),
      child: child,
    );
  }
}
