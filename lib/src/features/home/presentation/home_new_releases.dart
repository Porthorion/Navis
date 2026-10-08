import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/integrations/presentation/deezer_release_labels.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// Opens a New releases card: the library album when the library has the
/// release, else the server's remote album `ext-deezer-album-<id>`, whose page
/// loads it from the server (and offers a search when the server lacks it).
void openHomeNewRelease(
  BuildContext context,
  WidgetRef ref,
  HomeNewRelease release,
) {
  final libraryAlbumId = release.libraryAlbumId;
  if (libraryAlbumId != null) {
    NavService.openAlbumDetail(context, ref, libraryAlbumId);
    return;
  }
  NavService.openAlbumDetail(
    context,
    ref,
    remoteDeezerAlbumId(release.album.id),
    name: release.album.title,
    artistName: release.artistName,
  );
}

/// The New releases shelf: Home's album carousel with a card per release
/// showing its title and artist.
class HomeNewReleasesShelf extends ConsumerWidget {
  const new({
    required this.releases,
    required this.horizontalPadding,
    this.compact = false,
    super.key,
  });

  final List<HomeNewRelease> releases;
  final double horizontalPadding;

  /// Home's compact density.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final extent = ContentLayout.shelfCardExtent(width, compact: compact);
        final usableWidth = (width - horizontalPadding * 2).clamp(
          0.0,
          double.infinity,
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: ContentShelf(
            height: extent,
            extent: extent,
            gap: ContentLayout.gap(usableWidth),
            itemCount: releases.length,
            itemBuilder: (context, index) {
              final release = releases[index];
              return ExternalAlbumCard(
                key: ValueKey<String>('home-new-release-${release.album.id}'),
                title: release.album.title,
                subtitle: release.artistName,
                coverUrl: deezerReleaseCoverUrl(release.album),
                feature: IntegrationFeature.deezerNewReleases,
                extent: extent,
                onTap: () => openHomeNewRelease(context, ref, release),
              );
            },
          ),
        );
      },
    );
  }
}
