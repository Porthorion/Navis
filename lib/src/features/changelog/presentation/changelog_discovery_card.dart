import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_icon.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A quiet, in-context "What's New" card on Home after an update.
///
/// A major release reads "Check out 1.4 “Navi”" with its highlight badges; a
/// patch shows a single "Updated to 1.4.1" row. It never blocks Home.
/// Opening or dismissing the card records the running version as seen.
class ChangelogDiscoveryCard extends ConsumerStatefulWidget {
  const ChangelogDiscoveryCard({super.key});

  /// Highlight badges shown before collapsing the rest into "+N".
  static const int maxBadges = 3;

  @override
  ConsumerState<ChangelogDiscoveryCard> createState() =>
      _ChangelogDiscoveryCardState();
}

class _ChangelogDiscoveryCardState
    extends ConsumerState<ChangelogDiscoveryCard> {
  var _dismissed = false;

  void _markSeen(String version) {
    if (_dismissed) {
      return;
    }
    setState(() {
      _dismissed = true;
    });
    unawaited(markChangelogSeen(version));
  }

  void _open(BuildContext context, ChangelogDiscovery discovery) {
    _markSeen(discovery.seenVersion);
    NavService.openAboutChangelog(
      context,
      version: (discovery.featured ?? discovery.current).version,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const SizedBox.shrink();
    }
    final discovery = ref.watch(changelogToShowProvider).asData?.value;
    if (discovery == null) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final featured = discovery.featured;
    final horizontal = desktopMode ? NavisSpace.md : NavisSpace.sm;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        NavisSpace.xxs,
        horizontal,
        NavisSpace.sm,
      ),
      child: Semantics(
        container: true,
        label: l10n.changelogDiscoverySemanticLabel(
          discovery.current.version,
        ),
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: NavisRadius.lgAll,
            side: BorderSide(
              color: colorScheme.primary.withValues(
                alpha: featured == null ? 0.12 : 0.28,
              ),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('changelogDiscoveryOpen'),
            onTap: () => _open(context, discovery),
            child: featured == null
                ? _PatchContent(
                    version: discovery.current,
                    onDismiss: () => _markSeen(discovery.seenVersion),
                  )
                : _MajorContent(
                    version: featured,
                    onDismiss: () => _markSeen(discovery.seenVersion),
                  ),
          ),
        ),
      ),
    );
  }
}

class _MajorContent extends StatelessWidget {
  const _MajorContent({required this.version, required this.onDismiss});

  final ChangelogVersion version;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final codename = version.codename;
    final title = codename == null
        ? l10n.changelogDiscoveryCheckOut(version.displayVersion)
        : l10n.changelogDiscoveryCheckOutNamed(
            version.displayVersion,
            codename,
          );

    // Curated highlights make good badges; entry text does not, so a
    // release without them shows its change counts instead.
    final highlights = version.highlights;
    const maxBadges = ChangelogDiscoveryCard.maxBadges;
    final badges = <Widget>[
      if (highlights.isNotEmpty) ...<Widget>[
        for (final highlight in highlights.take(maxBadges))
          _Badge(
            icon: highlightIcon(highlight.icon),
            label: highlight.title,
          ),
        if (highlights.length > maxBadges)
          _Badge(
            key: const ValueKey<String>('changelogDiscoveryMore'),
            label: l10n.changelogDiscoveryMore(highlights.length - maxBadges),
            quiet: true,
          ),
      ] else
        for (final label in versionCountLabels(version, l10n))
          _Badge(label: label),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NavisSpace.sm,
        NavisSpace.sm,
        NavisSpace.xxs,
        NavisSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ChangelogReleaseIcon(version: version, size: 40),
              const SizedBox(width: NavisSpace.sm),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _DismissButton(onPressed: onDismiss),
            ],
          ),
          if (badges.isNotEmpty) ...<Widget>[
            const SizedBox(height: NavisSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: NavisSpace.xs),
              child: Wrap(
                spacing: NavisSpace.xs,
                runSpacing: NavisSpace.xs,
                children: badges,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PatchContent extends StatelessWidget {
  const _PatchContent({required this.version, required this.onDismiss});

  final ChangelogVersion version;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final counts = versionCountLabels(version, l10n).join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NavisSpace.sm,
        NavisSpace.xs,
        NavisSpace.xxs,
        NavisSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 20,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: NavisSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.changelogDiscoveryUpdatedTo(version.version),
                  style: theme.textTheme.titleSmall,
                ),
                if (counts.isNotEmpty)
                  Text(
                    counts,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: colorScheme.onSurfaceVariant,
          ),
          _DismissButton(onPressed: onDismiss),
        ],
      ),
    );
  }
}

class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey<String>('changelogDiscoveryDismiss'),
      tooltip: AppLocalizations.of(context)!.changelogDiscoveryDismiss,
      onPressed: onPressed,
      icon: const Icon(Icons.close),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, super.key, this.icon, this.quiet = false});

  final String label;
  final IconData? icon;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final icon = this.icon;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NavisRadius.pillAll,
        border: quiet ? null : Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NavisSpace.sm,
          vertical: NavisSpace.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 16, color: colorScheme.primary),
              const SizedBox(width: NavisSpace.xxs),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: quiet ? colorScheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
