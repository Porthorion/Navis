import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_icon.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// The centred banner at the top of a major release: its icon, version,
/// codename, optional summary and change counts.
class ChangelogReleaseHero extends StatelessWidget {
  const ChangelogReleaseHero({
    required this.version,
    super.key,
    this.compact = false,
  });

  final ChangelogVersion version;

  /// Smaller icon and type, for a major release shown inside the timeline.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final onHero = colorScheme.onSurface;
    final onHeroQuiet = colorScheme.onSurfaceVariant;
    // Tint a surface rather than use the container roles: with monochrome or
    // album-derived seeds, primaryContainer can be near-white while its "on"
    // colour stays mid-grey, which left the codename unreadable.
    final base = colorScheme.surfaceContainerHigh;
    final date = formatReleaseDate(context, version);
    final codename = version.codename;
    final summary = version.summary;
    final versionLabel = l10n.changelogDiscoveryVersion(
      version.displayVersion,
    );

    return Semantics(
      container: true,
      label: codename == null ? versionLabel : '$versionLabel, $codename',
      child: DecoratedBox(
        key: ValueKey<String>('changelogReleaseHero-${version.version}'),
        decoration: BoxDecoration(
          borderRadius: NavisRadius.xlAll,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color.alphaBlend(
                colorScheme.primary.withValues(alpha: 0.2),
                base,
              ),
              Color.alphaBlend(
                colorScheme.tertiary.withValues(alpha: 0.1),
                base,
              ),
            ],
          ),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.24),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            NavisSpace.md,
            NavisSpace.md,
            NavisSpace.md,
            compact ? NavisSpace.md : NavisSpace.xl,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: _HeroPill(label: l10n.changelogMajorRelease),
                  ),
                  if (date != null) ...<Widget>[
                    const SizedBox(width: NavisSpace.xs),
                    Expanded(
                      child: Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: textTheme.labelMedium?.copyWith(
                          color: onHeroQuiet,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: compact ? NavisSpace.xs : NavisSpace.md),
              ChangelogReleaseIcon(
                version: version,
                size: compact ? 48 : 76,
                background: colorScheme.primary.withValues(alpha: 0.16),
                foreground: colorScheme.primary,
              ),
              SizedBox(height: compact ? NavisSpace.xs : NavisSpace.sm),
              ExcludeSemantics(
                child: Column(
                  children: <Widget>[
                    if (codename != null) ...<Widget>[
                      Text(
                        versionLabel,
                        textAlign: TextAlign.center,
                        style: textTheme.labelLarge?.copyWith(
                          color: onHeroQuiet,
                        ),
                      ),
                      Text(
                        codename,
                        textAlign: TextAlign.center,
                        style:
                            (compact
                                    ? textTheme.headlineSmall
                                    : textTheme.headlineMedium)
                                ?.copyWith(
                                  color: onHero,
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ] else
                      Text(
                        versionLabel,
                        textAlign: TextAlign.center,
                        style:
                            (compact
                                    ? textTheme.headlineSmall
                                    : textTheme.headlineMedium)
                                ?.copyWith(
                                  color: onHero,
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                  ],
                ),
              ),
              if (summary != null && !compact) ...<Widget>[
                const SizedBox(height: NavisSpace.xs),
                Text(
                  summary,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(color: onHeroQuiet),
                ),
              ],
              const SizedBox(height: NavisSpace.sm),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: NavisSpace.xs,
                runSpacing: NavisSpace.xs,
                children: <Widget>[
                  for (final label in versionCountLabels(version, l10n))
                    _HeroPill(label: label, emphasized: false),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, this.emphasized = true});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: emphasized ? 0.85 : 0.6),
        borderRadius: NavisRadius.pillAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NavisSpace.sm,
          vertical: NavisSpace.xxs,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: emphasized ? colorScheme.primary : colorScheme.onSurface,
            fontWeight: emphasized ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}
