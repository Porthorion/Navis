import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Every change in a release: tabs for All, New, Improved and Fixed (the
/// same control as Library's), plain paragraphs under plain subheadings,
/// fixes folded past [collapsedFixCount], then the release's thanks.
///
/// Only entries for the running platform (and all-platform ones) are listed;
/// the rest fold behind one line that expands them in place.
class ChangelogReleaseDetails extends ConsumerStatefulWidget {
  const new({required this.version, super.key});

  final ChangelogVersion version;

  static const int collapsedFixCount = 5;

  @override
  ConsumerState<ChangelogReleaseDetails> createState() =>
      _ChangelogReleaseDetailsState();
}

class _ChangelogReleaseDetailsState
    extends ConsumerState<ChangelogReleaseDetails>
    with TickerProviderStateMixin {
  late List<ChangelogEntryType> _types = _presentTypes();
  late TabController _tabs = _createController();
  bool _showAllFixes = false;
  bool _showOtherPlatforms = false;

  ChangelogPlatform get _platform => ref.read(changelogPlatformProvider);

  List<ChangelogEntry> _relevant() => <ChangelogEntry>[
    for (final entry in widget.version.entries)
      if (entry.appliesTo(_platform)) entry,
  ];

  List<ChangelogEntryType> _presentTypes() {
    final relevant = _relevant();
    return <ChangelogEntryType>[
      for (final type in changelogSectionOrder)
        if (relevant.any((e) => e.type == type)) type,
    ];
  }

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
      _showOtherPlatforms = false;
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
    final platform = ref.watch(changelogPlatformProvider);
    final relevant = _relevant();
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
                tabLabel(l10n.changelogFilterAll, relevant.length),
                for (final type in _types)
                  tabLabel(
                    entryLabel(type, l10n),
                    relevant.where((e) => e.type == type).length,
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
            // A single-type view needs no subheading.
            showHeading: visibleTypes.length > 1,
            entries: relevant.where((e) => e.type == type).toList(),
            platform: platform,
            // A filtered view shows everything it asked for.
            collapse:
                type == ChangelogEntryType.fix &&
                selected == null &&
                !_showAllFixes,
            expanded: _showAllFixes,
            onToggle: () => setState(() => _showAllFixes = !_showAllFixes),
          ),
        _OtherPlatforms(
          entries: <ChangelogEntry>[
            for (final entry in version.entries)
              if (!entry.appliesTo(platform) &&
                  (selected == null || entry.type == selected))
                entry,
          ],
          expanded: _showOtherPlatforms,
          onToggle: () =>
              setState(() => _showOtherPlatforms = !_showOtherPlatforms),
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
  const new({
    required this.type,
    required this.showHeading,
    required this.entries,
    required this.platform,
    required this.collapse,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final ChangelogEntryType type;
  final bool showHeading;
  final List<ChangelogEntry> entries;
  final ChangelogPlatform platform;
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
            for (final entry in shown)
              ChangelogEntryTile(
                entry: entry,
                // A shared entry says where else it applies; one only for
                // this platform needs no label.
                platformLabel:
                    entry.platforms.length == 1 &&
                        entry.platforms.contains(platform)
                    ? null
                    : entry.platformsLabel,
              ),
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

/// "N changes for other platforms": one quiet line that expands those entries
/// in place, each labelled with its platforms. Nothing when there are none.
class _OtherPlatforms extends StatelessWidget {
  const new({
    required this.entries,
    required this.expanded,
    required this.onToggle,
  });

  final List<ChangelogEntry> entries;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: NavisSpace.md),
      child: AnimatedSize(
        duration: MotionPolicy.of(context).surface,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextButton(
              key: const ValueKey<String>('changelogToggleOtherPlatforms'),
              onPressed: onToggle,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: NavisSpace.xs),
              ),
              child: Text(
                expanded
                    ? l10n.changelogHideOtherPlatforms
                    : l10n.changelogOtherPlatforms(entries.length),
              ),
            ),
            if (expanded)
              for (final entry in entries)
                ChangelogEntryTile(
                  entry: entry,
                  platformLabel: entry.platformsLabel,
                  muted: true,
                ),
          ],
        ),
      ),
    );
  }
}
