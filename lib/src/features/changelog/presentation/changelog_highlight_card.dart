import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A major release's highlights: a horizontal strip on phones, a grid when
/// [asGrid] is set.
class ChangelogHighlights extends StatelessWidget {
  const ChangelogHighlights({
    required this.version,
    super.key,
    this.asGrid = false,
  });

  final ChangelogVersion version;
  final bool asGrid;

  static const double _cardWidth = 176;

  @override
  Widget build(BuildContext context) {
    final highlights = effectiveHighlights(version);
    if (highlights.isEmpty) {
      return const SizedBox.shrink();
    }
    if (asGrid) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 720 ? 3 : 2;
          final width =
              (constraints.maxWidth - NavisSpace.sm * (columns - 1)) / columns;
          return Wrap(
            spacing: NavisSpace.sm,
            runSpacing: NavisSpace.sm,
            children: <Widget>[
              for (final highlight in highlights)
                SizedBox(
                  width: width,
                  child: ChangelogHighlightCard(highlight: highlight),
                ),
            ],
          );
        },
      );
    }
    return SingleChildScrollView(
      key: const ValueKey<String>('changelogHighlightStrip'),
      scrollDirection: Axis.horizontal,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < highlights.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: NavisSpace.xs),
              SizedBox(
                width: _cardWidth,
                child: ChangelogHighlightCard(highlight: highlights[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ChangelogHighlightCard extends StatelessWidget {
  const ChangelogHighlightCard({required this.highlight, super.key});

  final ChangelogHighlight highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: NavisRadius.lgAll,
      ),
      child: Padding(
        padding: const EdgeInsets.all(NavisSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              highlightIcon(highlight.icon),
              color: colorScheme.primary,
            ),
            const SizedBox(height: NavisSpace.xs),
            Text(
              highlight.title,
              maxLines: highlight.body.isEmpty ? 4 : 2,
              overflow: TextOverflow.ellipsis,
              style: highlight.body.isEmpty
                  ? theme.textTheme.bodySmall
                  : theme.textTheme.titleSmall,
            ),
            if (highlight.body.isNotEmpty) ...<Widget>[
              const SizedBox(height: NavisSpace.xxs),
              Text(
                highlight.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
