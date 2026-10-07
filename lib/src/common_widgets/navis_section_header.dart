import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Heading for a content section, with an optional "See all" link or other
/// trailing actions.
///
/// Every shelf, list and grid heading uses this widget so section titles have
/// the same scale, weight, alignment and semantics throughout the app.
class NavisSectionHeader extends StatelessWidget {
  const new({
    required this.title,
    super.key,
    this.onSeeAll,
    this.seeAllLabel,
    this.trailing = const <Widget>[],
    this.compact = false,
    this.padding = EdgeInsetsDirectional.zero,
    this.caption,
    this.onCaptionTap,
  });

  final String title;

  /// A short credit under the title for content from an online service,
  /// such as "From Deezer".
  final String? caption;

  /// Opens the credited service; the caption then reads as a link.
  final VoidCallback? onCaptionTap;

  /// Shows a "See all" text button when non-null.
  final VoidCallback? onSeeAll;

  /// Overrides the default "See all" label.
  final String? seeAllLabel;

  /// Widgets placed after the title, before "See all".
  final List<Widget> trailing;

  /// Uses the smaller title style for narrow layouts and dense lists.
  final bool compact;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final seeAll = onSeeAll;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: compact
                        ? textTheme.titleMedium
                        : textTheme.titleLarge,
                  ),
                ),
                if (caption case final caption?)
                  NavisSourceCaption(caption, onTap: onCaptionTap),
              ],
            ),
          ),
          ...trailing,
          if (seeAll != null)
            TextButton(
              onPressed: seeAll,
              child: Text(
                seeAllLabel ??
                    AppLocalizations.of(context)!.libraryLikedAlbumsSeeAll,
              ),
            ),
        ],
      ),
    );
  }
}

/// A small credit naming the online service some content comes from, styled
/// like the lyrics source line. With [onTap] it is a link to that service.
class NavisSourceCaption extends StatelessWidget {
  const new(this.text, {super.key, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tap = onTap;
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
        decoration: tap == null ? null : TextDecoration.underline,
        decorationColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: 0.5,
        ),
      ),
    );
    if (tap == null) return label;
    return Semantics(
      link: true,
      child: InkWell(
        onTap: tap,
        borderRadius: NavisRadius.xsAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: label,
        ),
      ),
    );
  }
}
