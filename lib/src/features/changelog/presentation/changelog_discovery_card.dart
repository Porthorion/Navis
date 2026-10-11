import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_release_cover.dart';
import 'package:navis/src/features/changelog/presentation/changelog_style.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A quiet, in-context "What's New" row on Home after an update, styled like
/// a library row: the release's cover, "Check out 1.4 “Navi”" and one plain
/// line naming its highlights. A patch reads "Updated to Navis 1.4.1".
///
/// It never blocks Home. Opening or dismissing it records the running
/// version as seen.
class ChangelogDiscoveryCard extends ConsumerStatefulWidget {
  const new({super.key});

  /// Highlights named before the rest are summarised as "and N more".
  static const int namedHighlights = 3;

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
    NavService.openChangelog(
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
    final featured = discovery.featured;
    final current = discovery.current;

    final String title;
    final String subtitle;
    final ChangelogVersion? cover;
    if (featured != null) {
      final codename = featured.codename;
      title = codename == null
          ? l10n.changelogDiscoveryCheckOut(featured.displayVersion)
          : l10n.changelogDiscoveryCheckOutNamed(
              featured.displayVersion,
              codename,
            );
      subtitle = _highlightLine(l10n, featured);
      cover = featured;
    } else {
      title = l10n.changelogDiscoveryUpdatedTo(releaseProductName(current));
      subtitle = l10n.changelogChangeCount(current.entries.length);
      cover = null;
    }

    return HomeNoticeCard(
      openKey: const ValueKey<String>('changelogDiscoveryOpen'),
      dismissKey: const ValueKey<String>('changelogDiscoveryDismiss'),
      title: title,
      subtitle: subtitle,
      icon: Icons.auto_awesome_outlined,
      dismissTooltip: l10n.changelogDiscoveryDismiss,
      semanticLabel: l10n.changelogDiscoverySemanticLabel(current.version),
      leading: cover == null
          ? null
          : ChangelogReleaseCover(version: cover, size: 48),
      startPadding: NavisSpace.sm,
      onOpen: () => _open(context, discovery),
      onDismiss: () => _markSeen(discovery.seenVersion),
    );
  }

  /// "Equalizer, AutoEQ, Speed and pitch and 2 more". Without curated
  /// highlights, the release's size instead.
  String _highlightLine(AppLocalizations l10n, ChangelogVersion version) {
    final highlights = version.highlights;
    if (highlights.isEmpty) {
      return l10n.changelogChangeCount(version.entries.length);
    }
    const named = ChangelogDiscoveryCard.namedHighlights;
    final list = highlights.take(named).map((h) => h.title).join(', ');
    final rest = highlights.length - named;
    return rest > 0 ? l10n.changelogDiscoveryAndMore(list, rest) : list;
  }
}
