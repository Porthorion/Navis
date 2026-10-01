import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_cover.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// The top of a release, laid out like an album page: the cover beside the
/// release's name, version and date. Patches have no cover.
class ChangelogReleaseHeader extends StatelessWidget {
  const new({required this.version, super.key, this.desktop = false});

  final ChangelogVersion version;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;
    final major = version.isMajor;
    final codename = version.codename;
    final summary = version.summary;

    final titleStyle =
        (major
                ? (desktop ? textTheme.displaySmall : textTheme.headlineMedium)
                : textTheme.headlineSmall)
            ?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              height: 1.1,
            );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            major ? releaseTitle(version) : releaseProductName(version),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        if (major && codename != null)
          Padding(
            padding: const EdgeInsets.only(top: NavisSpace.xxs),
            child: Text(
              releaseProductName(version),
              style: textTheme.titleMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(height: 2),
        Text(
          releaseMeta(context, version),
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    return Column(
      key: ValueKey<String>('changelogReleaseHeader-${version.version}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (major)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              ChangelogReleaseCover(
                version: version,
                size: desktop ? 208 : 112,
              ),
              SizedBox(width: desktop ? NavisSpace.xl : NavisSpace.md),
              Expanded(child: text),
            ],
          )
        else
          text,
        if (summary != null)
          Padding(
            padding: const EdgeInsets.only(top: NavisSpace.md),
            child: Text(summary, style: textTheme.bodyLarge),
          ),
      ],
    );
  }
}
