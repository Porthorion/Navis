import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Every change in a release: tabs for All, New, Improved and Fixed (the
/// same control as Library's), plain paragraphs under plain subheadings,
/// fixes folded past [collapsedFixCount], then the release's thanks.
class ChangelogReleaseDetails extends StatefulWidget {
  const ChangelogReleaseDetails({required this.version, super.key});

  final ChangelogVersion version;

  static const int collapsedFixCount = 5;

  @override
  State<ChangelogReleaseDetails> createState() =>
      _ChangelogReleaseDetailsState();
}

class _ChangelogReleaseDetailsState extends State<ChangelogReleaseDetails>
    with TickerProviderStateMixin {
  late List<ChangelogEntryType> _types = _presentTypes();
  late TabController _tabs = _createController();
  bool _showAllFixes = false;

  List<ChangelogEntryType> _presentTypes() => <ChangelogEntryType>[
    for (final type in changelogSectionOrder)
      if (widget.version.countOf(type) > 0) type,
  ];

  TabController _createController() {
    final controller = TabController(length: _types.length + 1, vsync: this);
    controller.addListener(() => setState(() {}));
    return controller;
  }

  @override
  void didUpdateWidget(covariant ChangelogReleaseDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version.version != widget.version.version) {
      _tabs.dispose();
      _types = _presentTypes();
      _tabs = _createController();
      _showAllFixes = false;
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final version = widget.version;
    final showTabs = _types.length > 1;
    final selected = showTabs && _tabs.index > 0
        ? _types[_tabs.index - 1]
        : null;
    final visibleTypes = selected == null
        ? _types
        : <ChangelogEntryType>[selected];

    Widget tabLabel(String label, int count) => Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NavisSectionHeader(title: l10n.changelogAllChanges, compact: true),
        if (showTabs)
          Padding(
            padding: const EdgeInsets.only(top: NavisSpace.xxs),
            child: TabBar(
              key: const ValueKey<String>('changelogTypeTabs'),
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: <Widget>[
                tabLabel(l10n.changelogFilterAll, version.entries.length),
                for (final type in _types)
                  tabLabel(entryLabel(type, l10n), version.countOf(type)),
              ],
            ),
          ),
        for (final type in visibleTypes)
          _EntrySection(
            key: ValueKey<String>(
              'changelogSection-${version.version}-${type.name}',
            ),
            type: type,
            // A single-type view needs no subheading.
            showHeading: visibleTypes.length > 1,
            entries: version.entries.where((e) => e.type == type).toList(),
            // A filtered view shows everything it asked for.
            collapse:
                type == ChangelogEntryType.fix &&
                selected == null &&
                !_showAllFixes,
            expanded: _showAllFixes,
            onToggle: () => setState(() => _showAllFixes = !_showAllFixes),
          ),
        if (version.specialThanks.isNotEmpty) ...<Widget>[
          const SizedBox(height: NavisSpace.lg),
          Text(l10n.changelogSpecialThanks, style: theme.textTheme.titleSmall),
          for (final thankYou in version.specialThanks)
            Padding(
              padding: const EdgeInsets.only(top: NavisSpace.xs),
              child: Text(thankYou, style: theme.textTheme.bodyMedium),
            ),
        ],
      ],
    );
  }
}

class _EntrySection extends StatelessWidget {
  const _EntrySection({
    required this.type,
    required this.showHeading,
    required this.entries,
    required this.collapse,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final ChangelogEntryType type;
  final bool showHeading;
  final List<ChangelogEntry> entries;
  final bool collapse;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    const limit = ChangelogReleaseDetails.collapsedFixCount;
    final canCollapse =
        type == ChangelogEntryType.fix && entries.length > limit;
    final shown = collapse && canCollapse
        ? entries.take(limit).toList()
        : entries;

    return Padding(
      padding: const EdgeInsets.only(top: NavisSpace.md),
      child: AnimatedSize(
        duration: MotionPolicy.of(context).surface,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (showHeading)
              Semantics(
                header: true,
                child: Text(
                  entryLabel(type, l10n),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            for (final entry in shown) ChangelogEntryTile(entry: entry),
            if (canCollapse && (collapse || expanded))
              Padding(
                padding: const EdgeInsets.only(top: NavisSpace.xxs),
                child: TextButton(
                  key: const ValueKey<String>('changelogToggleFixes'),
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NavisSpace.xs,
                    ),
                  ),
                  child: Text(
                    collapse
                        ? l10n.changelogShowAllFixes(entries.length - limit)
                        : l10n.changelogShowFewerFixes,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
