import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

/// A grid-friendly artist card with a configurable shape avatar and the artist
/// name centered below. Suitable for use inside a `SliverGrid`.
class ArtistGridCard extends ConsumerWidget {
  const ArtistGridCard({
    required this.artist,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(artistCardShapeProvider);
    final borderRadius = coverArtShapeToRadius(shape);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = constraints.maxWidth < constraints.maxHeight
                      ? constraints.maxWidth
                      : constraints.maxHeight;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: CoverArtImage(
                        coverArtId: artist.coverArt,
                        size: kCoverArtStandardSize,
                        width: side,
                        height: side,
                        borderRadius: borderRadius,
                        placeholderIcon: Icons.person_outline,
                        isExternalSource: artist.isExternal,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
