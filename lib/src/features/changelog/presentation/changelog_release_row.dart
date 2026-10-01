import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_cover.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A release in a list, styled like a library row: a cover for major
/// releases (patches leave the slot empty so they sit under their major),
/// the release's name and its date and size.
class ChangelogReleaseRow extends StatelessWidget {
  const new({
    required this.version,
    required this.onTap,
    super.key,
    this.selected = false,
    this.showChevron = false,
    this.label,
  });

  final ChangelogVersion version;
  final VoidCallback onTap;
  final bool selected;
  final bool showChevron;

  /// Replaces the title, e.g. "Part of Navis 1.4 “Navi”".
  final String? label;

  static const double _leading = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final major = version.isMajor;
    final title = label ?? (major ? releaseTitle(version) : version.version);

    return Material(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: NavisRadius.mdAll,
      child: InkWell(
        key: ValueKey<String>('changelogReleaseRow-${version.version}'),
        borderRadius: NavisRadius.mdAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NavisSpace.xs,
            vertical: NavisSpace.xs,
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: _leading,
                child: major
                    ? ChangelogReleaseCover(version: version, size: _leading)
                    : null,
              ),
              const SizedBox(width: NavisSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: major ? FontWeight.w600 : null,
                        color: selected ? colorScheme.primary : null,
                      ),
                    ),
                    Text(
                      releaseMeta(
                        context,
                        version,
                        withProductName: label == null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (showChevron)
                Icon(
                  Icons.chevron_right_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
