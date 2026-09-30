import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// One changelog entry: a thin rule in its type's colour beside the text.
///
/// Entries are grouped under a section that names their type, so the row
/// itself carries no label.
class ChangelogEntryTile extends StatelessWidget {
  const ChangelogEntryTile({required this.entry, super.key});

  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isFix = entry.type == ChangelogEntryType.fix;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NavisSpace.xs),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: entryColor(
                    entry.type,
                    colorScheme,
                  ).withValues(alpha: isFix ? 0.35 : 0.8),
                  borderRadius: NavisRadius.pillAll,
                ),
              ),
            ),
            const SizedBox(width: NavisSpace.sm),
            Expanded(
              child: Text(
                entry.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isFix ? colorScheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
