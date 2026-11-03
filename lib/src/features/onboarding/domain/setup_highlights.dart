import 'package:navis/src/utils/semver.dart';

/// Setup options introduced together in a release, shown to updated users.
enum SetupHighlight {
  colorStyle('1.5.0'),
  colorTuning('1.5.0'),
  appearanceLooks('1.5.0'),
  oledForAuto('1.5.0'),
  nightSchedule('1.5.0'),
  flatSurfaces('1.5.0'),
  flatAreas('1.5.0'),
  albumArtShade('1.5.0'),
  nowPlayingBackground('1.5.0'),
  cornerStyle('1.5.0'),
  genresPage('1.5.2', standalone: true);

  new(this.since, {this.standalone = false});

  /// Release that introduced this setup option.
  final String since;

  /// A tag on a single option that is not part of a release group: it never
  /// sets [setupWhatsNewRelease], so it does not replace older unseen tags or
  /// create the Home setup card. See [standaloneSetupHighlightsFor].
  final bool standalone;

  /// Stable key stored in the seen-options JSON array.
  String get storageKey =>
      this == albumArtShade ? 'albumArtColoredShade' : name;
}

/// Whether [since]'s tags have expired at [app]: they survive the next minor
/// release, then expire; a new major also clears them.
bool _tagsExpired(List<int> app, List<int> since) =>
    app.first > since.first || app[1] > since[1] + 1;

/// Newest release-group highlight release at or before [appVersion], ignoring
/// build suffixes.
///
/// Tags survive the next minor release, then expire; a new major also clears
/// them unless it introduces its own highlights.
String? setupWhatsNewRelease(String appVersion) {
  final app = parseSemver(appVersion);
  if (app == null) return null;
  String? newest;
  List<int>? newestParts;
  for (final highlight in SetupHighlight.values) {
    if (highlight.standalone) continue;
    final parts = parseSemver(highlight.since)!;
    if (compareSemver(parts, app) > 0) continue;
    if (newestParts == null || compareSemver(parts, newestParts) > 0) {
      newest = highlight.since;
      newestParts = parts;
    }
  }
  if (newestParts == null || _tagsExpired(app, newestParts)) return null;
  return newest;
}

/// Only the options introduced in [release]; newer releases replace old tags.
Set<SetupHighlight> setupHighlightsFor(String release) => Set.unmodifiable(
  SetupHighlight.values.where(
    (highlight) => !highlight.standalone && highlight.since == release,
  ),
);

/// The standalone highlights still inside their tag window at [appVersion].
Set<SetupHighlight> standaloneSetupHighlightsFor(String appVersion) {
  final app = parseSemver(appVersion);
  if (app == null) return const <SetupHighlight>{};
  return Set.unmodifiable(
    SetupHighlight.values.where((highlight) {
      if (!highlight.standalone) return false;
      final since = parseSemver(highlight.since)!;
      return compareSemver(since, app) <= 0 && !_tagsExpired(app, since);
    }),
  );
}
