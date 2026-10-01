import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';

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
  });

  final String title;

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
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: compact ? textTheme.titleMedium : textTheme.titleLarge,
              ),
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
