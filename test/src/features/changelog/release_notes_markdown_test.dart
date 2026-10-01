import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/release_notes_markdown.dart';

void main() {
  test('renders codename, highlights and grouped sections', () {
    const version = ChangelogVersion(
      version: '9.9.0',
      codename: 'Aurora',
      summary: 'A summary.',
      iconAsset: 'assets/changelog/aurora.svg',
      entries: [
        ChangelogEntry('Fixed a bug', type: ChangelogEntryType.fix),
        ChangelogEntry('Added a feature', type: ChangelogEntryType.newFeature),
        ChangelogEntry('Improved a thing'),
      ],
      highlights: [
        ChangelogHighlight(
          icon: ChangelogHighlightIcon.equalizer,
          title: 'Equalizer',
          body: 'Shape the sound',
        ),
      ],
      specialThanks: ['To a tester.'],
    );

    final markdown = renderReleaseNotes(version);

    expect(markdown, startsWith("## What's New in Navis v9.9.0 “Aurora”"));
    expect(markdown, contains('A summary.'));
    expect(markdown, contains('- **Equalizer:** Shape the sound'));
    expect(markdown, isNot(contains('aurora.svg')));
    final newAt = markdown.indexOf('### New');
    final improvedAt = markdown.indexOf('### Improved');
    final fixedAt = markdown.indexOf('### Fixed');
    expect(newAt, greaterThan(0));
    expect(improvedAt, greaterThan(newAt));
    expect(fixedAt, greaterThan(improvedAt));
    expect(markdown, endsWith('- To a tester.'));
  });

  test('omits empty sections for a plain patch', () {
    const version = ChangelogVersion(
      version: '9.9.1',
      entries: [ChangelogEntry('Fixed a bug', type: ChangelogEntryType.fix)],
    );

    final markdown = renderReleaseNotes(version);

    expect(markdown, startsWith("## What's New in Navis v9.9.1\n"));
    expect(markdown, isNot(contains('### Highlights')));
    expect(markdown, isNot(contains('### New')));
    expect(markdown, contains('### Fixed\n\n- Fixed a bug'));
  });

  test('every shipped version renders', () {
    for (final version in changelogs) {
      expect(renderReleaseNotes(version), isNotEmpty);
    }
  });

  test('CLI prints the current release and rejects unknown versions', () {
    final dart = Platform.resolvedExecutable.endsWith('dart')
        ? Platform.resolvedExecutable
        : 'dart';
    final ok = Process.runSync(dart, <String>[
      'tool/generate_release_notes.dart',
      'v${changelogs.first.version}',
    ]);
    expect(ok.exitCode, 0, reason: '${ok.stderr}');
    expect(
      ok.stdout as String,
      startsWith("## What's New in Navis v${changelogs.first.version}"),
    );

    final missing = Process.runSync(dart, <String>[
      'tool/generate_release_notes.dart',
      'v0.0.0',
    ]);
    expect(missing.exitCode, 2);
  });
}
