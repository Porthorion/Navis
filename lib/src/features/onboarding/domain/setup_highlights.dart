import 'package:navis/src/features/changelog/changelog_provider.dart';

/// Setup options introduced together in a release, shown to updated users.
enum SetupHighlight {
  // The version move to 1.5.0 renames this together with the changelog entry.
  colorStyle('1.4.3'),
  oledForAuto('1.4.3'),
  nightSchedule('1.4.3'),
  flatSurfaces('1.4.3'),
  nowPlayingBackground('1.4.3'),
  cornerStyle('1.4.3'),
  density('1.4.3');

  new(this.since);

  /// Release that introduced this setup option.
  final String since;
}

/// Newest highlight release at or before [appVersion], ignoring build suffixes.
///
/// A later major without its own highlights clears the previous major's tags.
String? setupWhatsNewRelease(String appVersion) {
  final app = parseSemver(appVersion);
  if (app == null) return null;
  String? newest;
  List<int>? newestParts;
  for (final highlight in SetupHighlight.values) {
    final parts = parseSemver(highlight.since)!;
    if (compareSemver(parts, app) > 0) continue;
    if (newestParts == null || compareSemver(parts, newestParts) > 0) {
      newest = highlight.since;
      newestParts = parts;
    }
  }
  if (newestParts == null || app.first > newestParts.first) return null;
  return newest;
}

/// Only the options introduced in [release]; newer releases replace old tags.
Set<SetupHighlight> setupHighlightsFor(String release) => Set.unmodifiable(
  SetupHighlight.values.where((highlight) => highlight.since == release),
);
