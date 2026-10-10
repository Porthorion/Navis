import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';

void main() {
  test(
    'picks the newest eligible setup release and ignores build suffixes',
    () {
      expect(setupWhatsNewRelease('1.4.9'), isNull);
      expect(setupWhatsNewRelease('1.5.0'), '1.5.0');
      expect(setupWhatsNewRelease('1.5.0+10500'), '1.5.0');
      expect(setupWhatsNewRelease('1.5.0-sidecar'), '1.5.0');
      expect(setupWhatsNewRelease('1.5.10'), '1.5.0');
      expect(setupWhatsNewRelease('1.6.0'), '1.5.0');
      expect(setupWhatsNewRelease('1.6.9+10609'), '1.5.0');
      expect(setupWhatsNewRelease('1.7.0'), isNull);
      expect(setupWhatsNewRelease('1.7.0-sidecar'), isNull);
      expect(setupWhatsNewRelease('invalid'), isNull);
    },
  );

  test('a new major without highlights clears the older release', () {
    expect(setupWhatsNewRelease('2.0.0'), isNull);
    expect(setupWhatsNewRelease('2.0.0+20000'), isNull);
  });

  test('background and corner style are introduced in 1.5.0', () {
    expect(SetupHighlight.nowPlayingBackground.since, '1.5.0');
    expect(SetupHighlight.cornerStyle.since, '1.5.0');
    expect(SetupHighlight.flatAreas.since, '1.5.0');
    expect(SetupHighlight.albumArtColoredShade.since, '1.5.0');
    expect(
      setupHighlightsFor('1.5.0'),
      containsAll([
        SetupHighlight.nowPlayingBackground,
        SetupHighlight.cornerStyle,
      ]),
    );
  });

  test('release groups replace old highlights rather than accumulating', () {
    expect(setupHighlightsFor('1.5.0'), SetupHighlight.values.toSet());
    // A replacement release returns only its own group, never the older group.
    expect(setupHighlightsFor('1.6.0'), isEmpty);
    for (final release in SetupHighlight.values.map((h) => h.since).toSet()) {
      expect(
        setupHighlightsFor(release),
        SetupHighlight.values.where((h) => h.since == release).toSet(),
      );
    }
  });

  test('shared semver helpers compare numeric versions and build suffixes', () {
    expect(parseSemver(null), isNull);
    expect(parseSemver('1.4'), isNull);
    expect(parseSemver('1.4.x'), isNull);
    expect(parseSemver('1.4.3+10403'), [1, 4, 3]);
    expect(parseSemver('1.4.3-sidecar'), [1, 4, 3]);
    expect(
      compareSemver(parseSemver('1.4.10')!, parseSemver('1.4.3')!),
      greaterThan(0),
    );
    expect(compareSemver(parseSemver('1.4.3+2')!, parseSemver('1.4.3')!), 0);
  });
}
