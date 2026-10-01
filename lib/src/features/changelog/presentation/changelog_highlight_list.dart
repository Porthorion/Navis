import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A major release's highlights as plain rows, like a track list: a narrow
/// icon column, then the title and one line. [columns] lays the same rows
/// out side by side on wide screens.
class ChangelogHighlightList extends StatelessWidget {
  const new({required this.version, super.key, this.columns = 1});

  final ChangelogVersion version;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final highlights = effectiveHighlights(version);
    if (highlights.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final rows = <Widget>[
      for (final highlight in highlights) _HighlightRow(highlight: highlight),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NavisSectionHeader(title: l10n.changelogHighlights, compact: true),
        const SizedBox(height: NavisSpace.xxs),
        if (columns <= 1)
          ...rows
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final width =
                  (constraints.maxWidth - NavisSpace.xl * (columns - 1)) /
                  columns;
              return Wrap(
                spacing: NavisSpace.xl,
                children: <Widget>[
                  for (final row in rows) SizedBox(width: width, child: row),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const new({required this.highlight});

  final ChangelogHighlight highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fallback = highlight.body.isEmpty;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NavisSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 32,
              child: Icon(
                highlightIcon(highlight.icon),
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: NavisSpace.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    highlight.title,
                    // Fallback highlights carry a full entry as the title.
                    maxLines: fallback ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: fallback ? null : FontWeight.w600,
                    ),
                  ),
                  if (!fallback)
                    Text(
                      highlight.body,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
