import 'package:material_ui/material_ui.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// The frame of a one-time row on Home: a raised rounded surface that opens
/// on tap, an optional [leading] widget, a bold [title], an optional quiet
/// [subtitle] and a close button.
///
/// Shared by the What's New row (`ChangelogDiscoveryCard`) and the
/// Integrations notice (`IntegrationsNoticeCard`) so the two keep one look.
/// The caller owns what the row says and what opening or closing it does.
class HomeNoticeCard extends StatelessWidget {
  const new({
    required this.openKey,
    required this.dismissKey,
    required this.title,
    required this.dismissTooltip,
    required this.onOpen,
    required this.onDismiss,
    this.subtitle = '',
    this.leading,
    this.startPadding = NavisSpace.md,
    this.subtitleMaxLines,
    this.semanticLabel,
    super.key,
  });

  /// Keys the tappable surface and the close button, for tests and
  /// diagnostics.
  final Key openKey;
  final Key dismissKey;

  final String title;

  /// Shown under [title] when it is not empty.
  final String subtitle;
  final String dismissTooltip;

  /// A widget before the text, such as a release cover. The row then adds
  /// the gap after it.
  final Widget? leading;

  /// Inset before the first child.
  final double startPadding;

  /// Lines [subtitle] may take before it is cut off; null for no limit.
  final int? subtitleMaxLines;

  /// When set, the row is one labelled semantics container.
  final String? semanticLabel;

  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final horizontal = desktopMode ? NavisSpace.md : NavisSpace.sm;
    final leading = this.leading;
    final card = Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: NavisRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: openKey,
        onTap: onOpen,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            startPadding,
            NavisSpace.sm,
            NavisSpace.xxs,
            NavisSpace.sm,
          ),
          child: Row(
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
                        fontWeight: FontWeight.w700,
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
              IconButton(
                key: dismissKey,
                tooltip: dismissTooltip,
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
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
