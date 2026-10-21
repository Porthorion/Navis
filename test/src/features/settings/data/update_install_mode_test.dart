import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';

void main() {
  test('portable paths never query package managers', () {
    for (final path in ['/home/user/navis/navis', '/opt/navis-other/navis']) {
      expect(
        detectLinuxPackageMode(path, (_, _) => fail('Unexpected query')),
        UpdateInstallMode.linuxPortable,
      );
    }
  });

  test('dpkg ownership selects deb and queries the canonical binary', () {
    expect(
      detectLinuxPackageMode('/opt/navis/navis', (exe, args) {
        expect(exe, 'dpkg-query');
        expect(args, ['-S', '/opt/navis/navis']);
        return ProcessResult(1, 0, '', '');
      }),
      UpdateInstallMode.linuxDeb,
    );
  });

  for (final missingDpkg in [false, true]) {
    test('rpm ownership selects rpm with missing dpkg=$missingDpkg', () {
      final calls = <String>[];
      final mode = detectLinuxPackageMode('/opt/navis/navis', (exe, args) {
        calls.add(exe);
        if (exe == 'dpkg-query') {
          if (missingDpkg) throw ProcessException(exe, args);
          return ProcessResult(1, 1, '', '');
        }
        expect(exe, 'rpm');
        expect(args, ['-qf', '/opt/navis/navis']);
        return ProcessResult(1, 0, '', '');
      });
      expect(calls, ['dpkg-query', 'rpm']);
      expect(mode, UpdateInstallMode.linuxRpm);
    });
  }

  for (final missing in [false, true]) {
    test('unknown ownership stays package managed with missing=$missing', () {
      expect(
        detectLinuxPackageMode('/opt/navis/navis', (exe, args) {
          if (missing) throw ProcessException(exe, args);
          return ProcessResult(1, 1, '', '');
        }),
        UpdateInstallMode.linuxPackageManaged,
      );
    });
  }

  test('only Linux package modes are system package modes', () {
    for (final mode in UpdateInstallMode.values) {
      expect(
        isLinuxSystemPackageMode(mode),
        [
          UpdateInstallMode.linuxDeb,
          UpdateInstallMode.linuxRpm,
          UpdateInstallMode.linuxPackageManaged,
        ].contains(mode),
      );
    }
  });
}
