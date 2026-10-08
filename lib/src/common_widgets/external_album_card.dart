import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// An album card for a release that is not on the server, such as a Deezer
/// album: the same square, cover-shaped card and label as [AlbumCard], with
/// the cover loaded from [coverUrl].
///
/// The cover follows [feature]'s switch (for example `deezer.missingAlbums`)
/// and falls back to the album placeholder when it is off or fails to load.
class ExternalAlbumCard extends ConsumerWidget {
  const new({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.feature,
    this.extent,
    this.onTap,
    super.key,
  });

  final String title;

  /// One line under the title, such as "2021 • EP" or the artist.
  final String subtitle;

  final String? coverUrl;
  final IntegrationFeature feature;

  /// The card's width; the parent's width when null.
  final double? extent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(coverArtShapeProvider);
    final borderRadius = artworkBorderRadius(shape, extent: double.infinity);
    Widget placeholder(BuildContext _) => const CoverArtImage(
      coverArtId: null,
      fit: BoxFit.cover,
      placeholderIcon: Icons.album_outlined,
    );
    final url = coverUrl;
    return AlbumCardCaptionLayout(
      width: extent,
      title: title,
      subtitle: subtitle,
      card: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (url == null)
                placeholder(context)
              else
                ExternalArtworkImage(
                  url: url,
                  feature: feature,
                  fit: BoxFit.cover,
                  fallbackBuilder: placeholder,
                ),
              AlbumCardLabel(title: title, subtitle: subtitle),
            ],
          ),
        ),
      ),
    );
  }
}
