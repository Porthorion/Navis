import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';

/// Order in which entry types are grouped: what is new first, fixes last.
const List<ChangelogEntryType> changelogSectionOrder = <ChangelogEntryType>[
  ChangelogEntryType.newFeature,
  ChangelogEntryType.improvement,
  ChangelogEntryType.fix,
];

IconData entryIcon(ChangelogEntryType type) {
  switch (type) {
    case ChangelogEntryType.fix:
      return Icons.build_outlined;
    case ChangelogEntryType.improvement:
      return Icons.trending_up_rounded;
    case ChangelogEntryType.newFeature:
      return Icons.auto_awesome_outlined;
  }
}

/// Fixes use a neutral role so a long list of fixes does not read as an
/// error state.
Color entryColor(ChangelogEntryType type, ColorScheme scheme) {
  switch (type) {
    case ChangelogEntryType.fix:
      return scheme.onSurfaceVariant;
    case ChangelogEntryType.improvement:
      return scheme.secondary;
    case ChangelogEntryType.newFeature:
      return scheme.primary;
  }
}

String entryLabel(ChangelogEntryType type, AppLocalizations l10n) {
  switch (type) {
    case ChangelogEntryType.fix:
      return l10n.changelogEntryTypeFixed;
    case ChangelogEntryType.improvement:
      return l10n.changelogEntryTypeImproved;
    case ChangelogEntryType.newFeature:
      return l10n.changelogEntryTypeNew;
  }
}

/// "10 new", "41 improved", "39 fixes".
String entryCountLabel(
  ChangelogEntryType type,
  int count,
  AppLocalizations l10n,
) {
  switch (type) {
    case ChangelogEntryType.fix:
      return l10n.changelogFixedCount(count);
    case ChangelogEntryType.improvement:
      return l10n.changelogImprovedCount(count);
    case ChangelogEntryType.newFeature:
      return l10n.changelogNewCount(count);
  }
}

/// Count labels for the types present in [version], in section order.
List<String> versionCountLabels(
  ChangelogVersion version,
  AppLocalizations l10n,
) {
  return <String>[
    for (final type in changelogSectionOrder)
      if (version.countOf(type) > 0)
        entryCountLabel(type, version.countOf(type), l10n),
  ];
}

IconData highlightIcon(ChangelogHighlightIcon icon) {
  switch (icon) {
    case ChangelogHighlightIcon.sparkle:
      return Icons.auto_awesome_outlined;
    case ChangelogHighlightIcon.equalizer:
      return Icons.equalizer_rounded;
    case ChangelogHighlightIcon.speed:
      return Icons.speed_rounded;
    case ChangelogHighlightIcon.headphones:
      return Icons.headphones_outlined;
    case ChangelogHighlightIcon.performance:
      return Icons.bolt_outlined;
    case ChangelogHighlightIcon.search:
      return Icons.translate_rounded;
    case ChangelogHighlightIcon.library:
      return Icons.library_music_outlined;
    case ChangelogHighlightIcon.sync:
      return Icons.sync_rounded;
    case ChangelogHighlightIcon.desktop:
      return Icons.desktop_windows_outlined;
    case ChangelogHighlightIcon.player:
      return Icons.picture_in_picture_alt_outlined;
    case ChangelogHighlightIcon.download:
      return Icons.download_outlined;
    case ChangelogHighlightIcon.setup:
      return Icons.tune_rounded;
    case ChangelogHighlightIcon.audio:
      return Icons.graphic_eq_rounded;
    case ChangelogHighlightIcon.queue:
      return Icons.queue_music_rounded;
  }
}

/// Curated highlights, or up to three new-feature entries when a release has
/// none. Fallback titles are full entry texts, so callers must truncate.
List<ChangelogHighlight> effectiveHighlights(ChangelogVersion version) {
  if (version.highlights.isNotEmpty) {
    return version.highlights;
  }
  return <ChangelogHighlight>[
    for (final entry
        in version.entries
            .where((entry) => entry.type == ChangelogEntryType.newFeature)
            .take(3))
      ChangelogHighlight(
        icon: ChangelogHighlightIcon.sparkle,
        title: entry.text,
        body: '',
      ),
  ];
}

/// The release date in the reader's locale, or null when unknown.
String? formatReleaseDate(BuildContext context, ChangelogVersion version) {
  final date = version.releasedDate;
  if (date == null) {
    return null;
  }
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.yMMMd(locale).format(date);
}
