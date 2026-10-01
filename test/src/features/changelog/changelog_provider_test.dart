import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';

const _versions = <ChangelogVersion>[
  ChangelogVersion(version: '1.4.1', entries: []),
  ChangelogVersion(version: '1.4.0', entries: [], codename: 'Navi'),
  ChangelogVersion(version: '1.3.1', entries: []),
  ChangelogVersion(version: '1.3.0', entries: []),
];

void main() {
  test('nothing to show once the running version was seen', () {
    expect(
      resolveChangelogDiscovery(
        versions: _versions,
        currentVersion: '1.4.1',
        lastSeen: '1.4.1',
      ),
      isNull,
    );
  });

  test('nothing to show for a version without a changelog', () {
    expect(
      resolveChangelogDiscovery(
        versions: _versions,
        currentVersion: '1.5.0',
        lastSeen: '1.4.1',
      ),
      isNull,
    );
  });

  test('a major update features itself', () {
    final discovery = resolveChangelogDiscovery(
      versions: _versions,
      currentVersion: '1.4.0',
      lastSeen: '1.3.1',
    )!;
    expect(discovery.current.version, '1.4.0');
    expect(discovery.featured?.version, '1.4.0');
  });

  test('skipping past a major release still features it', () {
    final discovery = resolveChangelogDiscovery(
      versions: _versions,
      currentVersion: '1.4.1',
      lastSeen: '1.3.1',
    )!;
    expect(discovery.current.version, '1.4.1');
    expect(discovery.featured?.version, '1.4.0');
    expect(discovery.seenVersion, '1.4.1');
  });

  test('a patch after a seen major has no featured release', () {
    final discovery = resolveChangelogDiscovery(
      versions: _versions,
      currentVersion: '1.4.1',
      lastSeen: '1.4.0',
    )!;
    expect(discovery.current.version, '1.4.1');
    expect(discovery.featured, isNull);
  });

  test('a missing or malformed marker features the latest major', () {
    for (final lastSeen in <String?>[null, 'garbage']) {
      final discovery = resolveChangelogDiscovery(
        versions: _versions,
        currentVersion: '1.4.1',
        lastSeen: lastSeen,
      )!;
      expect(discovery.featured?.version, '1.4.0', reason: '$lastSeen');
    }
  });

  test('a downgrade features nothing newer than the running version', () {
    final discovery = resolveChangelogDiscovery(
      versions: _versions,
      currentVersion: '1.3.1',
      lastSeen: '1.4.1',
    )!;
    expect(discovery.current.version, '1.3.1');
    expect(discovery.featured, isNull);
  });
}
