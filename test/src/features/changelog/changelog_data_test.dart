import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';

List<int> _parts(String version) =>
    version.split('.').map(int.parse).toList(growable: false);

int _compare(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

void main() {
  group('ChangelogVersion', () {
    test('every x.y.0 release is major', () {
      expect(
        const ChangelogVersion(version: '1.4.0', entries: []).isMajor,
        isTrue,
      );
      expect(
        const ChangelogVersion(version: '1.4.1', entries: []).isMajor,
        isFalse,
      );
      expect(
        const ChangelogVersion(version: '2.0.0', entries: []).isMajor,
        isTrue,
      );
      expect(
        const ChangelogVersion(version: 'nightly', entries: []).isMajor,
        isFalse,
      );
    });

    test('display version drops the patch only for majors', () {
      expect(
        const ChangelogVersion(version: '1.4.0', entries: []).displayVersion,
        '1.4',
      );
      expect(
        const ChangelogVersion(version: '1.4.2', entries: []).displayVersion,
        '1.4.2',
      );
      expect(
        const ChangelogVersion(version: '1.4.2', entries: []).series,
        '1.4',
      );
    });
  });

  group('ChangelogEntry platforms', () {
    test('no platforms means every platform', () {
      const entry = ChangelogEntry('a');
      for (final platform in ChangelogPlatform.values) {
        expect(entry.appliesTo(platform), isTrue);
      }
      expect(entry.platformsLabel, isNull);
    });

    test('a tagged entry applies only to its platforms', () {
      const entry = ChangelogEntry(
        'a',
        platforms: {ChangelogPlatform.android, ChangelogPlatform.ios},
      );
      expect(entry.appliesTo(ChangelogPlatform.ios), isTrue);
      expect(entry.appliesTo(ChangelogPlatform.macos), isFalse);
    });

    test('labels read naturally and ignore set order', () {
      String? label(Set<ChangelogPlatform> p) =>
          ChangelogEntry('a', platforms: p).platformsLabel;
      expect(label({ChangelogPlatform.macos}), 'macOS');
      expect(
        label({ChangelogPlatform.ios, ChangelogPlatform.android}),
        'Android and iOS',
      );
      expect(
        label({ChangelogPlatform.linux, ChangelogPlatform.windows}),
        'Windows and Linux',
      );
      expect(
        label({
          ChangelogPlatform.android,
          ChangelogPlatform.ios,
          ChangelogPlatform.linux,
        }),
        'Android, iOS and Linux',
      );
      expect(
        label({
          ChangelogPlatform.linux,
          ChangelogPlatform.macos,
          ChangelogPlatform.windows,
        }),
        'Desktop',
      );
    });
  });

  group('changelogs', () {
    test('no entry text starts with a platform prefix', () {
      const name = '(?:Android|iOS|macOS|Windows|Linux|Desktop)';
      // "Android Auto:" names a feature, so only "<platform>(, | and )...:"
      // counts as a prefix.
      final prefix = RegExp('^$name(?:(?:,| and| &) $name)*:');
      for (final version in changelogs) {
        for (final entry in version.entries) {
          expect(
            entry.text,
            isNot(matches(prefix)),
            reason: '${version.version}: set `platforms` instead of a prefix',
          );
        }
      }
    });

    test('versions are valid, unique and newest first', () {
      final versions = changelogs.map((c) => c.version).toList();
      expect(versions.toSet().length, versions.length);
      for (final version in versions) {
        expect(version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      }
      for (var i = 1; i < versions.length; i++) {
        expect(
          _compare(versions[i - 1], versions[i]),
          greaterThan(0),
          reason: '${versions[i - 1]} must come before ${versions[i]}',
        );
      }
    });

    test('release dates parse and never go backwards', () {
      DateTime? newer;
      for (final version in changelogs) {
        if (version.released == null) continue;
        final date = version.releasedDate;
        expect(date, isNotNull, reason: version.version);
        expect(
          version.released,
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
          reason: version.version,
        );
        if (newer != null) {
          expect(date!.isAfter(newer), isFalse, reason: version.version);
        }
        newer = date;
      }
    });

    test('major releases from 1.2.0 onward have 3 to 5 highlights', () {
      for (final version in changelogs.where((c) => c.isMajor)) {
        if (_compare(version.version, '1.2.0') < 0) continue;
        expect(
          version.highlights.length,
          inInclusiveRange(3, 5),
          reason: '${version.version} needs curated highlights',
        );
        for (final highlight in version.highlights) {
          expect(highlight.title.trim(), isNotEmpty);
          expect(highlight.body.trim(), isNotEmpty);
        }
      }
    });

    test('release icons exist in the declared asset folder', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/changelog/'));
      for (final version in changelogs) {
        final asset = version.iconAsset;
        if (asset == null) continue;
        expect(asset, startsWith('assets/changelog/'), reason: asset);
        expect(
          asset.endsWith('.svg') || asset.endsWith('.png'),
          isTrue,
          reason: '$asset must be an SVG or PNG',
        );
        expect(File(asset).existsSync(), isTrue, reason: '$asset is missing');
      }
    });
  });
}
