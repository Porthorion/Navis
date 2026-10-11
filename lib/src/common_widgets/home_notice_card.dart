import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// A labelled button under a [HomeNoticeCard]'s text.
@immutable
class NoticeAction {
  const new({required this.label, required this.onPressed, this.key});

  final String label;
  final VoidCallback onPressed;
  final Key? key;
}

/// The shared notice tile: a raised rounded surface with a leading icon disc
/// (or a custom [leading] widget), a bold [title], an optional quiet
/// [subtitle], an optional close button and optional actions.
///
/// Used by the What's New row (`ChangelogDiscoveryCard`), the Integrations
/// and setup-highlight notices and the Home update tile so inline notices
/// keep one look. The fill is `surfaceContainerHigh`; with Flat Surfaces it is
/// an outlined, unfilled tile. Per the accent contract the [primaryAction] is
/// a tonal button and the [secondaryAction] a text button, never solid. The
/// caller owns what the tile says and what opening or closing it does.
class HomeNoticeCard extends StatelessWidget {
  const new({
    required this.title,
    this.openKey,
    this.dismissKey,
    this.dismissTooltip,
    this.onOpen,
    this.onDismiss,
    this.subtitle = '',
    this.icon,
    this.leading,
    this.startPadding = NavisSpace.md,
    this.subtitleMaxLines = 2,
    this.semanticLabel,
    this.primaryAction,
    this.secondaryAction,
    super.key,
  }) : assert(
         (onDismiss == null) == (dismissTooltip == null),
         'A dismissible notice needs both onDismiss and dismissTooltip.',
       );

  /// Keys the tappable surface and the close button, for tests and
  /// diagnostics.
  final Key? openKey;
  final Key? dismissKey;

  final String title;

  /// Shown under [title] when it is not empty.
  final String subtitle;

  /// The icon in the leading tonal disc. Ignored when [leading] is set.
  final IconData? icon;

  /// A widget before the text that replaces the icon disc, such as a release
  /// cover. The row then adds the gap after it.
  final Widget? leading;

  /// Inset before the first child.
  final double startPadding;

  /// Lines [subtitle] may take before it is cut off; null for no limit.
  final int? subtitleMaxLines;

  /// When set, the row is one labelled semantics container.
  final String? semanticLabel;

  /// When set, the whole tile is tappable.
  final VoidCallback? onOpen;

  /// Shows the close button when set (with [dismissTooltip]).
  final VoidCallback? onDismiss;
  final String? dismissTooltip;

  final NoticeAction? primaryAction;
  final NoticeAction? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final flat = NavisColorStyleData.of(context).flatSurfaces;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final horizontal = desktopMode ? NavisSpace.md : NavisSpace.sm;
    final radius = NavisShapeData.of(context).lgAll;
    final leading =
        this.leading ??
        (icon == null
            ? null
            : NoticeIconDisc(icon: icon!, size: 40, iconSize: 20));
    final onDismiss = this.onDismiss;
    final primaryAction = this.primaryAction;
    final secondaryAction = this.secondaryAction;
    final hasActions = primaryAction != null || secondaryAction != null;
    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        startPadding,
        NavisSpace.md,
        onDismiss == null ? NavisSpace.md : NavisSpace.xs,
        NavisSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading,
                const SizedBox(width: NavisSpace.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: subtitleMaxLines,
                        overflow: subtitleMaxLines == null
                            ? null
                            : TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  key: dismissKey,
                  tooltip: dismissTooltip,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18),
                  style: IconButton.styleFrom(
                    foregroundColor: colorScheme.onSurfaceVariant,
                    fixedSize: const Size.square(32),
                    minimumSize: const Size.square(32),
                    padding: EdgeInsets.zero,
                    // 32 px to see, 48 px to tap.
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                ),
            ],
          ),
          if (hasActions)
            Padding(
              // The close button's own box keeps the end inset smaller.
              padding: EdgeInsets.only(
                top: NavisSpace.sm,
                right: onDismiss == null ? 0 : NavisSpace.xs,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: NavisSpace.xs,
                runSpacing: NavisSpace.xxs,
                children: <Widget>[
                  if (secondaryAction != null)
                    TextButton(
                      key: secondaryAction.key,
                      onPressed: secondaryAction.onPressed,
                      child: Text(secondaryAction.label),
                    ),
                  if (primaryAction != null)
                    FilledButton(
                      key: primaryAction.key,
                      onPressed: primaryAction.onPressed,
                      style: NavisColorStyleData.tonalStyleOf(context),
                      child: Text(primaryAction.label),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    final onOpen = this.onOpen;
    final card = Material(
      color: flat ? Colors.transparent : colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: flat
            ? BorderSide(color: colorScheme.outlineVariant)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: onOpen == null
          ? KeyedSubtree(key: openKey, child: content)
          : InkWell(key: openKey, onTap: onOpen, child: content),
    );
    final label = semanticLabel;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        NavisSpace.xxs,
        horizontal,
        NavisSpace.sm,
      ),
      child: label == null
          ? card
          : Semantics(container: true, label: label, child: card),
    );
  }
}
