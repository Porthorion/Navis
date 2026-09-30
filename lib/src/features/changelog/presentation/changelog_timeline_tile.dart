import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_highlight_card.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_details.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_hero.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// "1.4 “Navi”" for a named release, the display version otherwise.
String changelogReleaseTitle(ChangelogVersion version) {
  final codename = version.codename;
  return codename == null
      ? version.displayVersion
      : '${version.displayVersion} “$codename”';
}

/// "Sep 30, 2026 · 10 new · 41 improved · 39 fixes".
String changelogReleaseSubtitle(
  BuildContext context,
  ChangelogVersion version,
) {
  final l10n = AppLocalizations.of(context)!;
  return <String>[
    ?formatReleaseDate(context, version),
    ...versionCountLabels(version, l10n),
  ].join(' · ');
}

/// A release on the changelog timeline. Collapsed, it shows the version,
/// date and counts beside a rail dot that is larger for major releases;
/// expanded, it shows the release's banner, highlights and entries.
class ChangelogTimelineTile extends StatefulWidget {
  const ChangelogTimelineTile({
    required this.version,
    super.key,
    this.isLast = false,
    this.initiallyExpanded = false,
  });

  final ChangelogVersion version;
  final bool isLast;
  final bool initiallyExpanded;

  @override
  State<ChangelogTimelineTile> createState() => _ChangelogTimelineTileState();
}

class _ChangelogTimelineTileState extends State<ChangelogTimelineTile> {
  late bool _expanded = widget.initiallyExpanded;

  static const double _railWidth = 28;
  static const double _headerHeight = 64;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final version = widget.version;
    final major = version.isMajor;
    final dotSize = major ? 14.0 : 8.0;

    return Stack(
      children: <Widget>[
        Positioned(
          left: _railWidth / 2 - 1,
          top: 0,
          bottom: widget.isLast && !_expanded ? _headerHeight / 2 : 0,
          width: 2,
          child: ColoredBox(color: colorScheme.outlineVariant),
        ),
        Positioned(
          left: (_railWidth - dotSize) / 2,
          top: (_headerHeight - dotSize) / 2,
          child: Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: major ? colorScheme.primary : colorScheme.outline,
              border: Border.all(color: colorScheme.surface, width: 2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: _railWidth + NavisSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              InkWell(
                key: ValueKey<String>(
                  'changelogTimelineTile-${version.version}',
                ),
                borderRadius: NavisRadius.mdAll,
                onTap: () => setState(() => _expanded = !_expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _headerHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NavisSpace.xs,
                      vertical: NavisSpace.xs,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                changelogReleaseTitle(version),
                                style: major
                                    ? theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      )
                                    : theme.textTheme.titleSmall,
                              ),
                              Text(
                                changelogReleaseSubtitle(context, version),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: MotionPolicy.of(context).surface,
                          child: Icon(
                            Icons.expand_more_rounded,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(
                    top: NavisSpace.xs,
                    bottom: NavisSpace.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (major) ...<Widget>[
                        ChangelogReleaseHero(version: version, compact: true),
                        const SizedBox(height: NavisSpace.sm),
                        ChangelogHighlights(version: version),
                      ],
                      ChangelogReleaseDetails(version: version),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
