import 'package:navis/src/utils/semver.dart';

/// Setup options introduced together in a release, shown to updated users.
enum SetupHighlight {
  colorStyle('1.5.0'),
  oledForAuto('1.5.0'),
  nightSchedule('1.5.0'),
  flatSurfaces('1.5.0'),
  nowPlayingBackground('1.5.0'),
  cornerStyle('1.5.0');

  new(this.since);

  /// Release that introduced this setup option.
  final String since;

  /// Stable key stored in the seen-options JSON array.
  String get storageKey => name;
}

/// Newest highlight release at or before [appVersion], ignoring build suffixes.
///
/// Tags survive the next minor release, then expire; a new major also clears
/// them unless it introduces its own highlights.
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
  if (newestParts == null ||
      app.first > newestParts.first ||
      app[1] > newestParts[1] + 1) {
    return null;
  }
  return newest;
}

/// Only the options introduced in [release]; newer releases replace old tags.
Set<SetupHighlight> setupHighlightsFor(String release) => Set.unmodifiable(
  SetupHighlight.values.where((highlight) => highlight.since == release),
);
