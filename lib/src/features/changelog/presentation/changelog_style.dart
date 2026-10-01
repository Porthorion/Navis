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

IconData highlightIcon(ChangelogHighlightIcon icon) {
  switch (icon) {
    case ChangelogHighlightIcon.sparkle:
      return Icons.new_releases_outlined;
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

/// "Navis 1.4" — the product name and display version.
String releaseProductName(ChangelogVersion version) =>
    'Navis ${version.displayVersion}';

/// The release's name: its codename, else "Navis 1.4".
String releaseTitle(ChangelogVersion version) =>
    version.codename ?? releaseProductName(version);

/// "Sep 30, 2026 • 90 changes", the album-style summary line. When
/// [withProductName] is set and the release has a codename, "Navis 1.4"
/// leads so the row still says which version it is.
String releaseMeta(
  BuildContext context,
  ChangelogVersion version, {
  bool withProductName = false,
}) {
  final l10n = AppLocalizations.of(context)!;
  return <String>[
    if (withProductName && version.codename != null)
      releaseProductName(version),
    ?formatReleaseDate(context, version),
    l10n.changelogChangeCount(version.entries.length),
  ].join(' • ');
}
