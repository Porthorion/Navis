import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_highlight_list.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_details.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_header.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_row.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Every app release, accessible from Settings > About.
///
/// A release reads like an album page: its cover and name, its highlights,
/// then every change. Phones show one release (the newest, or
/// [initialVersion]) followed by a list of the others; tapping one shows it.
/// The desktop shell keeps that list beside the selected release.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({
    super.key,
    this.initialVersion,
    this.versions = changelogs,
  });

  /// Version to show first, e.g. from the Home "What's New" card.
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
          return _ReleaseBody(
            key: ValueKey<String>('changelogFocused-${focused.version}'),
            version: focused,
            parentMajor: _parentMajor(focused),
            onOpen: _focus,
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(
              top: NavisSpace.xxl,
              bottom: NavisSpace.xs,
            ),
            child: NavisSectionHeader(
              title: focusedIsNewest
                  ? l10n.changelogEarlierReleases
                  : l10n.changelogReleases,
              compact: true,
            ),
          );
        }
        final version = others[index - 2];
        return ChangelogReleaseRow(
          version: version,
          showChevron: true,
          onTap: () => _focus(version),
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
          width: 300,
          child: ListView.builder(
            key: const ValueKey<String>('changelogVersionRail'),
            padding: const EdgeInsets.all(NavisSpace.sm),
            itemCount: widget.versions.length,
            itemBuilder: (context, index) {
              final version = widget.versions[index];
              return ChangelogReleaseRow(
                version: version,
                selected: version.version == focused.version,
                onTap: () => _focus(version),
              );
            },
          ),
        ),
        VerticalDivider(width: 1, color: colorScheme.outlineVariant),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: ListView(
                key: const ValueKey<String>('changelogDesktopDetail'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(
                  NavisSpace.xxl,
                  NavisSpace.xl,
                  NavisSpace.xxl,
                  NavisSpace.xxl,
                ),
                children: <Widget>[
                  _ReleaseBody(
                    key: ValueKey<String>(
                      'changelogFocused-${focused.version}',
                    ),
                    version: focused,
                    parentMajor: _parentMajor(focused),
                    onOpen: _focus,
                    desktop: true,
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

/// One release in full: header, highlights for a major (or the major a
/// patch belongs to), then every change.
class _ReleaseBody extends StatelessWidget {
  const _ReleaseBody({
    required this.version,
    required this.parentMajor,
    required this.onOpen,
    super.key,
    this.desktop = false,
  });

  final ChangelogVersion version;
  final ChangelogVersion? parentMajor;
  final ValueChanged<ChangelogVersion> onOpen;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final parent = parentMajor;
    final parentCodename = parent?.codename;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ChangelogReleaseHeader(version: version, desktop: desktop),
        if (version.isMajor) ...<Widget>[
          const SizedBox(height: NavisSpace.xl),
          ChangelogHighlightList(version: version, columns: desktop ? 2 : 1),
        ] else if (parent != null) ...<Widget>[
          const SizedBox(height: NavisSpace.md),
          ChangelogReleaseRow(
            key: const ValueKey<String>('changelogParentMajor'),
            version: parent,
            showChevron: true,
            label: parentCodename == null
                ? l10n.changelogPartOf(releaseProductName(parent))
                : l10n.changelogPartOfNamed(
                    releaseProductName(parent),
                    parentCodename,
                  ),
            onTap: () => onOpen(parent),
          ),
        ],
        const SizedBox(height: NavisSpace.xl),
        ChangelogReleaseDetails(version: version),
      ],
    );
  }
}
