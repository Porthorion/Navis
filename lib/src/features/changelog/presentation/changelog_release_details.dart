import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A release's entries grouped into New, Improved and Fixed sections, with
/// type filters, fixes collapsed past [collapsedFixCount] and the release's
/// Special Thanks.
class ChangelogReleaseDetails extends StatefulWidget {
  const ChangelogReleaseDetails({required this.version, super.key});

  final ChangelogVersion version;

  static const int collapsedFixCount = 5;

  @override
  State<ChangelogReleaseDetails> createState() =>
      _ChangelogReleaseDetailsState();
}

class _ChangelogReleaseDetailsState extends State<ChangelogReleaseDetails> {
  ChangelogEntryType? _filter;
  bool _showAllFixes = false;

  @override
  void didUpdateWidget(covariant ChangelogReleaseDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version.version != widget.version.version) {
      _filter = null;
      _showAllFixes = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final version = widget.version;
    final presentTypes = <ChangelogEntryType>[
      for (final type in changelogSectionOrder)
        if (version.countOf(type) > 0) type,
    ];
    final visibleTypes = _filter == null
        ? presentTypes
        : <ChangelogEntryType>[_filter!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (presentTypes.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: NavisSpace.xs),
            child: Wrap(
              spacing: NavisSpace.xs,
              runSpacing: NavisSpace.xs,
              children: <Widget>[
                ChoiceChip(
                  key: const ValueKey<String>('changelogFilter-all'),
                  label: Text(l10n.changelogFilterAll),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
                for (final type in presentTypes)
                  ChoiceChip(
                    key: ValueKey<String>('changelogFilter-${type.name}'),
                    label: Text(entryLabel(type, l10n)),
                    selected: _filter == type,
                    onSelected: (_) => setState(
                      () => _filter = _filter == type ? null : type,
                    ),
                  ),
              ],
            ),
          ),
        for (final type in visibleTypes)
          _EntrySection(
            key: ValueKey<String>(
              'changelogSection-${version.version}-${type.name}',
            ),
            type: type,
            entries: version.entries.where((e) => e.type == type).toList(),
            // A filtered view shows everything it asked for.
            collapse:
                type == ChangelogEntryType.fix &&
                _filter == null &&
                !_showAllFixes,
            expanded: _showAllFixes,
            onToggle: () => setState(() => _showAllFixes = !_showAllFixes),
          ),
        if (version.specialThanks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NavisSpace.md),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: NavisRadius.lgAll,
              ),
              child: Padding(
                padding: const EdgeInsets.all(NavisSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.favorite_outline_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: NavisSpace.xs),
                        Text(
                          l10n.changelogSpecialThanks,
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: NavisSpace.xs),
                    for (final thankYou in version.specialThanks)
                      Padding(
                        padding: const EdgeInsets.only(top: NavisSpace.xxs),
                        child: Text(
                          thankYou,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EntrySection extends StatelessWidget {
  const _EntrySection({
    required this.type,
    required this.entries,
    required this.collapse,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final ChangelogEntryType type;
  final List<ChangelogEntry> entries;
  final bool collapse;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final color = entryColor(type, theme.colorScheme);
    const limit = ChangelogReleaseDetails.collapsedFixCount;
    final canCollapse =
        type == ChangelogEntryType.fix && entries.length > limit;
    final shown = collapse && canCollapse
        ? entries.take(limit).toList()
        : entries;

    return Padding(
      padding: const EdgeInsets.only(top: NavisSpace.sm),
      child: AnimatedSize(
        duration: MotionPolicy.of(context).surface,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Row(
                children: <Widget>[
                  Icon(entryIcon(type), size: 18, color: color),
                  const SizedBox(width: NavisSpace.xs),
                  Text(
                    entryLabel(type, l10n),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(width: NavisSpace.xs),
                  Text(
                    '${entries.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NavisSpace.xxs),
            for (final entry in shown) ChangelogEntryTile(entry: entry),
            if (canCollapse && (collapse || expanded))
              TextButton.icon(
                key: const ValueKey<String>('changelogToggleFixes'),
                onPressed: onToggle,
                icon: Icon(
                  collapse
                      ? Icons.expand_more_rounded
                      : Icons.expand_less_rounded,
                ),
                label: Text(
                  collapse
                      ? l10n.changelogShowAllFixes(entries.length - limit)
                      : l10n.changelogShowFewerFixes,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
