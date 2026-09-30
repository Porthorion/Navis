import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_highlight_card.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_details.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_hero.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/features/changelog/presentation/changelog_timeline_tile.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Every app release, accessible from Settings > About.
///
/// Phones show one focused release (the newest, or [initialVersion]) in full,
/// then the rest as an expandable timeline. The desktop shell shows a list
/// of releases beside the selected release.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({
    super.key,
    this.initialVersion,
    this.versions = changelogs,
  });

  /// Version to focus first, e.g. from the Home "What's New" card.
  final String? initialVersion;

  /// Releases, newest first. Overridable for tests.
  final List<ChangelogVersion> versions;

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  late ChangelogVersion? _focused = _initialFocus();
  final ScrollController _scrollController = ScrollController();

  ChangelogVersion? _initialFocus() {
    final versions = widget.versions;
    if (versions.isEmpty) return null;
    return versions.firstWhere(
      (v) => v.version == widget.initialVersion,
      orElse: () => versions.first,
    );
  }

  @override
  void didUpdateWidget(covariant ChangelogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialVersion != widget.initialVersion ||
        oldWidget.versions != widget.versions) {
      _focused = _initialFocus();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _focus(ChangelogVersion version) {
    setState(() => _focused = version);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// The major release a patch belongs to, when it is in the list.
  ChangelogVersion? _parentMajor(ChangelogVersion version) {
    if (version.isMajor) return null;
    for (final candidate in widget.versions) {
      if (candidate.isMajor && candidate.series == version.series) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final focused = _focused;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutChangelog)),
      body: focused == null
          ? Center(child: Text(l10n.changelogEmpty))
          : LayoutBuilder(
              builder: (context, constraints) {
                if (desktopMode && constraints.maxWidth >= 840) {
                  return _buildDesktop(context, focused);
                }
                return _buildPhone(context, focused);
              },
            ),
    );
  }

  Widget _buildPhone(BuildContext context, ChangelogVersion focused) {
    final l10n = AppLocalizations.of(context)!;
    final others = widget.versions
        .where((v) => v.version != focused.version)
        .toList();
    final focusedIsNewest = focused.version == widget.versions.first.version;

    return ListView.builder(
      key: const ValueKey<String>('changelogList'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(
        NavisSpace.md,
        NavisSpace.xs,
        NavisSpace.md,
        NavisSpace.xxl,
      ),
      itemCount: others.isEmpty ? 1 : others.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _FocusedRelease(
            key: ValueKey<String>('changelogFocused-${focused.version}'),
            version: focused,
            parentMajor: _parentMajor(focused),
            onOpenParent: _focus,
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(
              top: NavisSpace.xl,
              bottom: NavisSpace.xs,
            ),
            child: Semantics(
              header: true,
              child: Text(
                focusedIsNewest
                    ? l10n.changelogEarlierReleases
                    : l10n.changelogReleases,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          );
        }
        final version = others[index - 2];
        return ChangelogTimelineTile(
          key: ValueKey<String>('changelogTimeline-${version.version}'),
          version: version,
          isLast: index - 2 == others.length - 1,
        );
      },
    );
  }

  Widget _buildDesktop(BuildContext context, ChangelogVersion focused) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 280,
          child: _VersionRail(
            versions: widget.versions,
            selected: focused,
            onSelected: _focus,
          ),
        ),
        VerticalDivider(width: 1, color: colorScheme.outlineVariant),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: ListView(
                key: const ValueKey<String>('changelogDesktopDetail'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(
                  NavisSpace.xl,
                  NavisSpace.md,
                  NavisSpace.xl,
                  NavisSpace.xxl,
                ),
                children: <Widget>[
                  _FocusedRelease(
                    key: ValueKey<String>(
                      'changelogFocused-${focused.version}',
                    ),
                    version: focused,
                    parentMajor: _parentMajor(focused),
                    onOpenParent: _focus,
                    highlightsAsGrid: true,
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

/// The release shown in full at the top of the page: the banner and
/// highlights for a major release, or a compact header for a patch.
class _FocusedRelease extends StatelessWidget {
  const _FocusedRelease({
    required this.version,
    required this.parentMajor,
    required this.onOpenParent,
    super.key,
    this.highlightsAsGrid = false,
  });

  final ChangelogVersion version;
  final ChangelogVersion? parentMajor;
  final ValueChanged<ChangelogVersion> onOpenParent;
  final bool highlightsAsGrid;

  @override
  Widget build(BuildContext context) {
    final parent = parentMajor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (version.isMajor) ...<Widget>[
          ChangelogReleaseHero(version: version),
          const SizedBox(height: NavisSpace.sm),
          ChangelogHighlights(version: version, asGrid: highlightsAsGrid),
          const SizedBox(height: NavisSpace.md),
        ] else ...<Widget>[
          _PatchHeader(version: version),
          if (parent != null) ...<Widget>[
            const SizedBox(height: NavisSpace.xs),
            _ParentMajorRow(major: parent, onTap: () => onOpenParent(parent)),
          ],
          const SizedBox(height: NavisSpace.xs),
        ],
        ChangelogReleaseDetails(version: version),
      ],
    );
  }
}

class _PatchHeader extends StatelessWidget {
  const _PatchHeader({required this.version});

  final ChangelogVersion version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NavisSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              l10n.changelogDiscoveryVersion(version.version),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: NavisSpace.xxs),
          Text(
            changelogReleaseSubtitle(context, version),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ParentMajorRow extends StatelessWidget {
  const _ParentMajorRow({required this.major, required this.onTap});

  final ChangelogVersion major;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final codename = major.codename;
    final label = codename == null
        ? l10n.changelogPartOf(major.displayVersion)
        : l10n.changelogPartOfNamed(major.displayVersion, codename);

    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.5),
      borderRadius: NavisRadius.lgAll,
      child: InkWell(
        key: const ValueKey<String>('changelogParentMajor'),
        borderRadius: NavisRadius.lgAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NavisSpace.sm),
          child: Row(
            children: <Widget>[
              Icon(Icons.auto_awesome_outlined, color: colorScheme.primary),
              const SizedBox(width: NavisSpace.sm),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.onPrimaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desktop list of releases. Major releases lead each series; its patches
/// sit indented beneath.
class _VersionRail extends StatelessWidget {
  const _VersionRail({
    required this.versions,
    required this.selected,
    required this.onSelected,
  });

  final List<ChangelogVersion> versions;
  final ChangelogVersion selected;
  final ValueChanged<ChangelogVersion> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView.builder(
      key: const ValueKey<String>('changelogVersionRail'),
      padding: const EdgeInsets.all(NavisSpace.sm),
      itemCount: versions.length,
      itemBuilder: (context, index) {
        final version = versions[index];
        final isSelected = version.version == selected.version;
        final major = version.isMajor;
        final date = formatReleaseDate(context, version);
        return Padding(
          padding: EdgeInsets.only(
            left: major ? 0 : NavisSpace.md,
            top: major && index > 0 ? NavisSpace.xs : 0,
          ),
          child: Material(
            color: isSelected
                ? colorScheme.secondaryContainer
                : Colors.transparent,
            borderRadius: NavisRadius.mdAll,
            child: InkWell(
              key: ValueKey<String>('changelogRail-${version.version}'),
              borderRadius: NavisRadius.mdAll,
              onTap: () => onSelected(version),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NavisSpace.sm,
                  vertical: NavisSpace.xs,
                ),
                child: Row(
                  children: <Widget>[
                    if (major) ...<Widget>[
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: NavisSpace.xs),
                    ],
                    Expanded(
                      child: Text(
                        changelogReleaseTitle(version),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: major
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (date != null)
                      Text(
                        date,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
