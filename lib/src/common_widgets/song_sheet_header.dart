import 'package:intl/intl.dart' show Bidi;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// Top of a song action sheet: cover, the whole title (wrapped to three
/// lines, never scrolled) and "Artist · Album" on one line, so a long title
/// is readable on a phone before an action is chosen.
class SongSheetHeader extends StatelessWidget {
  const new({
    required this.title,
    this.artist,
    this.album,
    this.coverArtId,
    this.coverArtRevision = 0,
    this.isExternal = false,
    super.key,
  });

  final String title;
  final String? artist;
  final String? album;
  final String? coverArtId;
  final int coverArtRevision;
  final bool isExternal;

  static const double _cover = 56;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      for (final part in <String?>[artist, album])
        if (part != null && part.trim().isNotEmpty) part,
    ].join(' · ');
    // The title's own direction, not the app's, as in MarqueeText.
    final direction = Bidi.startsWithRtl(title)
        ? TextDirection.rtl
        : Bidi.startsWithLtr(title)
        ? TextDirection.ltr
        : Directionality.of(context);
    return Semantics(
      header: true,
      label: subtitle.isEmpty ? title : '$title\n$subtitle',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: _cover,
                  child: CoverArtImage(
                    coverArtId: coverArtId,
                    revision: coverArtRevision,
                    size: 112,
                    width: _cover,
                    height: _cover,
                    shape: ArtworkShapeRole.cover,
                    isExternalSource: isExternal,
                    remoteSourceIndicatorPolicy:
                        RemoteSourceIndicatorPolicy.hidden,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Directionality(
                    textDirection: direction,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
